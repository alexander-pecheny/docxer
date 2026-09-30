import Foundation

/// Serialises the edited text back into `w:body` content.
struct BodyWriter {
    let doc: WordDocument
    let text: NSAttributedString
    let str: NSString
    private(set) var presentComments = Set<Int>()

    private enum Mark: Hashable { case bookmark(Int), comment(Int) }
    private var open: [Mark] = []
    private var closed = Set<Mark>()
    private var emittedPoints = Set<ObjectIdentifier>()
    private var seenProps = Set<ObjectIdentifier>()
    private var lastUse: [ObjectIdentifier: Int] = [:]
    private var paras: [(range: NSRange, props: ParaProps)] = []
    private var out: [UInt8] = []
    private var link: Hyperlink?

    init(doc: WordDocument, text: NSAttributedString) {
        self.doc = doc; self.text = text; str = text.string as NSString
    }

    mutating func write(into buffer: inout [UInt8]) {
        swap(&out, &buffer)
        defer { swap(&out, &buffer) }
        var p = 0
        while p < str.length {
            let r = str.paragraphRange(for: NSRange(location: p, length: 0))
            let props = text.attribute(.docxPara, at: r.location, effectiveRange: nil) as? ParaProps ?? ParaProps.plain()
            lastUse[ObjectIdentifier(props)] = paras.count
            paras.append((r, props))
            p = NSMaxRange(r)
        }
        for k in paras.indices { paragraph(k) }
        closeAll()
    }

    /// Whether any character in the range carries the attribute; one lookup when none does.
    private func has(_ key: NSAttributedString.Key, _ range: NSRange) -> Bool {
        var eff = NSRange()
        return text.attribute(key, at: range.location, longestEffectiveRange: &eff, in: range) != nil || NSMaxRange(eff) < NSMaxRange(range)
    }

    private mutating func w(_ s: String) { out.append(contentsOf: s.utf8) }

    private mutating func paragraph(_ k: Int) {
        let (range, props) = paras[k]
        if props.isSealed {
            closeAll()
            text.enumerateAttribute(.docxSealed, in: range) { v, _, _ in
                if let s = v as? Sealed { w(s.xml); presentComments.formUnion(s.commentIDs) }
            }
            return
        }
        let first = seenProps.insert(ObjectIdentifier(props)).inserted
        if first, let raw = doc.rawParagraph(props) {
            // Marks spanning this paragraph stay open across it; its own XML holds only marks internal to it.
            var through = marks(at: range.location)
            for m in props.rawCloses { through.insert(m.comment ? .comment(m.id) : .bookmark(m.id)) }
            for mark in open.reversed() where !through.contains(mark) { close(mark, bodyLevel: true) }
            w(props.leading)
            out += raw
            w(props.trailing)
            for m in props.rawOpens { let mark = m.comment ? Mark.comment(m.id) : .bookmark(m.id); if !open.contains(mark) { open.append(mark) } }
            for m in props.rawCloses { let mark = m.comment ? Mark.comment(m.id) : .bookmark(m.id); open.removeAll { $0 == mark }; closed.insert(mark) }
            if has(.docxMarks, range) {
                text.enumerateAttribute(.docxMarks, in: range) { v, _, _ in
                    guard let m = v as? MarkSet else { return }
                    for b in m.bookmarks where !open.contains(.bookmark(b)) { closed.insert(.bookmark(b)) }
                    for c in m.comments {
                        presentComments.insert(c)
                        if !open.contains(.comment(c)) { closed.insert(.comment(c)) }
                    }
                }
            }
            if has(.docxPoints, range) {
                text.enumerateAttribute(.docxPoints, in: range) { v, _, _ in
                    guard let pm = v as? PointMarks else { return }
                    emittedPoints.insert(ObjectIdentifier(pm)); presentComments.formUnion(pm.commentIDs)
                }
            }
            if has(.docxSealed, range) {
                text.enumerateAttribute(.docxSealed, in: range) { v, _, _ in
                    if let s = v as? Sealed { presentComments.formUnion(s.commentIDs) }
                }
            }
            return
        }
        openParagraph(props, first: first, last: lastUse[ObjectIdentifier(props)] == k)
        let content = NSRange(location: range.location, length: range.length - (str.character(at: NSMaxRange(range) - 1) == 10 ? 1 : 0))
        text.enumerateAttributes(in: content) { a, r, _ in segment(a, r, props: props) }
        if content.length < range.length, let pm = text.attribute(.docxPoints, at: NSMaxRange(content), effectiveRange: nil) as? PointMarks {
            points(pm)
        }
        setLink(nil)
        // Keep marks open only when the next paragraph continues them.
        var keep = Set<Mark>()
        if k + 1 < paras.count, !paras[k + 1].props.isSealed, paras[k + 1].range.length > 0 {
            keep = marks(at: paras[k + 1].range.location)
        }
        for mark in open.reversed() where !keep.contains(mark) { close(mark) }
        w("</w:p>")
    }

