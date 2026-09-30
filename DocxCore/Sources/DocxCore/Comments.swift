import Foundation

public final class Comment {
    public let id: Int
    public internal(set) var author: String
    public internal(set) var initials: String
    public internal(set) var date: String
    public internal(set) var text: String
    public internal(set) var paraId: String?
    public internal(set) var parentParaId: String?
    public internal(set) var done: Bool
    /// Original `<w:comment>` XML while unedited.
    var xml: String?

    init(id: Int, author: String, initials: String, date: String, text: String, paraId: String?, xml: String?) {
        self.id = id; self.author = author; self.initials = initials; self.date = date; self.text = text
        self.paraId = paraId; self.xml = xml; done = false
    }

    public var dateValue: Date? { ISO8601DateFormatter().date(from: date) }
}

let ns = (
    w: "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    w14: "http://schemas.microsoft.com/office/word/2010/wordml",
    w15: "http://schemas.microsoft.com/office/word/2012/wordml",
    mc: "http://schemas.openxmlformats.org/markup-compatibility/2006"
)

public final class CommentStore {
    public private(set) var comments: [Comment] = []
    private var byId: [Int: Comment] = [:]
    public private(set) var changed = false
    private let package: DocxPackage
    private var usedParaIds = Set<String>()

    static let commentsType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"
    static let extendedType = "http://schemas.microsoft.com/office/2011/relationships/commentsExtended"

    init(package: DocxPackage) {
        self.package = package
        guard let path = package.partPath(forType: "/comments"), let bytes = package.part(path), let x = try? XDoc(bytes) else { return }
        for c in x.children(x.root) where x.name(c) == "w:comment" {
            guard let id = x.attr(c, "w:id").flatMap(Int.init) else { continue }
            let paras = x.children(c).filter { x.name($0) == "w:p" }
            let text = paras.map { visibleText(x, $0) }.joined(separator: "\n")
            let pid = paras.last.flatMap { x.attr($0, "w14:paraId") }
            let cm = Comment(id: id, author: x.attr(c, "w:author") ?? "", initials: x.attr(c, "w:initials") ?? "",
                             date: x.attr(c, "w:date") ?? "", text: text, paraId: pid, xml: String(decoding: x.raw(c), as: UTF8.self))
            comments.append(cm)
            byId[id] = cm
            if let pid { usedParaIds.insert(pid) }
        }
        if let path = package.partPath(forType: "/commentsExtended"), let bytes = package.part(path), let x = try? XDoc(bytes) {
            var byPara: [String: Comment] = [:]
            for c in comments { if let p = c.paraId { byPara[p] = c } }
            for e in x.children(x.root) where x.name(e) == "w15:commentEx" {
                guard let p = x.attr(e, "w15:paraId"), let c = byPara[p] else { continue }
                c.parentParaId = x.attr(e, "w15:paraIdParent")
                c.done = x.attr(e, "w15:done") == "1"
            }
        }
    }

    public subscript(id: Int) -> Comment? { byId[id] }

    public func parent(of c: Comment) -> Comment? {
        guard let p = c.parentParaId else { return nil }
        return comments.first { $0.paraId == p }
    }

    public func replies(to c: Comment) -> [Comment] {
        guard let p = c.paraId else { return [] }
        return comments.filter { $0.parentParaId == p }
    }

    private func newParaId() -> String {
        while true {
            let v = String(format: "%08X", UInt32.random(in: 1 ..< 0x7FFF_FFFF))
            if usedParaIds.insert(v).inserted { return v }
        }
    }

    private func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    @discardableResult
    public func add(text: String, author: String, initials: String, replyingTo parent: Comment? = nil) -> Comment {
        let id = (comments.map(\.id).max() ?? -1) + 1
        let c = Comment(id: id, author: author, initials: initials, date: now(), text: text, paraId: newParaId(), xml: nil)
        if let parent {
            ensureParaId(parent)
            c.parentParaId = parent.paraId
        }
        comments.append(c)
        byId[id] = c
        changed = true
        return c
    }

    public func setText(_ c: Comment, _ text: String) {
        guard c.text != text else { return }
        c.text = text
        c.xml = nil
        ensureParaId(c)
        changed = true
    }

    public func setDone(_ c: Comment, _ done: Bool) {
        for k in [c] + replies(to: c) {
            ensureParaId(k)
            k.done = done
        }
        changed = true
    }

    /// Word links threads through the last paragraph's paraId, which older writers omit.
    private func ensureParaId(_ c: Comment) {
        if c.paraId == nil { c.paraId = newParaId(); c.xml = nil }
    }

    /// Writes comment parts, keeping only comments whose anchors survive in `present`.
    func write(present: Set<Int>, hasStyle: (String) -> Bool) {
        let alive = comments.filter { isAlive($0, present) }
        guard changed || alive.count != comments.count else { return }
        writeComments(alive, hasStyle: hasStyle)
        writeExtended(alive)
        filterIds(alive)
    }

    private func isAlive(_ c: Comment, _ present: Set<Int>, depth: Int = 0) -> Bool {
        guard present.contains(c.id) else { return false }
        guard let p = parent(of: c), depth < 50 else { return true }
        return isAlive(p, present, depth: depth + 1)
    }

