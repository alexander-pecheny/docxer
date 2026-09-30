import AppKit
import DocxCore

// MARK: outline

final class OutlinePane: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view: NSScrollView
    private let table = NSTableView()
    private weak var controller: EditorController?
    private var entries: [(location: Int, level: Int, text: String)] = []

    init(controller: EditorController) {
        self.controller = controller
        view = NSScrollView()
        super.init()
        table.addTableColumn(NSTableColumn(identifier: .init("t")))
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .small
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        view.documentView = table
        view.hasVerticalScroller = true
        view.drawsBackground = false
    }

    func reload() {
        guard let c = controller, !view.isHidden else { return }
        let s = c.storage, str = s.string as NSString
        let patterns = Settings.outlinePatterns
        var out: [(Int, Int, String)] = []
        var p = 0
        while p < str.length {
            let r = str.paragraphRange(for: NSRange(location: p, length: 0))
            p = NSMaxRange(r)
            guard let props = s.attribute(.docxPara, at: r.location, effectiveRange: nil) as? ParaProps, !props.isSealed, r.length > 1 else { continue }
            let head = str.substring(with: NSRange(location: r.location, length: min(r.length - 1, 80)))
            if let level = c.word.styles.headingLevel(props.styleId) {
                out.append((r.location, level, head))
            } else if let m = patterns.first(where: { $0.regex.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) != nil }) {
                out.append((r.location, m.level + 1, head))
            }
        }
        entries = out.map { (location: $0.0, level: $0.1, text: $0.2.trimmingCharacters(in: .whitespaces)) }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? NSTableCellView ?? {
            let v = NSTableCellView()
            v.identifier = .init("cell")
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingTail
            t.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(t)
            v.textField = t
            return v
        }()
        let e = entries[row]
        cell.textField?.stringValue = e.text
        cell.textField?.font = e.level == 0 ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        cell.constraints.forEach { cell.removeConstraint($0) }
        if let t = cell.textField {
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: CGFloat(4 + 12 * min(e.level, 5))),
                t.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                t.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        controller?.select(NSRange(location: entries[table.clickedRow].location, length: 0))
    }
}

// MARK: comments

final class CommentsPane: NSObject {
    let view: NSScrollView
    private let stack = NSStackView()
    private weak var controller: EditorController?
    private var threads: [(comment: Comment, range: NSRange)] = []
    private var cards: [Int: NSView] = [:]
    private var selectedId: Int?
    private var draft: ((String?) -> Void)?
    var userHid = false

    init(controller: EditorController) {
        self.controller = controller
        view = NSScrollView()
        super.init()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        let flipped = FlippedView()
        flipped.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.documentView = flipped
        flipped.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            flipped.widthAnchor.constraint(equalTo: view.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
        view.hasVerticalScroller = true
        view.drawsBackground = true
        view.backgroundColor = .underPageBackgroundColor
    }

    func beginNewComment(_ done: @escaping (String?) -> Void) {
        draft = done
        reload()
    }

    func reload() {
        guard let c = controller else { return }
        let word = c.word
        let anchors = word.commentAnchors(c.storage)
        var seen = Set<Int>()
        threads = anchors.compactMap { a in
            guard let cm = word.comments[a.id], word.comments.parent(of: cm) == nil, seen.insert(a.id).inserted else { return nil }
            return (cm, a.range)
        }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards = [:]
        if let draft {
            stack.addArrangedSubview(editorCard(title: "New comment", initial: "") { [weak self] text in
                self?.draft = nil
                draft(text)
                self?.reload()
            })
        }
        if threads.isEmpty, draft == nil {
            let empty = NSTextField(labelWithString: "No comments. Select text and press ⌥⌘M.")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
        }
        for t in threads {
            let card = threadCard(t.comment, word.comments.replies(to: t.comment))
            cards[t.comment.id] = card
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        highlightSelection()
    }

    func highlightSelection() {
        guard let c = controller else { return }
        let hit = threadAtCaret(c)
        let changed = hit?.comment.id != selectedId
        selectedId = hit?.comment.id
        if changed, let hit { reveal(hit.comment.id) }
        for (id, card) in cards {
            card.layer?.borderColor = (id == selectedId ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            card.layer?.borderWidth = id == selectedId ? 2 : 1
        }
        c.highlightAnchors(selected: hit?.comment)
    }

    /// The thread whose anchor holds the caret, or the character just before it.
    private func threadAtCaret(_ c: EditorController) -> (comment: Comment, range: NSRange)? {
        let loc = c.textView.selectedRange().location
        for p in [loc, loc - 1] where p >= 0 && p < c.storage.length {
            guard let m = c.storage.attribute(.docxMarks, at: p, effectiveRange: nil) as? MarkSet else { continue }
            for id in m.comments {
                guard var cm = c.word.comments[id] else { continue }
                while let parent = c.word.comments.parent(of: cm) { cm = parent }
                if let t = threads.first(where: { $0.comment === cm }) { return t }
            }
        }
        return nil
    }

    /// Opens the pane if needed and scrolls the thread's card to the middle.
    private func reveal(_ id: Int) {
        controller?.showComments(true)
        guard let card = cards[id], let doc = view.documentView else { return }
        doc.layoutSubtreeIfNeeded()
        let frame = card.convert(card.bounds, to: doc)
        if view.contentView.bounds.contains(frame) { return }
        let visible = view.contentView.bounds.height
        let y = min(max(0, frame.midY - visible / 2), max(0, doc.frame.height - visible))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            view.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
        }
        view.reflectScrolledClipView(view.contentView)
    }

    private func label(_ s: String, bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = bold ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 12)
        if secondary { t.textColor = .secondaryLabelColor }
        t.isSelectable = true
        t.preferredMaxLayoutWidth = 220
        return t
    }

    private func header(_ c: Comment) -> NSTextField {
        var s = c.author
        if let d = c.dateValue { s += " · " + d.formatted(date: .abbreviated, time: .shortened) }
        return label(s, bold: true, secondary: true)
    }

    private func threadCard(_ c: Comment, _ replies: [Comment]) -> NSView {
        let box = CardView()
        box.onClick = { [weak self] in
            guard let self, let t = self.threads.first(where: { $0.comment === c }) else { return }
            self.controller?.select(t.range)
        }
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 4
        v.addArrangedSubview(header(c))
        v.addArrangedSubview(label(c.text))
        for r in replies {
            let rv = NSStackView(views: [header(r), label(r.text)])
            rv.orientation = .vertical
            rv.alignment = .leading
            rv.spacing = 2
            rv.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 0, right: 0)
            v.addArrangedSubview(rv)
            if r.author == controller?.author.name {
                v.addArrangedSubview(buttons([("Edit", { [weak self] in self?.editComment(r) }), ("Delete", { [weak self] in self?.controller?.delete(r) })], indent: 12))
            }
        }
        var actions: [(String, () -> Void)] = [
            ("Reply", { [weak self] in self?.replyTo(c) }),
            (c.done ? "Reopen" : "Resolve", { [weak self] in self?.controller?.setDone(c, !c.done) }),
        ]
        if c.author == controller?.author.name {
            actions.append(("Edit", { [weak self] in self?.editComment(c) }))
        }
        actions.append(("Delete", { [weak self] in self?.controller?.delete(c) }))
        v.addArrangedSubview(buttons(actions, indent: 0))
        box.alphaValue = c.done ? 0.55 : 1
        box.embed(v)
        return box
    }

