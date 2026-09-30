import Foundation

public extension WordDocument {
    // MARK: character formatting

    func isOn(_ t: RunProps.Toggle, _ run: RunProps, para: ParaProps) -> Bool {
        var f = styles.resolved(paragraphStyle: para.styleId).1
        if let cs = run.format.charStyle { f = f.overlaid(styles.resolved(characterStyle: cs)) }
        f = f.overlaid(run.format)
        switch t {
        case .bold: return f.bold ?? false
        case .italic: return f.italic ?? false
        case .underline: return f.underline ?? false
        case .strike: return f.strike ?? false
        }
    }

    private func textRuns(_ s: NSAttributedString, _ range: NSRange, _ body: (NSRange, RunProps, ParaProps) -> Void) {
        s.enumerateAttributes(in: range) { a, r, _ in
            guard a[.docxSealed] == nil, let p = a[.docxPara] as? ParaProps, !p.isSealed else { return }
            let str = s.string as NSString
            // Newlines carry the paragraph mark's formatting, not text formatting.
            var rr = r
            while rr.length > 0, str.character(at: NSMaxRange(rr) - 1) == 10 { rr.length -= 1 }
            if rr.length > 0 { body(rr, a[.docxRun] as? RunProps ?? .plain, p) }
        }
    }

    /// Whether every text character in the range has the toggle on.
    func allOn(_ t: RunProps.Toggle, in s: NSAttributedString, range: NSRange) -> Bool {
        var all = true, any = false
        textRuns(s, range) { _, run, p in any = true; if !isOn(t, run, para: p) { all = false } }
        return any && all
    }

    func toggle(_ t: RunProps.Toggle, in s: NSMutableAttributedString, range: NSRange) {
        let on = !allOn(t, in: s, range: range)
        var changes: [(NSRange, RunProps)] = []
        textRuns(s, range) { r, run, p in
            let inherited = isOn(t, run.with(t, nil), para: p)
            changes.append((r, run.with(t, on == inherited ? nil : on)))
        }
        for (r, props) in changes { s.addAttribute(.docxRun, value: props, range: r) }
        normalize(s, editedRange: range)
    }

    /// Run properties to type with after the caret moves, with a toggle flipped.
    func typing(_ t: RunProps.Toggle, _ run: RunProps, para: ParaProps) -> RunProps {
        let on = !isOn(t, run, para: para)
        let inherited = isOn(t, run.with(t, nil), para: para)
        return run.with(t, on == inherited ? nil : on)
    }

    // MARK: paragraphs

    func paragraphs(_ s: NSAttributedString, _ range: NSRange) -> [(NSRange, ParaProps)] {
        let str = s.string as NSString
        var out: [(NSRange, ParaProps)] = []
        var p = str.paragraphRange(for: NSRange(location: min(range.location, max(0, str.length - 1)), length: 0)).location
        let end = max(NSMaxRange(range), p + 1)
        while p < min(end, str.length) {
            let r = str.paragraphRange(for: NSRange(location: p, length: 0))
            if let props = s.attribute(.docxPara, at: r.location, effectiveRange: nil) as? ParaProps, !props.isSealed { out.append((r, props)) }
            p = NSMaxRange(r)
        }
        return out
    }

    func setStyle(_ id: String?, in s: NSMutableAttributedString, range: NSRange) {
        for (r, p) in paragraphs(s, range) { s.addAttribute(.docxPara, value: p.with(style: .some(id)), range: r) }
        bodyEdited = true
    }

    func listKind(_ p: ParaProps) -> Bool? {
        let f = styles.resolved(paragraphStyle: p.styleId).0.overlaid(p.format)
        guard let n = f.numId, n != 0, numbering.nums[n] != nil else { return nil }
        return numbering.isBullet(n)
    }

