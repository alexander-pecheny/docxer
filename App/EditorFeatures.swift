import AppKit
import DocxCore
import UniformTypeIdentifiers

// MARK: images

extension EditorController {
    @objc func insertImageFromFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls { if let data = try? Data(contentsOf: url) { self.insertImage(data, ext: url.pathExtension) } }
        }
    }

    /// Inserts an image at the selection as an undoable edit. Formats Word may not read are converted to PNG.
    func insertImage(_ data: Data, ext: String) {
        guard let image = NSImage(data: data), image.size.width > 0 else { NSSound.beep(); return }
        var bytes = [UInt8](data)
        var ext = ext.lowercased()
        if !["png", "jpg", "jpeg", "gif"].contains(ext) {
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { NSSound.beep(); return }
            bytes = [UInt8](png)
            ext = "png"
        }
        let sealed = word.makeImage(bytes, ext: ext, width: image.size.width, height: image.size.height)
        let range = textView.rangeForUserTextChange
        guard range.location != NSNotFound, textView.shouldChangeText(in: range, replacementString: "\u{FFFC}") else { return }
        var a = WordDocument.typingAttributes(textView.typingAttributes)
        let para = a[.docxPara] as? ParaProps ?? currentParaProps()
        for (k, v) in doc.renderer.sealedAttributes(para, a[.docxRun] as? RunProps, sealed) { a[k] = v }
        a[.docxSealed] = sealed
        a[.docxPara] = para
        storage.replaceCharacters(in: range, with: NSAttributedString(string: "\u{FFFC}", attributes: a))
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
    }

    func currentParaProps() -> ParaProps {
        let at = min(textView.selectedRange().location, max(0, storage.length - 1))
        return storage.length > 0 ? storage.attribute(.docxPara, at: at, effectiveRange: nil) as? ParaProps ?? .plain() : .plain()
    }
}

// MARK: fonts

extension EditorController {
    /// Font family and size at the selection; nil family or size means mixed.
    var currentFont: (family: String?, size: Double?) {
        let sel = textView.selectedRange()
        let para = currentParaProps()
        if sel.length == 0 {
            let e = word.effectiveFont(textView.typingAttributes[.docxRun] as? RunProps ?? .plain, para: para)
            return (e.family ?? "Helvetica Neue", e.size)
        }
        let c = word.commonFont(in: storage, range: sel)
        let family: String? = switch c.family { case .some(let f): f ?? "Helvetica Neue"; case .none: nil }
        return (family, c.size)
    }

    func setFont(family: String? = nil, size: Double? = nil) {
        let sel = textView.selectedRange()
        if sel.length == 0 {
            let para = currentParaProps()
            var a = textView.typingAttributes
            let run = word.fontChange(a[.docxRun] as? RunProps ?? .plain, para: para, family: family, size: size)
            a[.docxRun] = run
            for (k, v) in doc.renderer.runAttributes(para, run, link: a[.docxLink] as? Hyperlink) { a[k] = v }
            textView.typingAttributes = a
        } else {
            modelChange(sel) { word.setFont(family: family, size: size, in: storage, range: sel) }
        }
        toolbarUpdate()
        window?.makeFirstResponder(textView)
    }

    /// Word's size ladder, used by Bigger and Smaller.
    static let fontSizes: [Double] = [8, 9, 10, 10.5, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72]

    @objc func fontBigger(_ sender: Any?) { stepFont(1) }
    @objc func fontSmaller(_ sender: Any?) { stepFont(-1) }

    private func stepFont(_ dir: Int) {
        let cur = currentFont.size ?? 12
        let next = dir > 0 ? Self.fontSizes.first { $0 > cur } ?? cur + 12 : Self.fontSizes.last { $0 < cur } ?? max(1, cur - 1)
        setFont(size: next)
    }
}

// MARK: zoom

extension EditorController {
    static let zoomSteps: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]

    @objc func zoomIn(_ sender: Any?) { setZoom(Self.zoomSteps.first { $0 > zoom + 0.01 } ?? zoom) }
    @objc func zoomOut(_ sender: Any?) { setZoom(Self.zoomSteps.last { $0 < zoom - 0.01 } ?? zoom) }
    @objc func zoomReset(_ sender: Any?) { setZoom(1) }
    @objc func zoomFromMenu(_ sender: NSMenuItem) { setZoom(CGFloat(sender.tag) / 100) }
}

// MARK: window tabs

extension EditorController {
    /// The "+" button in the tab bar.
    @objc override func newWindowForTab(_ sender: Any?) {
        NSDocumentController.shared.newDocument(sender)
    }
}

/// A compact "− 125% +" control for the status bar.
final class ZoomControl: NSStackView {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var controller: EditorController?

    init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        let minus = ClosureButton(title: "") { [weak controller] in controller?.zoomOut(nil) }
        minus.image = NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom out")
        let plus = ClosureButton(title: "") { [weak controller] in controller?.zoomIn(nil) }
        plus.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom in")
        for b in [minus, plus] { b.bezelStyle = .accessoryBarAction; b.isBordered = false; b.controlSize = .small }
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.isBordered = false
        for step in EditorController.zoomSteps {
            popup.addItem(withTitle: "\(Int(step * 100))%")
            popup.lastItem?.tag = Int(step * 100)
            popup.lastItem?.target = controller
            popup.lastItem?.action = #selector(EditorController.zoomFromMenu(_:))
        }
        popup.setContentCompressionResistancePriority(.required, for: .horizontal)
        spacing = 0
        [minus, popup, plus].forEach(addArrangedSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ zoom: CGFloat) {
        let pct = Int((zoom * 100).rounded())
        popup.itemArray.filter { $0.tag == -1 }.forEach { popup.menu?.removeItem($0) }
        if let item = popup.menu?.item(withTag: pct) { popup.select(item) } else {
            popup.addItem(withTitle: "\(pct)%")
            popup.lastItem?.tag = -1
            popup.select(popup.lastItem)
        }
    }
}

/// The window's root view: opens Word files dropped anywhere outside the text.
final class DropStackView: NSStackView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func documents(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { EditorTextView.documentExtensions.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { documents(info).isEmpty ? [] : .copy }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let docs = documents(info)
        for url in docs { NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in } }
        return !docs.isEmpty
    }
}
