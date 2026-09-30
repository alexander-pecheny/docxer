import Foundation

/// A minimal, non-validating XML scanner that keeps byte offsets for every node,
/// so callers can copy untouched elements verbatim.
public final class XDoc {
    public struct Node {
        public var name: Int32           // interned name, or -1 for text
        public var start: Int32          // outer range
        public var end: Int32
        var contentStart: Int32
        var contentEnd: Int32
        var attrStart: Int32
        var attrEnd: Int32
        public var parent: Int32
        public var firstChild: Int32 = -1
        public var nextSibling: Int32 = -1
    }

    public let bytes: [UInt8]
    public private(set) var nodes: [Node] = []
    public private(set) var root: Int32 = -1
    private var names: [String] = []
    private var nameIDs: [UInt64: Int32] = [:]

    public init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        nodes.reserveCapacity(bytes.count / 24)
        try bytes.withUnsafeBufferPointer { try scan($0) }
    }

    public convenience init(string: String) throws { try self.init(Array(string.utf8)) }

    public func id(_ name: String) -> Int32 {
        nameIDs[hash(Array(name.utf8)[...])] ?? -2
    }

    public func name(_ i: Int32) -> String { nodes[Int(i)].name < 0 ? "#text" : names[Int(nodes[Int(i)].name)] }
    public func isText(_ i: Int32) -> Bool { nodes[Int(i)].name == -1 }

    public func children(_ i: Int32) -> ChildSequence { ChildSequence(doc: self, cursor: nodes[Int(i)].firstChild) }

    public func child(_ i: Int32, _ nameID: Int32) -> Int32? {
        var c = nodes[Int(i)].firstChild
        while c >= 0 { if nodes[Int(c)].name == nameID { return c }; c = nodes[Int(c)].nextSibling }
        return nil
    }

    /// First descendant with the given name; nodes are stored in document order.
    public func descendant(_ i: Int32, _ name: String) -> Int32? {
        let id = self.id(name)
        guard id >= 0 else { return nil }
        let end = nodes[Int(i)].end
        var k = Int(i) + 1
        while k < nodes.count, nodes[k].start < end {
            if nodes[k].name == id { return Int32(k) }
            k += 1
        }
        return nil
    }

    public func raw(_ i: Int32) -> ArraySlice<UInt8> { bytes[Int(nodes[Int(i)].start) ..< Int(nodes[Int(i)].end)] }
    public func inner(_ i: Int32) -> ArraySlice<UInt8> {
        bytes[Int(nodes[Int(i)].contentStart) ..< Int(nodes[Int(i)].contentEnd)]
    }
    /// The start tag up to but excluding its `>` or `/>`, e.g. `<w:p w14:paraId=".."`.
    public func openTag(_ i: Int32) -> ArraySlice<UInt8> {
        bytes[Int(nodes[Int(i)].start) ..< Int(nodes[Int(i)].attrEnd)]
    }

    public func attr(_ i: Int32, _ name: String) -> String? {
        let n = nodes[Int(i)]
        guard n.name >= 0 else { return nil }
        let key = Array(name.utf8)
        var p = Int(n.attrStart)
        let end = Int(n.attrEnd)
        while p < end {
            while p < end, isSpace(bytes[p]) { p += 1 }
            let ks = p
            while p < end, bytes[p] != 0x3D, !isSpace(bytes[p]) { p += 1 }
            let ke = p
            while p < end, bytes[p] != 0x22, bytes[p] != 0x27 { p += 1 }
            guard p < end else { break }
            let q = bytes[p]; p += 1
            let vs = p
            while p < end, bytes[p] != q { p += 1 }
            if ke - ks == key.count, bytes[ks ..< ke].elementsEqual(key) {
                return decodeEntities(bytes[vs ..< p])
            }
            p += 1
        }
        return nil
    }

    /// Decoded text content of all descendant text nodes.
    public func text(_ i: Int32) -> String {
        if isText(i) { return decodeEntities(inner(i)) }
        var s = ""
        for c in children(i) { s += text(c) }
        return s
    }

    public struct ChildSequence: Sequence, IteratorProtocol {
        let doc: XDoc
        var cursor: Int32
        public mutating func next() -> Int32? {
            guard cursor >= 0 else { return nil }
            defer { cursor = doc.nodes[Int(cursor)].nextSibling }
            return cursor
        }
    }

    // MARK: scanning

    private func hash(_ b: ArraySlice<UInt8>) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for c in b { h = (h ^ UInt64(c)) &* 0x100_0000_01b3 }
        return h
    }

    private func intern(_ b: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int) -> Int32 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for k in s ..< e { h = (h ^ UInt64(b[k])) &* 0x100_0000_01b3 }
        if let id = nameIDs[h] { return id }
        let id = Int32(names.count)
        names.append(String(decoding: UnsafeBufferPointer(rebasing: b[s ..< e]), as: UTF8.self))
        nameIDs[h] = id
        return id
    }

    private func scan(_ b: UnsafeBufferPointer<UInt8>) throws {
        var stack: [Int32] = []
        var lastChild: [Int32] = []
        let n = b.count
        var p = 0

        func add(_ node: Node) -> Int32 {
            let i = Int32(nodes.count)
            nodes.append(node)
            if let parent = stack.last {
                let lc = lastChild[lastChild.count - 1]
                if lc < 0 { nodes[Int(parent)].firstChild = i } else { nodes[Int(lc)].nextSibling = i }
                lastChild[lastChild.count - 1] = i
            }
            return i
        }

        func find(_ a: UInt8, _ c: UInt8, from: Int) -> Int {
            var q = from
            while q + 1 < n, !(b[q] == a && b[q + 1] == c) { q += 1 }
            return q
        }

        while p < n {
            if b[p] != 0x3C {
                let s = p
                while p < n, b[p] != 0x3C { p += 1 }
                if let parent = stack.last {
                    var blank = true
                    for k in s ..< p where !isSpace(b[k]) { blank = false; break }
                    if !blank || keepsWhitespace(parent) {
                        _ = add(Node(name: -1, start: Int32(s), end: Int32(p), contentStart: Int32(s), contentEnd: Int32(p),
                                     attrStart: 0, attrEnd: 0, parent: parent))
                    }
                }
                continue
            }
            guard p + 1 < n else { break }
            switch b[p + 1] {
            case 0x3F: // <?
                p = find(0x3F, 0x3E, from: p + 2) + 2
            case 0x21: // <!
                if p + 3 < n, b[p + 2] == 0x2D, b[p + 3] == 0x2D {
                    var q = p + 4
                    while q + 2 < n, !(b[q] == 0x2D && b[q + 1] == 0x2D && b[q + 2] == 0x3E) { q += 1 }
                    p = q + 3
                } else if p + 8 < n, b[p + 2] == 0x5B { // <![CDATA[
                    var q = p + 9
                    while q + 2 < n, !(b[q] == 0x5D && b[q + 1] == 0x5D && b[q + 2] == 0x3E) { q += 1 }
                    if let parent = stack.last {
                        _ = add(Node(name: -1, start: Int32(p), end: Int32(q + 3), contentStart: Int32(p + 9), contentEnd: Int32(q),
                                     attrStart: 0, attrEnd: 0, parent: parent))
                    }
                    p = q + 3
                } else {
                    while p < n, b[p] != 0x3E { p += 1 }
                    p += 1
                }
            case 0x2F: // </
                var q = p + 2
                while q < n, b[q] != 0x3E { q += 1 }
                guard let top = stack.popLast() else { throw XMLError.malformed(p) }
                lastChild.removeLast()
                nodes[Int(top)].contentEnd = Int32(p)
                nodes[Int(top)].end = Int32(q + 1)
                p = q + 1
            default:
                let s = p
                var q = p + 1
                while q < n, !isSpace(b[q]), b[q] != 0x3E, b[q] != 0x2F { q += 1 }
                let nameID = intern(b, p + 1, q)
                let attrStart = q
                var quote: UInt8 = 0
                while q < n {
                    let c = b[q]
                    if quote != 0 { if c == quote { quote = 0 } } else if c == 0x22 || c == 0x27 { quote = c } else if c == 0x3E { break }
                    q += 1
                }
                guard q < n else { throw XMLError.malformed(s) }
                let selfClosing = b[q - 1] == 0x2F
                let attrEnd = selfClosing ? q - 1 : q
                let node = Node(name: nameID, start: Int32(s), end: Int32(q + 1), contentStart: Int32(q + 1), contentEnd: Int32(q + 1),
                                attrStart: Int32(attrStart), attrEnd: Int32(attrEnd), parent: stack.last ?? -1)
                let i = add(node)
                if root < 0 { root = i }
                if !selfClosing { stack.append(i); lastChild.append(-1) }
                p = q + 1
            }
        }
        guard stack.isEmpty, root >= 0 else { throw XMLError.malformed(n) }
    }

    private let textKeeperNames: Set<String> = ["w:t", "w:delText", "w:instrText", "w:delInstrText", "m:t", "a:t"]
    private var keeperCache: [Int32: Bool] = [:]
    private func keepsWhitespace(_ parent: Int32) -> Bool {
        let nm = nodes[Int(parent)].name
        if let k = keeperCache[nm] { return k }
        let k = textKeeperNames.contains(names[Int(nm)])
        keeperCache[nm] = k
        return k
    }
}