    private func buttons(_ actions: [(String, () -> Void)], indent: CGFloat) -> NSView {
        let row = NSStackView(views: actions.map { title, action in
            let b = ClosureButton(title: title, action: action)
            b.bezelStyle = .inline
            b.controlSize = .small
            return b
        })
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 2, left: indent, bottom: 0, right: 0)
        return row
    }

    private func replyTo(_ c: Comment) {
        replaceCard(of: c, with: editorCard(title: "Reply to \(c.author)", initial: "") { [weak self] text in
            if let text, !text.isEmpty { self?.controller?.reply(to: c, text) }
            self?.reload()
        })
    }

    private func editComment(_ c: Comment) {
        let root = controller?.word.comments.parent(of: c) ?? c
        replaceCard(of: root, with: editorCard(title: "Edit comment", initial: c.text) { [weak self] text in
            if let text, !text.isEmpty { self?.controller?.edit(c, text) }
            self?.reload()
        })
    }

    private func replaceCard(of c: Comment, with card: NSView) {
        guard let old = cards[c.id], let i = stack.arrangedSubviews.firstIndex(of: old) else { return }
        stack.insertArrangedSubview(card, at: i + 1)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
    }

    private func editorCard(title: String, initial: String, done: @escaping (String?) -> Void) -> NSView {
        let box = CardView()
        let text = NSTextView()
        text.string = initial
        text.font = .systemFont(ofSize: 12)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        let sc = NSScrollView()
        sc.documentView = text
        sc.hasVerticalScroller = true
        sc.borderType = .bezelBorder
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        sc.heightAnchor.constraint(equalToConstant: 70).isActive = true
        let ok = ClosureButton(title: "Save") { done(text.string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        ok.keyEquivalent = "\r"
        ok.keyEquivalentModifierMask = [.command]
        let cancel = ClosureButton(title: "Cancel") { done(nil) }
        cancel.keyEquivalent = "\u{1b}"
        let v = NSStackView(views: [label(title, bold: true, secondary: true), sc, NSStackView(views: [cancel, ok])])
        v.orientation = .vertical
        v.alignment = .leading
        sc.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        box.embed(v)
        DispatchQueue.main.async { text.window?.makeFirstResponder(text) }
        return box
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class CardView: NSView {
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func embed(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            v.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            v.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    /// Clicks on comment text select the thread; only buttons and editors keep their own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard onClick != nil, let hit else { return hit }
        var v: NSView? = hit
        while let cur = v, cur !== self {
            if cur is NSButton || cur is NSTextView { return hit }
            v = cur.superview
        }
        return self
    }
}

final class ClosureButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        handler = action
        target = self
        self.action = #selector(fire)
    }

    @objc private func fire() { handler?() }
}
