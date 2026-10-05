import AppKit
import DocxCore

/// Draws a Sealed Object: images, fields, tables and locked paragraphs. Images decode on first draw.
final class SealedAttachment: NSTextAttachment {
    let sealed: Sealed
    private weak var package: DocxPackage?
    private var decoded: NSImage??

    init(sealed: Sealed, package: DocxPackage) {
        self.sealed = sealed
        self.package = package
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = false
        attachmentCell = Cell()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let padding: CGFloat = 6
    private var cellFont: NSFont { NSFontManager.shared.convert(font, toSize: max(9, font.pointSize - 1)) }

    private func availableWidth(_ container: NSTextContainer?, _ proposed: CGRect) -> CGFloat {
        let w = proposed.width > 1 ? proposed.width : (container?.size.width ?? 400)
        return max(60, w - 2)
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: NSTextLocation, textContainer: NSTextContainer?,
                                   proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        bounds(font: attributes[.font] as? NSFont ?? font, container: textContainer, proposed: proposedLineFragment)
    }

    func bounds(font: NSFont, container textContainer: NSTextContainer?, proposed proposedLineFragment: CGRect) -> CGRect {
        let width = availableWidth(textContainer, proposedLineFragment)
        switch sealed.display {
        case .image(_, let w, let h):
            let scale = min(1, width / max(w, 1))
            return CGRect(x: 0, y: font.descender, width: w * scale, height: h * scale)
        case .text(let s):
            let size = label(s, font).size()
            return CGRect(x: 0, y: font.descender, width: ceil(size.width) + 4, height: ceil(font.ascender - font.descender))
        case .footnote(let n):
            let size = label("\(n)", NSFont.systemFont(ofSize: font.pointSize * 0.65)).size()
            return CGRect(x: 0, y: 0, width: ceil(size.width) + 2, height: font.ascender)
        case .pageBreak:
            return CGRect(x: 0, y: 0, width: width, height: 14)
        case .table(let t):
            return CGRect(origin: .zero, size: tableLayout(t, width).size)
        case .paragraphs(let ps):
            return CGRect(x: 0, y: 0, width: width, height: blockText(ps).boundingRect(with: CGSize(width: width - 2 * Self.padding, height: .greatestFiniteMagnitude),
                                                                                   options: [.usesLineFragmentOrigin]).height + 2 * Self.padding)
        }
    }

    var font = NSFont.systemFont(ofSize: 12)

    /// AppKit's TextKit 2 text view draws non-view attachments through their cell.
    private final class Cell: NSTextAttachmentCell {
        override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
                                characterIndex charIndex: Int) -> NSRect {
            guard let a = attachment as? SealedAttachment else { return .zero }
            return a.bounds(font: a.font, container: textContainer, proposed: lineFrag)
        }

        override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
            guard let a = attachment as? SealedAttachment else { return }
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: cellFrame.minX, yBy: cellFrame.minY)
            if controlView?.isFlipped == false { t.translateX(by: 0, yBy: cellFrame.height); t.scaleX(by: 1, yBy: -1) }
            t.concat()
            a.draw(in: CGRect(origin: .zero, size: cellFrame.size), font: a.font, color: .textColor)
            NSGraphicsContext.restoreGraphicsState()
        }

        override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int) {
            draw(withFrame: cellFrame, in: controlView)
        }

        override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
            draw(withFrame: cellFrame, in: controlView)
        }
    }

    // sloplint: ignore[magic-numbers] placeholder insets and radii are one-off drawing offsets that read best inline
    func draw(in rect: CGRect, font: NSFont, color: NSColor) {
        switch sealed.display {
        case .image:
            if let img = image() { img.draw(in: rect) } else {
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).fill()
                label("image", NSFont.systemFont(ofSize: 10), .secondaryLabelColor).draw(at: CGPoint(x: rect.midX - 14, y: rect.midY - 6))
            }
        case .text(let s):
            NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            label(s, font, color).draw(at: CGPoint(x: 2, y: 0))
        case .footnote(let n):
            label("\(n)", NSFont.systemFont(ofSize: font.pointSize * 0.65), .linkColor).draw(at: CGPoint(x: 1, y: 0))
        case .pageBreak:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 0, y: rect.midY)); path.line(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.separatorColor.setStroke(); path.stroke()
        case .table(let t):
            drawTable(t, rect)
        case .paragraphs(let ps):
            NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            blockText(ps).draw(with: rect.insetBy(dx: Self.padding, dy: Self.padding), options: [.usesLineFragmentOrigin])
        }
    }

    private func label(_ s: String, _ font: NSFont, _ color: NSColor = .textColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    private func blockText(_ ps: [String]) -> NSAttributedString {
        label(ps.joined(separator: "\n"), cellFont, .secondaryLabelColor)
    }

    private func image() -> NSImage? {
        if let d = decoded { return d }
        var img: NSImage?
        if case .image(let rel, _, _) = sealed.display, let package, let path = package.partPath(forRelationship: rel), let bytes = package.part(path) {
            img = NSImage(data: Data(bytes))
        }
        decoded = .some(img)
        return img
    }

    // MARK: tables

    private struct TableLayout {
        var x: [CGFloat]        // column edges
        var y: [CGFloat]        // row edges
        var size: CGSize
    }

    private func tableLayout(_ t: Table, _ available: CGFloat) -> TableLayout {
        let n = max(1, t.rows.map { $0.reduce(0) { $0 + $1.span } }.max() ?? 1)
        var cols = t.columns.count >= n ? t.columns.map { CGFloat($0) } : Array(repeating: available / CGFloat(n), count: n)
        let total = cols.reduce(0, +)
        let target = min(available, t.percent.map { available * $0 } ?? total)
        if total > 0, total != target { cols = cols.map { $0 * target / total } }
        // Borders are centred on the cell edges, so the outer ones need half their width inside the bounds.
        let pad = ceil(CGFloat(t.rows.flatMap { $0.flatMap { $0.borders.compactMap { $0?.width } } }.max() ?? 1) / 2)
        let width = cols.reduce(0, +)
        let left = switch t.align { case "center": max(pad, (available - width) / 2); case "right", "end": max(pad, available - width - pad); default: pad }
        let x = cols.reduce(into: [left]) { $0.append($0.last! + $1) }
        var y = [pad]
        for (r, row) in t.rows.enumerated() {
            var h = CGFloat(r < t.minHeights.count ? t.minHeights[r] : 0)
            var k = 0
            for cell in row {
                let inset = insets(cell)
                let w = x[min(k + cell.span, x.count - 1)] - x[min(k, x.count - 1)] - inset.left - inset.right
                let text = cell.text.boundingRect(with: CGSize(width: max(10, w), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
                h = max(h, ceil(text.height) + inset.top + inset.bottom)
                k += cell.span
            }
            y.append(y.last! + h)
        }
        let right = t.align == nil || t.align == "left" || t.align == "start" ? x.last! + pad : available
        return TableLayout(x: x, y: y, size: CGSize(width: right, height: y.last! + pad))
    }

    private func insets(_ c: Table.Cell) -> NSEdgeInsets {
        let b = c.borders.map { CGFloat($0?.width ?? 0) }, m = c.margins.map { CGFloat($0) } as [CGFloat]
        return NSEdgeInsets(top: m[0] + b[0], left: m[1] + b[1], bottom: m[2] + b[2], right: m[3] + b[3])
    }

    private func drawTable(_ t: Table, _ rect: CGRect) {
        let l = tableLayout(t, rect.width)
        var edges: [(CGPoint, CGPoint, Table.Border?)] = []
        for (r, row) in t.rows.enumerated() {
            var k = 0
            for cell in row {
                let x0 = l.x[min(k, l.x.count - 1)], x1 = l.x[min(k + cell.span, l.x.count - 1)], y0 = l.y[r], y1 = l.y[r + 1]
                let inset = insets(cell)
                cell.text.draw(with: CGRect(x: x0 + inset.left, y: y0 + inset.top, width: x1 - x0 - inset.left - inset.right,
                                            height: y1 - y0 - inset.top - inset.bottom), options: [.usesLineFragmentOrigin])
                let corners = [CGPoint(x: x0, y: y0), CGPoint(x: x0, y: y1), CGPoint(x: x1, y: y1), CGPoint(x: x1, y: y0)]
                // top, left, bottom, right
                for (side, (a, b)) in [(corners[0], corners[3]), (corners[0], corners[1]), (corners[1], corners[2]), (corners[3], corners[2])].enumerated() {
                    edges.append((a, b, cell.borders[side]))
                }
                k += cell.span
            }
        }
        // Edges without a border get a faint guide, as word processors show them, drawn first so real borders cover it.
        let guides = NSBezierPath()
        for (a, b, border) in edges where (border?.width ?? 0) == 0 { guides.move(to: a); guides.line(to: b) }
        guides.lineWidth = 0.5
        NSColor.separatorColor.setStroke()
        guides.stroke()
        for (a, b, border) in edges {
            guard let border, border.width > 0 else { continue }
            let p = NSBezierPath()
            p.move(to: a); p.line(to: b)
            p.lineWidth = border.width
            p.lineCapStyle = .square
            borderColor(border.color).setStroke()
            p.stroke()
        }
    }

    private func borderColor(_ hex: String?) -> NSColor {
        // Black and automatic borders follow the text colour, so they stay visible in dark mode.
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16), v != 0 else { return .textColor }
        return NSColor(srgbRed: CGFloat(v >> 16) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
