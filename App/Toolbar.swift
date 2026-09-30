import AppKit
import DocxCore

final class ToolbarItems: NSObject, NSToolbarDelegate {
    private weak var controller: EditorController?
    private let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let format = NSSegmentedControl()
    private let lists = NSSegmentedControl()

    private static let outline = NSToolbarItem.Identifier("outline")
    private static let style = NSToolbarItem.Identifier("style")
    private static let format = NSToolbarItem.Identifier("format")
    private static let lists = NSToolbarItem.Identifier("lists")
    private static let comment = NSToolbarItem.Identifier("comment")
    private static let comments = NSToolbarItem.Identifier("comments")

    init(controller: EditorController) {
        self.controller = controller
        super.init()
        stylePopup.target = self
        stylePopup.action = #selector(stylePicked)
        stylePopup.widthAnchor.constraint(equalToConstant: 150).isActive = true

        format.segmentCount = 4
        format.trackingMode = .selectAny
        for (i, (symbol, tip)) in [("bold", "Bold"), ("italic", "Italic"), ("underline", "Underline"), ("strikethrough", "Strikethrough")].enumerated() {
            format.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: tip), forSegment: i)
            format.setToolTip(tip, forSegment: i)
            format.setWidth(28, forSegment: i)
        }
        format.target = self
        format.action = #selector(formatClicked)

        lists.segmentCount = 2
        lists.trackingMode = .momentary
        lists.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Bulleted list"), forSegment: 0)
        lists.setImage(NSImage(systemSymbolName: "list.number", accessibilityDescription: "Numbered list"), forSegment: 1)
        lists.setToolTip("Bulleted list", forSegment: 0)
        lists.setToolTip("Numbered list", forSegment: 1)
        lists.target = self
        lists.action = #selector(listClicked)
    }

    func reloadStyles() {
        guard let c = controller else { return }
        stylePopup.removeAllItems()
        let styles = c.word.styles.paragraphStyles().sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }
        for s in styles {
            stylePopup.addItem(withTitle: s.name.prefix(1).uppercased() + s.name.dropFirst())
            stylePopup.lastItem?.representedObject = s.id
        }
        if styles.isEmpty { stylePopup.addItem(withTitle: "Normal") }
        update()
    }

    func update() {
        guard let c = controller else { return }
        let style = c.currentStyle ?? c.word.styles.defaultParagraphStyle
        if let i = stylePopup.itemArray.firstIndex(where: { $0.representedObject as? String == style }) { stylePopup.selectItem(at: i) }
        for (i, t) in [RunProps.Toggle.bold, .italic, .underline, .strike].enumerated() { format.setSelected(c.isOn(t), forSegment: i) }
    }

    @objc private func stylePicked() {
        guard let c = controller, let id = stylePopup.selectedItem?.representedObject as? String else { return }
        c.setStyle(id == c.word.styles.defaultParagraphStyle ? nil : id)
        c.window?.makeFirstResponder(c.textView)
    }

    @objc private func formatClicked() {
        guard let c = controller else { return }
        let t: RunProps.Toggle = [.bold, .italic, .underline, .strike][format.selectedSegment]
        c.toggle(t)
        c.window?.makeFirstResponder(c.textView)
        update()
    }

    @objc private func listClicked() {
        controller?.modelChangeList(bullet: lists.selectedSegment == 0)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.outline, .flexibleSpace, Self.style, Self.format, Self.lists, .flexibleSpace, Self.comment, Self.comments]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.outline:
            item.label = "Outline"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Outline")
            item.action = #selector(EditorController.toggleOutline(_:))
            item.isBordered = true
        case Self.style:
            item.label = "Style"
            item.view = stylePopup
        case Self.format:
            item.label = "Format"
            item.view = format
        case Self.lists:
            item.label = "Lists"
            item.view = lists
        case Self.comment:
            item.label = "Comment"
            item.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "New comment")
            item.action = #selector(EditorController.newComment(_:))
            item.isBordered = true
        case Self.comments:
            item.label = "Comments"
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Comments")
            item.action = #selector(EditorController.toggleComments(_:))
            item.isBordered = true
        default:
            return nil
        }
        item.toolTip = item.label
        return item
    }
}

extension EditorController {
    func modelChangeList(bullet: Bool) {
        if bullet { toggleBulletList(nil) } else { toggleNumberedList(nil) }
        window?.makeFirstResponder(textView)
    }
}
