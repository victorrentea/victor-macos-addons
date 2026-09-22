import AppKit

/// 🤖 **Last Prompts…** — today's intercepted prompts, with a Send button on
/// each one that never reached the room.
///
/// The bottom-left offer pill (`SessionNotesAppender.offerPrompt`) asks once
/// and gives up after 9.5 s. This panel is the second chance for everything
/// that pill offered: one scrollable list, newest first, where a click writes
/// the prompt into the session notes exactly as hovering the pill would have —
/// the same `- 🤖 <text>` line `training-assistant` turns into the
/// participants' Prompts tab. Nothing new reaches the room through here; the
/// only thing that changes is *when* Victor gets to decide.
///
/// **Today only, one line a prompt, paged as it scrolls** (2026-09-22, Victor:
/// *"sunt foarte multe-n lista și se încarcă greu … și doar prompturi de azi"*).
/// A day of workshop is 150 prompts; the week the panel used to open on was a
/// wall of two-line rows nobody read past the first screen. It now opens on the
/// newest `pageSize` and appends the next page when the scroll nears the end.
/// The line is `<agent icon> [Send] 5m ago | <prompt>`, his shape.
///
/// A row whose prompt already went to the notes (by pill or by this panel) is
/// greyed and its button reads "Sent" — that flag is the single reason the
/// store keeps state at all, and it is what makes the panel safe to scroll
/// through twice without double-posting.
final class PromptHistoryPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = PromptHistoryPanel()

    /// Key-capable panel: the app is an accessory (no Dock icon), so without
    /// this the list could be scrolled but never take a keystroke — and Esc is
    /// how a panel like this is expected to close.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        var onCancel: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }

    private var panel: Panel?
    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    /// Today's prompts, newest first — the whole day, of which `shown` are rows.
    private var today: [CapturedPrompt] = []
    private var shown = 0
    private var observers: [NSObjectProtocol] = []
    /// Re-reads the `5m ago` column once a minute while the panel is up.
    private var clock: Timer?

    private let width: CGFloat = 1000
    private let maxHeight: CGFloat = 800
    /// Everything in the row is 1.5× what it was (2026-09-22, Victor: *"mărește
    /// fontul cu 50% în last prompts window"*) — fonts, icon, columns, row.
    private let rowH: CGFloat = 38
    private let pageSize = 40
    private static let rowId = NSUserInterfaceItemIdentifier("promptRow")

    // MARK: Present / dismiss

    func present() {
        close()
        shown = 0
        reloadDay()

        let content = NSView()

        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        if tableView.tableColumns.isEmpty {
            tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("prompt")))
        }
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .none
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = rowH
        tableView.dataSource = self
        tableView.delegate = self
        scroll.documentView = tableView
        content.addSubview(scroll)

        emptyLabel.stringValue = "No prompts captured today.\n"
            + "Prompts are recorded only while a training session is running."
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 19.5)
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = !today.isEmpty
        content.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalToConstant: width - 80),
        ])

        let height = min(maxHeight, max(160, CGFloat(today.count) * (rowH + 2)))
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .resizable, .utilityWindow],
                          backing: .buffered,
                          defer: false)
        panel.title = "🤖 Today's prompts"
        panel.contentView = content
        panel.isFloatingPanel = true
        // Floats above the windows it is read against — but only while this app
        // is the active one. On a Mac whose built-in display is a projector, a
        // forgotten always-on-top panel is a panel the room reads for the rest
        // of the afternoon; clicking back into Chrome or the IDE puts it away
        // by itself, and the menu row brings it back.
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.onCancel = { [weak self] in self?.close() }
        panel.setFrame(frameCentredUnderMouse(width: width, height: height), display: false)
        self.panel = panel

        // Redraw when a prompt arrives (or is marked sent) while the list is up.
        observers.append(NotificationCenter.default.addObserver(
            forName: PromptCaptureStore.changed, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() })
        // The next page, when the scroll nears the end of what is drawn.
        scroll.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in self?.loadMoreIfNeeded() })
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.tableView.reloadData()
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        tableView.reloadData()
    }

    func close() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        clock?.invalidate()
        clock = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Open on the screen the hand is on, not the projected retina: this is a
    /// tool Victor reads, and the built-in display is what the room sees.
    private func frameCentredUnderMouse(width: CGFloat, height: CGFloat) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        return NSRect(x: visible.midX - width / 2,
                      y: visible.midY - height / 2,
                      width: width, height: height)
    }

    // MARK: Data

    /// Today's prompts from the store, newest first; `shown` keeps what has
    /// already been paged in and never exceeds the day.
    private func reloadDay() {
        let calendar = Calendar.current
        today = PromptCaptureStore.shared.all()
            .filter { calendar.isDateInToday($0.date) }
            .reversed()
        shown = min(today.count, max(shown, pageSize))
    }

    private func reload() {
        reloadDay()
        emptyLabel.isHidden = !today.isEmpty
        tableView.reloadData()
    }

    private func loadMoreIfNeeded() {
        guard shown < today.count else { return }
        let visible = scroll.contentView.bounds
        guard visible.maxY >= tableView.bounds.height - rowH * 5 else { return }
        let from = shown
        shown = min(today.count, shown + pageSize)
        tableView.insertRows(at: IndexSet(from..<shown), withAnimation: [])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < shown, row < today.count else { return nil }
        let view = (tableView.makeView(withIdentifier: Self.rowId, owner: nil) as? PromptRowView)
            ?? { let v = PromptRowView(); v.identifier = Self.rowId; return v }()
        view.configure(prompt: today[row], age: Self.age(of: today[row].date),
                       target: self, action: #selector(sendAction(_:)), tag: row)
        return view
    }

    /// `now`, `5m ago`, `3h ago` — the list is one day long, so nothing longer
    /// is ever needed.
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    // MARK: Send

    /// Write the row's prompt into today's session notes — the same call the
    /// offer pill makes on hover — and mark it sent so the button retires. The
    /// store's change notification is what redraws the row.
    @objc private func sendAction(_ sender: NSButton) {
        let index = sender.tag
        guard index < today.count else { return }
        let prompt = today[index]
        guard SessionNotesAppender.sendPrompt(prompt.text) else { return }
        PromptCaptureStore.shared.markSent(prompt.id)
    }
}

