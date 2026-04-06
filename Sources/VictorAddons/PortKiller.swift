import AppKit
import Foundation

class PortKiller: NSObject {
    private let portHistoryURL: URL
    private(set) var history: [Int]

    override init() {
        portHistoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".victor-macos-addons-ports.json")
        history = PortKiller.loadHistory(from: portHistoryURL)
        super.init()
    }

    func kill(port: Int) {
        let result = runCommand("/usr/sbin/lsof", args: ["-ti", ":\(port)"])
        let pids = result.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !pids.isEmpty else {
            overlayInfo("No process on :\(port)")
            sendNotification(title: "Kill port", message: "No process on :\(port)")
            return
        }

        var killed: [String] = []
        for pid in pids {
            let name = processName(pid: pid)
            runCommandVoid("/bin/kill", args: ["-9", pid])
            killed.append("\(name) (pid \(pid))")
        }
        let summary = killed.joined(separator: ", ")
        overlayInfo("Killed :\(port) — \(summary)")
        sendNotification(title: "Killed :\(port)", message: summary)

        // Update history: move to top, unique, max 5
        history.removeAll { $0 == port }
        history.insert(port, at: 0)
        if history.count > 5 { history = Array(history.prefix(5)) }
        saveHistory()
    }

    func showPortPrompt() {
        DispatchQueue.main.async {
            self.showPortPromptPanel()
        }
    }

    // MARK: - Port Prompt Panel

    private func showPortPromptPanel() {
        guard let screen = NSScreen.main else { return }
        let W: CGFloat = 200, H: CGFloat = 36
        let x: CGFloat = 1100
        let y = screen.frame.height - 80 - H

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: W, height: H),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.level = .floating

        let field = NSTextField(frame: NSRect(x: 4, y: 4, width: 152, height: 28))
        field.placeholderString = "8080"
        field.font = NSFont.systemFont(ofSize: 16)
        panel.contentView?.addSubview(field)

        let btn = NSButton(frame: NSRect(x: 160, y: 4, width: 36, height: 28))
        btn.title = "☠️"
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 16)
        btn.keyEquivalent = "\r"
        btn.target = self
        btn.action = #selector(stopModalOK)
        panel.contentView?.addSubview(btn)

        panel.makeFirstResponder(field)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = NSApplication.shared.runModal(for: panel)
        panel.orderOut(nil)

        guard response == .OK else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let port = Int(text), port > 0 else {
            overlayInfo("Invalid port: \(text)")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.kill(port: port)
        }
    }

    @objc private func stopModalOK() {
        NSApplication.shared.stopModal(withCode: .OK)
    }

    // MARK: - Helpers

    @discardableResult
    private func runCommand(_ path: String, args: [String]) -> String {
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

    private func runCommandVoid(_ path: String, args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    private func processName(pid: String) -> String {
        let output = runCommand("/bin/ps", args: ["-p", pid, "-o", "comm="])
        let comm = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: comm).lastPathComponent
    }

    private func sendNotification(title: String, message: String) {
        AppleScriptRunner.run("display notification \"\(message)\" with title \"\(title)\"")
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: portHistoryURL)
    }

    private static func loadHistory(from url: URL) -> [Int] {
        guard let data = try? Data(contentsOf: url),
              let ports = try? JSONDecoder().decode([Int].self, from: data) else {
            return [8080]
        }
        return ports
    }
}
