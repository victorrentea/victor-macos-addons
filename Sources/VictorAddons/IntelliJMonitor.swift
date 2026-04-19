import Foundation

private let ijScript = """
tell application "System Events" to tell process "idea" to return (frontmost as string) & tab & (title of front window)
"""

class IntelliJMonitor {
    private let outputDir: URL
    private var timer: Timer?
    private var lastLine: String?
    private var pendingKey: String?  // project+file seen on previous tick

    var onGitFileOpened: ((String, String, String, String?) -> Void)?

    init(outputDir: URL) {
        self.outputDir = outputDir
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                DispatchQueue.global(qos: .utility).async { self?.tick() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let raw = AppleScriptRunner.run(ijScript, timeout: 2.0) else { return }

        let parts = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map { String($0) }
        guard parts.count >= 2 else { return }

        let isFrontmost = parts[0].trimmingCharacters(in: .whitespaces) == "true"
        let title = parts[1].trimmingCharacters(in: .whitespaces)

        guard isFrontmost, !title.isEmpty else { return }

        // Parse window title: "kafka – WordsTopology.java [kafka-streams]"
        // U+2013 is en-dash, U+2009 is thin space
        // Split on " – " or "\u{2009}\u{2013}\u{2009}"
        let projectName: String
        let filename: String

        // Try thin-space em-dash separator first, then regular space em-dash
        let separators = ["\u{2009}\u{2013}\u{2009}", " \u{2013} "]
        var foundSeparator: String? = nil
        for sep in separators {
            if title.contains(sep) {
                foundSeparator = sep
                break
            }
        }

        if let sep = foundSeparator {
            let titleParts = title.components(separatedBy: sep)
            // Project name is before the separator, strip any "[module]" suffix
            projectName = titleParts[0]
                .components(separatedBy: "[")[0]
                .trimmingCharacters(in: .whitespaces)
            // Filename is the part after the separator, before " ["
            let afterDash = titleParts[1]
            filename = afterDash
                .components(separatedBy: " [")[0]
                .trimmingCharacters(in: .whitespaces)
        } else {
            // No separator: whole title (minus any bracket suffix) is project name
            projectName = title
                .components(separatedBy: "[")[0]
                .trimmingCharacters(in: .whitespaces)
            filename = ""
        }

        guard !projectName.isEmpty else { return }

        // Require the same project+file on two consecutive polls before doing git work
        let currentKey = "\(projectName)\t\(filename)"
        let stable = currentKey == pendingKey
        pendingKey = currentKey
        guard stable else { return }

        // Find project path from recentProjects.xml
        guard let projectPath = lookupProjectPath(projectName) else { return }

        // Get git info
        let remoteURL = git(["remote", "get-url", "origin"], at: projectPath)
        let branch = git(["branch", "--show-current"], at: projectPath)

        guard !remoteURL.isEmpty else { return }

        let resolvedBranch = branch.isEmpty ? "unknown" : branch
        let resolvedFile = filename.isEmpty ? "(none)" : filename

        // Resolve full file URL if filename is known
        let fileURL: String? = filename.isEmpty ? nil : resolveFileURL(
            remoteURL: remoteURL, branch: resolvedBranch,
            projectPath: projectPath, filename: filename
        )

        // Build line content (without timestamp for dedup)
        var content = "\(remoteURL) branch:\(resolvedBranch) file:\(resolvedFile)"
        if let fileURL { content += " fileURL:\(fileURL)" }

        // Skip duplicate
        if content == lastLine { return }
        lastLine = content

        // Send via addon WS bridge instead of writing to file
        onGitFileOpened?(remoteURL, resolvedBranch, resolvedFile, fileURL)
    }

    private func git(_ args: [String], at path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let deadline = Date(timeIntervalSinceNow: 2.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return ""
        }
        guard process.terminationStatus == 0 else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func resolveFileURL(remoteURL: String, branch: String, projectPath: String, filename: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", projectPath, "ls-files"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date(timeIntervalSinceNow: 2.0)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let matches = output.split(separator: "\n").map(String.init).filter { $0.hasSuffix("/\(filename)") || $0 == filename }
        guard matches.count == 1 else { return nil }
        let relativePath = matches[0]

        // Convert SSH remote to HTTPS
        var httpsURL = remoteURL
        if httpsURL.hasPrefix("git@") {
            httpsURL = httpsURL.replacingOccurrences(of: ":", with: "/")
                .replacingOccurrences(of: "git@", with: "https://")
        }
        httpsURL = httpsURL.replacingOccurrences(of: "\\.git$", with: "", options: .regularExpression)

        return "\(httpsURL)/blob/\(branch)/\(relativePath)"
    }

    private func lookupProjectPath(_ projectName: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let supportDir = (home as NSString).appendingPathComponent("Library/Application Support/JetBrains")

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: supportDir) else {
            return nil
        }

        // Find all IntelliJIdea* directories, sorted descending (most recent version first)
        let ijDirs = entries
            .filter { $0.hasPrefix("IntelliJIdea") }
            .sorted(by: >)
            .map { (supportDir as NSString).appendingPathComponent($0) }

        for ijDir in ijDirs {
            let xmlPath = (ijDir as NSString).appendingPathComponent("options/recentProjects.xml")
            guard FileManager.default.fileExists(atPath: xmlPath),
                  let data = FileManager.default.contents(atPath: xmlPath) else {
                continue
            }

            if let result = parseRecentProjects(data: data, projectName: projectName, home: home) {
                return result
            }
        }
        return nil
    }

    private func parseRecentProjects(data: Data, projectName: String, home: String) -> String? {
        let parser = RecentProjectsParser(projectName: projectName, home: home)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.bestPath
    }
}

// MARK: - XMLParser delegate for recentProjects.xml

private class RecentProjectsParser: NSObject, XMLParserDelegate {
    let projectName: String
    let home: String
    var bestPath: String? = nil
    var bestTimestamp: Int64 = -1

    // State
    private var currentEntryKey: String? = nil
    private var insideRecentProjectMetaInfo = false
    private var currentTimestamp: Int64 = 0

    init(projectName: String, home: String) {
        self.projectName = projectName
        self.home = home
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if elementName == "entry" {
            currentEntryKey = attributes["key"]
            insideRecentProjectMetaInfo = false
            currentTimestamp = 0
        } else if elementName == "RecentProjectMetaInfo" {
            insideRecentProjectMetaInfo = true
        } else if elementName == "option" && insideRecentProjectMetaInfo {
            if attributes["name"] == "activationTimestamp",
               let val = attributes["value"],
               let ts = Int64(val) {
                currentTimestamp = ts
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "entry" {
            guard let key = currentEntryKey else { return }
            let expandedPath = key.replacingOccurrences(of: "$USER_HOME$", with: home)
            let folderName = (expandedPath as NSString).lastPathComponent
            if folderName.lowercased() == projectName.lowercased() {
                if currentTimestamp > bestTimestamp {
                    bestTimestamp = currentTimestamp
                    bestPath = expandedPath
                }
            }
            currentEntryKey = nil
            insideRecentProjectMetaInfo = false
        } else if elementName == "RecentProjectMetaInfo" {
            insideRecentProjectMetaInfo = false
        }
    }
}
