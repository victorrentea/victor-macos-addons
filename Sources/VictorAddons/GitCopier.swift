import Foundation

enum GitCopier {
    static func copyIntelliJGit() {
        let script = "tell application \"System Events\" to tell process \"idea\" to return (frontmost as string) & tab & (title of front window)"
        guard let output = AppleScriptRunner.run(script) else {
            overlayInfo("IntelliJ not open")
            return
        }
        let parts = output.components(separatedBy: "\t")
        guard parts.count >= 2 else {
            overlayInfo("Could not parse IntelliJ window")
            return
        }
        let title = parts[1...].joined(separator: "\t")
        let projectName = parseProjectName(from: title)
        guard let projectPath = findProjectPath(name: projectName) else {
            overlayInfo("Could not find project: \(projectName)")
            return
        }
        let url = git(["-C", projectPath, "remote", "get-url", "origin"])
        let branch = git(["-C", projectPath, "branch", "--show-current"])
        guard !url.isEmpty else {
            overlayInfo("No git remote for \(projectName)")
            return
        }
        let text = branch.isEmpty ? url : "\(url) (\(branch))"
        DispatchQueue.main.async {
            ClipboardManager.write(text)
        }
        overlayInfo("Copied: \(text)")
    }

    private static func parseProjectName(from title: String) -> String {
        // Handle thin space (U+2009) + en-dash (U+2013) separator and similar
        let separators = ["\u{2009}\u{2013}\u{2009}", " \u{2013} ", " – ", " - "]
        for sep in separators {
            if title.contains(sep) {
                return title.components(separatedBy: sep).first?
                    .trimmingCharacters(in: .whitespaces) ?? title
            }
        }
        return title.components(separatedBy: "[").first?
            .trimmingCharacters(in: .whitespaces) ?? title
    }

    private static func findProjectPath(name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let jetBrainsBase = home.appendingPathComponent("Library/Application Support/JetBrains").path
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: jetBrainsBase) else { return nil }
        let ideaDirs = dirs.filter { $0.hasPrefix("IntelliJIdea") }.sorted().reversed()
        for dir in ideaDirs {
            let xmlPath = "\(jetBrainsBase)/\(dir)/options/recentProjects.xml"
            guard let data = FileManager.default.contents(atPath: xmlPath),
                  let xml = String(data: data, encoding: .utf8) else { continue }
            let lines = xml.components(separatedBy: "\n")
            for line in lines {
                if line.contains("key=") && line.contains(name) {
                    if let range = line.range(of: "key=\""),
                       let end = line[range.upperBound...].range(of: "\"") {
                        let rawPath = String(line[range.upperBound..<end.lowerBound])
                        let path = rawPath.replacingOccurrences(of: "$USER_HOME$", with: home.path)
                        if URL(fileURLWithPath: path).lastPathComponent.lowercased() == name.lowercased() {
                            return path
                        }
                    }
                }
            }
        }
        return nil
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
