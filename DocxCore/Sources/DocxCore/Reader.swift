import Foundation

/// Supplies display attributes while the reader builds text. Called in document order.
public protocol Styler: AnyObject {
    func paragraphAttributes(_ p: ParaProps) -> [NSAttributedString.Key: Any]
    func runAttributes(_ p: ParaProps, _ r: RunProps, link: Hyperlink?) -> [NSAttributedString.Key: Any]
    func sealedAttributes(_ p: ParaProps, _ r: RunProps?, _ s: Sealed) -> [NSAttributedString.Key: Any]
}

struct MarkerPart {
    var pos: Int
    var para: Int         // paragraph index, -1 when found between paragraphs
    var xml: String
}

final class Reader {
    let doc: WordDocument
    let x: XDoc
    var styler: Styler?
    let out: NSMutableAttributedString
    var pos = 0
    var paraIndex = 0
    var paraProps: [ParaProps] = []
    var paraStarts: [Int] = []

    var bookmarkStarts: [Int: MarkerPart] = [:], bookmarkEnds: [Int: MarkerPart] = [:]
    var commentStarts: [Int: MarkerPart] = [:], commentEnds: [Int: MarkerPart] = [:], commentRefs: [Int: MarkerPart] = [:]
    var sealedCommentIDs = Set<Int>()
    var points: [Int: [String]] = [:]
    var pointComments: [Int: Set<Int>] = [:]
    var pendingBodyStarts: [(kind: String, id: Int?, xml: String)] = []
    var footnoteCount = 0
    private var runCache: [UInt64: RunProps] = [:]

    // current paragraph state
    private var pAttrs: [NSAttributedString.Key: Any] = [:]
    private var cur: ParaProps!
    private var link: Hyperlink?

    init(doc: WordDocument, x: XDoc, styler: Styler?, out: NSMutableAttributedString) {
        self.doc = doc; self.x = x; self.styler = styler; self.out = out
    }

    struct Locked: Error {}

    private var kids: [Int32] = []
    private var i = 0
    var done: Bool { i >= kids.count }

    func start(_ body: Int32) {
        kids = Array(x.children(body))
        if let last = kids.last, x.name(last) == "w:sectPr" { kids.removeLast() }
    }

    /// Reads body elements until the text reaches `limit` characters or the body ends.
    func readMore(upTo limit: Int = .max) {
        out.beginEditing()
        defer { out.endEditing() }
        while i < kids.count, pos < limit {
            let c = kids[i]
            switch x.name(c) {
            case "w:p":
                let raw = x.raw(c)
                let depth = count(raw, "w:fldCharType=\"begin\"") - count(raw, "w:fldCharType=\"end\"")
                if depth > 0 {
                    // A field spanning paragraphs (e.g. a table of contents) is sealed as one block.
                    var group = [c], d = depth, j = i + 1
                    while j < kids.count, d > 0 {
                        let r = x.raw(kids[j])
                        d += count(r, "w:fldCharType=\"begin\"") - count(r, "w:fldCharType=\"end\"")
                        group.append(kids[j]); j += 1
                    }
                    sealBlock(group)
                    i = j
                    continue
                }
                if isLocked(raw) { sealBlock([c]) } else { paragraph(c) }
            case "w:bookmarkStart", "w:commentRangeStart", "w:permStart", "w:moveFromRangeStart", "w:moveToRangeStart":
                pendingBodyStarts.append((x.name(c), x.attr(c, "w:id").flatMap(Int.init), String(decoding: x.raw(c), as: UTF8.self)))
            case "w:bookmarkEnd", "w:commentRangeEnd", "w:permEnd", "w:moveFromRangeEnd", "w:moveToRangeEnd":
                bodyEnd(c)
            case "w:proofErr":
                break
            default:
                sealBlock([c])
            }
            i += 1
        }
    }

    func finishBody() {
        if !pendingBodyStarts.isEmpty {
            // Trailing markers with no paragraph after them: attach to the last paragraph's end.
            let at = max(0, pos - 1)
            for s in pendingBodyStarts { addBodyMarker(kind: s.kind, id: s.id, xml: s.xml, at: at, para: lastTextParagraph() ?? -1, leading: false) }
            pendingBodyStarts = []
        }
    }

