import Foundation

/// Character formatting; nil means "inherit".
public struct RunFormat: Hashable, Sendable {
    public var font: String?
    public var size: Double?          // points
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strike: Bool?
    public var color: String?         // hex RRGGBB, nil or "auto" for default
    public var highlight: String?     // highlight name or hex fill
    public var vertAlign: String?
    public var caps: Bool?
    public var smallCaps: Bool?
    public var hidden: Bool?
    public var charStyle: String?

    public init() {}

    /// `other` wins wherever it is set.
    public func overlaid(_ o: RunFormat) -> RunFormat {
        var r = self
        r.font = o.font ?? font; r.size = o.size ?? size; r.bold = o.bold ?? bold; r.italic = o.italic ?? italic
        r.underline = o.underline ?? underline; r.strike = o.strike ?? strike; r.color = o.color ?? color
        r.highlight = o.highlight ?? highlight; r.vertAlign = o.vertAlign ?? vertAlign; r.caps = o.caps ?? caps
        r.smallCaps = o.smallCaps ?? smallCaps; r.hidden = o.hidden ?? hidden; r.charStyle = o.charStyle ?? charStyle
        return r
    }
}

public struct ParaFormat: Hashable, Sendable {
    public var spaceBefore: Double?   // points
    public var spaceAfter: Double?
    public var lineSpacing: Double?   // multiple when lineAuto, else points
    public var lineAuto: Bool?
    public var lineExact: Bool?
    public var indentLeft: Double?
    public var indentRight: Double?
    public var firstLine: Double?     // negative for hanging
    public var align: String?
    public var outlineLevel: Int?
    public var numId: Int?
    public var ilvl: Int?
    public var contextualSpacing: Bool?
    public var shading: String?

    public init() {}

    public func overlaid(_ o: ParaFormat) -> ParaFormat {
        var r = self
        r.spaceBefore = o.spaceBefore ?? spaceBefore; r.spaceAfter = o.spaceAfter ?? spaceAfter
        if o.lineSpacing != nil { r.lineSpacing = o.lineSpacing; r.lineAuto = o.lineAuto; r.lineExact = o.lineExact }
        r.indentLeft = o.indentLeft ?? indentLeft; r.indentRight = o.indentRight ?? indentRight
        r.firstLine = o.firstLine ?? firstLine; r.align = o.align ?? align; r.outlineLevel = o.outlineLevel ?? outlineLevel
        if o.numId != nil { r.numId = o.numId; r.ilvl = o.ilvl ?? 0 } else if o.ilvl != nil { r.ilvl = o.ilvl }
        r.contextualSpacing = o.contextualSpacing ?? contextualSpacing; r.shading = o.shading ?? shading
        return r
    }
}

func onOff(_ x: XDoc, _ n: Int32) -> Bool {
    guard let v = x.attr(n, "w:val") else { return true }
    return !(v == "0" || v == "false" || v == "off" || v == "none")
}

func twipsToPt(_ s: String?) -> Double? { s.flatMap(Double.init).map { $0 / 20 } }

public func parseRunFormat(_ x: XDoc, _ rPr: Int32) -> RunFormat {
    var f = RunFormat()
    for c in x.children(rPr) {
        switch x.name(c) {
        case "w:rFonts": f.font = x.attr(c, "w:ascii") ?? x.attr(c, "w:hAnsi") ?? x.attr(c, "w:cs") ?? x.attr(c, "w:eastAsia")
        case "w:sz": f.size = x.attr(c, "w:val").flatMap(Double.init).map { $0 / 2 }
        case "w:b": f.bold = onOff(x, c)
        case "w:i": f.italic = onOff(x, c)
        case "w:u": f.underline = x.attr(c, "w:val").map { $0 != "none" } ?? true
        case "w:strike", "w:dstrike": f.strike = onOff(x, c)
        case "w:color": f.color = x.attr(c, "w:val")
        case "w:highlight": f.highlight = x.attr(c, "w:val")
        case "w:shd": if let fill = x.attr(c, "w:fill"), fill != "auto" { f.highlight = fill }
        case "w:vertAlign": f.vertAlign = x.attr(c, "w:val")
        case "w:caps": f.caps = onOff(x, c)
        case "w:smallCaps": f.smallCaps = onOff(x, c)
        case "w:vanish": f.hidden = onOff(x, c)
        case "w:rStyle": f.charStyle = x.attr(c, "w:val")
        default: break
        }
    }
    return f
}

