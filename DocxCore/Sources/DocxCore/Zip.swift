import Foundation
import zlib

public enum ZipError: Error {
    case notAZip, unsupported(String), corrupt(String)
}

public struct ZipEntry {
    public let name: String
    let method: UInt16
    let crc: UInt32
    let compressedSize: Int
    let size: Int
    let localOffset: Int
    let centralRecord: Range<Int>
    var dataOffset: Int
    var spanEnd: Int
}

/// Read-only view of a zip archive held in memory.
public final class ZipArchive {
    public let bytes: [UInt8]
    public private(set) var entries: [ZipEntry] = []
    private var index: [String: Int] = [:]

    public init(bytes: [UInt8]) throws {
        self.bytes = bytes
        try parse()
    }

    public func entry(_ name: String) -> ZipEntry? { index[name].map { entries[$0] } }

    public func read(_ name: String) throws -> [UInt8]? {
        guard let e = entry(name) else { return nil }
        return try read(e)
    }

    public func read(_ e: ZipEntry) throws -> [UInt8] {
        let raw = bytes[e.dataOffset ..< e.dataOffset + e.compressedSize]
        switch e.method {
        case 0: return Array(raw)
        case 8: return try inflate(raw, size: e.size)
        default: throw ZipError.unsupported("compression method \(e.method)")
        }
    }

    private func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
    private func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

    private func parse() throws {
        guard bytes.count >= 22 else { throw ZipError.notAZip }
        var eocd = -1
        var i = bytes.count - 22
        let floor = max(0, bytes.count - 65557)
        while i >= floor {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 5, bytes[i + 3] == 6 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = u16(eocd + 10), cdSize = u32(eocd + 12), cdOffset = u32(eocd + 16)
        if cdOffset == 0xFFFF_FFFF || count == 0xFFFF { throw ZipError.unsupported("zip64") }
        guard cdOffset + cdSize <= bytes.count else { throw ZipError.corrupt("central directory") }
        var p = cdOffset
        for _ in 0 ..< count {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4b50 else { throw ZipError.corrupt("central record") }
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let name = String(decoding: bytes[p + 46 ..< p + 46 + nameLen], as: UTF8.self)
            let local = u32(p + 42)
            guard local + 30 <= bytes.count, u32(local) == 0x0403_4b50 else { throw ZipError.corrupt("local header \(name)") }
            let end = p + 46 + nameLen + extraLen + commentLen
            let e = ZipEntry(name: name, method: UInt16(u16(p + 10)), crc: UInt32(u32(p + 16)),
                             compressedSize: u32(p + 20), size: u32(p + 24), localOffset: local,
                             centralRecord: p ..< end, dataOffset: local + 30 + u16(local + 26) + u16(local + 28), spanEnd: 0)
            index[name] = entries.count
            entries.append(e)
            p = end
        }
        // Each entry's raw span runs to the next local header, so data descriptors are copied along with it.
        let starts = entries.map(\.localOffset).sorted() + [cdOffset]
        for k in entries.indices {
            let s = entries[k].localOffset
            var lo = 0, hi = starts.count - 1
            while lo < hi { let m = (lo + hi) / 2; if starts[m] <= s { lo = m + 1 } else { hi = m } }
            entries[k].spanEnd = starts[lo]
        }
    }
}

func inflate(_ raw: ArraySlice<UInt8>, size: Int) throws -> [UInt8] {
    var out = [UInt8](repeating: 0, count: max(size, 1))
    var s = z_stream()
    guard inflateInit2_(&s, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZipError.corrupt("inflate init") }
    defer { inflateEnd(&s) }
    let rc: Int32 = raw.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            s.next_in = UnsafeMutablePointer(mutating: src.baseAddress)
            s.avail_in = UInt32(src.count)
            s.next_out = dst.baseAddress
            s.avail_out = UInt32(dst.count)
            return zlib.inflate(&s, Z_FINISH)
        }
    }
    guard rc == Z_STREAM_END else { throw ZipError.corrupt("inflate \(rc)") }
    out.removeLast(out.count - Int(s.total_out))
    return out
}

