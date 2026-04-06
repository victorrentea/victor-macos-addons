import AppKit
import Foundation

class MenuBarManager: NSObject, NSMenuDelegate {
    static let BUILD_TIME = "built"

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private(set) var kill8080Item: NSMenuItem!
    private(set) var transcribeItem: NSMenuItem!
    private(set) var darkModeItem: NSMenuItem!
    private(set) var wsStatusItem: NSMenuItem!
    private var killSubmenu: NSMenu!
    private var portHistory: [Int] = []

    // Callbacks wired in by AppDelegate
    var onQuit: (() -> Void)?
    var onToggleTranscribe: (() -> Void)?
    var onCopyGit: (() -> Void)?
    var onShowLog: (() -> Void)?
    var onToggleDarkMode: (() -> Void)?
    var onMonitor: (() -> Void)?
    var onKillPort: ((Int) -> Void)?
    var onKillPortPrompt: (() -> Void)?

    private var portHistoryURL: URL {
        PortKiller.portsFileURL
    }

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
        let portItem = NSMenuItem(title: "Port…", action: #selector(killPortPrompt), keyEquivalent: "")
        portItem.target = self
        killSubmenu.addItem(portItem)
        killSubmenu.addItem(.separator())
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
        wsStatusItem = addItem("WS 🔴", action: nil)
        wsStatusItem.isEnabled = false

        menu.addItem(.separator())

        // Build timestamp
        let buildItem = addItem(MenuBarManager.BUILD_TIME, action: nil)
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
        // Refresh kill submenu port history (remove dynamic items after separator)
        while killSubmenu.items.count > 2 {
            killSubmenu.removeItem(at: killSubmenu.items.count - 1)
        }
        for port in portHistory {
            let item = NSMenuItem(title: ":\(port)", action: #selector(killHistoricalPort(_:)), keyEquivalent: "")
            item.target = self
            item.tag = port
            item.isEnabled = true
            killSubmenu.addItem(item)
        }

        // Update kill8080 enabled state (simple check without live lsof)
        kill8080Item.isEnabled = portHistory.contains(8080)

        // Update dark mode item title
        let isDark = DarkModeToggle.isDark()
        darkModeItem.title = (isDark ? "Exit Dark Mode" : "Enter Dark Mode") + " — ⌘⌃⌥D"
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
        if !portHistory.contains(port) {
            portHistory.insert(port, at: 0)
            savePortHistory()
        }
    }

    // MARK: - Public API

    func updateWsStatus(_ connected: Bool) {
        wsStatusItem.title = connected ? "WS 🟢" : "WS 🔴"
    }

    func setTranscribing(_ active: Bool) {
        transcribeItem.title = active ? "Stop Transcribing" : "Start Transcribing"
    }

    // MARK: - Port History Persistence

    private func loadPortHistory() {
        guard let text = try? String(contentsOf: portHistoryURL, encoding: .utf8) else {
            return
        }
        portHistory = text
            .split(separator: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
    }

    private func savePortHistory() {
        let unique = Array(NSOrderedSet(array: portHistory).compactMap { $0 as? Int })
        let trimmed = Array(unique.prefix(20))
        portHistory = trimmed
        let content = trimmed.map(String.init).joined(separator: "\n")
        try? content.write(to: portHistoryURL, atomically: true, encoding: .utf8)
    }
}