    private func bodyEnd(_ c: Int32) {
        let xml = String(decoding: x.raw(c), as: UTF8.self)
        let id = x.attr(c, "w:id").flatMap(Int.init)
        let prev = lastTextParagraph()
        if let prev { addBodyMarker(kind: x.name(c), id: id, xml: xml, at: paraEnd(prev), para: prev, leading: false) } else {
            pendingBodyStarts.append((x.name(c), id, xml))
        }
    }

    private func lastTextParagraph() -> Int? {
        var k = paraProps.count - 1
        while k >= 0, paraProps[k].isSealed { k -= 1 }
        return k >= 0 ? k : nil
    }

    private func paraEnd(_ k: Int) -> Int { (k + 1 < paraStarts.count ? paraStarts[k + 1] : pos) - 1 }

    private func addBodyMarker(kind: String, id: Int?, xml: String, at: Int, para: Int, leading: Bool) {
        if para >= 0, para < paraProps.count {
            if leading { paraProps[para].leading += xml } else { paraProps[para].trailing += xml }
        }
        let part = MarkerPart(pos: at, para: para, xml: xml)
        switch (kind, id) {
        case ("w:bookmarkStart", let id?): bookmarkStarts[id] = part
        case ("w:bookmarkEnd", let id?): bookmarkEnds[id] = part
        case ("w:commentRangeStart", let id?): commentStarts[id] = part
        case ("w:commentRangeEnd", let id?): commentEnds[id] = part
        default: point(xml, at: at)
        }
    }

    private func point(_ xml: String, at p: Int, comment: Int? = nil) {
        points[p, default: []].append(xml)
        if let comment { pointComments[p, default: []].insert(comment) }
    }

    private func isLocked(_ raw: ArraySlice<UInt8>) -> Bool {
        for pat in ["<w:ins ", "<w:ins>", "<w:del ", "<w:del>", "<w:moveFrom ", "<w:moveFrom>", "<w:moveTo ", "<w:moveTo>",
                    "w:rPrChange", "w:pPrChange"] where has(raw, pat) { return true }
        return false
    }

    // MARK: paragraphs

    private func beginParagraph(_ p: ParaProps) {
        cur = p
        paraProps.append(p)
        paraStarts.append(pos)
        pAttrs = styler?.paragraphAttributes(p) ?? [:]
        pAttrs[.docxPara] = p
        link = nil
        if !pendingBodyStarts.isEmpty, !p.isSealed {
            for s in pendingBodyStarts { addBodyMarker(kind: s.kind, id: s.id, xml: s.xml, at: pos, para: paraIndex, leading: true) }
            pendingBodyStarts = []
        }
    }

    private func endParagraph(markRun: RunProps?) {
        var a = pAttrs
        if let markRun { a[.docxRun] = markRun }
        append("\n", a)
        paraIndex += 1
    }

    private func append(_ s: String, _ attrs: [NSAttributedString.Key: Any]) {
        out.append(NSAttributedString(string: s, attributes: attrs))
        pos += s.utf16.count
    }

    private func paragraph(_ p: Int32) {
        let pPrNode = x.child(p, x.id("w:pPr"))
        var kids: [RawChild] = []
        var sect: String?
        var markRun: RunProps?
        if let pPrNode {
            for c in x.children(pPrNode) {
                let name = x.name(c)
                if name == "w:sectPr" { sect = String(decoding: x.raw(c), as: UTF8.self); continue }
                if name == "w:rPr" { markRun = runProps(openAttrs: [], rPr: c) }
                kids.append(RawChild(name: name, xml: String(decoding: x.raw(c), as: UTF8.self)))
            }
        }
        let node = x.nodes[Int(p)]
        let props = ParaProps(openAttrs: String(decoding: x.openTag(p).dropFirst(4), as: UTF8.self), pPr: kids, sectPr: sect,
                              format: pPrNode.map { parseParaFormat(x, $0) } ?? ParaFormat(),
                              raw: Int(node.start) ..< Int(node.end))
        let mark = out.length, savedPos = pos, savedIndex = paraIndex
        let snapshot = markerSnapshot()
        beginParagraph(props)
        do {
            try container(p)
            endParagraph(markRun: markRun ?? RunProps.plain)
        } catch {
            // Undo the partial paragraph and seal it instead.
            out.deleteCharacters(in: NSRange(location: mark, length: out.length - mark))
            pos = savedPos; paraIndex = savedIndex
            paraProps.removeLast(); paraStarts.removeLast()
            restore(snapshot)
            sealBlock([p])
        }
    }

