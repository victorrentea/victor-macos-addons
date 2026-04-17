import AppKit
import Foundation

class MenuBarManager: NSObject, NSMenuDelegate {
    static let BUILD_TIME = "Apr 18, 01:47"

    struct TranscriptionDebugState {
        let isTranscribing: Bool
        let isStale: Bool
        let source: String
        let menuTitle: String
        let iconMode: String
    }

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private(set) var kill8080Item: NSMenuItem!
    private(set) var darkModeItem: NSMenuItem!
    private(set) var transcribeItem: NSMenuItem!
    private(set) var wsStatusItem: NSMenuItem!
    private var killSubmenu: NSMenu!
    private var portHistory: [Int] = []
    private var portItems: [Int: NSMenuItem] = [:]

    private var portRefreshTimer: Timer?
    private var isTranscribing: Bool = false
    private var isTranscriptionStale: Bool = false
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

        // Kill :8080
        kill8080Item = addItem("Kill :8080", action: #selector(killPort8080))
        kill8080Item.isEnabled = false

        // Kill… submenu
        let killItem = NSMenuItem(title: "Kill…", action: nil, keyEquivalent: "")
        killItem.isEnabled = true
        killSubmenu = NSMenu()
        killItem.submenu = killSubmenu
        menu.addItem(killItem)

        // Copy Git
        addItem("Copy Git", action: #selector(copyGitAction))

        // Open Catalog
        let catalogItem = addItem("Catalog", action: #selector(openCatalogAction))
        catalogItem.keyEquivalent = "c"
        catalogItem.keyEquivalentModifierMask = [.command, .control]

        // Dark mode (moved up)
        darkModeItem = addItem("Dark Mode", action: #selector(toggleDarkModeAction))
        darkModeItem.keyEquivalent = "d"
        darkModeItem.keyEquivalentModifierMask = [.command, .control, .option]

        menu.addItem(.separator())

        // Resume item
        resumeItem = addItem("Resumed -", action: nil)
        resumeItem.isEnabled = false
        // Transcribe toggle
        transcribeItem = addItem("Start Transcribing", action: #selector(toggleTranscribe))

        // Tail (was Monitor)
        addItem("Tail", action: #selector(monitorAction))

        // Screenshot — clickable
        let screenshotItem = addItem("Screenshot", action: #selector(takeScreenshotAction))
        screenshotItem.keyEquivalent = "p"
        screenshotItem.keyEquivalentModifierMask = .control

        menu.addItem(.separator())

        // WS status / join link — single unified item (state applied by refreshWsItem below)
        wsStatusItem = addItem("", action: nil)
        addItem("Display clipboard link", action: #selector(displayClipboardLinkAction))

        menu.addItem(.separator())

        addItem("🔌 Tablet via USB-C", action: #selector(connectTabletAction))

        // Desktop Effects submenu
        let effectsItem = NSMenuItem(title: "Desktop Effects", action: nil, keyEquivalent: "")
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
            ("Brother 🤝",       "brother"),
        ]
        for (title, name) in effectPairs {
            let item = NSMenuItem(title: title, action: #selector(desktopEffectAction(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.representedObject = name
            effectsSubmenu.addItem(item)
        }
        menu.addItem(effectsItem)

        // Dream submenu
        let dreamItem = NSMenuItem(title: "Dream", action: nil, keyEquivalent: "")
        dreamItem.isEnabled = true
        let dreamSubmenu = NSMenu()
        dreamItem.submenu = dreamSubmenu
        let dreamEntries: [(String, Selector)] = [
            ("Training assistant", #selector(openDreamTrainingAssistant)),
            ("Mac OS Add-ons",     #selector(openDreamMacOSAddons)),
            ("Workspace",          #selector(openDreamWorkspace)),
        ]
        for (title, sel) in dreamEntries {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            dreamSubmenu.addItem(item)
        }
        menu.addItem(dreamItem)

        // Shortcut reminders (disabled)
        let pasteItem = addItem("Paste Emotions", action: nil)
        pasteItem.isEnabled = false
        pasteItem.keyEquivalent = "v"
        pasteItem.keyEquivalentModifierMask = [.command, .control]

        // Build timestamp
        let buildItem = addItem("Built at " + MenuBarManager.BUILD_TIME, action: nil)
        buildItem.isEnabled = false

        // Quit
        let quitItem = addItem("Quit", action: #selector(quitApp))
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

        for port in portHistory {
            let item = NSMenuItem(title: ":\(port)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            killSubmenu.addItem(item)
            portItems[port] = item
        }

        killSubmenu.addItem(.separator())
        let portItem = NSMenuItem(title: "Port…", action: #selector(killPortPrompt), keyEquivalent: "")
        portItem.target = self
        killSubmenu.addItem(portItem)

        kill8080Item.title = "Kill :8080"
        kill8080Item.isEnabled = false
        kill8080Item.action = nil

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
                    if port == 8080 {
                        if let proc = proc {
                            self.kill8080Item.title = "Kill :8080 \(proc)"
                            self.kill8080Item.isEnabled = true
                            self.kill8080Item.action = #selector(self.killPort8080)
                        } else {
                            self.kill8080Item.title = "Kill :8080"
                            self.kill8080Item.isEnabled = false
                        }
                    } else {
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

    @objc private func killPort8080() {
        killPort(8080)
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

    @objc private func openDreamMacOSAddons() {
        openDreamClaude(directory: "~/workspace/victor-macos-addons", sessionName: "macos-addons", quarter: .bottomRight)
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
    }

    func setJoinLinkEnabled(_ enabled: Bool) {
        sessionActive = enabled
        refreshWsItem()
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

    private func refreshMenuIcon() {
        guard let button = statusItem.button else { return }
        if !isTranscribing {
            if let url = Bundle.module.url(forResource: "icon_chat_off", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                image.isTemplate = false
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            }
        } else if isTranscriptionStale {
            button.image = makeWarnIcon()
        } else {
            if let url = Bundle.module.url(forResource: "icon_chat", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            }
        }
    }

    private func makeWarnIcon() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "icon_chat", withExtension: "png"),
              let base = NSImage(contentsOf: url) else { return nil }
        let size = NSSize(width: 18, height: 18)
        let composite = NSImage(size: size)
        composite.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9)]
        let emoji = "⚠️" as NSString
        let strSize = emoji.size(withAttributes: attrs)
        emoji.draw(at: NSPoint(x: size.width - strSize.width, y: 0), withAttributes: attrs)
        composite.unlockFocus()
        return composite
    }

    func setTranscribeSource(_ emoji: String) {
        transcribeSource = emoji
        updateTranscribeTitle()
    }

    private func updateTranscribeTitle() {
        let suffix = transcribeSource.isEmpty ? "" : " \(transcribeSource)"
        transcribeItem.title = isTranscribing ? "Stop Transcribing\(suffix)" : "Start Transcribing"
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