    private mutating func openParagraph(_ props: ParaProps, first: Bool, last: Bool) {
        w("<w:p" + (first ? props.openAttrs : stripIds(props.openAttrs)) + ">")
        let sect = last ? props.sectPr : nil
        if !props.pPr.isEmpty || sect != nil {
            w("<w:pPr>")
            var sectDone = sect == nil
            for c in props.pPr {
                if !sectDone, c.name == "w:pPrChange" { w(sect!); sectDone = true }
                w(c.xml)
            }
            if !sectDone { w(sect!) }
            w("</w:pPr>")
        }
    }

    private mutating func segment(_ a: [NSAttributedString.Key: Any], _ r: NSRange, props: ParaProps) {
        let newLink = a[.docxLink] as? Hyperlink
        if newLink !== link { setLink(nil) }
        transition(a[.docxMarks] as? MarkSet)
        if newLink !== link { setLink(newLink) }
        if let pm = a[.docxPoints] as? PointMarks { points(pm) }
        if let s = a[.docxSealed] as? Sealed {
            presentComments.formUnion(s.commentIDs)
            for _ in 0 ..< r.length {
                if s.isBlock {
                    // Defensive: a block that ended up inside a paragraph is split out of it.
                    setLink(nil)
                    w("</w:p>"); w(s.xml)
                    openParagraph(props.copyForSplit(), first: false, last: false)
                } else {
                    w(s.xml)
                }
            }
            return
        }
        runs(str.substring(with: r), a[.docxRun] as? RunProps ?? RunProps.plain)
    }

    private mutating func setLink(_ l: Hyperlink?) {
        if link != nil { w("</w:hyperlink>") }
        link = l
        if let l { w(l.openTag) }
    }

    private mutating func points(_ pm: PointMarks) {
        guard emittedPoints.insert(ObjectIdentifier(pm)).inserted else { return }
        for x in pm.xml { w(x) }
        presentComments.formUnion(pm.commentIDs)
    }

    private mutating func transition(_ m: MarkSet?) {
        var want: [Mark] = []
        if let m { want = m.bookmarks.map(Mark.bookmark) + m.comments.map(Mark.comment) }
        let wantSet = Set(want)
        for mark in open.reversed() where !wantSet.contains(mark) { close(mark) }
        for mark in want where !open.contains(mark) && !closed.contains(mark) {
            switch mark {
            case .bookmark(let id):
                guard let b = doc.bookmarks[id] else { continue }
                w(b.start)
            case .comment(let id):
                w("<w:commentRangeStart w:id=\"\(id)\"/>")
                presentComments.insert(id)
            }
            open.append(mark)
        }
    }

    /// Between paragraphs only the range end is legal; a comment's reference run needs a paragraph, so it is dropped there.
    private mutating func close(_ mark: Mark, bodyLevel: Bool = false) {
        open.removeAll { $0 == mark }
        closed.insert(mark)
        switch mark {
        case .bookmark(let id):
            if let b = doc.bookmarks[id] { w(b.end) }
        case .comment(let id):
            w("<w:commentRangeEnd w:id=\"\(id)\"/>")
            if bodyLevel { return }
            if let ref = doc.commentRefXML[id] { w(ref) } else {
                let style = doc.styles.styles["CommentReference"] != nil ? "<w:rPr><w:rStyle w:val=\"CommentReference\"/></w:rPr>" : ""
                w("<w:r>\(style)<w:commentReference w:id=\"\(id)\"/></w:r>")
            }
        }
    }

    private func marks(at p: Int) -> Set<Mark> {
        guard let m = text.attribute(.docxMarks, at: p, effectiveRange: nil) as? MarkSet else { return [] }
        return Set(m.bookmarks.map(Mark.bookmark) + m.comments.map(Mark.comment))
    }

    private mutating func closeAll() {
        for mark in open.reversed() { close(mark, bodyLevel: true) }
    }

    private mutating func runs(_ s: String, _ rp: RunProps) {
        w("<w:r" + rp.openAttrs + ">")
        if !rp.rPr.isEmpty {
            w("<w:rPr>")
            for c in rp.rPr { w(c.xml) }
            w("</w:rPr>")
        }
        var buf = ""
        func flush(_ me: inout BodyWriter) {
            guard !buf.isEmpty else { return }
            let preserve = buf.first == " " || buf.last == " " || buf.contains("  ") || buf.first == "\t"
            me.w(preserve ? "<w:t xml:space=\"preserve\">" : "<w:t>")
            me.w(escapeXML(buf))
            me.w("</w:t>")
            buf = ""
        }
        for ch in s.unicodeScalars {
            switch ch {
            case "\t": flush(&self); w("<w:tab/>")
            case "\u{2028}", "\r", "\n", "\u{2029}": flush(&self); w("<w:br/>")
            case "\u{2011}": flush(&self); w("<w:noBreakHyphen/>")
            case "\u{00AD}": flush(&self); w("<w:softHyphen/>")
            case "\u{FFFC}": continue
            default: buf.unicodeScalars.append(ch)
            }
        }
        flush(&self)
        w("</w:r>")
    }
}
