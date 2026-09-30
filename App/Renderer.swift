import AppKit
import DocxCore

extension NSAttributedString.Key {
    /// The list label drawn in the paragraph's margin, as an attributed string.
    static let listLabel = NSAttributedString.Key("docxer.listLabel")
    /// Where the list label starts, in points from the text's left edge.
    static let listLabelX = NSAttributedString.Key("docxer.listLabelX")
}

/// Derives display attributes (fonts, paragraph styles, colours, attachments) from the Word model.
final class Renderer: Styler {
    let doc: WordDocument
    private var fontCache: [FontKey: NSFont] = [:]
    private var paraCache: [ParaFormat: NSParagraphStyle] = [:]
    private var runCache: [RunKey: [NSAttributedString.Key: Any]] = [:]
    private var counters: [Int: [Int]] = [:]

    init(doc: WordDocument) { self.doc = doc }

    private struct FontKey: Hashable { let family: String?; let size: Double; let bold: Bool; let italic: Bool }
    private struct RunKey: Hashable { let style: String?; let run: RunProps; let link: Bool }

    // MARK: Styler

    func paragraphAttributes(_ p: ParaProps) -> [NSAttributedString.Key: Any] {
        if p.isSealed { return [.paragraphStyle: blockStyle] }
        let (styleFormat, styleRun) = doc.styles.resolved(paragraphStyle: p.styleId)
        var f = styleFormat
        var label: String?
        let numbered = styleFormat.overlaid(p.format)
        if let n = numbered.numId, n != 0, let lvl = doc.numbering.level(n, numbered.ilvl ?? 0) {
            // Indent precedence: style, then list level, then direct formatting.
            f.indentLeft = lvl.indentLeft ?? f.indentLeft
            f.firstLine = lvl.firstLine ?? f.firstLine
            label = doc.numbering.label(numId: n, ilvl: numbered.ilvl ?? 0, counters: &counters)
        }
        f = f.overlaid(p.format)
        var a: [NSAttributedString.Key: Any] = [:]
        if let label, !label.isEmpty {
            let left = f.indentLeft ?? 0, first = f.firstLine ?? 0
            let labelX = first < 0 ? left + first : max(0, left - 18)
            f.firstLine = nil
            a[.listLabel] = NSAttributedString(string: label, attributes: runDisplay(styleRun, link: false))
            a[.listLabelX] = labelX
        }
        a[.paragraphStyle] = paragraphStyle(f)
        if let shading = f.shading, let c = color(shading) { a[.backgroundColor] = c }
        return a
    }

    func runAttributes(_ p: ParaProps, _ r: RunProps, link: Hyperlink?) -> [NSAttributedString.Key: Any] {
        let key = RunKey(style: p.styleId, run: r, link: link != nil)
        var a: [NSAttributedString.Key: Any]
        if let c = runCache[key] { a = c } else {
            var f = doc.styles.resolved(paragraphStyle: p.styleId).1
            if let cs = r.format.charStyle { f = f.overlaid(doc.styles.resolved(characterStyle: cs)) }
            a = runDisplay(f.overlaid(r.format), link: link != nil)
            runCache[key] = a
        }
        if let url = link?.url { a[.link] = url }
        return a
    }

    func sealedAttributes(_ p: ParaProps, _ r: RunProps?, _ s: Sealed) -> [NSAttributedString.Key: Any] {
        var a = r.map { runAttributes(p, $0, link: nil) } ?? runAttributes(p, .plain, link: nil)
        let att = SealedAttachment(sealed: s, package: doc.package)
        if let f = a[.font] as? NSFont { att.font = f }
        a[.attachment] = att
        return a
    }

    func resetCounters() { counters = [:] }

    // MARK: restyling after edits

    /// Recomputes display attributes for the paragraphs touching `range`.
    func restyle(_ s: NSTextStorage, _ range: NSRange) {
        let str = s.string as NSString
        guard str.length > 0 else { return }
        let lo = min(range.location, str.length - 1)
        let span = str.paragraphRange(for: NSRange(location: lo, length: min(NSMaxRange(range), str.length) - lo))
        s.beginEditing()
        var p = span.location
        while p < NSMaxRange(span) {
            let pr = str.paragraphRange(for: NSRange(location: p, length: 0))
            guard let props = s.attribute(.docxPara, at: pr.location, effectiveRange: nil) as? ParaProps else { p = NSMaxRange(pr); continue }
            // List labels depend on every earlier paragraph, so relabel() owns them.
            var pa = paragraphAttributes(props)
            pa[.listLabel] = nil
            pa[.listLabelX] = nil
            s.addAttributes(pa, range: pr)
            if pa[.backgroundColor] == nil, !props.isSealed { s.removeAttribute(.backgroundColor, range: pr) }
            var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
            s.enumerateAttributes(in: pr) { a, r, _ in
                let run = a[.docxRun] as? RunProps ?? .plain
                if let sealed = a[.docxSealed] as? Sealed {
                    var d = runAttributes(props, run, link: nil)
                    d[.attachment] = a[.attachment] ?? sealedAttributes(props, run, sealed)[.attachment]
                    runs.append((r, d))
                } else {
                    runs.append((r, runAttributes(props, run, link: a[.docxLink] as? Hyperlink)))
                }
            }
            for (r, d) in runs {
                for k in [NSAttributedString.Key.link, .underlineStyle, .strikethroughStyle, .backgroundColor, .baselineOffset, .toolTip]
                where d[k] == nil { s.removeAttribute(k, range: r) }
                s.addAttributes(d, range: r)
            }
            p = NSMaxRange(pr)
        }
        s.endEditing()
    }

