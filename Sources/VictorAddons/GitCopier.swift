import Foundation
import AppKit

enum GitCopier {
    /// Copies "<remote-url> (<branch>)" to the clipboard for the last-used
    /// IntelliJ project. Returns the bare remote URL so callers can also
    /// surface it in the on-screen banner.
    @discardableResult
    static func copyIntelliJGit() -> String? {
        guard let path = findLastUsedProjectPath() else {
            overlayInfo("No IntelliJ project found")
            return nil
        }
        let url = git(["-C", path, "remote", "get-url", "origin"])
        let branch = git(["-C", path, "branch", "--show-current"])
        guard !url.isEmpty else {
            overlayInfo("No git remote found")
            return nil
        }
        let text = branch.isEmpty ? url : "\(url) (\(branch))"
        DispatchQueue.main.async {
            ClipboardManager.write(text)
            notify(body: text)
        }
        return url
    }

    private static func notify(body: String) {
        let notification = NSUserNotification()
        notification.title = "Copied to clipboard"
        notification.informativeText = body
        NSUserNotificationCenter.default.deliver(notification)
    }

    private static func findLastUsedProjectPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let jetBrainsBase = home.appendingPathComponent("Library/Application Support/JetBrains").path
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: jetBrainsBase) else { return nil }
        let ideaDirs = dirs.filter { $0.hasPrefix("IntelliJIdea") }.sorted().reversed()
        var bestTs: Int64 = -1
        var bestPath: String? = nil
        for dir in ideaDirs {
            let xmlPath = "\(jetBrainsBase)/\(dir)/options/recentProjects.xml"
            guard let data = FileManager.default.contents(atPath: xmlPath),
                  let doc = try? XMLDocument(data: data, options: []) else { continue }
            let entries = (try? doc.nodes(forXPath: "//entry")) ?? []
            for entry in entries {
                guard let element = entry as? XMLElement,
                      let key = element.attribute(forName: "key")?.stringValue,
                      !key.isEmpty else { continue }
                let tsNodes = (try? element.nodes(forXPath: ".//option[@name='activationTimestamp']")) ?? []
                guard let tsNode = tsNodes.first as? XMLElement,
                      let tsStr = tsNode.attribute(forName: "value")?.stringValue,
                      let ts = Int64(tsStr) else { continue }
                if ts > bestTs {
                    bestTs = ts
                    bestPath = key.replacingOccurrences(of: "$USER_HOME$", with: home.path)
                }
            }
        }
        return bestPath
    }

    private static func git(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
