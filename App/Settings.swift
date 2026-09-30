import AppKit

enum Settings {
    static let defaultPatterns = "Тур \\d+\nRound \\d+\n\tВопрос \\d+\n\tQuestion \\d+"

    /// Zoom new windows open at; 100% unless the user picks another in Settings.
    static var defaultZoom: CGFloat {
        let v = UserDefaults.standard.double(forKey: "defaultZoom")
        return v > 0 ? CGFloat(v) : 1
    }

    static var author: (name: String, initials: String) {
        let d = UserDefaults.standard
        let name = d.string(forKey: "authorName").flatMap { $0.isEmpty ? nil : $0 } ?? NSFullUserName()
        let initials = d.string(forKey: "authorInitials").flatMap { $0.isEmpty ? nil : $0 }
            ?? String(name.split(separator: " ").compactMap(\.first).prefix(3))
        return (name, initials)
    }

    /// Outline Patterns: one regular expression per line, leading tabs or spaces give the level.
    static var outlinePatterns: [(level: Int, regex: NSRegularExpression)] {
        let text = UserDefaults.standard.string(forKey: "outlinePatterns") ?? defaultPatterns
        return text.split(separator: "\n").compactMap { line in
            let level = line.prefix { $0 == "\t" || $0 == " " }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 4
            let body = line.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty, let re = try? NSRegularExpression(pattern: "^\\s*(?:" + body + ")") else { return nil }
            return (level, re)
        }
    }
}

final class SettingsWindow: NSWindowController {
    static let shared = SettingsWindow()
    private let name = NSTextField()
    private let initials = NSTextField()
    private let patterns = NSTextView()
    private let zoom = NSPopUpButton(frame: .zero, pullsDown: false)

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        w.title = "Settings"
        super.init(window: w)
        let a = Settings.author
        name.stringValue = a.name
        initials.stringValue = a.initials
        patterns.string = UserDefaults.standard.string(forKey: "outlinePatterns") ?? Settings.defaultPatterns
        for step in EditorController.zoomSteps {
            zoom.addItem(withTitle: "\(Int(step * 100))%")
            zoom.lastItem?.tag = Int(step * 100)
        }
        zoom.selectItem(withTag: Int((Settings.defaultZoom * 100).rounded()))
        zoom.target = self
        zoom.action = #selector(save)
        patterns.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        patterns.isAutomaticQuoteSubstitutionEnabled = false
        let patternScroll = NSScrollView()
        patternScroll.documentView = patterns
        patternScroll.hasVerticalScroller = true
        patternScroll.borderType = .bezelBorder
        patterns.autoresizingMask = [.width]
        patterns.isVerticallyResizable = true
        patternScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Comment author:"), name],
            [NSTextField(labelWithString: "Initials:"), initials],
            [NSTextField(labelWithString: "Default zoom:"), zoom],
            [NSTextField(labelWithString: "Outline patterns:"), patternScroll],
            [NSGridCell.emptyContentView, NSTextField(wrappingLabelWithString: "One regular expression per line, matched at the start of a paragraph. Indent a line with a tab to nest it.")],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = NSView()
        w.contentView!.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 20),
            name.widthAnchor.constraint(equalToConstant: 280),
            initials.widthAnchor.constraint(equalToConstant: 80),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(save), name: NSWindow.willCloseNotification, object: w)
        NotificationCenter.default.addObserver(self, selector: #selector(save), name: NSControl.textDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(save), name: NSText.didChangeNotification, object: patterns)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func save() {
        let d = UserDefaults.standard
        d.set(name.stringValue, forKey: "authorName")
        d.set(initials.stringValue, forKey: "authorInitials")
        d.set(patterns.string, forKey: "outlinePatterns")
        if zoom.selectedTag() > 0 { d.set(Double(zoom.selectedTag()) / 100, forKey: "defaultZoom") }
    }
}
