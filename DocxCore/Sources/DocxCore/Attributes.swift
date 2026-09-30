import Foundation

public extension NSAttributedString.Key {
    /// `ParaProps`, uniform across a paragraph including its newline.
    static let docxPara = NSAttributedString.Key("docx.para")
    /// `RunProps` for text characters.
    static let docxRun = NSAttributedString.Key("docx.run")
    /// `Hyperlink` wrapping the characters.
    static let docxLink = NSAttributedString.Key("docx.link")
    /// `Sealed` on a U+FFFC character.
    static let docxSealed = NSAttributedString.Key("docx.sealed")
    /// `MarkSet`: bookmarks and comment anchors covering the characters.
    static let docxMarks = NSAttributedString.Key("docx.marks")
    /// `PointMarks`: raw XML written just before this character.
    static let docxPoints = NSAttributedString.Key("docx.points")
}

public let objectReplacement: Character = "\u{FFFC}"

/// A child element kept as raw XML, with its name for schema ordering.
public struct RawChild: Equatable, Hashable, Sendable {
    public let name: String
    public let xml: String
}

public final class ParaProps: NSObject, @unchecked Sendable {
    public let openAttrs: String          // attributes of <w:p ...>
    public let pPr: [RawChild]            // excluding sectPr
    public let sectPr: String?
    public let format: ParaFormat         // direct formatting
    public let isSealed: Bool
    /// Original `<w:p>` XML, usable while the paragraph is unedited and self-contained.
    let raw: Range<Int>?
    var selfContained = true
    /// Marks whose start or end XML sits inside `raw` but whose other end is in another paragraph.
    var rawOpens: [MarkRef] = []
    /// Markers found between paragraphs, written around `raw` when it is copied verbatim.
    var leading = ""
    var trailing = ""
    var rawCloses: [MarkRef] = []
    public internal(set) var dirty = false

    init(openAttrs: String, pPr: [RawChild], sectPr: String?, format: ParaFormat, raw: Range<Int>?, isSealed: Bool = false) {
        self.openAttrs = openAttrs; self.pPr = pPr; self.sectPr = sectPr; self.format = format; self.raw = raw; self.isSealed = isSealed
        styleId = pPr.first { $0.name == "w:pStyle" }.flatMap { attrValue($0.xml, "w:val") }
    }

    public static func sealedBlock() -> ParaProps { ParaProps(openAttrs: "", pPr: [], sectPr: nil, format: ParaFormat(), raw: nil, isSealed: true) }
    public static func plain() -> ParaProps { ParaProps(openAttrs: "", pPr: [], sectPr: nil, format: ParaFormat(), raw: nil) }

    public let styleId: String?

    /// A copy with the given changes; always starts dirty.
    public func with(style: String?? = .none, numbering: (numId: Int, ilvl: Int)?? = .none) -> ParaProps {
        var kids = pPr
        var f = format
        if case .some(let s) = style {
            kids.removeAll { $0.name == "w:pStyle" }
            if let s { kids.append(RawChild(name: "w:pStyle", xml: "<w:pStyle w:val=\"\(escapeXML(s, attribute: true))\"/>")) }
        }
        if case .some(let n) = numbering {
            kids.removeAll { $0.name == "w:numPr" }
            if let n {
                kids.append(RawChild(name: "w:numPr", xml: "<w:numPr><w:ilvl w:val=\"\(n.ilvl)\"/><w:numId w:val=\"\(n.numId)\"/></w:numPr>"))
                f.numId = n.numId; f.ilvl = n.ilvl
                // A list sets its own indent; direct indents would fight it.
                kids.removeAll { $0.name == "w:ind" }
                f.indentLeft = nil; f.firstLine = nil
            } else {
                f.numId = nil; f.ilvl = nil
            }
        }
        let p = ParaProps(openAttrs: stripIds(openAttrs), pPr: sortChildren(kids, pPrOrder), sectPr: sectPr, format: f, raw: nil)
        p.dirty = true
        return p
    }

    func copyForSplit() -> ParaProps {
        let p = ParaProps(openAttrs: stripIds(openAttrs), pPr: pPr, sectPr: nil, format: format, raw: nil)
        p.dirty = true
        return p
    }
}

struct MarkRef: Hashable {
    let comment: Bool
    let id: Int
}

public final class RunProps: NSObject, @unchecked Sendable {
    public let openAttrs: String
    public let rPr: [RawChild]
    public let format: RunFormat