    private typealias Snapshot = ([Int: MarkerPart], [Int: MarkerPart], [Int: MarkerPart], [Int: MarkerPart], [Int: MarkerPart],
                                  [Int: [String]], [Int: Set<Int>], [(kind: String, id: Int?, xml: String)], Int)
    private func markerSnapshot() -> Snapshot {
        (bookmarkStarts, bookmarkEnds, commentStarts, commentEnds, commentRefs, points, pointComments, pendingBodyStarts, footnoteCount)
    }
    private func restore(_ s: Snapshot) {
        (bookmarkStarts, bookmarkEnds, commentStarts, commentEnds, commentRefs, points, pointComments, pendingBodyStarts, footnoteCount) = s
    }

    private func runProps(openAttrs: ArraySlice<UInt8>, rPr: Int32?) -> RunProps {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in openAttrs { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        h = (h ^ 0xff) &* 0x100_0000_01b3
        if let rPr { for b in x.inner(rPr) { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 } }
        if let r = runCache[h] { return r }
        var kids: [RawChild] = []
        if let rPr { for c in x.children(rPr) { kids.append(RawChild(name: x.name(c), xml: String(decoding: x.raw(c), as: UTF8.self))) } }
        let r = RunProps(openAttrs: String(decoding: openAttrs, as: UTF8.self), rPr: kids, format: rPr.map { parseRunFormat(x, $0) } ?? RunFormat())
        runCache[h] = r
        return r
    }

    private struct Field {
        var depth = 0
        var xml = ""
        var display = ""
        var separated = false
        var run: RunProps?
    }

    private func container(_ node: Int32) throws {
        var field: Field?
        for c in x.children(node) {
            let name = x.name(c)
            if field != nil {
                field!.xml += String(decoding: x.raw(c), as: UTF8.self)
                noteComments(in: x.raw(c))
                if name == "w:r" { scanField(c, &field!) }
                if field!.depth == 0 {
                    let f = field!
                    sealed(Sealed(xml: f.xml, isBlock: false, display: .text(f.display), commentIDs: commentIDs(f.xml)), run: f.run)
                    field = nil
                }
                continue
            }
            switch name {
            case "w:pPr", "w:proofErr", "w:smartTagPr", "w:customXmlPr":
                break
            case "w:r":
                if has(x.raw(c), "w:fldCharType=\"begin\"") {
                    var f = Field(xml: String(decoding: x.raw(c), as: UTF8.self))
                    f.run = runProps(openAttrs: x.openTag(c).dropFirst(4), rPr: x.child(c, x.id("w:rPr")))
                    scanField(c, &f)
                    noteComments(in: x.raw(c))
                    if f.depth == 0 {
                        sealed(Sealed(xml: f.xml, isBlock: false, display: .text(f.display), commentIDs: commentIDs(f.xml)), run: f.run)
                    } else {
                        field = f
                    }
                } else {
                    try run(c)
                }
            case "w:hyperlink":
                guard link == nil else { throw Locked() }
                let open = String(decoding: x.openTag(c), as: UTF8.self) + ">"
                let url = x.attr(c, "r:id").flatMap { doc.package.relationships[$0] }.flatMap { URL(string: $0.target) }
                link = Hyperlink(openTag: open, url: url, anchor: x.attr(c, "w:anchor"))
                try container(c)
                link = nil
            case "w:smartTag":
                try container(c)
            case "w:bookmarkStart", "w:bookmarkEnd", "w:commentRangeStart", "w:commentRangeEnd":
                let id = x.attr(c, "w:id").flatMap(Int.init)
                let part = MarkerPart(pos: pos, para: paraIndex, xml: String(decoding: x.raw(c), as: UTF8.self))
                switch (name, id) {
                case ("w:bookmarkStart", let id?): bookmarkStarts[id] = part
                case ("w:bookmarkEnd", let id?): bookmarkEnds[id] = part
                case ("w:commentRangeStart", let id?): commentStarts[id] = part
                case ("w:commentRangeEnd", let id?): commentEnds[id] = part
                default: point(part.xml, at: pos)
                }
            case "w:ins", "w:del", "w:moveFrom", "w:moveTo":
                throw Locked()
            default:
                if x.nodes[Int(c)].firstChild < 0 || x.text(c).isEmpty && !has(x.raw(c), "<w:drawing") && !has(x.raw(c), "<w:pict") {
                    // Empty markers such as permStart carry no text; keep them in place.
                    point(String(decoding: x.raw(c), as: UTF8.self), at: pos)
                    noteComments(in: x.raw(c))
                } else {
                    let xml = String(decoding: x.raw(c), as: UTF8.self)
                    sealed(Sealed(xml: xml, isBlock: false, display: .text(visibleText(c)), commentIDs: commentIDs(xml)), run: nil)
                }
            }
        }
        if field != nil { throw Locked() }
    }

    private func scanField(_ r: Int32, _ f: inout Field) {
        for k in x.children(r) {
            switch x.name(k) {
            case "w:fldChar":
                switch x.attr(k, "w:fldCharType") {
                case "begin": f.depth += 1
                case "separate": if f.depth == 1 { f.separated = true }
                case "end": f.depth -= 1
                default: break
                }
            case "w:t": if f.separated { f.display += x.text(k) }
            case "w:tab": if f.separated { f.display += "\t" }
            default: break
            }
        }
    }

    private func run(_ r: Int32) throws {
        let openAttrs = x.openTag(r).dropFirst(4)
        let rPr = x.child(r, x.id("w:rPr"))
        let props = runProps(openAttrs: openAttrs, rPr: rPr)
        var text = ""
        func flush() {
            guard !text.isEmpty else { return }
            var a = styler?.runAttributes(cur, props, link: link) ?? [:]
            for (k, v) in pAttrs where a[k] == nil { a[k] = v }
            a[.docxRun] = props
            if let link { a[.docxLink] = link }
            append(text, a)
            text = ""
        }
        let rPrXML = rPr.map { String(decoding: x.raw($0), as: UTF8.self) } ?? ""
        let open = String(decoding: x.openTag(r), as: UTF8.self) + ">"
        func seal(_ c: Int32, _ display: Sealed.Display) {
            flush()
            let xml = open + rPrXML + String(decoding: x.raw(c), as: UTF8.self) + "</w:r>"
            sealed(Sealed(xml: xml, isBlock: false, display: display, commentIDs: commentIDs(xml)), run: props)
        }
        for c in x.children(r) {
            switch x.name(c) {
            case "w:rPr", "w:lastRenderedPageBreak": break
            case "w:t": text += inlineText(x.text(c))
            case "w:tab": text += "\t"
            case "w:br":
                switch x.attr(c, "w:type") {
                case "page", "column": seal(c, .pageBreak)
                default: if x.attr(c, "w:clear") != nil { seal(c, .text("")) } else { text += "\u{2028}" }
                }
            case "w:cr": text += "\u{2028}"
            case "w:noBreakHyphen": text += "\u{2011}"
            case "w:softHyphen": text += "\u{00AD}"
            case "w:commentReference":
                flush()
                if let id = x.attr(c, "w:id").flatMap(Int.init) {
                    commentRefs[id] = MarkerPart(pos: pos, para: paraIndex, xml: open + rPrXML + String(decoding: x.raw(c), as: UTF8.self) + "</w:r>")
                }
            case "w:footnoteReference", "w:endnoteReference":
                footnoteCount += 1
                seal(c, .footnote(footnoteCount))
            case "w:drawing", "w:pict", "w:object", "mc:AlternateContent":
                seal(c, imageDisplay(c))
            case "w:sym":
                let code = x.attr(c, "w:char").flatMap { UInt32($0, radix: 16) } ?? 0x3F
                let scalar = Unicode.Scalar(code >= 0xF000 ? code - 0xF000 : code) ?? "?"
                seal(c, .text(String(scalar)))
            case "w:instrText", "w:delText", "w:fldChar":
                throw Locked()
            default:
                seal(c, .text(visibleText(c)))
            }
        }
        flush()
    }

    private func sealed(_ s: Sealed, run: RunProps?) {
        var a = styler?.sealedAttributes(cur, run, s) ?? [:]
        for (k, v) in pAttrs where a[k] == nil { a[k] = v }
        a[.docxSealed] = s
        if let run { a[.docxRun] = run }
        if let link { a[.docxLink] = link }
        sealedCommentIDs.formUnion(s.commentIDs)
        append(String(objectReplacement), a)
    }

    private func noteComments(in raw: ArraySlice<UInt8>) {
        guard has(raw, "w:comment") else { return }
        sealedCommentIDs.formUnion(commentIDs(String(decoding: raw, as: UTF8.self)))
    }

    private func imageDisplay(_ c: Int32) -> Sealed.Display {
        let embed = x.descendant(c, "a:blip").flatMap { x.attr($0, "r:embed") }
            ?? x.descendant(c, "v:imagedata").flatMap { x.attr($0, "r:id") }
        var w = 0.0, h = 0.0
        if let e = x.descendant(c, "wp:extent"), let cx = x.attr(e, "cx").flatMap(Double.init), let cy = x.attr(e, "cy").flatMap(Double.init) {
            w = cx / 12700; h = cy / 12700
        } else if let shape = x.descendant(c, "v:shape"), let style = x.attr(shape, "style") {
            w = cssPoints(style, "width"); h = cssPoints(style, "height")
        }
        if let embed, w > 0, h > 0 { return .image(relId: embed, width: w, height: h) }
        let t = visibleText(c)
        return .text(t.isEmpty ? "▢" : t)
    }

    // MARK: sealed blocks

    private func sealBlock(_ nodes: [Int32]) {
        let xml = nodes.map { String(decoding: x.raw($0), as: UTF8.self) }.joined()
        let display: Sealed.Display
        if nodes.count == 1, x.name(nodes[0]) == "w:tbl" {
            display = tableDisplay(nodes[0])
        } else {
            display = .paragraphs(nodes.flatMap { paragraphTexts($0) })
        }
        let s = Sealed(xml: xml, isBlock: true, display: display, commentIDs: commentIDs(xml))
        sealedCommentIDs.formUnion(s.commentIDs)
        let p = ParaProps.sealedBlock()
        beginParagraph(p)
        var a = styler?.sealedAttributes(p, nil, s) ?? [:]
        for (k, v) in pAttrs where a[k] == nil { a[k] = v }
        a[.docxSealed] = s
        append(String(objectReplacement), a)
        endParagraph(markRun: nil)
    }

    private func paragraphTexts(_ n: Int32) -> [String] {
        if x.name(n) == "w:p" { return [visibleText(n)] }
        if x.name(n) == "w:tbl", case .table(let rows, _) = tableDisplay(n) { return rows.map { $0.joined(separator: "  |  ") } }
        return x.children(n).flatMap { paragraphTexts($0) }
    }

    private func tableDisplay(_ t: Int32) -> Sealed.Display {
        var rows: [[String]] = []
        var widths: [Double] = []
        for c in x.children(t) {
            switch x.name(c) {
            case "w:tblGrid":
                widths = x.children(c).compactMap { twipsToPt(x.attr($0, "w:w")) }
            case "w:tr":
                rows.append(x.children(c).filter { x.name($0) == "w:tc" }.map { paragraphTexts($0).joined(separator: "\n") })
            default: break
            }
        }
        return .table(rows: rows, columnWidths: widths)
    }

    func visibleText(_ n: Int32) -> String { DocxCore.visibleText(x, n) }

    // MARK: markers

    /// Turns paired markers into ranges and leaves the rest as point markers.
    func finishMarkers() {
        var ranges: [(NSRange, bookmark: Int?, comment: Int?)] = []
        func span(_ s: MarkerPart, _ e: MarkerPart, _ mark: MarkRef? = nil) {
            guard s.para != e.para || s.para < 0 else { return }
            if let mark, s.para >= 0, e.para >= 0 {
                paraProps[s.para].rawOpens.append(mark)
                paraProps[e.para].rawCloses.append(mark)
            } else {
                paraProps[paraIndexAt(s.pos)].selfContained = false
                paraProps[paraIndexAt(e.pos)].selfContained = false
            }
        }
        for (id, s) in bookmarkStarts {
            if let e = bookmarkEnds[id], e.pos > s.pos {
                ranges.append((NSRange(location: s.pos, length: e.pos - s.pos), id, nil))
                doc.bookmarks[id] = (s.xml, e.xml)
                span(s, e, MarkRef(comment: false, id: id))
                bookmarkEnds[id] = nil
            } else {
                point(s.xml, at: s.pos)
            }
        }
        for (id, r) in commentRefs { doc.commentRefXML[id] = r.xml }
        for (_, e) in bookmarkEnds { point(e.xml, at: e.pos) }

        let ids = Set(commentStarts.keys).union(commentEnds.keys).union(commentRefs.keys)
        for id in ids.sorted() {
            let s = commentStarts[id], e = commentEnds[id], r = commentRefs[id]
            var anchored = false
            if !sealedCommentIDs.contains(id) {
                if let s, let e, e.pos > s.pos {
                    ranges.append((NSRange(location: s.pos, length: e.pos - s.pos), nil, id))
                    if let r, r.para != e.para { span(s, e); span(e, r) } else { span(s, e, MarkRef(comment: true, id: id)) }
                    anchored = true
                } else if let r, let near = anchorNear(r.pos) {
                    ranges.append((NSRange(location: near, length: 1), nil, id))
                    for p in [s, e].compactMap({ $0 }) { span(p, r) }
                    paraProps[paraIndexAt(r.pos)].selfContained = false
                    anchored = true
                }
            }
            if !anchored {
                for p in [s, e, r].compactMap({ $0 }) { point(p.xml, at: p.pos, comment: id) }
            }
        }

        let str = out.string as NSString
        for (loc, xmls) in points {
            let at = min(loc, str.length - 1)
            guard at >= 0 else { continue }
            let pm = PointMarks(xml: xmls, commentIDs: pointComments[loc] ?? [])
            out.addAttribute(.docxPoints, value: pm, range: NSRange(location: at, length: 1))
        }
        guard !ranges.isEmpty else { return }
        // Sweep over range edges so overlapping ranges combine into one MarkSet per interval.
        var events: [(pos: Int, open: Bool, bookmark: Int?, comment: Int?)] = []
        for (r, bid, cid) in ranges {
            events.append((r.location, true, bid, cid))
            events.append((NSMaxRange(r), false, bid, cid))
        }
        events.sort { $0.pos < $1.pos }
        var bm: [Int: Int] = [:], cm: [Int: Int] = [:]
        var k = 0
        while k < events.count {
            let at = events[k].pos
            while k < events.count, events[k].pos == at {
                let e = events[k]
                if let b = e.bookmark { bm[b, default: 0] += e.open ? 1 : -1; if bm[b] == 0 { bm[b] = nil } }
                if let c = e.comment { cm[c, default: 0] += e.open ? 1 : -1; if cm[c] == 0 { cm[c] = nil } }
                k += 1
            }
            guard k < events.count, !(bm.isEmpty && cm.isEmpty) else { continue }
            let span = NSRange(location: at, length: events[k].pos - at)
            guard span.length > 0 else { continue }
            // Marks never cover sealed blocks.
            let set = MarkSet(bookmarks: Array(bm.keys), comments: Array(cm.keys))
            var targets: [NSRange] = []
            out.enumerateAttribute(.docxSealed, in: span) { v, r, _ in
                if (v as? Sealed)?.isBlock != true { targets.append(r) }
            }
            for r in targets { out.addAttribute(.docxMarks, value: set, range: r) }
        }
    }

    private func anchorNear(_ p: Int) -> Int? {
        let str = out.string as NSString
        let k = paraIndexAt(p)
        let start = paraStarts[k]
        if p > start { return p - 1 }
        if p < str.length, str.character(at: p) != 10 { return p }
        return nil
    }

    func paraIndexAt(_ p: Int) -> Int {
        var lo = 0, hi = paraStarts.count - 1
        while lo < hi { let m = (lo + hi + 1) / 2; if paraStarts[m] <= p { lo = m } else { hi = m - 1 } }
        return max(lo, 0)
    }
}

// MARK: helpers

/// Word shows raw line breaks inside `w:t` as spaces; here they would split the paragraph.
func inlineText(_ s: String) -> String {
    guard s.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{85}" || $0 == "\u{2029}" }) else { return s }
    return String(String.UnicodeScalarView(s.unicodeScalars.map { ["\n", "\r", "\u{85}", "\u{2029}"].contains($0) ? " " : $0 }))
}

func has(_ s: ArraySlice<UInt8>, _ pattern: String) -> Bool {
    let p = Array(pattern.utf8)
    return s.withUnsafeBytes { buf in
        p.withUnsafeBytes { pat in memmem(buf.baseAddress, buf.count, pat.baseAddress, pat.count) != nil }
    }
}

func count(_ s: ArraySlice<UInt8>, _ pattern: String) -> Int {
    let p = Array(pattern.utf8)
    return s.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
        p.withUnsafeBytes { (pat: UnsafeRawBufferPointer) -> Int in
            guard let base = buf.baseAddress else { return 0 }
            var n = 0, off = 0
            while off < buf.count, let hit = memmem(base + off, buf.count - off, pat.baseAddress, pat.count) {
                n += 1
                off = UnsafeRawPointer(hit) - base + pat.count
            }
            return n
        }
    }
}

