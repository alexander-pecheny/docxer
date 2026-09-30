import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        // Crash-recovery copies go to a side location; the file itself changes only on Save.
        NSDocumentController.shared.autosavingDelay = 5
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        TestScript.runIfRequested()
        guard UserDefaults.standard.bool(forKey: "DocxerBackgroundTest") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSDocumentController.shared.documents.forEach { $0.showWindows() }
        }
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindow.shared.showWindow(nil) }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0,
                  object: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            i.representedObject = object
            return i
        }
        let sep = { NSMenuItem.separator() }
        let app = ProcessInfo.processInfo.processName

        submenu(app, [
            item("About \(app)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))), sep(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","), sep(),
            item("Hide \(app)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))), sep(),
            item("Quit \(app)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let recent = item("Open Recent", nil)
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        recentMenu.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        recent.submenu = recentMenu
        submenu("File", [
            item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("New Tab", #selector(NSResponder.newWindowForTab(_:)), "t"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recent, sep(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save…", #selector(NSDocument.save(_:)), "s"),
            item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))),
        ])
        let find = { (title: String, key: String, mods: NSEvent.ModifierFlags, action: NSTextFinder.Action) in
            item(title, #selector(NSTextView.performTextFinderAction(_:)), key, mods, tag: action.rawValue)
        }
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]), sep(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"), sep(),
            find("Find…", "f", [.command], .showFindInterface),
            find("Find and Replace…", "f", [.command, .option], .showReplaceInterface),
            find("Find Next", "g", [.command], .nextMatch),
            find("Find Previous", "g", [.command, .shift], .previousMatch),
            find("Use Selection for Find", "e", [.command], .setSearchString),
        ])
        var styleItems = [item("Normal", #selector(EditorController.setStyleFromMenu(_:)), "0", [.command, .option], object: "Normal")]
        for n in 1 ... 3 {
            styleItems.append(item("Heading \(n)", #selector(EditorController.setStyleFromMenu(_:)), "\(n)", [.command, .option], object: "Heading\(n)"))
        }
        submenu("Format", [
            item("Bold", #selector(EditorController.docxBold(_:)), "b"),
            item("Italic", #selector(EditorController.docxItalic(_:)), "i"),
            item("Underline", #selector(EditorController.docxUnderline(_:)), "u"),
            item("Strikethrough", #selector(EditorController.docxStrike(_:)), "x", [.command, .shift]), sep(),
        ] + styleItems + [sep(),
            item("Bulleted List", #selector(EditorController.toggleBulletList(_:)), "l", [.command, .shift]),
            item("Numbered List", #selector(EditorController.toggleNumberedList(_:)), "n", [.command, .option]),
            item("Bigger Font", #selector(EditorController.fontBigger(_:)), ".", [.command, .shift]),
            item("Smaller Font", #selector(EditorController.fontSmaller(_:)), ",", [.command, .shift]),
            item("Increase List Level", #selector(EditorController.indentMore(_:)), "]"),
            item("Decrease List Level", #selector(EditorController.indentLess(_:)), "["),
        ])
        submenu("Insert", [
            item("Comment", #selector(EditorController.newComment(_:)), "m", [.command, .option]),
            item("Image…", #selector(EditorController.insertImageFromFile(_:)), "i", [.command, .shift]),
        ])
        submenu("View", [
            item("Show Outline", #selector(EditorController.toggleOutline(_:)), "s", [.command, .control]),
            item("Show Comments", #selector(EditorController.toggleComments(_:)), "c", [.command, .control]), sep(),
            item("Zoom In", #selector(EditorController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(EditorController.zoomOut(_:)), "-"),
            item("Actual Size", #selector(EditorController.zoomReset(_:)), "0"), sep(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
