import Foundation

/// The zip container, its content types and the main document's relationships.
public final class DocxPackage {
    public struct Relationship {
        public let id: String
        public let type: String
        public let target: String
        public let external: Bool
    }

    let zip: ZipArchive?
    public let mainPath: String
    private(set) var modified: [String: [UInt8]] = [:]
    private var added: [String] = []
    public private(set) var relationships: [String: Relationship] = [:]

    public init(bytes: [UInt8]) throws {
        let zip = try ZipArchive(bytes: bytes)
        self.zip = zip
        var main = "word/document.xml"
        if let rels = try zip.read("_rels/.rels"), let x = try? XDoc(rels) {
            for r in x.children(x.root) where x.attr(r, "Type")?.hasSuffix("/officeDocument") == true {
                if let t = x.attr(r, "Target") { main = t.hasPrefix("/") ? String(t.dropFirst()) : t }
            }
        }
        mainPath = main
        guard zip.entry(main) != nil else { throw ZipError.corrupt("no main document part") }
        try loadRelationships()
    }

    public var mainDirectory: String { (mainPath as NSString).deletingLastPathComponent }
    var relsPath: String { mainDirectory + "/_rels/" + (mainPath as NSString).lastPathComponent + ".rels" }

    public func part(_ path: String) -> [UInt8]? {
        if let m = modified[path] { return m }
        return try? zip?.read(path)
    }

    public func setPart(_ path: String, _ bytes: [UInt8]) {
        if modified[path] == nil, zip?.entry(path) == nil { added.append(path) }
        modified[path] = bytes
    }

    public var hasChanges: Bool { !modified.isEmpty }

    private func loadRelationships() throws {
        relationships = [:]
        guard let bytes = part(relsPath), let x = try? XDoc(bytes) else { return }
        for r in x.children(x.root) where x.name(r) == "Relationship" {
            guard let id = x.attr(r, "Id"), let type = x.attr(r, "Type"), let target = x.attr(r, "Target") else { continue }
            relationships[id] = Relationship(id: id, type: type, target: target, external: x.attr(r, "TargetMode") == "External")
        }
    }

    /// Resolves a relationship target to a part path.
    public func partPath(forRelationship id: String) -> String? {
        guard let r = relationships[id], !r.external else { return nil }
        return resolve(r.target)
    }

    func resolve(_ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        return (mainDirectory + "/" + target as NSString).standardizingPath.replacingOccurrences(of: "^/", with: "", options: .regularExpression)
    }

    public func partPath(forType suffix: String) -> String? {
        relationships.values.first { $0.type.hasSuffix(suffix) && !$0.external }.map { resolve($0.target) }
    }

    /// Adds a part with its content type override and a relationship from the main document.
    public func addPart(_ path: String, bytes: [UInt8], contentType: String, relationshipType: String) {
        setPart(path, bytes)
        let ct = String(decoding: part("[Content_Types].xml") ?? [], as: UTF8.self)
        if !ct.contains("PartName=\"/\(path)\"") {
            let entry = "<Override PartName=\"/\(path)\" ContentType=\"\(contentType)\"/>"
            setPart("[Content_Types].xml", Array(ct.replacingOccurrences(of: "</Types>", with: entry + "</Types>").utf8))
        }
        let rels = String(decoding: part(relsPath) ?? Array(emptyRels.utf8), as: UTF8.self)
        let target = path.hasPrefix(mainDirectory + "/") ? String(path.dropFirst(mainDirectory.count + 1)) : "/" + path
        if !rels.contains("Target=\"\(target)\"") { addRelationship("Type=\"\(relationshipType)\" Target=\"\(target)\"") }
    }

    /// Adds a relationship from the main document to an outside address, such as a hyperlink's URL, and returns its id.
    public func addExternalRelationship(type: String, target: String) -> String {
        addRelationship("Type=\"\(type)\" Target=\"\(escapeXML(target, attribute: true))\" TargetMode=\"External\"")
    }

    @discardableResult
    private func addRelationship(_ attrs: String) -> String {
        var n = relationships.count + 1
        while relationships["rId\(n)"] != nil { n += 1 }
        let rels = String(decoding: part(relsPath) ?? Array(emptyRels.utf8), as: UTF8.self)
        setPart(relsPath, Array(rels.replacingOccurrences(of: "</Relationships>", with: "<Relationship Id=\"rId\(n)\" \(attrs)/></Relationships>").utf8))
        try? loadRelationships()
        return "rId\(n)"
    }

    /// Declares a content type for a file extension unless one exists.
    public func ensureDefaultContentType(ext: String, type: String) {
        let ct = String(decoding: part("[Content_Types].xml") ?? [], as: UTF8.self)
        guard !ct.lowercased().contains("extension=\"\(ext.lowercased())\"") else { return }
        setPart("[Content_Types].xml", Array(ct.replacingOccurrences(of: "</Types>",
                                                                    with: "<Default Extension=\"\(ext)\" ContentType=\"\(type)\"/></Types>").utf8))
    }

    /// Switches the main part's content type, e.g. from template to document.
    public func setMainContentType(_ type: String) {
        let ct = String(decoding: part("[Content_Types].xml") ?? [], as: UTF8.self)
        let pattern = "(<Override[^>]*PartName=\"/\(NSRegularExpression.escapedPattern(for: mainPath))\"[^>]*ContentType=\")[^\"]*(\")"
        let updated = ct.replacingOccurrences(of: pattern, with: "$1\(type)$2", options: .regularExpression)
        if updated != ct { setPart("[Content_Types].xml", Array(updated.utf8)) }
    }

    public var mainContentType: String? {
        let ct = String(decoding: part("[Content_Types].xml") ?? [], as: UTF8.self)
        guard let r = ct.range(of: "PartName=\"/\(mainPath)\"") else { return nil }
        let tag = ct[..<r.lowerBound].components(separatedBy: "<").last.map { "<" + $0 } ?? ""
        let rest = tag + ct[r.lowerBound...].prefix { $0 != ">" }
        return attrValue(String(rest), "ContentType")
    }

    public func write() -> [UInt8] {
        guard let zip else { return [] }
        if modified.isEmpty { return zip.bytes }
        var items: [ZipWriter.Item] = zip.entries.map { e in modified[e.name].map { .data(e.name, $0) } ?? .copy(e) }
        items += added.map { .data($0, modified[$0]!) }
        return ZipWriter.write(items, source: zip)
    }
}

let emptyRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"></Relationships>"
