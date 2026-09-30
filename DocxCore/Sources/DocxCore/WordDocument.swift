import Foundation

/// A Package opened for editing. The text lives in an attributed string the caller owns;
/// this object knows how to turn it back into XML.
public final class WordDocument {
    public let package: DocxPackage
    public let styles: StyleSheet
    public internal(set) var numbering: Numbering
    public let comments: CommentStore
    var bookmarks: [Int: (start: String, end: String)] = [:]
    var commentRefXML: [Int: String] = [:]
    let docBytes: [UInt8]
    let body: Int32
    let x: XDoc
    private let bodyStart: Int
    private let bodySuffix: Int
    public internal(set) var bodyEdited = false
    /// Width of the text column on the page, in points.
    public let textWidth: Double

    public init(bytes: [UInt8]) throws {
        let package = try DocxPackage(bytes: bytes)
        self.package = package
        guard let main = package.part(package.mainPath) else { throw ZipError.corrupt("main part") }
        docBytes = main
        let x = try XDoc(main)
        self.x = x
        guard let b = x.child(x.root, x.id("w:body")) else { throw ZipError.corrupt("no w:body") }
        body = b
        bodyStart = Int(x.nodes[Int(b)].contentStart)
        var suffix = Int(x.nodes[Int(b)].contentEnd)
        var last: Int32 = -1
        for c in x.children(b) { last = c }
        if last >= 0, x.name(last) == "w:sectPr" { suffix = Int(x.nodes[Int(last)].start) }
        bodySuffix = suffix
        var width = 468.0
        if last >= 0, x.name(last) == "w:sectPr" {
            let pg = x.child(last, x.id("w:pgSz")).flatMap { x.attr($0, "w:w") }.flatMap(Double.init)
            let mar = x.child(last, x.id("w:pgMar"))
            let l = mar.flatMap { x.attr($0, "w:left") }.flatMap(Double.init) ?? 1440
            let r = mar.flatMap { x.attr($0, "w:right") }.flatMap(Double.init) ?? 1440
            if let pg, pg - l - r > 1000 { width = (pg - l - r) / 20 }
        }
        textWidth = width
        styles = StyleSheet(package.partPath(forType: "/styles").flatMap { package.part($0) })
        numbering = Numbering(package.partPath(forType: "/numbering").flatMap { package.part($0) })
        comments = CommentStore(package: package)
    }

    public convenience init(data: Data) throws { try self.init(bytes: [UInt8](data)) }

    /// Builds the editable text, into `target` when given. Call once.
    public func load(styler: Styler?, into target: NSMutableAttributedString? = nil) -> NSMutableAttributedString {
        let l = Loader(doc: self, styler: styler, into: target ?? NSMutableAttributedString())
        return l.finish()
    }

    /// Loads a document in two steps: a prefix to show at once, then the rest.
    public final class Loader {
        private let reader: Reader
        private let doc: WordDocument

        public init(doc: WordDocument, styler: Styler?, into target: NSMutableAttributedString = NSMutableAttributedString()) {
            self.doc = doc
            reader = Reader(doc: doc, x: doc.x, styler: styler, out: target)
            reader.start(doc.body)
        }

        /// A copy of the text read so far, or nil when the whole body fit within `chars`.
        public func prefix(chars: Int) -> NSAttributedString? {
            reader.readMore(upTo: chars)
            return reader.done ? nil : NSAttributedString(attributedString: reader.out)
        }

        /// Reads the rest, optionally with a different styler, and returns the full text.
        public func finish(styler: Styler? = nil) -> NSMutableAttributedString {
            if let styler { reader.styler = styler }
            reader.readMore()
            reader.finishBody()
            reader.finishMarkers()
            if reader.out.length == 0 {
                let p = ParaProps.plain()
                var a = reader.styler?.paragraphAttributes(p) ?? [:]
                a[.docxPara] = p
                a[.docxRun] = RunProps.plain
                reader.out.append(NSAttributedString(string: "\n", attributes: a))
                doc.bodyEdited = true
            }
            return reader.out
        }
    }

    public static func blank() -> WordDocument { try! WordDocument(bytes: BlankDocx.bytes) }

    // MARK: editing hooks

