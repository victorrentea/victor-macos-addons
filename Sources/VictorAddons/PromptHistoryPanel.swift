import AppKit

/// 🤖 **Prompts…** — the week of intercepted prompts, with a Send button on
/// each one that never reached the room.
///
/// The bottom-left offer pill (`SessionNotesAppender.offerPrompt`) asks once
/// and gives up after 9.5 s. This panel is the second chance for everything
/// that pill offered: one scrollable list, newest first, day by day, where a
/// click writes the prompt into the session notes exactly as hovering the pill
/// would have — the same `- 🤖 <text>` line `training-assistant` turns into the
/// participants' Prompts tab. Nothing new reaches the room through here; the
/// only thing that changes is *when* Victor gets to decide.
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

    private enum Row {
        case header(String)
        case prompt(CapturedPrompt)
    }

    private var panel: Panel?
    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var observer: NSObjectProtocol?

    private let width: CGFloat = 760
    private let maxHeight: CGFloat = 620
    private let headerRowH: CGFloat = 30
    private let promptRowH: CGFloat = 56

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: Present / dismiss

    /// The menu row's gesture: open it, or close it if it is already up.
    /// Keyed on `isVisible`, not on the reference: the panel hides itself when
    /// the app is deactivated, and after that a click on the row must bring it
    /// back rather than spend itself "closing" something already off-screen.
    func toggle() {
        if panel?.isVisible == true { close() } else { present() }
    }

    func present() {
        close()
        rebuildRows()

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
        tableView.dataSource = self
        tableView.delegate = self
        scroll.documentView = tableView
        content.addSubview(scroll)

        emptyLabel.stringValue = "No prompts captured yet.\n"
            + "Prompts are recorded only while a training session is running."
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = !rows.isEmpty
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

        let height = min(maxHeight, max(160, contentHeight()))
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .resizable, .utilityWindow],
                          backing: .buffered,
                          defer: false)
        panel.title = "🤖 Prompts — last \(PromptCapturePolicy.retentionDays) days"
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
        observer = NotificationCenter.default.addObserver(
            forName: PromptCaptureStore.changed, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        tableView.reloadData()
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
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

    private func contentHeight() -> CGFloat {
        rows.reduce(0) { total, row in
            switch row {
            case .header: return total + headerRowH + 2
            case .prompt: return total + promptRowH + 2
            }
        }
    }

    // MARK: Data

    private func rebuildRows() {
        rows = PromptCaptureStore.shared.sections().flatMap { section -> [Row] in
            [.header(section.title)] + section.prompts.map { Row.prompt($0) }
        }
    }

    private func reload() {
        rebuildRows()
        emptyLabel.isHidden = !rows.isEmpty
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return promptRowH }
        switch rows[row] {
        case .header: return headerRowH
        case .prompt: return promptRowH
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .prompt(let prompt):
            let view = PromptRowView()
            view.configure(prompt: prompt,
                           time: timeFormatter.string(from: prompt.date),
                           target: self,
                           action: #selector(sendAction(_:)),
                           tag: row)
            return view
        }
    }

    // MARK: Send

    /// Write the row's prompt into today's session notes — the same call the
    /// offer pill makes on hover — and mark it sent so the button retires. The
    /// store's change notification is what redraws the row.
    @objc private func sendAction(_ sender: NSButton) {
        let index = sender.tag
        guard index < rows.count, case .prompt(let prompt) = rows[index] else { return }
        guard SessionNotesAppender.sendPrompt(prompt.text) else { return }
        PromptCaptureStore.shared.markSent(prompt.id)
    }
}

/// One prompt in the list: source badge + time on the left, the prompt itself
/// in the middle (two lines, truncated — the full text is the tooltip), and the
/// Send button on the right, live only for a prompt the room has not seen.
private final class PromptRowView: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let body = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Send", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        badge.font = .systemFont(ofSize: 15)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .tertiaryLabelColor
        body.font = .systemFont(ofSize: 13)
        body.maximumNumberOfLines = 2
        body.lineBreakMode = .byTruncatingTail
        body.cell?.usesSingleLineMode = false
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)

        let left = NSStackView(views: [badge, time])
        left.orientation = .vertical
        left.alignment = .centerX
        left.spacing = 0

        let stack = NSStackView(views: [left, body, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: 42),
            button.widthAnchor.constraint(equalToConstant: 62),
        ])
        // The prompt text is the part that gives: the badge column and the
        // button keep their size, the middle absorbs the panel's width.
        body.setContentHuggingPriority(.defaultLow, for: .horizontal)
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    func configure(prompt: CapturedPrompt, time timeText: String,
                   target: AnyObject, action: Selector, tag: Int) {
        badge.stringValue = prompt.source.badge
        time.stringValue = timeText
        body.stringValue = PromptCapturePolicy.singleLine(prompt.text)
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
