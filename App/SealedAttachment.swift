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
        case .table(let rows, let widths):
            return CGRect(x: 0, y: 0, width: width, height: tableLayout(rows, widths, width).total)
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
        case .table(let rows, let widths):
            drawTable(rows, widths, rect)
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

    private func tableLayout(_ rows: [[String]], _ grid: [Double], _ width: CGFloat) -> (cols: [CGFloat], heights: [CGFloat], total: CGFloat) {
        let n = max(1, rows.map(\.count).max() ?? 1)
        var w = grid.count == n ? grid.map { CGFloat($0) } : Array(repeating: 1, count: n)
        let sum = w.reduce(0, +)
        w = w.map { $0 / max(sum, 1) * width }
        var heights: [CGFloat] = []
        for row in rows {
            var h: CGFloat = 0
            for (k, cell) in row.enumerated() {
                let cw = k < w.count ? w[k] : w.last!
                let r = label(cell, cellFont).boundingRect(with: CGSize(width: max(10, cw - 2 * Self.padding), height: .greatestFiniteMagnitude),
                                                                options: [.usesLineFragmentOrigin])
                h = max(h, ceil(r.height))
            }
            heights.append(h + 2 * Self.padding)
        }
        return (w, heights, heights.reduce(0, +) + 1)
    }

    private func drawTable(_ rows: [[String]], _ grid: [Double], _ rect: CGRect) {
        let (cols, heights, _) = tableLayout(rows, grid, rect.width)
        let grid = NSBezierPath()
        var y: CGFloat = 0.5
        for (i, row) in rows.enumerated() {
            var x: CGFloat = 0.5
            for (k, cell) in row.enumerated() {
                let cw = k < cols.count ? cols[k] : cols.last!
                let cellRect = CGRect(x: x, y: y, width: cw, height: heights[i])
                label(cell, cellFont).draw(with: cellRect.insetBy(dx: Self.padding, dy: Self.padding), options: [.usesLineFragmentOrigin])
                if k > 0 { grid.move(to: CGPoint(x: x, y: y)); grid.line(to: CGPoint(x: x, y: y + heights[i])) }
                x += cw
            }
            if i > 0 { grid.move(to: CGPoint(x: 0, y: y)); grid.line(to: CGPoint(x: rect.width, y: y)) }
            y += heights[i]
        }
        grid.appendRect(CGRect(x: 0.5, y: 0.5, width: rect.width - 1, height: y - 0.5))
        grid.lineWidth = 1
        NSColor.separatorColor.setStroke()
        grid.stroke()
    }
}
