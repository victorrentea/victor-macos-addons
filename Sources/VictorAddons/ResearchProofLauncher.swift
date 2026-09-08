import Foundation

/// 🔬 **Research Proof** — "go find out whether what I just said is true."
///
/// Fires `research-proof.sh` in a self-closing Terminal: it waits for whisper to
/// catch up, cuts the last 10 minutes of speech out of today's transcript, and
/// runs an unattended `claude` that extracts the checkable claims, researches
/// each one, proves every quote with a literal substring search
/// (`verify-quote.py`), and renders the verdicts into a fixed HTML report.
///
/// Structurally this is `BreakSummaryLauncher` — the same sentinel handshake,
/// the same reason for it (a `do script` tab reads `busy = false` during
/// startup, so waiting on that flag SIGHUPs claude a second in). Two things are
/// different, and both come from the report being the *product* rather than a
/// side effect:
///
/// * **The report path is decided HERE and handed to the script**, so the
///   launcher knows exactly which file to watch for. The alternative — parsing
///   a path out of the sentinel — races the AppleScript, which deletes the
///   sentinel as it closes the window.
/// * **The launcher opens the report, not the script.** It lands on the
///   built-in Retina display, which is the screen the room is watching: Victor
///   asked for the result to be shown, not filed. `open`ing it from bash would
///   hand the URL to LaunchServices and could land it in a Playwright Chrome
///   signed into nothing (see `OfficialChrome`), on whichever screen that
///   window happened to be parked.
enum ResearchProofLauncher {

    /// Set by `AppDelegate` to `openUrlInChrome(url, target: .retina)`. Called on
    /// the main queue with a `file://` URL once the report exists.
    static var onReportReady: ((String) -> Void)?

    /// How long to keep watching for the report before giving up. Generous: a
    /// run is a claim-extraction pass plus two waves of subagents, and a slow
    /// one is still worth showing.
    private static let watchTimeout: TimeInterval = 30 * 60
    private static let pollInterval: TimeInterval = 1.5

    /// One run at a time. The script has its own pid lock (it must — the HTTP
    /// hook and the menu are separate entry points), but that guard makes the
    /// *second* run exit quietly, which would leave this side polling for a
    /// report that is never written. Refusing here keeps the two in step.
    private static let queue = DispatchQueue(label: "research-proof.launcher")
    private static var running = false

    /// Menu click and `GET /test/research-proof`.
    @discardableResult
    static func launchNow(reason: String) -> Bool {
        var alreadyRunning = false
        queue.sync {
            alreadyRunning = running
            running = true
        }
        guard !alreadyRunning else {
            overlayInfo("🔬 research-proof: already running — ignoring \(reason)")
            return false
        }

        guard let script = findScript() else {
            queue.sync { running = false }
            overlayError("🔬 research-proof: research-proof.sh not found — skipping")
            return false
        }

        let report = reportPath(nextTo: script)
        launchTerminal(script: script, report: report)
        watchForReport(at: report)
        overlayInfo("🔬 research-proof: \(reason) — checking the last 10 min (\(report))")
        return true
    }

    /// `addons-output/research-proof-<stamp>.html`, next to the transcripts and
    /// the run log. Second-resolution stamp: two runs a minute apart must not
    /// overwrite each other's page while the first is still on screen.
    private static func reportPath(nextTo script: String) -> String {
        let root = URL(fileURLWithPath: script).deletingLastPathComponent()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        return root.appendingPathComponent("addons-output")
            .appendingPathComponent("research-proof-\(fmt.string(from: Date())).html").path
    }

    /// Same resolution strategy as `BreakSummaryLauncher.findScript` (env root,
    /// binary-relative, canonical workspace path, cwd).
    private static func findScript() -> String? {
        let binaryDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        let envRoot = ProcessInfo.processInfo.environment["VICTOR_ADDONS_ROOT"] ?? ""
        let home = NSHomeDirectory()
        let cwd = FileManager.default.currentDirectoryPath
        var candidates = [
            "\(binaryDir)/../../../research-proof.sh",
            "\(binaryDir)/research-proof.sh",
        ]
        if !envRoot.isEmpty { candidates.append("\(envRoot)/research-proof.sh") }
        candidates.append("\(home)/workspace/victor-macos-addons/research-proof.sh")
        candidates.append("\(cwd)/research-proof.sh")
        for c in candidates {
            let resolved = URL(fileURLWithPath: c).standardized.path
            if FileManager.default.fileExists(atPath: resolved) { return resolved }
        }
        return nil
    }

    /// Open a Terminal window on the run and close it only when the script
    /// reports success. Verbatim the `BreakSummaryLauncher` handshake — see the
    /// comment there for why Terminal's `busy` flag cannot be used instead.
    private static func launchTerminal(script: String, report: String) {
        let sentinel = "/tmp/research-proof-\(Int(Date().timeIntervalSince1970)).done"
        let osa = """
        set sentinel to "\(sentinel)"
        do shell script "rm -f " & quoted form of sentinel
        set verdict to ""
        tell application "Terminal"
            activate
            set t to do script "bash '\(script)' '\(sentinel)' '\(report)'"
        end tell
        repeat 900 times
            delay 2
            try
                set verdict to (do shell script "cat " & quoted form of sentinel & " 2>/dev/null")
            end try
            if verdict is not "" then exit repeat
        end repeat
        if verdict is "ok" then
            delay 3
            try
                tell application "Terminal" to close (every window whose tabs contains t) saving no
            end try
        end if
        try
            do shell script "rm -f " & quoted form of sentinel
        end try
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", osa]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()          // fire-and-forget: survives an app redeploy
        } catch {
            queue.sync { running = false }
            overlayError("🔬 research-proof: failed to launch Terminal — \(error.localizedDescription)")
        }
    }

    /// Poll for the report and show it the moment it lands.
    ///
    /// Watching the FILE rather than the script's exit is what makes the failure
    /// pages work: `research-proof.sh` renders one for every way a run can end
    /// (no transcript, a silent 10 minutes, claude crashing, unparseable JSON),
    /// precisely so the click always produces something on screen. Whichever
    /// page it wrote, this opens it.
    private static func watchForReport(at path: String) {
        let deadline = Date().addingTimeInterval(watchTimeout)
        DispatchQueue.global(qos: .utility).async {
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: path) {
                    // The renderer writes in one `write_text`, but the file can
                    // still be seen mid-write on a slow disk; a beat costs
                    // nothing against a run measured in minutes.
                    Thread.sleep(forTimeInterval: 0.5)
                    let url = URL(fileURLWithPath: path).absoluteString
                    DispatchQueue.main.async {
                        queue.sync { running = false }
                        overlayInfo("🔬 research-proof: report ready — opening on the retina")
                        onReportReady?(url)
                    }
                    return
                }
                Thread.sleep(forTimeInterval: pollInterval)
            }
            DispatchQueue.main.async {
                queue.sync { running = false }
                overlayError("🔬 research-proof: no report after \(Int(watchTimeout / 60)) min — check addons-output/research-proof-*.log")
            }
        }
    }
}