    init(openAttrs: String, rPr: [RawChild], format: RunFormat) {
        self.openAttrs = openAttrs; self.rPr = rPr; self.format = format
    }

    public static let plain = RunProps(openAttrs: "", rPr: [], format: RunFormat())

    public override func isEqual(_ o: Any?) -> Bool {
        guard let o = o as? RunProps else { return false }
        return o === self || (o.openAttrs == openAttrs && o.rPr == rPr)
    }

    public override var hash: Int { var h = Hasher(); h.combine(openAttrs); h.combine(rPr); return h.finalize() }

    public enum Toggle: String { case bold = "w:b", italic = "w:i", underline = "w:u", strike = "w:strike" }

    /// A copy with the font family set, or removed (nil) so the style decides.
    public func with(font: String?) -> RunProps {
        var kids = rPr.filter { $0.name != "w:rFonts" }
        var f = format
        if let font {
            let v = escapeXML(font, attribute: true)
            kids.append(RawChild(name: "w:rFonts", xml: "<w:rFonts w:ascii=\"\(v)\" w:hAnsi=\"\(v)\" w:eastAsia=\"\(v)\" w:cs=\"\(v)\"/>"))
        }
        f.font = font
        return RunProps(openAttrs: openAttrs, rPr: sortChildren(kids, rPrOrder), format: f)
    }

    /// A copy with the size in points set, or removed (nil) so the style decides.
    public func with(size: Double?) -> RunProps {
        var kids = rPr.filter { $0.name != "w:sz" && $0.name != "w:szCs" }
        var f = format
        if let size {
            let half = Int((size * 2).rounded())
            kids += [RawChild(name: "w:sz", xml: "<w:sz w:val=\"\(half)\"/>"), RawChild(name: "w:szCs", xml: "<w:szCs w:val=\"\(half)\"/>")]
            f.size = Double(half) / 2
        } else {
            f.size = nil
        }
        return RunProps(openAttrs: openAttrs, rPr: sortChildren(kids, rPrOrder), format: f)
    }

    /// A copy with a toggle set on, off, or removed (nil) so the style decides.
    public func with(_ t: Toggle, _ on: Bool?) -> RunProps {
        let names: Set<String> = switch t {
        case .bold: ["w:b", "w:bCs"]
        case .italic: ["w:i", "w:iCs"]
        case .underline: ["w:u"]
        case .strike: ["w:strike", "w:dstrike"]
        }
        var kids = rPr.filter { !names.contains($0.name) }
        var f = format
        if let on {
            let off = on ? "" : " w:val=\"0\""
            switch t {
            case .bold: kids += [RawChild(name: "w:b", xml: "<w:b\(off)/>"), RawChild(name: "w:bCs", xml: "<w:bCs\(off)/>")]
            case .italic: kids += [RawChild(name: "w:i", xml: "<w:i\(off)/>"), RawChild(name: "w:iCs", xml: "<w:iCs\(off)/>")]
            case .underline: kids.append(RawChild(name: "w:u", xml: on ? "<w:u w:val=\"single\"/>" : "<w:u w:val=\"none\"/>"))
            case .strike: kids.append(RawChild(name: "w:strike", xml: "<w:strike\(off)/>"))
            }
        }
        switch t {
        case .bold: f.bold = on
        case .italic: f.italic = on
        case .underline: f.underline = on
        case .strike: f.strike = on
        }
        return RunProps(openAttrs: openAttrs, rPr: sortChildren(kids, rPrOrder), format: f)
    }
}

public final class Hyperlink: NSObject, @unchecked Sendable {
    public let openTag: String   // `<w:hyperlink ...>` start tag, complete
    public let url: URL?
    public let anchor: String?
    init(openTag: String, url: URL?, anchor: String?) { self.openTag = openTag; self.url = url; self.anchor = anchor }
}

/// Content the app shows but cannot edit, carried through saving verbatim.
public final class Sealed: NSObject, @unchecked Sendable {
    public enum Display {
        case text(String)
        case image(relId: String, width: Double, height: Double)   // points
        case table(rows: [[String]], columnWidths: [Double])
        case paragraphs([String])
        case footnote(Int)
        case pageBreak
    }

    public let xml: String
    public let isBlock: Bool
    public let display: Display
    let commentIDs: Set<Int>