public func parseParaFormat(_ x: XDoc, _ pPr: Int32) -> ParaFormat {
    var f = ParaFormat()
    for c in x.children(pPr) {
        switch x.name(c) {
        case "w:spacing":
            f.spaceBefore = twipsToPt(x.attr(c, "w:before"))
            f.spaceAfter = twipsToPt(x.attr(c, "w:after"))
            if x.attr(c, "w:beforeAutospacing") == "1" { f.spaceBefore = 14 }
            if x.attr(c, "w:afterAutospacing") == "1" { f.spaceAfter = 14 }
            if let line = x.attr(c, "w:line").flatMap(Double.init) {
                let rule = x.attr(c, "w:lineRule") ?? "auto"
                f.lineAuto = rule == "auto"
                f.lineExact = rule == "exact"
                f.lineSpacing = rule == "auto" ? line / 240 : line / 20
            }
        case "w:ind":
            f.indentLeft = twipsToPt(x.attr(c, "w:left") ?? x.attr(c, "w:start"))
            f.indentRight = twipsToPt(x.attr(c, "w:right") ?? x.attr(c, "w:end"))
            if let h = twipsToPt(x.attr(c, "w:hanging")) { f.firstLine = -h } else if let fl = twipsToPt(x.attr(c, "w:firstLine")) { f.firstLine = fl }
        case "w:jc": f.align = x.attr(c, "w:val")
        case "w:outlineLvl": f.outlineLevel = x.attr(c, "w:val").flatMap(Int.init)
        case "w:numPr":
            if let n = x.child(c, x.id("w:numId")) { f.numId = x.attr(n, "w:val").flatMap(Int.init) }
            if let l = x.child(c, x.id("w:ilvl")) { f.ilvl = x.attr(l, "w:val").flatMap(Int.init) }
        case "w:contextualSpacing": f.contextualSpacing = onOff(x, c)
        case "w:shd": if let fill = x.attr(c, "w:fill"), fill != "auto" { f.shading = fill }
        default: break
        }
    }
    return f
}

public final class StyleSheet: @unchecked Sendable {
    public struct Style {
        public let id: String
        public let type: String
        public let name: String
        public let basedOn: String?
        public let next: String?
        public let run: RunFormat
        public let para: ParaFormat
        public let hidden: Bool
        public let priority: Int
    }

    public private(set) var styles: [String: Style] = [:]
    public private(set) var order: [String] = []
    public private(set) var defaultRun = RunFormat()
    public private(set) var defaultPara = ParaFormat()
    public private(set) var defaultParagraphStyle: String?
    private var paraCache: [String: (ParaFormat, RunFormat)] = [:]
    private var charCache: [String: RunFormat] = [:]
    private let lock = NSLock()   // caches fill from the background loader too

