import AppKit
import Foundation
import UserNotifications

class MenuBarManager: NSObject, NSMenuDelegate {
    static let BUILD_TIME = "Apr 29, 01:00"

    struct TranscriptionDebugState {
        let isTranscribing: Bool
        let isStale: Bool
        let source: String
        let menuTitle: String
        let iconMode: String
    }

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private(set) var darkModeItem: NSMenuItem!
    private(set) var transcribeItem: NSMenuItem!
    private(set) var wsStatusItem: NSMenuItem!
    private var killSubmenu: NSMenu!
    private var portHistory: [Int] = []
    private var portItems: [Int: NSMenuItem] = [:]

    private var portRefreshTimer: Timer?
    private var isTranscribing: Bool = false
    private var isTranscriptionStale: Bool = false
    private var isTranscriptionPausedByBattery: Bool = false
    private var transcribeSource: String = ""
    private var wsConnected: Bool = false
    private var sessionActive: Bool = false

    private(set) var resumeItem: NSMenuItem!
    var breakEndedAt: Date?

    // Callbacks wired in by AppDelegate
    var onQuit: (() -> Void)?
    var onToggleTranscribe: (() -> Void)?
    var onCopyGit: (() -> Void)?
    var onToggleDarkMode: (() -> Void)?
    var onMonitor: (() -> Void)?
    var onKillPort: ((Int) -> Void)?
    var onKillPortPrompt: (() -> Void)?
    var onTakeScreenshot: (() -> Void)?
    var onDisplayJoinLink: (() -> Void)?
    var onDisplayClipboardLink: (() -> Void)?
    var onConnectTablet: (() -> Void)?
    var onOpenCatalog: (() -> Void)?
    var onDesktopEffect: ((String) -> Void)?
    var onTileTerminals: (() -> Void)?

    private var portHistoryURL: URL { PortKiller.portsFileURL }