    func toggleList(bullet: Bool, in s: NSMutableAttributedString, range: NSRange) {
        let paras = paragraphs(s, range)
        guard !paras.isEmpty else { return }
        if paras.allSatisfy({ listKind($0.1) == bullet }) {
            for (r, p) in paras { s.addAttribute(.docxPara, value: p.with(numbering: .some(nil)), range: r) }
            // A style that carries numbering needs an explicit "no list".
            for (r, p) in paragraphs(s, range) where listKind(p) != nil {
                s.addAttribute(.docxPara, value: p.with(numbering: .some((0, 0))), range: r)
            }
        } else {
            let numId = listId(bullet: bullet, near: s, at: paras[0].0.location)
            for (r, p) in paras {
                let level = listKind(p) != nil ? (styles.resolved(paragraphStyle: p.styleId).0.overlaid(p.format).ilvl ?? 0) : 0
                s.addAttribute(.docxPara, value: p.with(numbering: .some((numId, level))), range: r)
            }
        }
        bodyEdited = true
    }

    func indentList(by delta: Int, in s: NSMutableAttributedString, range: NSRange) -> Bool {
        var changed = false
        for (r, p) in paragraphs(s, range) {
            let f = styles.resolved(paragraphStyle: p.styleId).0.overlaid(p.format)
            guard let n = f.numId, n != 0 else { continue }
            let level = min(8, max(0, (f.ilvl ?? 0) + delta))
            s.addAttribute(.docxPara, value: p.with(numbering: .some((n, level))), range: r)
            changed = true
        }
        if changed { bodyEdited = true }
        return changed
    }

    /// Continues the list just above when it has the right kind, otherwise reuses or creates one.
    private func listId(bullet: Bool, near s: NSAttributedString, at loc: Int) -> Int {
        let str = s.string as NSString
        if loc > 0 {
            let prev = str.paragraphRange(for: NSRange(location: loc - 1, length: 0))
            if let p = s.attribute(.docxPara, at: prev.location, effectiveRange: nil) as? ParaProps, listKind(p) == bullet,
               let n = styles.resolved(paragraphStyle: p.styleId).0.overlaid(p.format).numId { return n }
        }
        if bullet, let n = numbering.nums.keys.sorted().first(where: { numbering.isBullet($0) && numbering.level($0, 1) != nil }) { return n }
        return addNumbering(bullet: bullet)
    }