    public init(_ bytes: [UInt8]?) {
        guard let bytes, let x = try? XDoc(bytes) else { return }
        for c in x.children(x.root) {
            switch x.name(c) {
            case "w:docDefaults":
                if let rd = x.child(c, x.id("w:rPrDefault")), let r = x.child(rd, x.id("w:rPr")) { defaultRun = parseRunFormat(x, r) }
                if let pd = x.child(c, x.id("w:pPrDefault")), let p = x.child(pd, x.id("w:pPr")) { defaultPara = parseParaFormat(x, p) }
            case "w:style":
                guard let id = x.attr(c, "w:styleId") else { continue }
                let type = x.attr(c, "w:type") ?? "paragraph"
                let val: (String) -> String? = { n in x.child(c, x.id(n)).flatMap { x.attr($0, "w:val") } }
                let s = Style(id: id, type: type, name: val("w:name") ?? id, basedOn: val("w:basedOn"), next: val("w:next"),
                              run: x.child(c, x.id("w:rPr")).map { parseRunFormat(x, $0) } ?? RunFormat(),
                              para: x.child(c, x.id("w:pPr")).map { parseParaFormat(x, $0) } ?? ParaFormat(),
                              hidden: x.child(c, x.id("w:semiHidden")) != nil || x.child(c, x.id("w:hidden")) != nil,
                              priority: val("w:uiPriority").flatMap(Int.init) ?? 99)
                if styles[id] == nil { order.append(id) }
                styles[id] = s
                if type == "paragraph", x.attr(c, "w:default") == "1" { defaultParagraphStyle = id }
            default: break
            }
        }
    }

    /// Paragraph and run formatting a paragraph style resolves to, including document defaults.
    public func resolved(paragraphStyle id: String?) -> (ParaFormat, RunFormat) {
        let key = id ?? defaultParagraphStyle ?? ""
        lock.lock(); defer { lock.unlock() }
        if let c = paraCache[key] { return c }
        var chain: [Style] = []
        var cur: String? = key
        while let c = cur, let s = styles[c], s.type == "paragraph", chain.count < 20 { chain.append(s); cur = s.basedOn }
        var p = defaultPara, r = defaultRun
        for s in chain.reversed() { p = p.overlaid(s.para); r = r.overlaid(s.run) }
        paraCache[key] = (p, r)
        return (p, r)
    }

    public func resolved(characterStyle id: String) -> RunFormat {
        lock.lock(); defer { lock.unlock() }
        if let c = charCache[id] { return c }
        var chain: [Style] = []
        var cur: String? = id
        while let c = cur, let s = styles[c], s.type == "character", chain.count < 20 { chain.append(s); cur = s.basedOn }
        var r = RunFormat()
        for s in chain.reversed() { r = r.overlaid(s.run) }
        charCache[id] = r
        return r
    }

    /// 0-based heading level of a paragraph style, if it is a heading.
    public func headingLevel(_ id: String?) -> Int? {
        guard let id else { return nil }
        if let l = resolved(paragraphStyle: id).0.outlineLevel, l < 9 { return l }
        let name = (styles[id]?.name ?? id).lowercased()
        for prefix in ["heading ", "heading", "заголовок "] where name.hasPrefix(prefix) {
            if let n = Int(name.dropFirst(prefix.count)), n >= 1 { return n - 1 }
        }
        return nil
    }

    public func paragraphStyles() -> [Style] {
        order.compactMap { styles[$0] }.filter { $0.type == "paragraph" && !$0.hidden }
    }

    public func id(named name: String) -> String? {
        styles.values.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }
}

public final class Numbering: @unchecked Sendable {
    public struct Level {
        public var start = 1
        public var format = "decimal"
        public var text = "%1."
        public var indentLeft: Double?
        public var firstLine: Double?
    }

    public private(set) var abstracts: [Int: [Int: Level]] = [:]
    public private(set) var nums: [Int: (abstract: Int, starts: [Int: Int])] = [:]

