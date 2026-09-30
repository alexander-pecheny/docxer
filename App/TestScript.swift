import AppKit
import DocxCore

/// Drives the frontmost editor from a script file, for tests that must not touch the user's keyboard or mouse.
/// Launch with `-DocxerScript /path/to/script`; one command per line.
enum TestScript {
    static func runIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "DocxerScript"),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { step(lines[...]) }
    }

    private static func findLabel(_ text: String, in v: NSView) -> NSTextField? {
        if let t = v as? NSTextField, t.stringValue.contains(text) { return t }
        for sub in v.subviews { if let hit = findLabel(text, in: sub) { return hit } }
        return nil
    }

    private static func step(_ lines: ArraySlice<String>) {
        guard let line = lines.first else { return }
        let rest = lines.dropFirst()
        let (cmd, arg) = line.firstIndex(of: " ").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) } ?? (line, "")
        let ed = NSDocumentController.shared.documents.first?.windowControllers.first as? EditorController
        let tv = ed?.textView
        let log = { (s: String) in FileHandle.standardError.write("SCRIPT \(s)\n".data(using: .utf8)!) }
        switch cmd {
        case "find":
            let r = (tv!.string as NSString).range(of: arg.replacingOccurrences(of: "\\n", with: "\n"))
            if r.location == NSNotFound { log("not found: \(arg)") } else { ed!.select(r) }
        case "caret":  // move caret to the end of the current selection, plus an offset
            let s = tv!.selectedRange()
            tv!.setSelectedRange(NSRange(location: NSMaxRange(s) + (Int(arg) ?? 0), length: 0))
            ed!.selectionMoved()
        case "select":  // extend selection by N characters from the caret
            let s = tv!.selectedRange()
            tv!.setSelectedRange(NSRange(location: s.location, length: Int(arg) ?? 0))
            ed!.selectionMoved()
        case "type": tv!.insertText(arg.replacingOccurrences(of: "\\n", with: "\n"), replacementRange: tv!.selectedRange())
        case "enter": tv!.insertNewline(nil)
        case "tab": tv!.insertTab(nil)
        case "backspace": tv!.deleteBackward(nil)
        case "delete": tv!.delete(nil)
        case "undo": tv!.undoManager?.undo()
        case "bold": ed!.docxBold(nil)
        case "italic": ed!.docxItalic(nil)
        case "style": ed!.setStyle(arg.isEmpty ? nil : arg)
        case "bullets": ed!.toggleBulletList(nil)
        case "numbers": ed!.toggleNumberedList(nil)
        case "comment":
            let r = tv!.selectedRange()
            let a = ed!.author
            ed!.modelChange(r) { ed!.word.addComment(arg, author: a.name, initials: a.initials, in: ed!.storage, range: r) }
        case "reply":
            if let c = ed!.word.commentAnchors(ed!.storage).compactMap({ ed!.word.comments[$0.id] }).first(where: { ed!.word.comments.parent(of: $0) == nil }) {
                ed!.reply(to: c, arg)
            }
        case "resolve":
            if let c = ed!.word.commentAnchors(ed!.storage).compactMap({ ed!.word.comments[$0.id] }).first { ed!.setDone(c, true) }
        case "outline": ed!.toggleOutline(nil)
        case "font": ed!.setFont(family: arg)
        case "size": ed!.setFont(size: Double(arg))
        case "bigger": ed!.fontBigger(nil)
        case "image": if let d = try? Data(contentsOf: URL(fileURLWithPath: arg)) { ed!.insertImage(d, ext: (arg as NSString).pathExtension) }
        case "zoom": ed!.setZoom(CGFloat(Double(arg) ?? 100) / 100)
        case "clicktext":  // hit-tests the first label containing the text and clicks whatever receives it; sends no events, so nothing activates
            if let w = ed!.window, let label = findLabel(arg, in: w.contentView!) {
                let p = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: nil)
                let hit = w.contentView!.hitTest(w.contentView!.convert(p, from: nil))
                log("hit \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
                (hit as? CardView)?.onClick?()
                let r = tv!.selectedRange()
                log("selection \((tv!.string as NSString).substring(with: r))")
            } else { log("label not found: \(arg)") }
        case "scroll": tv!.scrollToEndOfDocument(nil)
        case "save":
            ed!.doc.save(to: URL(fileURLWithPath: arg), ofType: DocxDocument.docx, for: .saveToOperation) { err in log("saved \(err?.localizedDescription ?? "ok")") }
        case "text": log("text \(tv!.string.debugDescription)")
        case "tabs": log("documents \(NSDocumentController.shared.documents.count), tabs in first window \(ed?.window?.tabbedWindows?.count ?? 1)")
        case "wait": break
        case "quit": NSApp.terminate(nil)
        default: log("unknown \(cmd)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (cmd == "wait" ? (Double(arg) ?? 1) : 0.15)) { step(rest) }
    }
}