    /// Whether an edit keeps every surviving sealed block alone in its own paragraph.
    public func allowsEdit(_ s: NSAttributedString, range r: NSRange, replacement: String?) -> Bool {
        let str = s.string as NSString
        let t = replacement ?? ""
        func isBlock(_ p: Int) -> Bool {
            p >= 0 && p < str.length && (s.attribute(.docxSealed, at: p, effectiveRange: nil) as? Sealed)?.isBlock == true
        }
        let newline: unichar = 10
        if isBlock(NSMaxRange(r)) {
            let prev: unichar? = t.utf16.last ?? (r.location > 0 ? str.character(at: r.location - 1) : nil)
            if let prev, prev != newline { return false }
        }
        if isBlock(r.location - 1) {
            let next: unichar? = t.utf16.first ?? (NSMaxRange(r) < str.length ? str.character(at: NSMaxRange(r)) : nil)
            if next != newline { return false }
        }
        return true
    }

    /// Restores paragraph invariants after an edit and marks touched paragraphs for rewriting.
    public func normalize(_ s: NSMutableAttributedString, editedRange: NSRange) {
        let str = s.string as NSString
        guard str.length > 0 else { return }
        var lo = min(editedRange.location, str.length - 1)
        if lo > 0 { lo -= 1 }
        // Cover the character at the edit point too, so a deletion at a paragraph start marks that paragraph.
        let hi = min(max(NSMaxRange(editedRange), editedRange.location + 1), str.length)
        let span = str.paragraphRange(for: NSRange(location: lo, length: hi - lo))
        bodyEdited = true
        var p = span.location
        while p < NSMaxRange(span) {
            let pr = str.paragraphRange(for: NSRange(location: p, length: 0))
            var props = s.attribute(.docxPara, at: pr.location, effectiveRange: nil) as? ParaProps
            let blockChar = (s.attribute(.docxSealed, at: pr.location, effectiveRange: nil) as? Sealed)?.isBlock == true
            if let pp = props, pp.isSealed, !(blockChar && pr.length <= 2) {
                props = ParaProps.plain()
            } else if props == nil || (blockChar && props?.isSealed == false && pr.length <= 2) {
                props = blockChar ? ParaProps.sealedBlock() : ParaProps.plain()
            }
            var uniform: NSRange = NSRange()
            let at = s.attribute(.docxPara, at: pr.location, longestEffectiveRange: &uniform, in: pr) as? ParaProps
            if at !== props || uniform.length < pr.length {
                s.addAttribute(.docxPara, value: props!, range: pr)
            }
            props!.dirty = true
            p = NSMaxRange(pr)
        }
    }

    /// Forces every paragraph through the XML generator; used by tests.
    public func markAllEdited(_ s: NSAttributedString) {
        bodyEdited = true
        s.enumerateAttribute(.docxPara, in: NSRange(location: 0, length: s.length)) { v, _, _ in (v as? ParaProps)?.dirty = true }
    }

    // MARK: saving

    public func save(_ s: NSAttributedString) -> [UInt8] {
        var present = Set(comments.comments.map(\.id))
        if bodyEdited {
            var w = BodyWriter(doc: self, text: s)
            var out = Array(docBytes[..<bodyStart])
            out.reserveCapacity(docBytes.count + 4096)
            w.write(into: &out)
            out += docBytes[bodySuffix...]
            package.setPart(package.mainPath, out)
            present = w.presentComments
        }
        comments.write(present: present) { self.styles.styles[$0] != nil }
        return package.write()
    }

    // MARK: helpers for BodyWriter

    func rawParagraph(_ p: ParaProps) -> ArraySlice<UInt8>? {
        guard !p.dirty, p.selfContained, let r = p.raw else { return nil }
        return docBytes[r]
    }
}

extension WordDocument {
    /// Rewrites the body on the next save without marking paragraphs edited; for tests.
    public func touchBody() { bodyEdited = true }

    /// Counts paragraphs by why they can or cannot be copied verbatim; for diagnostics.
    public func rawStats(_ s: NSAttributedString) -> [String: Int] {
        var c: [String: Int] = [:]
        s.enumerateAttribute(.docxPara, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            guard let p = v as? ParaProps else { c["none", default: 0] += 1; return }
            let k = p.isSealed ? "sealed" : p.dirty ? "dirty" : !p.selfContained ? "notSelfContained" : p.raw == nil ? "noRaw" : "raw"
            c[k, default: 0] += 1
        }
        return c
    }
}
