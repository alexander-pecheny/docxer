import AppKit
import DocxCore

/// Draws list labels in the paragraph's hanging indent.
final class ListFragment: NSTextLayoutFragment {
    override var renderingSurfaceBounds: CGRect {
        let b = super.renderingSurfaceBounds
        return b.union(CGRect(x: b.minX - 400, y: b.minY, width: 1200, height: b.height))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let para = textElement as? NSTextParagraph, para.attributedString.length > 0,
              let label = para.attributedString.attribute(.listLabel, at: 0, effectiveRange: nil) as? NSAttributedString,
              let line = textLineFragments.first else { return }
        let x = para.attributedString.attribute(.listLabelX, at: 0, effectiveRange: nil) as? Double ?? 0
        let font = label.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 12)
        let baseline = line.typographicBounds.minY + line.glyphOrigin.y
        // Place the label relative to where the first line's text starts.
        let textStart = (para.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
        let lineStart = line.typographicBounds.minX + line.glyphOrigin.x
        NSGraphicsContext.saveGraphicsState()
        label.draw(at: CGPoint(x: point.x + lineStart - (textStart - x), y: point.y + baseline - font.ascender))
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class EditorTextView: NSTextView, NSTextLayoutManagerDelegate {
    weak var editor: EditorController?

    static let fragmentType = NSPasteboard.PasteboardType("me.pecheny.docxer.fragment")
    private static var clipboard: (token: String, text: NSAttributedString, doc: ObjectIdentifier)?

    func textLayoutManager(_ m: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in element: NSTextElement) -> NSTextLayoutFragment {
        if let p = element as? NSTextParagraph, p.attributedString.length > 0,
           p.attributedString.attribute(.listLabel, at: 0, effectiveRange: nil) != nil {
            return ListFragment(textElement: element, range: element.elementRange)
        }
        return NSTextLayoutFragment(textElement: element, range: element.elementRange)
    }

    // MARK: copy and paste

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [Self.fragmentType, .string] }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [Self.fragmentType, .fileURL, .png, .tiff, .string] }

    static let documentExtensions: Set<String> = ["docx", "docm", "dotx"]

    // NSTextView takes drag types from here, not from readablePasteboardTypes, and leaves out files without importsGraphics.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { readablePasteboardTypes }

    override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        type == .fileURL ? .copy : super.dragOperation(for: dragInfo, type: type)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage, let doc = editor?.word else { return false }
        let range = selectedRange()
        guard range.length > 0 else { return false }
        let fragment = storage.attributedSubstring(from: range)
        let token = UUID().uuidString
        Self.clipboard = (token, fragment, ObjectIdentifier(doc))
        pboard.declareTypes([Self.fragmentType, .string], owner: nil)
        pboard.setString(token, forType: Self.fragmentType)
        pboard.setString(plainText(fragment), forType: .string)
        return true
    }

    private func plainText(_ s: NSAttributedString) -> String {
        var out = ""
        s.enumerateAttribute(.docxSealed, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if let sealed = v as? Sealed { out += String(repeating: sealed.plainText, count: r.length) } else {
                out += (s.string as NSString).substring(with: r)
            }
        }
        return out.replacingOccurrences(of: "\u{2028}", with: "\n")
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .fileURL, let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            // Word files open as documents; image files are inserted; anything else is refused.
            let docs = urls.filter { Self.documentExtensions.contains($0.pathExtension.lowercased()) }
            for url in docs { NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in } }
            let images = urls.filter { !docs.contains($0) }.compactMap { url in (try? Data(contentsOf: url)).map { ($0, url.pathExtension) } }
            for (data, ext) in images { editor?.insertImage(data, ext: ext) }
            return !docs.isEmpty || !images.isEmpty
        }
        if type == .png || type == .tiff, let data = pboard.data(forType: type) {
            editor?.insertImage(data, ext: type == .png ? "png" : "tiff")
            return true
        }
        let range = rangeForUserTextChange
        guard range.location != NSNotFound else { return false }
        if type == Self.fragmentType, let token = pboard.string(forType: Self.fragmentType), let clip = Self.clipboard,
           clip.token == token, let doc = editor?.word, clip.doc == ObjectIdentifier(doc) {
            // Sealed Objects travel only within the same Package.
            let fragment = NSMutableAttributedString(attributedString: clip.text)
            let str = textStorage!.string as NSString
            if fragment.length > 0, (fragment.attribute(.docxSealed, at: 0, effectiveRange: nil) as? Sealed)?.isBlock == true,
               range.location > 0, str.character(at: range.location - 1) != 10 {
                fragment.insert(NSAttributedString(string: "\n", attributes: WordDocument.typingAttributes(typingAttributes)), at: 0)
            }
            if fragment.length > 0, (fragment.attribute(.docxSealed, at: fragment.length - 1, effectiveRange: nil) as? Sealed)?.isBlock == true {
                fragment.append(NSAttributedString(string: "\n", attributes: fragment.attributes(at: fragment.length - 1, effectiveRange: nil)))
            }
            return insert(fragment, range)
        }
        guard var text = pboard.string(forType: .string) else { return false }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return insert(NSAttributedString(string: text, attributes: WordDocument.typingAttributes(typingAttributes)), range)
    }

    private func insert(_ s: NSAttributedString, _ range: NSRange) -> Bool {
        guard shouldChangeText(in: range, replacementString: s.string) else { return false }
        textStorage!.replaceCharacters(in: range, with: s)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + s.length, length: 0))
        return true
    }

    // MARK: keys

    override func insertTab(_ sender: Any?) {
        if editor?.indentList(by: 1) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if editor?.indentList(by: -1) == true { return }
        super.insertBacktab(sender)
    }

    override func insertNewline(_ sender: Any?) {
        super.insertNewline(sender)
        editor?.applyNextStyleAfterNewline()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = super.menu(for: event) ?? NSMenu()
        m.insertItem(withTitle: "New Comment", action: #selector(EditorController.newComment(_:)), keyEquivalent: "", at: 0)
        m.insertItem(.separator(), at: 1)
        if let at = linkIndex(event), let link = editor?.link(at: at) {
            m.insertItem(ClosureMenuItem("Open Link") { NSWorkspace.shared.open(link.url) }, at: 0)
            m.insertItem(ClosureMenuItem("Edit Link…") { [weak self] in self?.editor?.editLink(at: at) }, at: 1)
            m.insertItem(.separator(), at: 2)
        }
        return m
    }

    /// The character under the mouse, if it is part of a link.
    private func linkIndex(_ event: NSEvent) -> Int? {
        let i = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        return [i, i - 1].first { editor?.link(at: $0) != nil }
    }

    override func mouseDown(with event: NSEvent) {
        // A plain click on a link places the caret; Command-click opens it.
        if event.modifierFlags.contains(.command), let at = linkIndex(event), let link = editor?.link(at: at) {
            NSWorkspace.shared.open(link.url)
            return
        }
        super.mouseDown(with: event)
        editor?.selectionMoved()
    }
}