/// One prompt, one line: `<agent icon> [Send] 5m ago | <prompt>`. The full text
/// is the tooltip.
private final class PromptRowView: NSTableCellView {
    private let icon = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Send", target: nil, action: nil)
    private let age = NSTextField(labelWithString: "")
    private let body = FittedLine()

    /// The agent's own icon, read off the Mac at runtime — nothing brand-owned
    /// is bundled. Claude from its app, Copilot from the extension VS Code
    /// ships; nil falls back to `PromptSource.badge`.
    private static let icons: [PromptSource: NSImage] = {
        var out: [PromptSource: NSImage] = [:]
        // Clawd, Claude Code's own mark — these prompts are Claude Code's.
        if let clawd = ClaudeCodeIcon.image(height: 16) { out[.claude] = clawd }
        let copilot = "/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/copilot/assets/copilot.png"
        if let image = NSImage(contentsOfFile: copilot) { out[.copilot] = image }
        return out
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        badge.font = .systemFont(ofSize: 14)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 17, weight: .medium)
        age.font = .monospacedDigitSystemFont(ofSize: 16.5, weight: .regular)
        age.textColor = .secondaryLabelColor
        age.alignment = .left
        body.font = .systemFont(ofSize: 19.5)

        // `5m ago [Send] <icon> <prompt>` (2026-09-23, Victor: *"pune în
        // ordine data, [Send mai mare] <icon mai mic> | <Prompt>"*).
        let stack = NSStackView(views: [age, button, icon, badge, body])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 16),
            button.widthAnchor.constraint(equalToConstant: 84),
            age.widthAnchor.constraint(equalToConstant: 78),
        ])
        // The prompt text is the part that gives.
        body.setContentHuggingPriority(.defaultLow, for: .horizontal)
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    func configure(prompt: CapturedPrompt, age ageText: String,
                   target: AnyObject, action: Selector, tag: Int) {
        let image = Self.icons[prompt.source]
        icon.image = image
        icon.isHidden = image == nil
        badge.stringValue = prompt.source.badge
        badge.isHidden = image != nil
        icon.toolTip = prompt.source.name
        age.stringValue = ageText
        body.text = PromptCapturePolicy.singleLine(prompt.text)
        body.textColor = prompt.sent ? .tertiaryLabelColor : .labelColor
        toolTip = prompt.text
        button.title = prompt.sent ? "Sent" : "Send"
        button.isEnabled = !prompt.sent
        button.target = target
        button.action = action
        button.tag = tag
        button.toolTip = prompt.sent
            ? "Already on the participants' Prompts tab"
            : "Append to the session notes — the room sees it"
    }
}

/// **One line of text, fitted when it is drawn** — `<start> [...] <last 20>`
/// when it does not fit (2026-09-23, Victor: *"prompturile lungi să conțină și
/// ultimele 20 char"*).
///
/// A view that draws, not a label, and that is the fix: the first version
/// rewrote an `NSTextField`'s string inside `layout()`, which invalidates its
/// intrinsic size mid-pass, and AppKit ended the resulting constraint loop by
/// throwing — the app died every time the panel opened. Fitting at `draw`
/// changes pixels only; the view's size never depends on its text.
private final class FittedLine: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var font = NSFont.systemFont(ofSize: 13) { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var textColor = NSColor.labelColor { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(font.ascender - font.descender + font.leading) + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let line = Self.fitted(text, width: bounds.width, attrs: attrs)
        let size = (line as NSString).size(withAttributes: attrs)
        (line as NSString).draw(at: NSPoint(x: 0, y: ((bounds.height - size.height) / 2).rounded()),
                                withAttributes: attrs)
    }

    static func fitted(_ text: String, width: CGFloat, attrs: [NSAttributedString.Key: Any]) -> String {
        func fits(_ s: String) -> Bool { (s as NSString).size(withAttributes: attrs).width <= width }
        guard width > 0, !fits(text) else { return text }
        let tail = text.count > 40 ? " [...] " + String(text.suffix(20)) : "…"
        let head = Array(text.count > 40 ? text.dropLast(20) : Substring(text))
        var lo = 0, hi = head.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(String(head[..<mid]) + tail) { lo = mid } else { hi = mid - 1 }
        }
        return String(head[..<lo]).trimmingCharacters(in: .whitespaces) + tail
    }
}
