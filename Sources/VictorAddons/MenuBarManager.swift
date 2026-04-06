import AppKit
import Foundation

class MenuBarManager: NSObject, NSMenuDelegate {
    static let BUILD_TIME = "Apr 6, 21:52"

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private(set) var kill8080Item: NSMenuItem!
    private(set) var transcribeItem: NSMenuItem!
    private(set) var darkModeItem: NSMenuItem!
    private(set) var wsStatusItem: NSMenuItem!
    private var killSubmenu: NSMenu!
    private var portHistory: [Int] = []
    private var portItems: [Int: NSMenuItem] = [:]  // submenu items tracked for async update

    // Callbacks wired in by AppDelegate
    var onQuit: (() -> Void)?
    var onToggleTranscribe: (() -> Void)?
    var onCopyGit: (() -> Void)?
    var onShowLog: (() -> Void)?
    var onToggleDarkMode: (() -> Void)?
    var onMonitor: (() -> Void)?
    var onKillPort: ((Int) -> Void)?
    var onKillPortPrompt: (() -> Void)?
    var onTakeScreenshot: (() -> Void)?

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
        kill8080Item.isEnabled = false // refreshed in menuNeedsUpdate

        // Kill… submenu
        let killItem = NSMenuItem(title: "Kill…", action: nil, keyEquivalent: "")
        killItem.isEnabled = true
        killSubmenu = NSMenu()
        // Port history items and "Port..." will be added in refreshDynamicItems
        killItem.submenu = killSubmenu
        menu.addItem(killItem)

        menu.addItem(.separator())

        // Transcribe toggle
        transcribeItem = addItem("Start Transcribing", action: #selector(toggleTranscribe))

        // Monitor
        addItem("Monitor", action: #selector(monitorAction))

        menu.addItem(.separator())

        // Copy Git
        addItem("Copy Git", action: #selector(copyGitAction))

        // Log
        addItem("Log", action: #selector(showLogAction))

        // Screenshot
        addItem("Take Screenshot", action: #selector(takeScreenshotAction))

        menu.addItem(.separator())

        // Shortcut reminders (disabled)
        let pasteItem = addItem("Paste Emotions — ⌘⌃V", action: nil)
        pasteItem.isEnabled = false

        darkModeItem = addItem("Enter Dark Mode — ⌘⌃⌥D", action: #selector(toggleDarkModeAction))

        let rePasteItem = addItem("Re-paste — Wheel x 2", action: nil)
        rePasteItem.isEnabled = false

        let screenshotItem = addItem("Screenshot — ⌃P", action: nil)
        screenshotItem.isEnabled = false

        // WS status
        wsStatusItem = addItem("🔴 WS: not connected", action: nil)
        wsStatusItem.isEnabled = false

        menu.addItem(.separator())

        // Build timestamp
        let buildItem = addItem("Built at " + MenuBarManager.BUILD_TIME, action: nil)
        buildItem.isEnabled = false

        // Quit
        addItem("Quit", action: #selector(quitApp))
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshDynamicItems()
    }

    private func refreshDynamicItems() {
        loadPortHistory()
        // Rebuild submenu with "?" placeholders (fast, on main thread)
        killSubmenu.removeAllItems()
        portItems = [:]

        // Add port history items first
        for port in portHistory {
            let item = NSMenuItem(title: ":\(port) ?", action: nil, keyEquivalent: "")
            item.isEnabled = false
            killSubmenu.addItem(item)
            portItems[port] = item
        }

        // Add "Port..." at the end
        let portItem = NSMenuItem(title: "Port…", action: #selector(killPortPrompt), keyEquivalent: "")
        portItem.target = self
        killSubmenu.addItem(portItem)

        kill8080Item.title = "Kill :8080 ?"
        kill8080Item.isEnabled = false
        kill8080Item.action = nil

        // Dark mode (cheap — no lsof)
        let isDark = DarkModeToggle.isDark()
        darkModeItem.title = (isDark ? "Exit Dark Mode" : "Enter Dark Mode") + " — ⌘⌃⌥D"

        // Check each port in background, update item when done
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

    @objc private func toggleTranscribe() {
        onToggleTranscribe?()
    }

    @objc private func monitorAction() {
        onMonitor?()
    }

    @objc private func copyGitAction() {
        onCopyGit?()
    }

    @objc private func showLogAction() {
        onShowLog?()
    }

    @objc private func toggleDarkModeAction() {
        onToggleDarkMode?()
    }

    @objc private func takeScreenshotAction() {
        onTakeScreenshot?()
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
        wsStatusItem.title = connected ? "🟢 WS: connected" : "🔴 WS: not connected"
    }

    func setTranscribing(_ active: Bool) {
        transcribeItem.title = active ? "Stop Transcribing" : "Start Transcribing"

        // Update menu bar icon
        guard let button = statusItem.button else { return }
        let iconName = active ? "icon_chat" : "icon_chat_off"
        if let url = Bundle.module.url(forResource: iconName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            // Use template mode for active icon (monochrome), but not for stopped icon (preserve red line)
            image.isTemplate = active
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        }
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