    private func addNumbering(bullet: Bool) -> Int {
        let path = package.partPath(forType: "/numbering")
        var xml = path.flatMap { package.part($0) }.map { String(decoding: $0, as: UTF8.self) }
            ?? BlankDocx.xmlHead + "<w:numbering xmlns:w=\"\(BlankDocx.w)\"></w:numbering>"
        if xml.contains("<w:numbering"), !xml.contains("</w:numbering>") {
            xml = xml.replacingOccurrences(of: #"<w:numbering([^>]*)/>"#, with: "<w:numbering$1></w:numbering>", options: .regularExpression)
        }
        let aid = (numbering.abstracts.keys.max() ?? -1) + 1
        let nid = (numbering.nums.keys.max() ?? 0) + 1
        var levels = ""
        for l in 0 ..< 9 {
            let (fmt, text): (String, String) = bullet ? ("bullet", ["•", "◦", "▪"][l % 3])
                : (["decimal", "lowerLetter", "lowerRoman"][l % 3], "%\(l + 1).")
            levels += "<w:lvl w:ilvl=\"\(l)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(fmt)\"/><w:lvlText w:val=\"\(text)\"/>"
                + "<w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 * (l + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }
        let abstract = "<w:abstractNum w:abstractNumId=\"\(aid)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels)</w:abstractNum>"
        // Schema order: every abstractNum precedes every num.
        if let r = xml.range(of: "<w:num ") ?? xml.range(of: "<w:num>") ?? xml.range(of: "<w:numIdMacAtCleanup") ?? xml.range(of: "</w:numbering>") {
            xml.insert(contentsOf: abstract, at: r.lowerBound)
        }
        let num = "<w:num w:numId=\"\(nid)\"><w:abstractNumId w:val=\"\(aid)\"/></w:num>"
        if let r = xml.range(of: "<w:numIdMacAtCleanup") ?? xml.range(of: "</w:numbering>") { xml.insert(contentsOf: num, at: r.lowerBound) }
        let bytes = Array(xml.utf8)
        if let path { package.setPart(path, bytes) } else {
            package.addPart(package.mainDirectory + "/numbering.xml", bytes: bytes,
                            contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml",
                            relationshipType: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering")
        }
        numbering = Numbering(bytes)
        return nid
    }

    // MARK: comments

    /// First anchored range of each comment present in the text, in document order.
    func commentAnchors(_ s: NSAttributedString) -> [(id: Int, range: NSRange)] {
        var first: [Int: NSRange] = [:]
        s.enumerateAttribute(.docxMarks, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            guard let m = v as? MarkSet else { return }
            for id in m.comments {
                if let f = first[id] {
                    if NSMaxRange(f) == r.location { first[id] = NSUnionRange(f, r) }
                } else { first[id] = r }
            }
        }
        return first.map { ($0.key, $0.value) }.sorted { $0.range.location < $1.range.location }
    }

    @discardableResult
    func addComment(_ text: String, author: String, initials: String, in s: NSMutableAttributedString, range: NSRange) -> Comment {
        let c = comments.add(text: text, author: author, initials: initials)
        addMark(c.id, in: s, range: range)
        return c
    }

    @discardableResult
    func reply(to parent: Comment, _ text: String, author: String, initials: String, in s: NSMutableAttributedString) -> Comment {
        let c = comments.add(text: text, author: author, initials: initials, replyingTo: parent)
        var ranges: [NSRange] = []
        s.enumerateAttribute(.docxMarks, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if (v as? MarkSet)?.comments.contains(parent.id) == true { ranges.append(r) }
        }
        for r in ranges { addMark(c.id, in: s, range: r) }
        return c
    }

    func deleteComment(_ c: Comment, in s: NSMutableAttributedString) {
        let ids = Set([c.id] + comments.replies(to: c).map(\.id))
        var changes: [(NSRange, MarkSet?)] = []
        s.enumerateAttribute(.docxMarks, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            guard let m = v as? MarkSet, !ids.isDisjoint(with: m.comments) else { return }
            let next = MarkSet(bookmarks: m.bookmarks, comments: m.comments.filter { !ids.contains($0) })
            changes.append((r, next.isEmpty ? nil : next))
        }
        for (r, m) in changes {
            if let m { s.addAttribute(.docxMarks, value: m, range: r) } else { s.removeAttribute(.docxMarks, range: r) }
        }
        for (r, _) in changes { normalize(s, editedRange: r) }
    }

    private func addMark(_ id: Int, in s: NSMutableAttributedString, range: NSRange) {
        var changes: [(NSRange, MarkSet)] = []
        s.enumerateAttributes(in: range) { a, r, _ in
            if (a[.docxSealed] as? Sealed)?.isBlock == true { return }
            let m = a[.docxMarks] as? MarkSet ?? MarkSet(bookmarks: [], comments: [])
            changes.append((r, m.adding(comment: id)))
        }
        for (r, m) in changes { s.addAttribute(.docxMarks, value: m, range: r) }
        normalize(s, editedRange: range)
    }
}

public extension WordDocument {
    /// Attributes new text should take from its neighbour: never the neighbour's sealed content or point markers.
    static func typingAttributes(_ a: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var t = a
        for k in [NSAttributedString.Key.docxSealed, .docxPoints, NSAttributedString.Key("NSAttachment")] { t[k] = nil }
        if (t[.docxPara] as? ParaProps)?.isSealed == true { t[.docxPara] = nil }
        if t[.docxRun] == nil { t[.docxRun] = RunProps.plain }
        return t
    }
}
