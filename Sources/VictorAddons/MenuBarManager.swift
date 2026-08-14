import AppKit
import Foundation
import UserNotifications

class MenuBarManager: NSObject, NSMenuDelegate {
    static let BUILD_TIME = "Aug 14, 22:53"

    struct TranscriptionDebugState {
        let isTranscribing: Bool
        let isStale: Bool
        let isPausedByBattery: Bool
        let source: String
        let menuTitle: String
        let iconMode: String
    }

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private(set) var darkModeItem: NSMenuItem!
    private(set) var emojiOverlayItem: NSMenuItem!
    private(set) var transcribeItem: NSMenuItem!
    private(set) var wsStatusItem: NSMenuItem!
    private var killSubmenu: NSMenu!
    private var portHistory: [Int] = []
    private var portItems: [Int: NSMenuItem] = [:]

    private var portRefreshTimer: Timer?
    private var stopBlinkTimer: Timer?
    private var stopBlinkAlt: Bool = false
    private var isTranscribing: Bool = false
    private var isTranscriptionStale: Bool = false
    private var isTranscriptionPausedByBattery: Bool = false
    private var transcribeSource: String = ""
    private var availableSources: [String] = []
    private var wsConnected: Bool = false
    private var sessionActive: Bool = false
    private(set) var tailItem: NSMenuItem!
    private(set) var fluxInboxItem: NSMenuItem!
    private var transcribeSubmenu: NSMenu!

    private(set) var resumeItem: NSMenuItem!

