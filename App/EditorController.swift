import AppKit
import DocxCore

final class EditorController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextStorageDelegate {
    let doc: DocxDocument
    var word: WordDocument { doc.word }
    var storage: NSTextStorage { doc.storage }

    private(set) var textView: EditorTextView!
    private var scroll: NSScrollView!
    private var contentStorage: NSTextContentStorage!
    private var split: NSSplitView!
    private var outlinePane: OutlinePane!
    private var commentsPane: CommentsPane!
    private var status: NSTextField!
    private var zoomControl: ZoomControl!
    private var textZoom: CGFloat = 1
    private var highlighted: [(NSRange, String)] = []
    private var toolbarItems: ToolbarItems!
    private var refreshPending = false
    private var relabelPending = false

    init(document: DocxDocument) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.tabbingMode = .preferred
        window.setFrameAutosaveName("DocxerEditor")
        doc = document
        super.init(window: window)
        window.delegate = self
        buildUI()
        attachStorage()
        window.center()
        if Timing.enabled {
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            Timing.log("process start to first screen laid out", since: Timing.processStart)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        guard let window else { return }
        contentStorage = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: word.textWidth, height: 0))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.textContainer = container

        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        tv.editor = self
        tv.delegate = self
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = []
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 40, height: 40)
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        layout.delegate = tv
        textView = tv
        tv.updateDragTypeRegistration()

        scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        // Sideways scrolling only exists while pinched in, when the column is wider than the view.
        scroll.hasHorizontalScroller = true
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        textZoom = Settings.defaultZoom
        scroll.minMagnification = textZoom
        scroll.maxMagnification = textZoom * Self.maxPinch
        scroll.magnification = textZoom
        scroll.contentView.postsFrameChangedNotifications = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(layoutTextColumn), name: NSView.frameDidChangeNotification, object: scroll.contentView)

        outlinePane = OutlinePane(controller: self)
        commentsPane = CommentsPane(controller: self)

        split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(outlinePane.view)
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(commentsPane.view)
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 1)
        split.autosaveName = "DocxerSplit"

        status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        zoomControl = ZoomControl(controller: self)
        zoomControl.show(scroll.magnification)
        let bar = NSStackView()
        bar.addView(status, in: .leading)
        bar.addView(zoomControl, in: .trailing)
        zoomControl.setHuggingPriority(.required, for: .horizontal)
        status.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 4, right: 12)
        let root = DropStackView(views: [split, bar])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        bar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        split.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = root

        outlinePane.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        commentsPane.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        outlinePane.view.isHidden = !UserDefaults.standard.bool(forKey: "showOutline")
        commentsPane.view.isHidden = true

        toolbarItems = ToolbarItems(controller: self)
        let toolbar = NSToolbar(identifier: "DocxerToolbar")
        toolbar.delegate = toolbarItems
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.initialFirstResponder = tv
    }

    private func attachStorage() {
        contentStorage.textStorage = storage
        storage.delegate = self
        highlighted = []
        if let lm = textView.textLayoutManager {
            lm.removeRenderingAttribute(.backgroundColor, for: lm.documentRange)
            lm.removeRenderingAttribute(.foregroundColor, for: lm.documentRange)
            lm.invalidateLayout(for: lm.documentRange)
        }
        textView.isEditable = !doc.isLoading
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.typingAttributes = WordDocument.typingAttributes(storage.length > 0 ? storage.attributes(at: 0, effectiveRange: nil) : [:])
        textView.textContainer?.size = CGSize(width: word.textWidth, height: 0)
        toolbarItems.reloadStyles()
        layoutTextColumn()
        // Sidebars and word count can wait until the first screen is up.
        DispatchQueue.main.async { [weak self] in self?.refreshNow() }
    }

    func loadingFinished() {
        let sel = textView.selectedRange()
        textView.isEditable = true
        textView.setSelectedRange(NSRange(location: min(sel.location, storage.length), length: 0))
        doc.renderer.relabel(storage)
        refreshNow()
    }

    func documentReloaded() {
        textView.undoManager?.removeAllActions()
        attachStorage()
    }

    /// Fits the text column to the view at the text zoom. Pinching magnifies on top of this without refitting,
    /// so the text keeps its line breaks and the pinched spot stays put.
    @objc func layoutTextColumn() {
        let visible = scroll.contentView.frame.width / textZoom
        if abs(textView.frame.width - visible) > 0.5 { textView.setFrameSize(NSSize(width: visible, height: textView.frame.height)) }
        let width = min(CGFloat(word.textWidth), max(200, visible - 48))
        textView.textContainer?.size = CGSize(width: width, height: 0)
        textView.textContainerInset = NSSize(width: max(24, (visible - width) / 2), height: 32)
    }

    func windowDidResize(_ notification: Notification) { layoutTextColumn() }

    // MARK: text delegate

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let text else { return true }
        if word.allowsEdit(storage, range: range, replacement: text) { return true }
        NSSound.beep()
        return false
    }

    func textStorage(_ s: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters), !doc.applyingLoad else { return }
        word.normalize(s, editedRange: range)
        doc.renderer.restyle(s, range)
        relabelSoon()
        refreshSoon()
    }

    func textViewDidChangeSelection(_ notification: Notification) { selectionMoved() }

    func selectionMoved() {
        fixTypingAttributes()
        toolbarItems.update()
        commentsPane.highlightSelection()
    }

    /// Typing at the edge of a link or comment should not extend it, as in Word.
    private func fixTypingAttributes() {
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return }
        var t = WordDocument.typingAttributes(textView.typingAttributes)
        let next = sel.location < storage.length ? storage.attributes(at: sel.location, effectiveRange: nil) : [:]
        if let m = t[.docxMarks] as? MarkSet {
            let n = next[.docxMarks] as? MarkSet
            let keep = MarkSet(bookmarks: m.bookmarks.filter { n?.bookmarks.contains($0) == true },
                               comments: m.comments.filter { n?.comments.contains($0) == true })
            t[.docxMarks] = keep.isEmpty ? nil : keep
        }
        if let l = t[.docxLink] as? Hyperlink, (next[.docxLink] as? Hyperlink) !== l, let p = t[.docxPara] as? ParaProps {
            t[.docxLink] = nil
            t[.link] = nil
            for (k, v) in doc.renderer.runAttributes(p, t[.docxRun] as? RunProps ?? .plain, link: nil) { t[k] = v }
            t[.underlineStyle] = t[.underlineStyle]
        }
        textView.typingAttributes = t
    }

    // MARK: model changes

    /// Applies a model change as one undoable step covering whole paragraphs.
    func modelChange(_ range: NSRange, _ body: () -> Void) {
        let str = storage.string as NSString
        guard str.length > 0 else { return }
        let lo = min(range.location, str.length - 1)
        let pr = str.paragraphRange(for: NSRange(location: lo, length: min(NSMaxRange(range), str.length) - lo))
        guard textView.shouldChangeText(in: pr, replacementString: nil) else { return }
        storage.beginEditing()
        body()
        doc.renderer.restyle(storage, pr)
        storage.endEditing()
        textView.didChangeText()
        relabelSoon()
        refreshSoon()
        toolbarItems.update()
    }

    private var selection: NSRange { textView.selectedRange() }

    private func currentPara() -> ParaProps? {
        guard storage.length > 0 else { return nil }
        let at = min(selection.location, storage.length - 1)
        return storage.attribute(.docxPara, at: at, effectiveRange: nil) as? ParaProps
    }

    func toggle(_ t: RunProps.Toggle) {
        if selection.length == 0 {
            guard let p = currentPara() else { return }
            var a = textView.typingAttributes
            let run = word.typing(t, a[.docxRun] as? RunProps ?? .plain, para: p)
            a[.docxRun] = run
            for k in [NSAttributedString.Key.underlineStyle, .strikethroughStyle] { a[k] = nil }
            for (k, v) in doc.renderer.runAttributes(p, run, link: a[.docxLink] as? Hyperlink) { a[k] = v }
            textView.typingAttributes = a
            toolbarItems.update()
            return
        }
        modelChange(selection) { word.toggle(t, in: storage, range: selection) }
    }

    func isOn(_ t: RunProps.Toggle) -> Bool {
        guard let p = currentPara() else { return false }
        if selection.length == 0 { return word.isOn(t, textView.typingAttributes[.docxRun] as? RunProps ?? .plain, para: p) }
        return word.allOn(t, in: storage, range: selection)
    }

    @objc func docxBold(_ sender: Any?) { toggle(.bold) }
    @objc func docxItalic(_ sender: Any?) { toggle(.italic) }
    @objc func docxUnderline(_ sender: Any?) { toggle(.underline) }
    @objc func docxStrike(_ sender: Any?) { toggle(.strike) }

    var currentStyle: String? { currentPara().flatMap { $0.isSealed ? nil : ($0.styleId ?? word.styles.defaultParagraphStyle) } }

    func setStyle(_ id: String?) {
        modelChange(selection) { word.setStyle(id, in: storage, range: selection) }
    }

    @objc func setStyleFromMenu(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String ?? "Normal"
        let id = word.styles.styles[name] != nil ? name : word.styles.id(named: name.replacingOccurrences(of: "Heading", with: "heading "))
        guard let id else { NSSound.beep(); return }
        setStyle(id == word.styles.defaultParagraphStyle ? nil : id)
    }

    @objc func toggleBulletList(_ sender: Any?) { modelChange(selection) { word.toggleList(bullet: true, in: storage, range: selection) } }
    @objc func toggleNumberedList(_ sender: Any?) { modelChange(selection) { word.toggleList(bullet: false, in: storage, range: selection) } }
    @objc func indentMore(_ sender: Any?) { _ = indentList(by: 1) }
    @objc func indentLess(_ sender: Any?) { _ = indentList(by: -1) }

    /// Tab and Shift-Tab change list level only at the start of a list item, as in Word.
    func indentList(by delta: Int) -> Bool {
        guard let p = currentPara(), word.listKind(p) != nil else { return false }
        let str = storage.string as NSString
        let start = str.paragraphRange(for: NSRange(location: selection.location, length: 0)).location
        if selection.length == 0, selection.location != start, delta != 0, NSApp.currentEvent?.type == .keyDown { return false }
        var changed = false
        modelChange(selection) { changed = word.indentList(by: delta, in: storage, range: selection) }
        return changed
    }

    func applyNextStyleAfterNewline() {
        let str = storage.string as NSString
        let loc = selection.location
        guard loc > 0, loc <= str.length, let p = currentPara(), let id = p.styleId,
              let next = word.styles.styles[id]?.next, next != id,
              str.paragraphRange(for: NSRange(location: loc, length: 0)).length <= 1 else { return }
        setStyle(next == word.styles.defaultParagraphStyle ? nil : next)
    }

    // MARK: comments

    var author: (name: String, initials: String) { Settings.author }

    @objc func newComment(_ sender: Any?) {
        var range = selection
        if range.length == 0 {
            // Anchor to the word at the caret.
            range = textView.selectionRange(forProposedRange: range, granularity: .selectByWord)
        }
        guard range.length > 0 else { NSSound.beep(); return }
        showComments(true)
        commentsPane.beginNewComment { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            let a = self.author
            self.modelChange(range) { self.word.addComment(text, author: a.name, initials: a.initials, in: self.storage, range: range) }
        }
    }

    func reply(to c: Comment, _ text: String) {
        let anchors = word.commentAnchors(storage).filter { $0.id == c.id }.map(\.range)
        guard let r = anchors.first else { return }
        let a = author
        modelChange(r) { word.reply(to: c, text, author: a.name, initials: a.initials, in: storage) }
    }

    func delete(_ c: Comment) {
        let anchors = word.commentAnchors(storage).filter { $0.id == c.id }.map(\.range)
        let r = anchors.reduce(anchors.first ?? NSRange(location: 0, length: 0)) { NSUnionRange($0, $1) }
        modelChange(r) { word.deleteComment(c, in: storage) }
    }

    func setDone(_ c: Comment, _ done: Bool) {
        let before = c.done
        word.comments.setDone(c, done)
        doc.undoManager?.registerUndo(withTarget: self) { $0.setDone(c, before) }
        doc.updateChangeCount(.changeDone)
        commentsPane.reload()
    }

    func edit(_ c: Comment, _ text: String) {
        let before = c.text
        word.comments.setText(c, text)
        doc.undoManager?.registerUndo(withTarget: self) { $0.edit(c, before) }
        doc.updateChangeCount(.changeDone)
        commentsPane.reload()
    }

    func select(_ range: NSRange) {
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    // MARK: panes

    @objc func toggleOutline(_ sender: Any?) {
        outlinePane.view.isHidden.toggle()
        UserDefaults.standard.set(!outlinePane.view.isHidden, forKey: "showOutline")
        split.adjustSubviews()
        layoutTextColumn()
    }

    @objc func toggleComments(_ sender: Any?) {
        commentsPane.userHid = !commentsPane.view.isHidden
        showComments(commentsPane.view.isHidden)
    }

    func showComments(_ show: Bool) {
        guard commentsPane.view.isHidden == show else { return }
        commentsPane.view.isHidden = !show
        split.adjustSubviews()
        layoutTextColumn()
    }

    /// Text zoom: scales and rewraps the text. Pinch magnification sits on top of it.
    var zoom: CGFloat { textZoom }
    static let maxPinch: CGFloat = 6

    /// Sets the text zoom and drops any pinch magnification.
    func setZoom(_ z: CGFloat) {
        textZoom = min(4, max(0.5, z))
        scroll.minMagnification = min(scroll.minMagnification, textZoom)
        scroll.magnification = textZoom
        scroll.minMagnification = textZoom
        scroll.maxMagnification = textZoom * Self.maxPinch
        zoomControl.show(textZoom)
        layoutTextColumn()
    }

    func toolbarUpdate() { toolbarItems.update() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(docxBold(_:)): item.state = isOn(.bold) ? .on : .off
        case #selector(docxItalic(_:)): item.state = isOn(.italic) ? .on : .off
        case #selector(docxUnderline(_:)): item.state = isOn(.underline) ? .on : .off
        case #selector(docxStrike(_:)): item.state = isOn(.strike) ? .on : .off
        case #selector(toggleOutline(_:)): item.title = outlinePane.view.isHidden ? "Show Outline" : "Hide Outline"
        case #selector(toggleComments(_:)): item.title = commentsPane.view.isHidden ? "Show Comments" : "Hide Comments"
        default: break
        }
        return true
    }

    // MARK: refresh

    private func relabelSoon() {
        guard !relabelPending else { return }
        relabelPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.relabelPending = false
            self.doc.renderer.relabel(self.storage)
        }
    }

    private func refreshSoon() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshPending = false
            self?.refreshNow()
        }
    }

    private func refreshNow() {
        outlinePane.reload()
        commentsPane.reload()
        if commentsPane.view.isHidden, !word.commentAnchors(storage).isEmpty, !commentsPane.userHid { showComments(true) }
        status.stringValue = wordCount()
    }

    private func wordCount() -> String {
        var words = 0, inWord = false
        for u in storage.string.utf16 {
            let space = u == 32 || u == 10 || u == 9 || u == 0x2028 || u == 0xA0 || u == 0xFFFC
            if !space, !inWord { words += 1 }
            inWord = !space
        }
        return "\(words.formatted()) words"
    }

    // MARK: anchor highlighting

    /// Comment anchors look like a highlighter pen: light yellow with dark text, in both appearances.
    static let commentTint = NSColor(srgbRed: 1, green: 0.94, blue: 0.6, alpha: 1)
    static let selectedTint = NSColor(srgbRed: 1, green: 0.82, blue: 0.3, alpha: 1)
    static let resolvedTint = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.06) }

    /// Tints every commented character: resolved threads faintly, the selected thread strongest.
    func highlightAnchors(selected: Comment?) {
        guard let lm = textView.textLayoutManager, let tcm = lm.textContentManager else { return }
        let comments = word.comments
        let selectedIds = selected.map { Set([$0.id] + comments.replies(to: $0).map(\.id)) } ?? []
        var next: [(NSRange, NSColor, Bool)] = []
        storage.enumerateAttribute(.docxMarks, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let m = v as? MarkSet, !m.comments.isEmpty else { return }
            if !selectedIds.isDisjoint(with: m.comments) { next.append((r, Self.selectedTint, true)) } else if m.comments.allSatisfy({ comments[$0]?.done == true }) {
                next.append((r, Self.resolvedTint, false))
            } else { next.append((r, Self.commentTint, true)) }
        }
        func textRange(_ r: NSRange) -> NSTextRange? {
            guard NSMaxRange(r) <= storage.length, let s = tcm.location(tcm.documentRange.location, offsetBy: r.location),
                  let e = tcm.location(s, offsetBy: r.length) else { return nil }
            return NSTextRange(location: s, end: e)
        }
        let changed = Set(highlighted.map { "\($0.0)\($0.1)" }) != Set(next.map { "\($0.0)\($0.1.hash)" })
        lm.removeRenderingAttribute(.backgroundColor, for: tcm.documentRange)
        lm.removeRenderingAttribute(.foregroundColor, for: tcm.documentRange)
        for (r, tint, dark) in next {
            guard let tr = textRange(r) else { continue }
            lm.addRenderingAttribute(.backgroundColor, value: tint, for: tr)
            if dark { lm.addRenderingAttribute(.foregroundColor, value: NSColor.black, for: tr) }
        }
        // Fragments draw into cached layers, so re-lay out the ones whose tint changed.
        if changed {
            for r in Set(highlighted.map(\.0) + next.map(\.0)) {
                if let tr = textRange((storage.string as NSString).paragraphRange(for: NSRange(location: min(r.location, max(0, storage.length - 1)), length: 0))) {
                    lm.invalidateLayout(for: tr)
                }
            }
            lm.textViewportLayoutController.layoutViewport()
            func redraw(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(redraw) }
            redraw(textView)
        }
        highlighted = next.map { ($0.0, "\($0.1.hash)") }
    }
}

extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
