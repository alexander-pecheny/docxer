import AppKit
import DocxCore

/// A link in the text: its model object, where it points and the characters it covers.
struct LinkSpan {
    let link: Hyperlink
    let url: URL
    let range: NSRange
}

extension EditorController {
    func link(at i: Int) -> LinkSpan? {
        guard i >= 0, i < storage.length else { return nil }
        var r = NSRange()
        guard let l = storage.attribute(.docxLink, at: i, longestEffectiveRange: &r, in: NSRange(location: 0, length: storage.length)) as? Hyperlink,
              let url = l.url else { return nil }
        return LinkSpan(link: l, url: url, range: r)
    }

    /// Shows the link bubble while the caret sits in or just after a link.
    func updateLinkBubble() {
        let sel = textView.selectedRange()
        guard sel.length == 0, let span = link(at: sel.location) ?? link(at: sel.location - 1), let rect = firstLineRect(span.range) else {
            linkBubble.close()
            return
        }
        linkBubble.show(span, below: rect, in: textView) { [weak self] in self?.editLink(at: span.range.location) }
    }

    private func firstLineRect(_ r: NSRange) -> NSRect? {
        guard let lm = textView.textLayoutManager, let tcm = lm.textContentManager,
              let s = tcm.location(tcm.documentRange.location, offsetBy: r.location), let e = tcm.location(s, offsetBy: r.length),
              let tr = NSTextRange(location: s, end: e) else { return nil }
        var rect: NSRect?
        lm.enumerateTextSegments(in: tr, type: .standard, options: []) { _, frame, _, _ in rect = frame; return false }
        let o = textView.textContainerOrigin
        return rect?.offsetBy(dx: o.x, dy: o.y)
    }

    func editLink(at i: Int) {
        guard let span = link(at: i), let window else { return }
        linkBubble.close()
        let text = NSTextField(string: storage.attributedSubstring(from: span.range).string)
        let address = NSTextField(string: span.url.absoluteString)
        for f in [text, address] { f.widthAnchor.constraint(equalToConstant: 320).isActive = true }
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Text:"), text], [NSTextField(labelWithString: "Address:"), address]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.frame.size = grid.fittingSize
        let alert = NSAlert()
        alert.messageText = "Edit Link"
        alert.informativeText = "Clear the address to remove the link."
        alert.accessoryView = grid
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = text
        alert.window.alphaValue = window.alphaValue
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.setLink(span, text: text.stringValue, address: address.stringValue)
        }
    }

    /// Replaces a link's text and address as one undoable edit. An empty address removes the link.
    func setLink(_ span: LinkSpan, text: String, address: String) {
        let r = span.range
        let old = storage.attributedSubstring(from: r)
        let new = NSMutableAttributedString(attributedString: text.isEmpty || text == old.string ? old
            : NSAttributedString(string: text, attributes: storage.attributes(at: r.location, effectiveRange: nil)))
        let full = NSRange(location: 0, length: new.length)
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty {
            new.removeAttribute(.docxLink, range: full)
        } else if address != span.url.absoluteString, let url = URL(string: address.contains(":") ? address : "https://" + address) {
            new.addAttribute(.docxLink, value: word.link(span.link, to: url), range: full)
        }
        guard textView.shouldChangeText(in: r, replacementString: new.string) else { return }
        storage.replaceCharacters(in: r, with: new)
        textView.didChangeText()
        select(NSRange(location: r.location + new.length, length: 0))
    }
}

/// The bubble under a link at the caret: its address and a button that opens it.
final class LinkBubble: NSObject {
    private let popover = NSPopover()
    private let address = NSTextField(labelWithString: "")
    private var url: URL?
    private var edit: () -> Void = {}

    override init() {
        super.init()
        address.lineBreakMode = .byTruncatingMiddle
        address.textColor = .secondaryLabelColor
        address.font = .systemFont(ofSize: 15)
        address.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        let open = ClosureButton(title: "") { [weak self] in self?.url.map { _ = NSWorkspace.shared.open($0) } }
        open.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Open Link")
        open.toolTip = "Open Link (⌘-click)"
        let pencil = ClosureButton(title: "") { [weak self] in self?.edit() }
        pencil.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit Link")
        pencil.toolTip = "Edit Link"
        for b in [open, pencil] {
            b.isBordered = false
            b.symbolConfiguration = .init(pointSize: 16, weight: .regular)
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        }
        let stack = NSStackView(views: [address, open, pencil])
        stack.spacing = 8
        stack.setCustomSpacing(14, after: address)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 18, bottom: 10, right: 14)
        let vc = NSViewController()
        vc.view = stack
        popover.contentViewController = vc
        popover.behavior = .applicationDefined
    }

    func show(_ span: LinkSpan, below rect: NSRect, in view: NSView, edit: @escaping () -> Void) {
        let same = popover.isShown && url == span.url
        url = span.url
        self.edit = edit
        address.stringValue = span.url.absoluteString
        popover.contentSize = popover.contentViewController!.view.fittingSize
        popover.contentSize = popover.contentViewController!.view.fittingSize
        // The bubble and the edit sheet stay as transparent as their window, which test runs hide.
        let hidden = view.window?.alphaValue == 0
        popover.animates = !hidden
        if same { popover.positioningRect = rect } else { popover.show(relativeTo: rect, of: view, preferredEdge: .maxY) }
        if hidden { popover.contentViewController?.view.window?.alphaValue = 0 }
    }

    func close() {
        if popover.isShown { popover.close() }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private var handler: () -> Void = {}

    convenience init(_ title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
    }

    @objc private func fire() { handler() }
}