    /// When the last break ended (✕ or expiry). Persisted so the "Resumed Xm ago"
    /// clock survives an app restart mid-workshop.
    private static let kBreakEndedAt = "BreakTimer.lastEndedAt"
    var breakEndedAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: Self.kBreakEndedAt)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let d = newValue {
                UserDefaults.standard.set(d.timeIntervalSince1970, forKey: Self.kBreakEndedAt)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.kBreakEndedAt)
            }
        }
    }

    // Callbacks wired in by AppDelegate
    var onQuit: (() -> Void)?
    var onToggleDarkMode: (() -> Void)?
    var onMonitor: (() -> Void)?
    var onKillPort: ((Int) -> Void)?
    var onKillPortPrompt: (() -> Void)?
    var onTakeScreenshot: (() -> Void)?
    var onDisplayJoinLink: (() -> Void)?
    var onDisplayClipboardLink: (() -> Void)?
    /// ⌘⌃K, from the event tap — the catalog has no menu row of its own.
    var onOpenCatalog: (() -> Void)?
    var onOpenCalendar: (() -> Void)?
    var onOpenGmail: (() -> Void)?
    var onDesktopEffect: ((String) -> Void)?
    var onTileTerminals: (() -> Void)?
    var onFixDisplayLayout: (() -> Void)?
    var onPickSource: ((String) -> Void)?
    var onTailPreview: (() -> String?)?
    var onMenuOpened: (() -> Void)?
    var onAppendClipboardToNotes: (() -> Void)?
    var onWhip: (() -> Void)?
    var onBreak: ((Int) -> Void)?
    var onEmojiOverlayEnabledChanged: ((Bool) -> Void)?
    /// Force one Flux-inbox poll now, bypassing the power gate.
    var onCheckTaskInbox: (() -> Void)?
    /// Current `(last real inbox read, agents launched so far)` for the 📬 title.
    var onTaskInboxStatus: (() -> (lastCheck: Date?, launches: Int))?

    // 🔥 Whip Claude — playful "interrupt Claude" overlay. Fires on click; Esc dismisses.

    private var portHistoryURL: URL { PortKiller.portsFileURL }

    func setup() {
        loadPortHistory()
        buildMenu()
        setupStatusItem()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        if let url = Bundle.module.url(forResource: "icon_leaf", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        }
        statusItem.menu = menu
    }

    // MARK: - Menu Building

    private func buildMenu() {
        menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // Kill… submenu (8080 is included as a regular entry inside)
        let killItem = NSMenuItem(title: "☠️ Kill by port…", action: nil, keyEquivalent: "")
        killItem.isEnabled = true
        killSubmenu = NSMenu()
        killItem.submenu = killSubmenu
        menu.addItem(killItem)

        // ☕️ Break — countdown "watch" overlay. The durations are FLAT items
        // in the main menu (no submenu), each starting/resetting the overlay
        // directly on click.
        let breakDurations: [(String, Int)] = [
            ("☕️ Break: 1 minute", 1),
            ("☕️ Break: 5 minutes", 5),
            ("☕️ Break: 10 minutes", 10),
            ("☕️ Break: 12 minutes", 12),
            ("☕️ Break: 15 minutes", 15),
            ("☕️ Break: 1 hour", 60),
        ]
        for (title, minutes) in breakDurations {
            let item = NSMenuItem(title: title, action: #selector(breakAction(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.representedObject = minutes
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Resume item
        resumeItem = addItem("⏱️ Resumed -", action: nil)
        resumeItem.isEnabled = false
        // Transcribe status row (read-only; opens the mic-source submenu).
        // Transcription runs automatically on AC — no manual start/stop here.
        transcribeItem = addItem("Transcribing", action: nil)
        transcribeSubmenu = NSMenu()
        transcribeSubmenu.autoenablesItems = false

        // Tail (was Monitor)
        tailItem = addItem("🐕 Tail", action: #selector(monitorAction))

        // 📬 Check task inbox — the manual override for the poller's power
        // gate. Scheduled polls only run on AC, so while unplugged this item is
        // the ONLY way an email ever becomes a task. Its title carries the two
        // facts worth knowing at a glance: how long since the inbox was
        // actually read, and how many agents have been launched from it.
        fluxInboxItem = addItem(FluxInboxMenu.base, action: #selector(checkTaskInboxAction))

        // Screenshot — ONE item for one key. Clicking it takes the whole screen
        // (a click cannot be held); the title is where the other half of the
        // shortcut is taught, since a hold is the one gesture nothing on screen
        // reveals. A second item for the crop would have been a row you can
        // never usefully click, explaining a key you already have.
        let screenshotItem = addItem("📸 Screenshot (hold to crop)", action: #selector(takeScreenshotAction))
        screenshotItem.keyEquivalent = "p"
        screenshotItem.keyEquivalentModifierMask = .control

        menu.addItem(.separator())

        // WS status / join link — single unified item (state applied by refreshWsItem below)
        wsStatusItem = addItem("", action: nil)
        addItem("🔳 Display clipboard link", action: #selector(displayClipboardLinkAction))

        menu.addItem(.separator())

        // Desktop Effects submenu
        let effectsItem = NSMenuItem(title: "⭐️ Effects", action: nil, keyEquivalent: "")
        effectsItem.isEnabled = true
        let effectsSubmenu = NSMenu()
        effectsItem.submenu = effectsSubmenu
        let effectPairs: [(String, String)] = [
            ("Heart ❤️",        "heart"),
            ("Confetti 🎊",     "confetti"),
            ("Zorro",           "zorro"),
            ("Fear 😱",         "fear"),
            ("Old Film 📽️",    "sepia"),
            ("Fail Stamp",      "fail"),
            ("Fireworks 🎆",    "fireworks"),
            ("Applause 👏",     "applause"),
            ("Nuke ☢️",          "explosion"),
            ("Broken Glass 💥", "broken-glass"),
            ("Game Over",       "game-over"),
            ("Pulse",           "pulse"),
            ("Fire Alarm 🚨",    "fire-alarm"),
            ("Bullet Holes 🎯",  "bullet-holes"),
            ("Phone Ring 📱",   "phone-ring"),
            ("FBI Knock 🚪",    "fbi-knock"),
            ("Brother 🤢",       "brother"),
            ("Gangnam 💃",       "gangnam"),
            ("Love Hands 🤲",   "love-hands"),
            ("Death Star ☠️",    "star-wars"),
            ("Gong 🔔",          "gong"),
            ("Rainbow 🌈",       "rainbow"),
            ("Snow ❄️",          "snow"),
            ("Cavalry 🐎",       "cavalry"),
            ("Counter-Strike 🔫", "counter-strike"),
            ("Microwave ⏲️",      "microwave"),
            ("Wrong X ❌",        "wrong-x"),
            ("Drum Roll 🥁",     "drum-roll"),
            ("Phoenix 🔥",        "phoenix"),
            ("Money 💸",          "money"),
            ("Laugh 🤣",          "laugh"),
            ("Corner Confetti 🎉", "corner-confetti"),
            ("Heartbeat 💓",      "heartbeat"),
            ("Spiral Hearts 💘",  "spiral-hearts"),
            ("Green Flash 🟢",    "green-flash"),
        ]
        for (title, name) in effectPairs {
            let item = NSMenuItem(title: title, action: #selector(desktopEffectAction(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.representedObject = name
            effectsSubmenu.addItem(item)
        }
        menu.addItem(effectsItem)

        // Extra submenu
        let extraItem = NSMenuItem(title: "👩🏻‍💻 Extra", action: nil, keyEquivalent: "")
        extraItem.isEnabled = true
        let extraSubmenu = NSMenu()
        extraItem.submenu = extraSubmenu

        // Append clipboard to session notes (⌃⌥V)
        let appendNotesItem = NSMenuItem(title: "📝 Paste Clipboard to Notes", action: #selector(appendClipboardToNotesAction), keyEquivalent: "v")
        appendNotesItem.keyEquivalentModifierMask = [.control, .option]
        appendNotesItem.target = self
        appendNotesItem.isEnabled = true
        extraSubmenu.addItem(appendNotesItem)

        emojiOverlayItem = NSMenuItem(title: "Emoji Overlay", action: #selector(toggleEmojiOverlayAction), keyEquivalent: "")
        emojiOverlayItem.target = self
        emojiOverlayItem.isEnabled = true
        emojiOverlayItem.state = KeymapOverlaySettings.isEnabled ? .on : .off
        extraSubmenu.addItem(emojiOverlayItem)

        // Dark Mode (⌘⌃⌥D)
        darkModeItem = NSMenuItem(title: "Dark Mode", action: #selector(toggleDarkModeAction), keyEquivalent: "d")
        darkModeItem.keyEquivalentModifierMask = [.command, .control, .option]
        darkModeItem.target = self
        darkModeItem.isEnabled = true
        extraSubmenu.addItem(darkModeItem)

        // Gmail (⌘⌃G), Calendar (⌘⌃L), Tile (⌘⌃A), Terminal (⌘⌃T) and Claude in
        // ~/workspace (F8, ⌘⌃C) have no rows here: every one of those keys is
        // taught by the ⌘⌃ cheat-sheet you get by *holding* the modifiers, which
        // is both faster to reach than a submenu and shows all of them at once.
        // What stays is what the sheet can't replace: the two toggles, and the
        // clipboard→notes item (a menu click cannot capture the previous app's
        // selection, so ⌘⌃S has no menu form at all).
        //
        // The claude-per-repo launchers stay because they are not a key: each
        // opens claude in a specific repo, renamed, in its own screen quarter.
        // `🎅 workspace` pointed at ~/workspace/ai, which no longer exists (it
        // became skills-private), so that one is gone.
        let dreamEntries: [(String, Selector)] = [
            ("🎅 training-assistant", #selector(openDreamTrainingAssistant)),
            ("🎅 macos-addons",       #selector(openDreamMacOSAddons)),
        ]
        for (title, sel) in dreamEntries {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            extraSubmenu.addItem(item)
        }

        menu.addItem(extraItem)

        // 🖥️ Arrange Monitors — force the projector/standard arrangement now (manual
        // fallback for a venue projector that came up wrong). Top-level rather
        // than buried in the submenu: it's wanted in a hurry, mid-talk.
        let fixDisplayItem = addItem("🖥️ Arrange Monitors", action: #selector(fixDisplayLayoutAction))
        fixDisplayItem.isEnabled = true

        // 📕 Catalog has no row: ⌘⌃K opens it from the event tap and the ⌘⌃
        // cheat-sheet already teaches that key, so the menu line was a third
        // copy of something two other places say better.

        // 🔥 Whip — crack a whip to interrupt Claude (⌃W). Plain action (no checkbox); Esc dismisses.
        menu.addItem(.separator())
        let wipItem = addItem("🔥 Whip Agent", action: #selector(whipAction))
        wipItem.keyEquivalent = "w"
        wipItem.keyEquivalentModifierMask = .control

        // 🔁 Restart has no row either: opening the app again (Spotlight, Finder,
        // Dock) relaunches it — `AppDelegate.applicationShouldHandleReopen` →
        // `AppRelaunch` — which is the gesture you reach for anyway when
        // something is wedged.

        // Quit (build timestamp inlined to save a menu line). Uses a full-width
        // emoji (🔴) instead of the narrow ⏻ power glyph so it lines up with the
        // other menu items' emojis.
        let quitItem = addItem("🔴 Quit - built " + MenuBarManager.BUILD_TIME, action: #selector(quitApp))
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = .command

        refreshWsItem()
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if action != nil {
            item.isEnabled = true
        }
        menu.addItem(item)
        return item
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        onMenuOpened?()
        portRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshPortItems()
            // Lets a "checking…" click resolve to its real result without the
            // user having to close and reopen the menu.
            self?.updateFluxInboxItem()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        portRefreshTimer?.invalidate()
        portRefreshTimer = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshDynamicItems()
    }

    private func refreshDynamicItems() {
        loadPortHistory()
        killSubmenu.removeAllItems()
        portItems = [:]

        // Always include 8080 first, then deduped port history.
        let allPorts = ([8080] + portHistory).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        for port in allPorts {
            let item = NSMenuItem(title: ":\(port)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            killSubmenu.addItem(item)
            portItems[port] = item
        }

        killSubmenu.addItem(.separator())
        let portItem = NSMenuItem(title: "New Port…", action: #selector(killPortPrompt), keyEquivalent: "")
        portItem.target = self
        killSubmenu.addItem(portItem)

        darkModeItem.title = "Dark Mode"

        updateTranscribeTitle()
        updateTailItem()
        updateFluxInboxItem()

        refreshPortItems()

        // Show up to 12h (a full workshop day); beyond that the value is stale.
        if let endedAt = breakEndedAt,
           case let elapsed = Int(Date().timeIntervalSince(endedAt)),
           (0...(12 * 3600)).contains(elapsed) {
            applyResumedTitle(RHTimerMonitor.formatElapsed(elapsed),
                              urgency: RHTimerMonitor.urgency(elapsed))
        } else {
            applyResumedTitle("⏱️ Resumed -", urgency: .fresh)
        }

    }

    /// Colour the "Resumed …" row once a break is due, so the glance is enough.
    ///
    /// It is drawn through `attributedTitle` because the item is **disabled** —
    /// it is a readout, nothing to click — and a disabled item's plain title is
    /// dimmed by AppKit, which is precisely the opposite of what a warning wants.
    /// An explicit foreground colour survives that dimming.
    ///
    /// The yellow is appearance-resolved for the same reason the menu-bar apple
    /// glyph is: `systemYellow` is legible on a dark menu and nearly invisible on
    /// a light one, so in light mode it becomes a dark amber instead.
    private func applyResumedTitle(_ title: String, urgency: RHTimerMonitor.Urgency) {
        resumeItem.title = title
        switch urgency {
        case .fresh:
            resumeItem.attributedTitle = nil
        case .due, .overdue:
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let color: NSColor = urgency == .overdue
                ? .systemRed
                : (dark ? .systemYellow : NSColor(calibratedRed: 0.62, green: 0.44, blue: 0.0, alpha: 1))
            resumeItem.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: color,
                             .font: NSFont.menuFont(ofSize: 0)])
        }
    }

    private func refreshPortItems() {
        let allPorts = ([8080] + portHistory).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        for port in allPorts {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let proc = MenuBarManager.processName(forPort: port)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard let item = self.portItems[port] else { return }
                    if let proc = proc {
                        item.title = ":\(port) \(proc)"
                        item.isEnabled = true
                        item.action = #selector(self.killHistoricalPort(_:))
                        item.tag = port
                        item.target = self
                    } else {
                        item.title = ":\(port)"
                        item.isEnabled = false
                    }
                }
            }
        }
    }

    private static func processName(forPort port: Int) -> String? {
        let pidOut = runShell("/usr/sbin/lsof", args: ["-ti", ":\(port)"])
        guard let pid = pidOut.split(separator: "\n")
            .map({ String($0).trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let comm = runShell("/bin/ps", args: ["-p", pid, "-o", "comm="]).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = URL(fileURLWithPath: comm).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func runShell(_ path: String, args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - Actions

    @objc private func monitorAction() {
        onMonitor?()
    }

    @objc private func toggleDarkModeAction() {
        onToggleDarkMode?()
    }

    @objc private func toggleEmojiOverlayAction() {
        let enabled = !KeymapOverlaySettings.isEnabled
        KeymapOverlaySettings.isEnabled = enabled
        emojiOverlayItem.state = enabled ? .on : .off
        onEmojiOverlayEnabledChanged?(enabled)
    }

    @objc private func takeScreenshotAction() {
        onTakeScreenshot?()
    }

    @objc private func displayJoinLinkAction() {
        onDisplayJoinLink?()
    }

    @objc private func desktopEffectAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        onDesktopEffect?(name)
    }

    @objc private func fixDisplayLayoutAction() {
        onFixDisplayLayout?()
    }


    @objc private func killHistoricalPort(_ sender: NSMenuItem) {
        killPort(sender.tag)
    }

    @objc private func killPortPrompt() {
        onKillPortPrompt?()
    }

    @objc private func displayClipboardLinkAction() {
        onDisplayClipboardLink?()
    }

    @objc private func appendClipboardToNotesAction() {
        onAppendClipboardToNotes?()
    }

    @objc private func startTrainingAssistantAction() {
        let script = """
        tell application "Terminal"
            do script "cd ~/workspace/training-assistant && ./start.sh"
            activate
        end tell
        """
        DispatchQueue.global().async { AppleScriptRunner.run(script) }
    }

    @objc private func openDreamTrainingAssistant() {
        openDreamClaude(directory: "~/workspace/training-assistant", sessionName: "training-assistant", quarter: .topRight)
    }

    @objc func openDreamMacOSAddons() {
        openDreamClaude(directory: "~/workspace/victor-macos-addons", sessionName: "macos-addons", quarter: .bottomRight)
    }

    /// F8 / ⌘⌃C global hotkey lands here.
    @objc func openDreamPlainWorkspace() {
        openWorkspaceTerminal(command: "claude")
    }

    /// ⌘⌃Q — the same window with permissions bypassed. The shell here is again
    /// interactive (see `openWorkspaceTerminal`), so `cx` — Victor's ~/.zshrc
    /// alias — would work; the flag stays spelled out anyway, so renaming the
    /// alias can never break the hotkey.
    @objc func openBypassClaudeWorkspace() {
        openWorkspaceTerminal(command: "claude --dangerously-skip-permissions")
    }

    /// ⌘⌃T global hotkey lands here — same window, no `claude`: just a shell.
    /// The empty `do script ""` opens the window and runs NOTHING: ~/.zshrc
    /// already cds a shell that started in $HOME to ~/workspace, so an explicit
    /// `cd` would only print a redundant command line into a fresh window.
    @objc func openPlainTerminalWorkspace() {
        openWorkspaceTerminal(command: nil)
    }

    /// The screen a point is on — for the cursor, that is the screen Victor is
    /// looking at when he reaches for the shortcut, and the only one he can
    /// mean. (Pinning these windows to the built-in Retina, as this used to,
    /// puts them on the projector during a workshop.)
    ///
    /// It takes the point rather than sampling `NSEvent.mouseLocation` itself so
    /// that the screen and the quarter below are answered from **one** sample: two
    /// separate reads can straddle a screen or quadrant edge while the hand is
    /// still moving, and the window would then be sized for one screen and placed
    /// by the other half of a different one.
    private func screen(containing p: NSPoint) -> NSScreen {
        NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Which quarter of `screen` the cursor is in. The window opens **where the
    /// hand already is**: the shortcut is pressed while looking at a spot, and that
    /// spot is the answer to "where do you want this" — a fixed corner lands the
    /// terminal on top of what is being read about as often as not.
    ///
    /// NB `NSScreen` coordinates count y **upward**, so `p.y < midY` is the BOTTOM
    /// half (the opposite of every top-left-origin space in this file).
    private func quarter(of p: NSPoint, on screen: NSScreen) -> ScreenQuarter {
        let f = screen.frame
        switch (p.y < f.midY, p.x < f.midX) {
        case (true, true):   return .bottomLeft
        case (true, false):  return .bottomRight
        case (false, true):  return .topLeft
        case (false, false): return .topRight
        }
    }

    /// Open a Terminal window in ~/workspace on the screen under the cursor,
    /// optionally running `command`.
    ///
    /// **The command is typed into the window by `do script`.** It used to travel
    /// in a `/tmp/victor_*.sh` file passed as the shell's argv, which closed one
    /// real race — `do script` writes its characters into a window that already
    /// has keyboard focus, so anything typed in that gap interleaves and the shell
    /// runs `clahelloude` — but paid for it with a **whole extra zsh per window**:
    /// Terminal opens a document by running it from the window's own login shell,
    /// so the tree was `login → zsh --login → zsh -l victor_claude.sh → claude`
    /// instead of `login → zsh --login → claude`. The race is rare (it needs a
    /// keystroke inside the ~200 ms the window takes to appear) and self-evident
    /// when it happens; the extra process is permanent. So the simple shape is
    /// back, deliberately.
    ///
    /// A second consequence, this one in our favour: `do script` runs in an
    /// **interactive** login shell, so ~/.zshrc loads — which is what cds a window
    /// started in $HOME to ~/workspace (no explicit `cd` to print) and what makes
    /// aliases exist again.
    private func openWorkspaceTerminal(command: String?) {
        // `do script` / `open` already spawn a NEW window (not a tab), but
        // without an explicit `set bounds` Terminal reopens it on whichever
        // display it last had a window on. Both the screen AND the quarter come
        // from where the cursor was at the moment of the shortcut — one sample,
        // read once here and passed to both (see `screen(containing:)`). This
        // used to be pinned to `.bottomLeft`, which meant reaching for a terminal
        // while reading the bottom-left of a screen covered exactly what you were
        // looking at.
        let cursor = NSEvent.mouseLocation
        let screen = screen(containing: cursor)
        let displayID = displayID(of: screen)
        let (l, t, r, b) = appleScriptBounds(screen: screen, quarter: quarter(of: cursor, on: screen))

        // `do script` opens the window AND returns only once it exists, so the
        // bounds can be written on the next line — no `open -a Terminal` +
        // window-count polling loop, which is what the script-file version needed
        // because `open` is asynchronous and would otherwise resize the *previous*
        // window. An empty command (⌘⌃T) opens the window and runs nothing.
        let script = """
        tell application "Terminal"
            do script "\(Self.escapeForAppleScript(command ?? ""))"
            activate
            set bounds of front window to {\(l), \(t), \(r), \(b)}
        end tell
        """
        DispatchQueue.global().async {
            _ = AppleScriptRunner.run(script, timeout: 10)
            Self.tileAfterOpening(displayID: displayID)
        }
    }

    /// Both callers pass literals, but the command lands inside an AppleScript
    /// string literal, so a quote or a backslash in it would end that string early
    /// and turn the rest into (invalid) code rather than into arguments.
    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Tile the screen the new window landed on, so the window that was already
    /// there makes room instead of being covered. The wait is for Terminal: the
    /// `set bounds` above is still settling when the script returns, and reading
    /// a frame mid-move would tile the window from a position it has already left.
    /// Only that display is touched — see `TerminalTiler.tile(onDisplay:)`.
    private static func tileAfterOpening(displayID: CGDirectDisplayID?) {
        Thread.sleep(forTimeInterval: 0.6)
        TerminalTiler.tile(onDisplay: displayID)
    }

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private enum ScreenQuarter { case topLeft, topRight, bottomLeft, bottomRight }

    private func openDreamClaude(directory: String, sessionName: String, quarter: ScreenQuarter) {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let (l, t, r, b) = appleScriptBounds(screen: screen, quarter: quarter)

        // Typed into the window rather than carried by a `/tmp/dream_*.sh` file,
        // for the reason spelled out in `openWorkspaceTerminal`: a document opened
        // through Terminal is run BY the window's shell, so the script file cost an
        // extra zsh process for the lifetime of every one of these windows.
        let command = "cd \(directory) && claude '/rename \(sessionName)'"
        let script = """
        tell application "Terminal"
            do script "\(Self.escapeForAppleScript(command))"
            activate
            set bounds of front window to {\(l), \(t), \(r), \(b)}
        end tell
        """
        DispatchQueue.global().async { AppleScriptRunner.run(script, timeout: 10) }
    }

    private func appleScriptBounds(screen: NSScreen, quarter: ScreenQuarter) -> (Int, Int, Int, Int) {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens[0].frame.height
        let f = screen.visibleFrame
        let halfW = f.width / 2
        let halfH = f.height / 2
        let nsX: CGFloat
        let nsY: CGFloat
        switch quarter {
        case .topLeft:     nsX = f.minX;         nsY = f.minY + halfH
        case .topRight:    nsX = f.minX + halfW;  nsY = f.minY + halfH
        case .bottomLeft:  nsX = f.minX;         nsY = f.minY
        case .bottomRight: nsX = f.minX + halfW;  nsY = f.minY
        }
        let asLeft = Int(nsX)
        let asTop = Int(primaryHeight - nsY - halfH)
        let asRight = Int(nsX + halfW)
        let asBottom = Int(primaryHeight - nsY)
        return (asLeft, asTop, asRight, asBottom)
    }

    @objc private func quitApp() {
        overlayInfo("Quit")
        onQuit?()
        exit(0)
    }

    @objc private func whipAction() {
        onWhip?()
    }

    @objc private func breakAction(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        onBreak?(minutes)
    }

    private func killPort(_ port: Int) {
        onKillPort?(port)
    }

    // MARK: - Public API

    func updateWsStatus(_ connected: Bool) {
        wsConnected = connected
        refreshWsItem()
        refreshMenuIcon()
    }

    func setJoinLinkEnabled(_ enabled: Bool) {
        sessionActive = enabled
        refreshWsItem()
        refreshMenuIcon()
    }

    private func refreshWsItem() {
        if sessionActive {
            wsStatusItem.title = "🟢 Interact Link"
            wsStatusItem.isEnabled = true
            wsStatusItem.action = #selector(displayJoinLinkAction)
            wsStatusItem.target = self
        } else if wsConnected {
            wsStatusItem.title = "🟢 WS connected"
            wsStatusItem.isEnabled = false
            wsStatusItem.action = nil
        } else {
            wsStatusItem.title = "🔴 Start training assistant"
            wsStatusItem.isEnabled = true
            wsStatusItem.action = #selector(startTrainingAssistantAction)
            wsStatusItem.target = self
        }
    }

    func flashScreenshotIcon() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = "📷"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            button.title = ""
            self?.refreshMenuIcon()
        }
    }

    func setTranscribing(_ active: Bool) {
        isTranscribing = active
        updateTranscribeTitle()
        refreshMenuIcon()
    }

    func setTranscriptionStale(_ stale: Bool) {
        isTranscriptionStale = stale
        refreshMenuIcon()
    }

    func setTranscriptionPausedByBattery(_ paused: Bool) {
        isTranscriptionPausedByBattery = paused
        refreshMenuIcon()
        updateTranscribeTitle()
    }

    private func refreshMenuIcon() {
        guard let button = statusItem.button else { return }
        let badge = (wsConnected || sessionActive) ? "🟢" : "🟥"

        if !isTranscribing && isTranscriptionPausedByBattery {
            button.image = makePngIcon("icon_leaf", badge: badge)
        } else if !isTranscribing {
            let asset = stopBlinkAlt ? "icon_stop_blue" : "icon_stop"
            button.image = makePngIcon(asset, badge: badge)
        } else if isTranscriptionStale {
            button.image = makeEmojiIcon("🤐", badge: badge)
        } else if !transcribeSource.isEmpty, let icon = makeEmojiIcon(transcribeSource, badge: badge) {
            button.image = icon
        } else {
            button.image = makeChatBubbleIcon(badge: badge)
        }
        updateStopBlinkTimer()
    }

    private func updateStopBlinkTimer() {
        // "Stopped" here means on AC but Whisper isn't running — an error
        // state in the auto-on model (it should always run on AC). Blink the
        // red stop icon to flag it, at any hour. On battery we show the leaf
        // instead, so this never fires there.
        let isStopped = !isTranscribing && !isTranscriptionPausedByBattery
        if isStopped {
            if stopBlinkTimer == nil {
                let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.stopBlinkAlt.toggle()
                    self.refreshMenuIcon()
                }
                RunLoop.main.add(timer, forMode: .common)
                stopBlinkTimer = timer
            }
        } else {
            stopBlinkTimer?.invalidate()
            stopBlinkTimer = nil
            stopBlinkAlt = false
        }
    }

    /// Resource PNG composited with a badge in the bottom-right quadrant.
    private func makePngIcon(_ resourceName: String, badge: String?) -> NSImage? {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
              let base = NSImage(contentsOf: url) else { return nil }
        let size = NSSize(width: 18, height: 18)
        let composite = NSImage(size: size)
        composite.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        if let badge = badge, !badge.isEmpty {
            drawBadge(badge, canvas: size)
        }
        composite.unlockFocus()
        composite.isTemplate = false
        return composite
    }

    // MARK: - Source glyphs

    /// Whisper reports the built-in mic as 💻. That string is the **wire value**
    /// — it comes from `whisper_runner.py`'s `_ME_PATTERNS` and every lookup here
    /// (`availableSources`, the checkmark in the submenu) is string equality — so
    /// it stays 💻 on the protocol and only the glyph we *draw* changes, to the
    /// Apple logo (U+F8FF, the bitten apple): "this Mac", not "a laptop".
    private static let glyphOverrides: [String: String] = ["💻": "\u{F8FF}"]

    private static func displayGlyph(_ emoji: String) -> String {
        glyphOverrides[emoji] ?? emoji
    }

    /// Overridden glyphs are the only *monochrome* ones — every real emoji
    /// carries its own colour. A monochrome glyph must be tinted to match the
    /// surface it lands on, or a black apple vanishes into a dark menu bar.
    private static func isMonochromeGlyph(_ emoji: String) -> Bool {
        glyphOverrides[emoji] != nil
    }

    private static func glyphInk(_ appearance: NSAppearance?) -> NSColor {
        let dark = (appearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? .white : .black
    }

    /// A text glyph is drawn inside its em-box, and the Apple logo occupies far
    /// less of that box than an emoji does — measured at the same point size in
    /// an 18×18 icon, 💻 inks the full 18×18 while  inks only 10.5×13, which
    /// reads as a visibly *smaller* icon. Scale it up to compensate: ×1.25 gets
    ///  to 13×16 and still clears both icon sizes we draw (18×18 menu bar,
    /// 16×16 menu item). ×1.4 clips.
    private static let monochromeGlyphScale: CGFloat = 1.25

    /// Attributes for drawing one source glyph on `appearance`.
    ///
    /// The system font is the right one for U+F8FF — verified with
    /// `CTFontGetGlyphsForCharacters`, `.AppleSystemUIFont` carries the glyph
    /// directly while "Apple Symbols", despite the name, does not (it only
    /// renders it through fallback).
    private static func glyphAttributes(_ emoji: String, size: CGFloat,
                                        on appearance: NSAppearance?) -> [NSAttributedString.Key: Any] {
        guard isMonochromeGlyph(emoji) else {
            return [.font: NSFont.systemFont(ofSize: size)]
        }
        return [.font: NSFont.systemFont(ofSize: size * monochromeGlyphScale),
                .foregroundColor: glyphInk(appearance)]
    }

    /// Our menu-bar icons are baked bitmaps, so a light/dark flip cannot repaint
    /// them by itself — the monochrome ones have to be re-drawn. The theme
    /// notification lands slightly *before* `effectiveAppearance` updates, hence
    /// the short delay.
    @objc private func systemAppearanceChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refreshMenuIcon()
            self?.updateTranscribeTitle()
        }
    }

    /// Render any emoji as a colored 18×18 menu-bar icon, optionally with a small
    /// emoji badge in the bottom-right 9×9 quadrant (50% w × 50% h).
    /// `isTemplate = false` is essential — template images are forced to a single
    /// tone by macOS, which strips the emoji's color glyph (renders as a white blob).
    /// Apple Color Emoji draws colored only when the host image is non-template.
    private func makeEmojiIcon(_ emoji: String, badge: String? = nil) -> NSImage? {
        guard !emoji.isEmpty else { return nil }
        let size = NSSize(width: 18, height: 18)
        let composite = NSImage(size: size)
        composite.lockFocus()
        let attrs = Self.glyphAttributes(emoji, size: 16,
                                         on: statusItem.button?.effectiveAppearance)
        let str = Self.displayGlyph(emoji) as NSString
        let strSize = str.size(withAttributes: attrs)
        let origin = NSPoint(x: (size.width - strSize.width) / 2,
                             y: (size.height - strSize.height) / 2)
        str.draw(at: origin, withAttributes: attrs)
        if let badge = badge, !badge.isEmpty {
            drawBadge(badge, canvas: size)
        }
        composite.unlockFocus()
        composite.isTemplate = false
        return composite
    }

    /// Chat-bubble PNG fallback (used briefly while transcribing before a source
    /// is detected). Always composites with badge so the indicator is visible.
    private func makeChatBubbleIcon(badge: String?) -> NSImage? {
        guard let url = Bundle.module.url(forResource: "icon_leaf", withExtension: "png"),
              let base = NSImage(contentsOf: url) else { return nil }
        let size = NSSize(width: 18, height: 18)
        let composite = NSImage(size: size)
        composite.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        if let badge = badge, !badge.isEmpty {
            drawBadge(badge, canvas: size)
        }
        composite.unlockFocus()
        composite.isTemplate = false
        return composite
    }

    /// Draw an emoji badge centered in the bottom-right quadrant of the current
    /// drawing context. Caller owns lockFocus/unlockFocus.
    private func drawBadge(_ emoji: String, canvas: NSSize) {
        let quadSide = canvas.width / 2
        let quad = NSRect(x: canvas.width - quadSide, y: 0, width: quadSide, height: quadSide)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8)]
        let str = emoji as NSString
        let strSize = str.size(withAttributes: attrs)
        let origin = NSPoint(x: quad.midX - strSize.width / 2,
                             y: quad.midY - strSize.height / 2)
        str.draw(at: origin, withAttributes: attrs)
    }

    func setTranscribeSource(_ emoji: String) {
        transcribeSource = emoji
        updateTranscribeTitle()
        refreshMenuIcon()
    }

    private func updateTranscribeTitle() {
        // Read-only status row. Transcription runs automatically on AC and
        // pauses on battery — there is no manual start/stop. The only
        // interaction is picking which mic captures your voice (submenu).

        // Reset everything; configure per-state below.
        transcribeItem.image = nil
        transcribeItem.submenu = nil
        transcribeItem.action = nil
        transcribeItem.target = self
        transcribeItem.keyEquivalent = ""
        transcribeItem.keyEquivalentModifierMask = []

        if isTranscriptionPausedByBattery {
            transcribeItem.title = "Off - On Battery"
            transcribeItem.image = loadResourceIcon("icon_leaf")
            transcribeItem.isEnabled = false
            return
        }

        if isTranscribing {
            transcribeItem.title = "Transcribing"
            transcribeItem.image = transcribeSource.isEmpty ? nil : emojiAsIcon(transcribeSource)
            transcribeItem.submenu = transcribeSubmenu
            transcribeItem.isEnabled = true
            rebuildTranscribeSubmenu()
        } else {
            // On AC but momentarily down (starting up, or a crash before the
            // heartbeat restart). Auto-recovers; nothing for the user to do.
            transcribeItem.title = "Transcribing (off)"
            transcribeItem.isEnabled = false
        }
    }

    // Known _ME_PATTERNS in whisper_runner.py — order matches Python priority.
    // Each tuple: (display name, short emoji emitted by whisper, pattern token sent back).
    private static let knownSources: [(name: String, emoji: String, pattern: String)] = [
        ("Wireless Mic",     "🎤",  "Wireless Mic"),
        ("Stage Speakerphone","🏛️", "Room Speakerphone"),
        ("XLR Mic",          "🎙️",  "XLR"),
        ("Bose Headset",     "🎧",  "Bose"),
        ("MacBook",          "💻",  "MacBook"),
    ]

    private func rebuildTranscribeSubmenu() {
        transcribeSubmenu.removeAllItems()
        for src in Self.knownSources {
            // Titles are drawn by AppKit in the menu's own label colour, so the
            // monochrome  needs no tinting here — only the substitution.
            let item = NSMenuItem(title: "\(Self.displayGlyph(src.emoji)) \(src.name)",
                                  action: #selector(pickSource(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = src.pattern
            let available = availableSources.contains(src.emoji)
            item.isEnabled = available
            item.state = (src.emoji == transcribeSource) ? .on : .off
            transcribeSubmenu.addItem(item)
        }
    }

    @objc private func pickSource(_ sender: NSMenuItem) {
        guard let pattern = sender.representedObject as? String else { return }
        onPickSource?(pattern)
    }

    private func updateFluxInboxItem() {
        guard let item = fluxInboxItem else { return }
        let status = onTaskInboxStatus?() ?? (lastCheck: nil, launches: 0)
        item.title = FluxInboxMenu.title(lastCheck: status.lastCheck, launches: status.launches)
    }

    @objc private func checkTaskInboxAction() {
        // The poll is async; show that the click landed rather than leaving the
        // title reading "17m ago" until the round trip returns.
        fluxInboxItem?.title = "\(FluxInboxMenu.base) (checking…)"
        onCheckTaskInbox?()
    }

    private func updateTailItem() {
        let preview = onTailPreview?() ?? nil
        if let preview = preview, !preview.isEmpty {
            tailItem.title = "🐕 Tail \(preview)"
        } else {
            tailItem.title = "🐕 Tail"
        }
    }

    private func loadResourceIcon(_ name: String, size: NSSize = NSSize(width: 16, height: 16)) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = size
        return img
    }

    private func emojiAsIcon(_ emoji: String, size: NSSize = NSSize(width: 16, height: 16)) -> NSImage? {
        guard !emoji.isEmpty else { return nil }
        let img = NSImage(size: size)
        img.lockFocus()
        // Menu items are drawn on the menu's surface, which follows the system
        // appearance — not the (possibly different) menu-bar one.
        let attrs = Self.glyphAttributes(emoji, size: size.height - 2,
                                         on: NSApp.effectiveAppearance)
        let str = Self.displayGlyph(emoji) as NSString
        let strSize = str.size(withAttributes: attrs)
        let origin = NSPoint(x: (size.width - strSize.width) / 2,
                             y: (size.height - strSize.height) / 2)
        str.draw(at: origin, withAttributes: attrs)
        img.unlockFocus()
        return img
    }

    func setAvailableSources(_ sources: [String]) {
        availableSources = sources
        updateTranscribeTitle()
    }

    func transcriptionDebugState() -> TranscriptionDebugState {
        let iconMode: String
        if !isTranscribing {
            iconMode = "off"
        } else if isTranscriptionStale {
            iconMode = "stale"
        } else {
            iconMode = "on"
        }
        return TranscriptionDebugState(
            isTranscribing: isTranscribing,
            isStale: isTranscriptionStale,
            isPausedByBattery: isTranscriptionPausedByBattery,
            source: transcribeSource,
            menuTitle: transcribeItem.title,
            iconMode: iconMode
        )
    }

    // MARK: - Port History Persistence

    private func loadPortHistory() {
        portHistory = PortKiller.loadHistory(from: portHistoryURL)
    }
}
