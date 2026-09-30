import AppKit
import DocxCore

final class DocxDocument: NSDocument {
    private(set) var word: WordDocument
    private(set) var renderer: Renderer
    private(set) var storage = NSTextStorage()

    static let docx = "org.openxmlformats.wordprocessingml.document"
    static let template = "org.openxmlformats.wordprocessingml.template"
    static let mainDocumentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"

    override init() {
        word = WordDocument.blank()
        renderer = Renderer(doc: word)
        super.init()
        _ = word.load(styler: renderer, into: storage)
    }

    override class var autosavesInPlace: Bool { false }
    override class var preservesVersions: Bool { false }

    override func read(from data: Data, ofType typeName: String) throws {
        let t0 = Date()
        defer { Timing.log("read \(data.count) bytes", since: t0) }
        let w = try WordDocument(data: data)
        let r = Renderer(doc: w)
        let loader = WordDocument.Loader(doc: w, styler: r)
        word = w
        renderer = r
        if let prefix = loader.prefix(chars: 20_000) {
            // Large document: show the first screens now and read the rest in the background, read-only meanwhile.
            storage = NSTextStorage(attributedString: prefix)
            isLoading = true
            loading.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                pendingFull = loader.finish(styler: Renderer(doc: w))
                loading.leave()
                DispatchQueue.main.async { [self] in self.finishLoading(for: w) }
            }
        } else {
            storage = NSTextStorage(attributedString: loader.finish())
        }
        windowControllers.forEach { ($0 as? EditorController)?.documentReloaded() }
    }

    private(set) var isLoading = false
    private let loading = DispatchGroup()
    private var pendingFull: NSAttributedString?

    /// True while the loader's text replaces the prefix, so edit hooks stay quiet.
    private(set) var applyingLoad = false

    private func finishLoading(for w: WordDocument) {
        guard w === word, isLoading, let full = pendingFull else { return }
        isLoading = false
        pendingFull = nil
        let t0 = Date()
        applyingLoad = true
        storage.setAttributedString(full)
        applyingLoad = false
        Timing.log("apply full text", since: t0)
        windowControllers.forEach { ($0 as? EditorController)?.loadingFinished() }
    }

    override func makeWindowControllers() {
        if fileType == Self.template {
            // A template opens as a new untitled document.
            fileURL = nil
            fileType = Self.docx
            word.package.setMainContentType(Self.mainDocumentType)
        }
        addWindowController(EditorController(document: self))
    }

    override func showWindows() {
        // Test runs launch in the background and must not cover the user's screen.
        if UserDefaults.standard.bool(forKey: "DocxerBackgroundTest") {
            windowControllers.forEach { $0.window?.orderBack(nil) }
        } else {
            super.showWindows()
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        if isLoading {
            loading.wait()
            finishLoading(for: word)
        }
        let t0 = Date()
        defer { Timing.log("save", since: t0) }
        return Data(word.save(storage))
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        [fileType == Self.template ? Self.docx : (fileType ?? Self.docx)]
    }

    // MARK: changes from other apps

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in self?.checkForOutsideChange() }
    }

    private func checkForOutsideChange() {
        guard let url = fileURL, let known = fileModificationDate,
              let current = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              current > known.addingTimeInterval(0.5) else { return }
        if !isDocumentEdited {
            try? revert(toContentsOf: url, ofType: fileType ?? Self.docx)
            return
        }
        guard let window = windowForSheet else { return }
        let alert = NSAlert()
        alert.messageText = "“\(displayName ?? "This document")” was changed by another app."
        alert.informativeText = "You have unsaved edits. Keep yours, or load the version on disk and lose them?"
        alert.addButton(withTitle: "Keep My Edits")
        alert.addButton(withTitle: "Load From Disk")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                try? self.revert(toContentsOf: url, ofType: self.fileType ?? Self.docx)
            } else {
                self.fileModificationDate = current
            }
        }
    }
}