    private func writeComments(_ alive: [Comment], hasStyle: (String) -> Bool) {
        let path = package.partPath(forType: "/comments") ?? package.mainDirectory + "/comments.xml"
        var head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:comments xmlns:w=\"\(ns.w)\" xmlns:w14=\"\(ns.w14)\" xmlns:mc=\"\(ns.mc)\" mc:Ignorable=\"w14\">"
        var tail = "</w:comments>"
        if let bytes = package.part(path), let x = try? XDoc(bytes) {
            let r = x.nodes[Int(x.root)]
            if r.end > r.contentEnd {
                head = String(decoding: bytes[..<Int(r.contentStart)], as: UTF8.self)
                tail = String(decoding: bytes[Int(r.contentEnd)...], as: UTF8.self)
            } else {
                head = String(decoding: bytes[..<Int(r.attrEnd)], as: UTF8.self) + ">"
            }
            if !head.contains("xmlns:w14=") {
                head = head.replacingOccurrences(of: "<w:comments", with: "<w:comments xmlns:w14=\"\(ns.w14)\"")
            }
        }
        var body = ""
        for c in alive { body += c.xml ?? generate(c, hasStyle: hasStyle) }
        let bytes = Array((head + body + tail).utf8)
        if package.partPath(forType: "/comments") == nil {
            package.addPart(path, bytes: bytes, contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml",
                            relationshipType: Self.commentsType)
        } else {
            package.setPart(path, bytes)
        }
    }

    private func generate(_ c: Comment, hasStyle: (String) -> Bool) -> String {
        let pStyle = hasStyle("CommentText") ? "<w:pPr><w:pStyle w:val=\"CommentText\"/></w:pPr>" : ""
        let rStyle = hasStyle("CommentReference") ? "<w:rPr><w:rStyle w:val=\"CommentReference\"/></w:rPr>" : ""
        var s = "<w:comment w:id=\"\(c.id)\" w:author=\"\(escapeXML(c.author, attribute: true))\" w:date=\"\(c.date)\" w:initials=\"\(escapeXML(c.initials, attribute: true))\">"
        let lines = c.text.components(separatedBy: "\n")
        for (k, line) in lines.enumerated() {
            let pid = k == lines.count - 1 ? c.paraId! : newParaId()
            s += "<w:p w14:paraId=\"\(pid)\" w14:textId=\"77777777\">\(pStyle)"
            if k == 0 { s += "<w:r>\(rStyle)<w:annotationRef/></w:r>" }
            if !line.isEmpty { s += "<w:r><w:t xml:space=\"preserve\">\(escapeXML(line))</w:t></w:r>" }
            s += "</w:p>"
        }
        return s + "</w:comment>"
    }

    private func writeExtended(_ alive: [Comment]) {
        let existing = package.partPath(forType: "/commentsExtended")
        let needed = alive.contains { $0.done || $0.parentParaId != nil }
        guard existing != nil || needed else { return }
        let path = existing ?? package.mainDirectory + "/commentsExtended.xml"
        var head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w15:commentsEx xmlns:mc=\"\(ns.mc)\" xmlns:w15=\"\(ns.w15)\" mc:Ignorable=\"w15\">"
        var tail = "</w15:commentsEx>"
        if let existing, let bytes = package.part(existing), let x = try? XDoc(bytes) {
            let r = x.nodes[Int(x.root)]
            head = String(decoding: bytes[..<Int(r.attrEnd)], as: UTF8.self) + ">"
            if r.end > r.contentEnd { tail = String(decoding: bytes[Int(r.contentEnd)...], as: UTF8.self) }
        }
        var body = ""
        for c in alive {
            guard let p = c.paraId else { continue }
            body += "<w15:commentEx w15:paraId=\"\(p)\""
            if let parent = c.parentParaId { body += " w15:paraIdParent=\"\(parent)\"" }
            body += " w15:done=\"\(c.done ? 1 : 0)\"/>"
        }
        let bytes = Array((head + body + tail).utf8)
        if existing == nil {
            package.addPart(path, bytes: bytes, contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.commentsExtended+xml",
                            relationshipType: Self.extendedType)
        } else {
            package.setPart(path, bytes)
        }
    }

    /// Drops entries of deleted comments from the newer Word id parts.
    private func filterIds(_ alive: [Comment]) {
        let paraIds = Set(alive.compactMap(\.paraId))
        var durable = Set<String>()
        if let path = package.partPath(forType: "/commentsIds"), let bytes = package.part(path), let x = try? XDoc(bytes) {
            let kept = x.children(x.root).filter { c in
                guard let p = x.attr(c, "w16cid:paraId"), paraIds.contains(p) else { return false }
                if let d = x.attr(c, "w16cid:durableId") { durable.insert(d) }
                return true
            }
            package.setPart(path, rebuild(x, bytes, kept))
            if let path = package.partPath(forType: "/commentsExtensible"), let bytes = package.part(path), let x = try? XDoc(bytes) {
                let kept = x.children(x.root).filter { c in
                    x.name(c) != "w16cex:commentExtensible" || x.attr(c, "w16cex:durableId").map(durable.contains) == true
                }
                package.setPart(path, rebuild(x, bytes, kept))
            }
        }
    }

    private func rebuild(_ x: XDoc, _ bytes: [UInt8], _ kept: [Int32]) -> [UInt8] {
        let r = x.nodes[Int(x.root)]
        guard r.end > r.contentEnd else { return bytes }
        var out = Array(bytes[..<Int(r.contentStart)])
        for k in kept { out += x.raw(k) }
        out += bytes[Int(r.contentEnd)...]
        return out
    }
}