    public init(_ bytes: [UInt8]?) {
        guard let bytes, let x = try? XDoc(bytes) else { return }
        for c in x.children(x.root) {
            switch x.name(c) {
            case "w:abstractNum":
                guard let aid = x.attr(c, "w:abstractNumId").flatMap(Int.init) else { continue }
                var levels: [Int: Level] = [:]
                for l in x.children(c) where x.name(l) == "w:lvl" {
                    guard let il = x.attr(l, "w:ilvl").flatMap(Int.init) else { continue }
                    var lv = Level()
                    let val: (String) -> String? = { n in x.child(l, x.id(n)).flatMap { x.attr($0, "w:val") } }
                    lv.start = val("w:start").flatMap(Int.init) ?? 1
                    lv.format = val("w:numFmt") ?? "decimal"
                    lv.text = val("w:lvlText") ?? ""
                    if let p = x.child(l, x.id("w:pPr")) {
                        let pf = parseParaFormat(x, p)
                        lv.indentLeft = pf.indentLeft; lv.firstLine = pf.firstLine
                    }
                    levels[il] = lv
                }
                abstracts[aid] = levels
            case "w:num":
                guard let nid = x.attr(c, "w:numId").flatMap(Int.init),
                      let a = x.child(c, x.id("w:abstractNumId")).flatMap({ x.attr($0, "w:val") }).flatMap(Int.init) else { continue }
                var starts: [Int: Int] = [:]
                for o in x.children(c) where x.name(o) == "w:lvlOverride" {
                    if let il = x.attr(o, "w:ilvl").flatMap(Int.init),
                       let s = x.child(o, x.id("w:startOverride")).flatMap({ x.attr($0, "w:val") }).flatMap(Int.init) { starts[il] = s }
                }
                nums[nid] = (a, starts)
            default: break
            }
        }
    }

    public func level(_ numId: Int, _ ilvl: Int) -> Level? {
        guard let n = nums[numId] else { return nil }
        guard var lv = abstracts[n.abstract]?[ilvl] else { return nil }
        if let s = n.starts[ilvl] { lv.start = s }
        return lv
    }

    public func isBullet(_ numId: Int) -> Bool { level(numId, 0)?.format == "bullet" }

    /// Computes list labels in document order. `counters` must persist across calls within one pass.
    public func label(numId: Int, ilvl: Int, counters: inout [Int: [Int]]) -> String? {
        guard numId != 0, let n = nums[numId], let lv = level(numId, ilvl) else { return nil }
        var c = counters[n.abstract] ?? []
        while c.count <= ilvl { c.append(Int.min) }
        c[ilvl] = c[ilvl] == Int.min ? lv.start : c[ilvl] + 1
        for k in (ilvl + 1) ..< max(c.count, ilvl + 1) { c[k] = Int.min }
        counters[n.abstract] = c
        if lv.format == "bullet" { return bulletGlyph(lv.text) }
        if lv.format == "none" { return "" }
        var out = lv.text
        for k in 0 ... ilvl {
            let lk = level(numId, k) ?? Level()
            let v = c[k] == Int.min ? lk.start : c[k]
            out = out.replacingOccurrences(of: "%\(k + 1)", with: format(v, lk.format))
        }
        return out
    }

    private func bulletGlyph(_ t: String) -> String {
        guard let s = t.unicodeScalars.first else { return "•" }
        switch s.value {
        case 0xF0B7, 0xF06C, 0x2022: return "•"
        case 0xF0A7, 0xF06E: return "▪"
        case 0x6F, 0xF06F: return "◦"
        case 0xF0D8, 0xF0E0: return "➢"
        case 0xF0FC: return "✓"
        default: return s.value >= 0xF000 ? "•" : t
        }
    }

    private func format(_ v: Int, _ fmt: String) -> String {
        switch fmt {
        case "lowerLetter": return letters(v, "abcdefghijklmnopqrstuvwxyz")
        case "upperLetter": return letters(v, "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        case "russianLower": return letters(v, "абвгдежзиклмнопрстуфхцчшщэюя")
        case "russianUpper": return letters(v, "АБВГДЕЖЗИКЛМНОПРСТУФХЦЧШЩЭЮЯ")
        case "lowerRoman": return roman(v).lowercased()
        case "upperRoman": return roman(v)
        case "decimalZero": return v < 10 ? "0\(v)" : "\(v)"
        default: return "\(v)"
        }
    }

    private func letters(_ v: Int, _ alphabet: String) -> String {
        let a = Array(alphabet)
        guard v > 0 else { return "\(v)" }
        return String(repeating: a[(v - 1) % a.count], count: (v - 1) / a.count + 1)
    }

    private func roman(_ v: Int) -> String {
        guard v > 0 else { return "\(v)" }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = v, s = ""
        for (k, r) in table { while n >= k { s += r; n -= k } }
        return s
    }
}