    /// Recomputes list labels for the whole document; only changed paragraphs are touched.
    func relabel(_ s: NSTextStorage) {
        counters = [:]
        var updates: [(NSRange, Any?, Any?)] = []
        s.enumerateAttribute(.docxPara, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            guard let p = v as? ParaProps, !p.isSealed else { return }
            let pa = paragraphAttributes(p)
            let old = s.attribute(.listLabel, at: r.location, effectiveRange: nil) as? NSAttributedString
            let new = pa[.listLabel] as? NSAttributedString
            if old?.string != new?.string { updates.append((r, new, pa[.listLabelX])) }
        }
        guard !updates.isEmpty else { return }
        s.beginEditing()
        for (r, label, x) in updates {
            if let label { s.addAttribute(.listLabel, value: label, range: r); s.addAttribute(.listLabelX, value: x!, range: r) } else {
                s.removeAttribute(.listLabel, range: r)
            }
        }
        s.endEditing()
    }

    // MARK: mapping

    private lazy var blockStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 6; p.paragraphSpacingBefore = 6
        return p
    }()

    func paragraphStyle(_ f: ParaFormat) -> NSParagraphStyle {
        if let c = paraCache[f] { return c }
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = f.spaceBefore ?? 0
        p.paragraphSpacing = f.spaceAfter ?? 0
        if let l = f.lineSpacing {
            if f.lineAuto ?? true { p.lineHeightMultiple = max(0.5, l) } else if f.lineExact == true {
                p.minimumLineHeight = l; p.maximumLineHeight = l
            } else { p.minimumLineHeight = l }
        }
        let left = f.indentLeft ?? 0
        p.headIndent = max(0, left)
        p.firstLineHeadIndent = max(0, left + (f.firstLine ?? 0))
        p.tailIndent = -(f.indentRight ?? 0)
        switch f.align {
        case "center": p.alignment = .center
        case "right", "end": p.alignment = .right
        case "both", "distribute", "lowKashida", "mediumKashida", "highKashida", "thaiDistribute": p.alignment = .justified
        default: p.alignment = .natural
        }
        p.defaultTabInterval = 36
        p.tabStops = []
        paraCache[f] = p
        return p
    }

    private func runDisplay(_ f: RunFormat, link: Bool) -> [NSAttributedString.Key: Any] {
        var size = f.size ?? 10
        var a: [NSAttributedString.Key: Any] = [:]
        if let v = f.vertAlign, v == "superscript" || v == "subscript" {
            a[.baselineOffset] = v == "superscript" ? size * 0.35 : -size * 0.15
            size *= 0.65
        }
        a[.font] = font(f.font, size: size, bold: f.bold ?? false, italic: f.italic ?? false)
        if f.underline == true || link { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if f.strike == true { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        var fg: NSColor = link ? .linkColor : color(f.color) ?? .textColor
        if let h = f.highlight, let bg = highlight(h) {
            a[.backgroundColor] = bg
            if f.color == nil || f.color == "auto" { fg = .black }
        }
        if f.hidden == true {
            fg = .tertiaryLabelColor
            a[.underlineStyle] = NSUnderlineStyle.single.union(.patternDot).rawValue
        }
        a[.foregroundColor] = fg
        return a
    }

    func font(_ family: String?, size: Double, bold: Bool, italic: Bool) -> NSFont {
        let key = FontKey(family: family, size: size, bold: bold, italic: italic)
        if let f = fontCache[key] { return f }
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let fm = NSFontManager.shared
        var font: NSFont?
        for name in candidates(family) {
            if let f = fm.font(withFamily: name, traits: traits, weight: bold ? 9 : 5, size: size) { font = f; break }
        }
        if font == nil {
            var f = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
            font = f
        }
        fontCache[key] = font
        return font!
    }

    private func candidates(_ family: String?) -> [String] {
        guard let family, !family.isEmpty else { return ["Helvetica Neue"] }
        let fallback: String
        switch family.lowercased() {
        case "calibri", "aptos", "arial", "segoe ui", "tahoma", "verdana", "calibri light", "arial narrow": fallback = "Helvetica Neue"
        case "cambria", "georgia", "garamond", "book antiqua", "palatino linotype", "pt serif": fallback = "Times New Roman"
        case "consolas", "courier new", "lucida console": fallback = "Menlo"
        default: fallback = "Helvetica Neue"
        }
        return [family, fallback]
    }

    private func color(_ hex: String?) -> NSColor? {
        guard let hex, hex != "auto", hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        // Pure black means "default" in practice, so it follows dark mode.
        if v == 0 { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    private func highlight(_ name: String) -> NSColor? {
        let named: [String: UInt32] = ["yellow": 0xFFFF00, "green": 0x00FF00, "cyan": 0x00FFFF, "magenta": 0xFF00FF, "blue": 0x0000FF,
                                       "red": 0xFF0000, "darkBlue": 0x000080, "darkCyan": 0x008080, "darkGreen": 0x008000,
                                       "darkMagenta": 0x800080, "darkRed": 0x800000, "darkYellow": 0x808000, "darkGray": 0x808080,
                                       "lightGray": 0xC0C0C0, "black": 0x000000, "white": 0xFFFFFF]
        if name == "none" || name == "auto" { return nil }
        let v = named[name] ?? UInt32(name, radix: 16)
        guard let v else { return nil }
        if name == "white" || v == 0xFFFFFF { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