    init(xml: String, isBlock: Bool, display: Display, commentIDs: Set<Int> = []) {
        self.xml = xml; self.isBlock = isBlock; self.display = display; self.commentIDs = commentIDs
    }

    public var plainText: String {
        switch display {
        case .text(let s): return s
        case .image: return ""
        case .table(let rows, _): return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .paragraphs(let p): return p.joined(separator: "\n")
        case .footnote(let n): return "[\(n)]"
        case .pageBreak: return ""
        }
    }
}

/// Bookmarks and comments covering a character. Compared by content so adjacent runs merge.
public final class MarkSet: NSObject, @unchecked Sendable {
    public let bookmarks: [Int]
    public let comments: [Int]

    public init(bookmarks: [Int], comments: [Int]) {
        self.bookmarks = bookmarks.sorted(); self.comments = comments.sorted()
    }

    public var isEmpty: Bool { bookmarks.isEmpty && comments.isEmpty }

    public override func isEqual(_ o: Any?) -> Bool {
        guard let o = o as? MarkSet else { return false }
        return o.bookmarks == bookmarks && o.comments == comments
    }

    public override var hash: Int { var h = Hasher(); h.combine(bookmarks); h.combine(comments); return h.finalize() }

    public func adding(comment id: Int) -> MarkSet { MarkSet(bookmarks: bookmarks, comments: Array(Set(comments + [id]))) }
    public func removing(comment id: Int) -> MarkSet { MarkSet(bookmarks: bookmarks, comments: comments.filter { $0 != id }) }
}

public final class PointMarks: NSObject, @unchecked Sendable {
    public let xml: [String]
    let commentIDs: Set<Int>
    init(xml: [String], commentIDs: Set<Int>) { self.xml = xml; self.commentIDs = commentIDs }
}

// MARK: schema order

let pPrOrder = ["w:pStyle", "w:keepNext", "w:keepLines", "w:pageBreakBefore", "w:framePr", "w:widowControl", "w:numPr",
                "w:suppressLineNumbers", "w:pBdr", "w:shd", "w:tabs", "w:suppressAutoHyphens", "w:kinsoku", "w:wordWrap",
                "w:overflowPunct", "w:topLinePunct", "w:autoSpaceDE", "w:autoSpaceDN", "w:bidi", "w:adjustRightInd",
                "w:snapToGrid", "w:spacing", "w:ind", "w:contextualSpacing", "w:mirrorIndents", "w:suppressOverlap", "w:jc",
                "w:textDirection", "w:textAlignment", "w:textboxTightWrap", "w:outlineLvl", "w:divId", "w:cnfStyle",
                "w:rPr", "w:sectPr", "w:pPrChange"]

let rPrOrder = ["w:rStyle", "w:rFonts", "w:b", "w:bCs", "w:i", "w:iCs", "w:caps", "w:smallCaps", "w:strike", "w:dstrike",
                "w:outline", "w:shadow", "w:emboss", "w:imprint", "w:noProof", "w:snapToGrid", "w:vanish", "w:webHidden",
                "w:color", "w:spacing", "w:w", "w:kern", "w:position", "w:sz", "w:szCs", "w:highlight", "w:u", "w:effect",
                "w:bdr", "w:shd", "w:fitText", "w:vertAlign", "w:rtl", "w:cs", "w:em", "w:lang", "w:eastAsianLayout",
                "w:specVanish", "w:oMath", "w:rPrChange"]

/// Stable sort into schema order; unknown elements keep their relative place after known ones before them.
func sortChildren(_ kids: [RawChild], _ order: [String]) -> [RawChild] {
    var rank: [String: Int] = [:]
    for (i, n) in order.enumerated() { rank[n] = i }
    var last = -1
    let keyed = kids.enumerated().map { (i, c) -> (Int, Int, RawChild) in
        if let r = rank[c.name] { last = r; return (r, i, c) }
        return (last, i, c)
    }
    return keyed.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.2)
}

func stripIds(_ attrs: String) -> String {
    guard attrs.contains("w14:") else { return attrs }
    return attrs.replacingOccurrences(of: #"\s+w14:(paraId|textId)="[^"]*""#, with: "", options: .regularExpression)
}

func attrValue(_ xml: String, _ name: String) -> String? {
    guard let r = xml.range(of: " \(name)=\"") else { return nil }
    guard let e = xml[r.upperBound...].firstIndex(of: "\"") else { return nil }
    return decodeEntities(Array(xml[r.upperBound ..< e].utf8)[...])
}
