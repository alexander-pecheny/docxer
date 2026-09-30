import DocxCore
import Foundation

// Usage: docx-bench bench|roundtrip [--out DIR] files...
var args = Array(CommandLine.arguments.dropFirst())
let mode = args.removeFirst()
var outDir: String?
if let i = args.firstIndex(of: "--out") { outDir = args[i + 1]; args.removeSubrange(i ... i + 1) }

func ms(_ t: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(t) * 1000) }

func text(_ s: NSAttributedString) -> String {
    // Sealed characters compare by their display text.
    var out = ""
    s.enumerateAttribute(.docxSealed, in: NSRange(location: 0, length: s.length)) { v, r, _ in
        if let v = v as? Sealed { out += "[" + v.plainText + "]" } else { out += (s.string as NSString).substring(with: r) }
    }
    return out
}

var failures = 0, skipped = 0
for (n, path) in args.enumerated() {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else { skipped += 1; continue }
    let original = [UInt8](data)
    do {
        let t0 = Date()
        let doc = try WordDocument(bytes: original)
        let s = doc.load(styler: nil)
        let loadMs = ms(t0)
        switch mode {
        case "edit1":
            s.replaceCharacters(in: NSRange(location: 10, length: 0), with: "x")
            doc.normalize(s, editedRange: NSRange(location: 10, length: 1))
            let t1 = Date()
            var out = doc.save(s)
            if ProcessInfo.processInfo.environment["DOCX_REPEAT"] != nil { for _ in 0 ..< 20 { out = doc.save(s) } }
            print(doc.rawStats(s)); print("\(ms(t1))ms save after one edit, \(out.count) bytes")
        case "edits":
            // Deterministic edits spread through the document: typing, a cross-paragraph delete,
            // bold, a heading, a list, a comment with a reply.
            var seed = UInt64(truncatingIfNeeded: path.hashValue) | 1
            func rnd(_ n: Int) -> Int { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return n > 0 ? Int(seed % UInt64(n)) : 0 }
            func edit(_ r: NSRange, _ t: String) {
                guard NSMaxRange(r) <= s.length, doc.allowsEdit(s, range: r, replacement: t) else { return }
                let from = max(0, r.location - 1)
                let a = s.length > 0 ? WordDocument.typingAttributes(s.attributes(at: min(from, s.length - 1), effectiveRange: nil)) : [:]
                s.replaceCharacters(in: r, with: NSAttributedString(string: t, attributes: a))
                doc.normalize(s, editedRange: NSRange(location: r.location, length: (t as NSString).length))
            }
            for _ in 0 ..< 5 { edit(NSRange(location: rnd(s.length), length: 0), "ред & <x> ") }
            edit(NSRange(location: rnd(s.length), length: 0), "\n")
            let d0 = rnd(max(1, s.length - 200)); edit(NSRange(location: d0, length: min(120, s.length - d0 - 1)), "")
            let b0 = rnd(max(1, s.length - 50)); doc.toggle(.bold, in: s, range: NSRange(location: b0, length: min(30, s.length - b0 - 1)))
            if let h = doc.styles.styles.keys.first(where: { doc.styles.headingLevel($0) == 1 }) {
                doc.setStyle(h, in: s, range: NSRange(location: rnd(s.length - 1), length: 0))
            }
            doc.toggleList(bullet: rnd(2) == 0, in: s, range: NSRange(location: rnd(s.length - 1), length: 0))
            let c0 = rnd(max(1, s.length - 30))
            let c = doc.addComment("Проверка", author: "Tester", initials: "T", in: s, range: NSRange(location: c0, length: min(10, s.length - c0 - 1)))
            doc.reply(to: c, "Ответ", author: "Tester", initials: "T", in: s)
            doc.comments.setDone(c, true)
            let bytes = doc.save(s)
            let again = try WordDocument(bytes: bytes)
            let s2 = again.load(styler: nil)
            if text(s) != text(s2) {
                let a = Array(text(s)), b = Array(text(s2))
                let k = zip(a, b).prefix { $0 == $1 }.count
                print("FAIL edited text \(path) at \(k)/\(a.count)/\(b.count)\n  had \(String(a[max(0, k - 60) ..< min(a.count, k + 60)]).debugDescription)\n  got \(String(b[max(0, k - 60) ..< min(b.count, k + 60)]).debugDescription)")
                failures += 1
            }
            if let outDir {
                try Data(bytes).write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(n).docx"))
                try data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(n).orig.docx"))
            }
        case "bench":
            let t1 = Date()
            doc.markAllEdited(s)
            _ = doc.save(s)
            print("\(loadMs)ms load, \(ms(t1))ms save, \(s.length) chars  \(path)")
        default:
            if doc.save(s) != original { print("FAIL identity \(path)"); failures += 1; continue }
            // With nothing edited, the verbatim path must reproduce the body exactly, give or take inter-tag whitespace.
            doc.touchBody()
            let copied = try WordDocument(bytes: doc.save(s)).package.part(doc.package.mainPath)!
            let squash = { (b: [UInt8]) in String(decoding: b, as: UTF8.self).replacingOccurrences(of: #">\s+<"#, with: "><", options: .regularExpression) }
            if squash(copied) != squash(try WordDocument(bytes: original).package.part(doc.package.mainPath)!) {
                let a = Array(squash(copied)), b = Array(squash(try WordDocument(bytes: original).package.part(doc.package.mainPath)!))
                let k = zip(a, b).prefix { $0 == $1 }.count
                print("FAIL verbatim \(path)\n  got  \(String(a[max(0, k - 150) ..< min(a.count, k + 150)]))\n  want \(String(b[max(0, k - 150) ..< min(b.count, k + 150)]))")
                failures += 1
            }
            doc.markAllEdited(s)
            let bytes = doc.save(s)
            let again = try WordDocument(bytes: bytes)
            let s2 = again.load(styler: nil)
            if text(s) != text(s2) {
                let a = Array(text(s)), b = Array(text(s2))
                let k = zip(a, b).prefix { $0 == $1 }.count
                print("FAIL text \(path) at \(k): \(String(a[max(0, k - 20) ..< min(a.count, k + 40)]).debugDescription) vs \(String(b[max(0, k - 20) ..< min(b.count, k + 40)]).debugDescription)")
                failures += 1
            } else if Set(doc.comments.comments.map(\.id)) != Set(again.comments.comments.map(\.id)) {
                print("FAIL comments \(path)"); failures += 1
            }
            if let outDir {
                try Data(bytes).write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(n).docx"))
                try data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(n).orig.docx"))
            }
        }
    } catch {
        print("ERROR \(error) \(path)")
        failures += 1
    }
}
print("\(args.count - skipped) files checked, \(skipped) unreadable, \(failures) failures")
