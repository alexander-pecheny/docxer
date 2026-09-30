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
            if let c = ed!.word.commentAnchors(ed!.storage).compactMap({ ed!.word.comments[$0.id] }).first {
                ed!.setDone(c, true)
                log("resolved \(c.id) \(c.text.prefix(20)) done=\(c.done)")
            }
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
        case "dropfile":  // "dropfile text|root PATH": offers a fake file drag to a view, as Finder would
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let target: NSView = parts[0] == "text" ? tv! : ed!.window!.contentView!
            let pb = NSPasteboard(name: NSPasteboard.Name("docxer-test-\(UUID().uuidString)"))
            pb.clearContents()
            pb.writeObjects([URL(fileURLWithPath: parts[1]) as NSURL])
            let drag = FakeDrag(pb, at: target.convert(NSPoint(x: target.bounds.midX, y: 40), to: nil), window: ed!.window!)
            let before = NSDocumentController.shared.documents.count
            let op = target.draggingEntered(drag)
            let ok = target.performDragOperation(drag)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                log("drop on \(parts[0]): accepted \(op.rawValue != 0), performed \(ok), documents \(before) -> \(NSDocumentController.shared.documents.count)")
            }
        case "marks":
            let r = (tv!.string as NSString).range(of: arg)
            if let m = ed!.storage.attribute(.docxMarks, at: r.location, effectiveRange: nil) as? MarkSet {
                log("marks \(m.comments.map { "\($0):done=\(ed!.word.comments[$0]?.done ?? false)" })")
            } else { log("marks none") }
        case "settings": SettingsWindow.shared.window?.orderBack(nil); log("zoom now \(Int(ed!.zoom * 100))%")
        case "hscroll":
            let clip = tv!.enclosingScrollView!.contentView
            var target = clip.bounds
            target.origin.x = 5000
            clip.scroll(to: clip.constrainBoundsRect(target).origin)
            tv!.enclosingScrollView!.reflectScrolledClipView(clip)
            log("textView width \(Int(tv!.frame.width)), visible \(Int(clip.bounds.width)), scrolled x \(Int(clip.bounds.origin.x)), inset \(Int(tv!.textContainerInset.width)), container \(Int(tv!.textContainer!.size.width))")
        case "bar":
            let root = ed!.window!.contentView!
            func dump(_ v: NSView, _ d: Int) { if d < 3 { log(String(repeating: "  ", count: d) + "\(type(of: v)) \(v.frame)"); v.subviews.forEach { dump($0, d + 1) } } }
            dump(root.subviews.last!, 0); log("root \(root.frame)")
        case "pinch":  // "pinch 2": magnifies ×2 around the first image, as a trackpad pinch would
            let sv = tv!.enclosingScrollView!
            var imageAt = 0
            ed!.storage.enumerateAttribute(.docxSealed, in: NSRange(location: 0, length: ed!.storage.length)) { v, r, stop in
                if case .image? = (v as? Sealed)?.display { imageAt = r.location; stop.pointee = true }
            }
            func imageFrame() -> NSRect {
                let lm = tv!.textLayoutManager!, tcm = lm.textContentManager!
                guard let loc = tcm.location(tcm.documentRange.location, offsetBy: imageAt), let f = lm.textLayoutFragment(for: loc) else { return .zero }
                return f.layoutFragmentFrame.offsetBy(dx: tv!.textContainerOrigin.x, dy: tv!.textContainerOrigin.y)
            }
            tv!.scrollRangeToVisible(NSRange(location: imageAt, length: 1))
            let before = imageFrame(), container = tv!.textContainer!.size.width, width = tv!.frame.width
            sv.setMagnification(sv.magnification * (Double(arg) ?? 2), centeredAt: NSPoint(x: before.midX, y: before.midY))
            let after = imageFrame()
            log("pinch: magnification \(sv.magnification), container \(container) -> \(tv!.textContainer!.size.width), textView \(Int(width)) -> \(Int(tv!.frame.width)), image \(before.origin) -> \(after.origin), image visible \(sv.contentView.bounds.intersects(after)), zoom label \(Int(ed!.zoom * 100))%")
        case "wait": break
        case "quit": NSApp.terminate(nil)
        default: log("unknown \(cmd)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (cmd == "wait" ? (Double(arg) ?? 1) : 0.15)) { step(rest) }
    }
}

final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    init(_ pb: NSPasteboard, at p: NSPoint, window: NSWindow) { draggingPasteboard = pb; draggingLocation = p; draggingDestinationWindow = window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .link] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