    func setup() {
        loadPortHistory()
        buildMenu()
        setupStatusItem()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        if let url = Bundle.module.url(forResource: "icon_chat", withExtension: "png"),
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
        let killItem = NSMenuItem(title: "☠️ Kill…", action: nil, keyEquivalent: "")
        killItem.isEnabled = true
        killSubmenu = NSMenu()
        killItem.submenu = killSubmenu
        menu.addItem(killItem)

        // Copy Git
        addItem("🌳 Copy Git from IntelliJ", action: #selector(copyGitAction))

        menu.addItem(.separator())

        // Resume item
        resumeItem = addItem("Resumed -", action: nil)
        resumeItem.isEnabled = false
        // Transcribe toggle
        transcribeItem = addItem("Start Transcribing", action: #selector(toggleTranscribe))
        transcribeItem.keyEquivalent = "t"
        transcribeItem.keyEquivalentModifierMask = [.command, .control]

        // Tail (was Monitor)
        addItem("🐕 Tail", action: #selector(monitorAction))

        // Screenshot — clickable
        let screenshotItem = addItem("📸 Screenshot", action: #selector(takeScreenshotAction))
        screenshotItem.keyEquivalent = "p"
        screenshotItem.keyEquivalentModifierMask = .control

        menu.addItem(.separator())

        // WS status / join link — single unified item (state applied by refreshWsItem below)
        wsStatusItem = addItem("", action: nil)
        addItem("🔳 Display clipboard link", action: #selector(displayClipboardLinkAction))

        menu.addItem(.separator())

        addItem("🔌 Connect Tablet / USB-c", action: #selector(connectTabletAction))

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
            ("Gong 🔔",          "gong"),
            ("Drum Roll 🥁",     "drum-roll"),
            ("Laugh 🤣",          "laugh"),
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
        let extraItem = NSMenuItem(title: "Extra", action: nil, keyEquivalent: "")
        extraItem.isEnabled = true
        let extraSubmenu = NSMenu()
        extraItem.submenu = extraSubmenu

        // Paste Emotions (disabled — shortcut reminder)
        let pasteItem = NSMenuItem(title: "Paste Emotions", action: nil, keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = [.command, .control]
        pasteItem.isEnabled = false
        extraSubmenu.addItem(pasteItem)

        // Dark Mode (⌘⌃⌥D)
        darkModeItem = NSMenuItem(title: "Dark Mode", action: #selector(toggleDarkModeAction), keyEquivalent: "d")
        darkModeItem.keyEquivalentModifierMask = [.command, .control, .option]
        darkModeItem.target = self
        darkModeItem.isEnabled = true
        extraSubmenu.addItem(darkModeItem)

        // Catalog (⌘⌃C)
        let catalogItem = NSMenuItem(title: "Catalog", action: #selector(openCatalogAction), keyEquivalent: "c")
        catalogItem.keyEquivalentModifierMask = [.command, .control]
        catalogItem.target = self
        catalogItem.isEnabled = true
        extraSubmenu.addItem(catalogItem)

        // Tile Terminals (⌘⌃A)
        let tileItem = NSMenuItem(title: "Tile Terminals", action: #selector(tileTerminalsAction), keyEquivalent: "a")
        tileItem.keyEquivalentModifierMask = [.command, .control]
        tileItem.target = self
        tileItem.isEnabled = true
        extraSubmenu.addItem(tileItem)

        // Flattened Dream entries
        let dreamEntries: [(String, Selector)] = [
            ("🎅 training-assistant", #selector(openDreamTrainingAssistant)),
            ("🎅 macos-addons",       #selector(openDreamMacOSAddons)),
            ("🎅 workspace",          #selector(openDreamWorkspace)),
        ]
        for (title, sel) in dreamEntries {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            extraSubmenu.addItem(item)
        }

        menu.addItem(extraItem)

        // Quit (build timestamp inlined to save a menu line)
        let quitItem = addItem("⏻ Quit – " + MenuBarManager.BUILD_TIME, action: #selector(quitApp))
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
        portRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshPortItems()
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

        refreshPortItems()

        if let endedAt = breakEndedAt {
            let elapsed = Int(Date().timeIntervalSince(endedAt))
            resumeItem.title = elapsed < 3 * 3600 ? RHTimerMonitor.formatElapsed(elapsed) : "Resumed -"
        } else {
            resumeItem.title = "Resumed -"
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

    @objc private func copyGitAction() {
        onCopyGit?()
    }

    @objc private func openCatalogAction() {
        onOpenCatalog?()
    }

    @objc private func toggleTranscribe() {
        onToggleTranscribe?()
    }

    @objc private func monitorAction() {
        onMonitor?()
    }

    @objc private func toggleDarkModeAction() {
        onToggleDarkMode?()
    }

    @objc private func takeScreenshotAction() {
        onTakeScreenshot?()
    }

    @objc private func displayJoinLinkAction() {
        onDisplayJoinLink?()
    }

    @objc private func connectTabletAction() {
        onConnectTablet?()
    }

    @objc private func desktopEffectAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        onDesktopEffect?(name)
    }

    @objc private func tileTerminalsAction() {
        onTileTerminals?()
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

    func openClaudeCodeTerminal() {
        let script = """
        tell application "Terminal"
            do script "~/.claude/local/claude"
            activate
        end tell
        """
        DispatchQueue.global().async { AppleScriptRunner.run(script, timeout: 10) }
    }

    @objc private func openDreamWorkspace() {
        openDreamClaude(directory: "~/workspace/ai", sessionName: "workspace", quarter: .topLeft)
    }

    private enum ScreenQuarter { case topLeft, topRight, bottomLeft, bottomRight }

    private func openDreamClaude(directory: String, sessionName: String, quarter: ScreenQuarter) {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let (l, t, r, b) = appleScriptBounds(screen: screen, quarter: quarter)

        let tmpPath = "/tmp/dream_\(sessionName).sh"
        let shContent = "#!/bin/bash\ncd \(directory) && ~/.claude/local/claude '/rename \(sessionName)'\n"
        try? shContent.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpPath)

        let script = """
        do shell script "open -a Terminal \(tmpPath)"
        delay 0.5
        tell application "Terminal"
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

    private func killPort(_ port: Int) {
        onKillPort?(port)
        addToPortHistory(port)
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
            wsStatusItem.title = "🟢 Display Join Link"
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
        let originalImage = button.image
        button.image = nil
        button.title = "📷"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            button.title = ""
            button.image = originalImage
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
            button.image = makeEmojiIcon("⏸️", badge: badge)
        } else if !isTranscribing {
            button.image = makeEmojiIcon("⏹️", badge: badge)
        } else if isTranscriptionStale {
            button.image = makeEmojiIcon("🤐", badge: badge)
        } else if !transcribeSource.isEmpty, let icon = makeEmojiIcon(transcribeSource, badge: badge) {
            button.image = icon
        } else {
            button.image = makeChatBubbleIcon(badge: badge)
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
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16)]
        let str = emoji as NSString
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
        guard let url = Bundle.module.url(forResource: "icon_chat", withExtension: "png"),
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
        if isTranscriptionPausedByBattery {
            transcribeItem.title = "Off - On Battery"
            transcribeItem.isEnabled = false
        } else {
            let prefix = transcribeSource.isEmpty ? "" : "\(transcribeSource) "
            transcribeItem.title = isTranscribing ? "\(prefix)Stop Transcribing" : "Start Transcribing"
            transcribeItem.isEnabled = true
        }
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
            source: transcribeSource,
            menuTitle: transcribeItem.title,
            iconMode: iconMode
        )
    }

    func addToPortHistory(_ port: Int) {
        portHistory.removeAll { $0 == port }
        portHistory.insert(port, at: 0)
        if portHistory.count > 5 { portHistory = Array(portHistory.prefix(5)) }
        let text = portHistory.map { String($0) }.joined(separator: "\n")
        try? text.write(toFile: "/Users/victorrentea/workspace/victor-macos-addons/ports-to-kill.txt",
                        atomically: true, encoding: .utf8)
    }

    // MARK: - Port History Persistence

    private func loadPortHistory() {
        portHistory = PortKiller.loadHistory(from: portHistoryURL)
    }
}
