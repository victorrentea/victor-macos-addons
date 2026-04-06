import AppKit
import Foundation

class PortKiller: NSObject {
    static let portsFileURL = URL(fileURLWithPath: "/Users/victorrentea/workspace/victor-macos-addons/ports-to-kill.txt")
    private let portHistoryURL: URL
    private(set) var history: [Int]

    override init() {
        portHistoryURL = Self.portsFileURL
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
            remember(port: port)
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

        remember(port: port)
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
        // Persist immediately when user confirms the dialog, even if kill later fails.
        remember(port: port)
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

    private func remember(port: Int) {
        // Merge with latest on-disk list to avoid overwriting newer entries.
        history = Self.loadHistory(from: portHistoryURL)
        history.removeAll { $0 == port }
        history.insert(port, at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
        saveHistory()
    }

    private func saveHistory() {
        let content = history.map(String.init).joined(separator: "\n")
        do {
            let dir = portHistoryURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: portHistoryURL, atomically: true, encoding: .utf8)
        } catch {
            overlayError("Failed saving ports file: \(error.localizedDescription)")
        }
    }

    private static func loadHistory(from url: URL) -> [Int] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [8080]
        }
        let ports = text
            .split(separator: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
        return ports.isEmpty ? [8080] : ports
    }
}