func deflate(_ data: [UInt8]) -> [UInt8] {
    var s = z_stream()
    // Large parts favour speed: level 1 is 4x faster for about 30% more bytes.
    deflateInit2_(&s, data.count > 2 << 20 ? 1 : 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
    defer { deflateEnd(&s) }
    var out = [UInt8](repeating: 0, count: Int(deflateBound(&s, UInt(data.count))) + 16)
    data.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            s.next_in = UnsafeMutablePointer(mutating: src.baseAddress)
            s.avail_in = UInt32(src.count)
            s.next_out = dst.baseAddress
            s.avail_out = UInt32(dst.count)
            _ = zlib.deflate(&s, Z_FINISH)
        }
    }
    out.removeLast(out.count - Int(s.total_out))
    return out
}

func crc(_ data: [UInt8]) -> UInt32 {
    data.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, UInt32($0.count))) }
}

/// Writes a new archive, copying untouched entries from the source byte for byte.
public struct ZipWriter {
    public enum Item {
        case copy(ZipEntry)
        case data(String, [UInt8])
    }

    public static func write(_ items: [Item], source: ZipArchive?) -> [UInt8] {
        var out: [UInt8] = []
        var central: [UInt8] = []
        out.reserveCapacity(source?.bytes.count ?? 1 << 16)
        let (time, date) = dosNow()
        for item in items {
            let offset = out.count
            switch item {
            case .copy(let e):
                let src = source!.bytes
                out.append(contentsOf: src[e.localOffset ..< e.spanEnd])
                var rec = Array(src[e.centralRecord])
                put32(&rec, 42, UInt32(offset))
                central.append(contentsOf: rec)
            case .data(let name, let data):
                let packed = deflate(data)
                let (method, body): (UInt16, [UInt8]) = packed.count < data.count ? (8, packed) : (0, data)
                let sum = crc(data), nameBytes = Array(name.utf8)
                var h: [UInt8] = []
                h32(&h, 0x0403_4b50); h16(&h, 20); h16(&h, 0x0800); h16(&h, method); h16(&h, time); h16(&h, date)
                h32(&h, sum); h32(&h, UInt32(body.count)); h32(&h, UInt32(data.count)); h16(&h, UInt16(nameBytes.count)); h16(&h, 0)
                out.append(contentsOf: h); out.append(contentsOf: nameBytes); out.append(contentsOf: body)
                var c: [UInt8] = []
                h32(&c, 0x0201_4b50); h16(&c, 20); h16(&c, 20); h16(&c, 0x0800); h16(&c, method); h16(&c, time); h16(&c, date)
                h32(&c, sum); h32(&c, UInt32(body.count)); h32(&c, UInt32(data.count)); h16(&c, UInt16(nameBytes.count))
                h16(&c, 0); h16(&c, 0); h16(&c, 0); h16(&c, 0); h32(&c, 0); h32(&c, UInt32(offset))
                central.append(contentsOf: c); central.append(contentsOf: nameBytes)
            }
        }
        let cdOffset = out.count
        out.append(contentsOf: central)
        var e: [UInt8] = []
        h32(&e, 0x0605_4b50); h16(&e, 0); h16(&e, 0); h16(&e, UInt16(items.count)); h16(&e, UInt16(items.count))
        h32(&e, UInt32(central.count)); h32(&e, UInt32(cdOffset)); h16(&e, 0)
        out.append(contentsOf: e)
        return out
    }

    private static func h16(_ a: inout [UInt8], _ v: UInt16) { a.append(UInt8(v & 0xff)); a.append(UInt8(v >> 8)) }
    private static func h32(_ a: inout [UInt8], _ v: UInt32) { h16(&a, UInt16(v & 0xffff)); h16(&a, UInt16(v >> 16)) }
    private static func put32(_ a: inout [UInt8], _ o: Int, _ v: UInt32) {
        for k in 0 ..< 4 { a[o + k] = UInt8((v >> (8 * UInt32(k))) & 0xff) }
    }

    private static func dosNow() -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let t = UInt16(c.hour! << 11 | c.minute! << 5 | c.second! / 2)
        let d = UInt16((c.year! - 1980) << 9 | c.month! << 5 | c.day!)
        return (t, d)
    }
}