private let regexCache = NSCache<NSString, NSRegularExpression>()

func regex(_ pattern: String) -> NSRegularExpression {
    if let r = regexCache.object(forKey: pattern as NSString) { return r }
    let r = try! NSRegularExpression(pattern: pattern)
    regexCache.setObject(r, forKey: pattern as NSString)
    return r
}

func firstMatch(_ s: String, _ pattern: String) -> String? {
    guard case let re = regex(pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[r])
}

func commentIDs(_ xml: String) -> Set<Int> {
    guard xml.contains("w:comment") else { return [] }
    var ids = Set<Int>()
    let re = regex(#"<w:comment(?:Reference|RangeStart|RangeEnd)[^>]*w:id="(\d+)""#)
    for m in re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
        if let r = Range(m.range(at: 1), in: xml), let v = Int(xml[r]) { ids.insert(v) }
    }
    return ids
}

private func cssPoints(_ style: String, _ key: String) -> Double {
    guard let v = firstMatch(style, key + #":\s*([\d.]+)(pt|in|px)?"#).flatMap(Double.init) else { return 0 }
    let unit = firstMatch(style, key + #":\s*[\d.]+(pt|in|px)"#) ?? "pt"
    return unit == "in" ? v * 72 : unit == "px" ? v * 0.75 : v
}

func visibleText(_ x: XDoc, _ n: Int32) -> String {
    if x.isText(n) { return "" }
    switch x.name(n) {
    case "w:t": return x.text(n)
    case "w:tab": return "\t"
    case "w:br", "w:cr": return "\n"
    case "w:instrText", "w:delText", "w:delInstrText", "w:rPr", "w:pPr", "mc:Fallback": return ""
    default: return x.children(n).map { visibleText(x, $0) }.joined()
    }
}