public enum XMLError: Error { case malformed(Int) }

@inline(__always) func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 }

public func decodeEntities(_ s: ArraySlice<UInt8>) -> String {
    guard s.contains(0x26) else { return String(decoding: s, as: UTF8.self) }
    var out: [UInt8] = []
    out.reserveCapacity(s.count)
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        guard c == 0x26, let semi = s[i...].prefix(12).firstIndex(of: 0x3B) else { out.append(c); i += 1; continue }
        let ent = String(decoding: s[(i + 1) ..< semi], as: UTF8.self)
        var scalar: UInt32?
        switch ent {
        case "amp": scalar = 0x26
        case "lt": scalar = 0x3C
        case "gt": scalar = 0x3E
        case "quot": scalar = 0x22
        case "apos": scalar = 0x27
        default:
            if ent.hasPrefix("#x") { scalar = UInt32(ent.dropFirst(2), radix: 16) } else if ent.hasPrefix("#") { scalar = UInt32(ent.dropFirst()) }
        }
        if let v = scalar, let u = Unicode.Scalar(v) {
            out.append(contentsOf: Array(String(Character(u)).utf8))
            i = semi + 1
        } else {
            out.append(c); i += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

public func escapeXML(_ s: String, attribute: Bool = false) -> String {
    var needs = false
    for u in s.utf8 where u == 0x26 || u == 0x3C || u == 0x3E || (attribute && u == 0x22) || u < 0x20 { needs = true; break }
    guard needs else { return s }
    var out = ""
    out.reserveCapacity(s.utf8.count + 16)
    for ch in s.unicodeScalars {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"" where attribute: out += "&quot;"
        case "\t", "\n", "\r": out.unicodeScalars.append(ch)
        default:
            if ch.value < 0x20 { continue } // not allowed in XML 1.0
            out.unicodeScalars.append(ch)
        }
    }
    return out
}
