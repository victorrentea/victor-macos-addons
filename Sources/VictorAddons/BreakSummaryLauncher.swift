import Foundation

/// Fires the incremental training-summary delta when a >= 5 min ☕️ break starts.
///
/// A coffee break is the "a section just ended, I have slack now" signal, so we
/// use it to amortize the expensive transcript read across the day: each break
/// opens a self-closing Terminal window running `summarize-on-break.sh`, which
/// runs an unattended `claude` that appends the new section(s) to Discussion.md
/// ONLY. By wrap-up Discussion.md is ~complete, so the manual summary run is a
/// tiny delta + a cheap distill instead of reading the whole day at once.
enum BreakSummaryLauncher {
    /// Skip re-launching within this window — re-clicking a break duration just
    /// resets the timer in place, and we don't want a second Terminal window for it.
    private static let cooldown: TimeInterval = 90
    private static var lastLaunch: Date?

    /// Call from the break handler. No-op for sub-5-min breaks or within cooldown.
    static func launchIfDue(minutes: Int) {
        guard minutes >= 5 else { return }
        if let last = lastLaunch, Date().timeIntervalSince(last) < cooldown {
            overlayInfo("break-summary: within \(Int(cooldown))s cooldown — skipping relaunch")
            return
        }
        guard let script = findScript() else {
            overlayError("break-summary: summarize-on-break.sh not found — skipping")
            return
        }
        lastLaunch = Date()
        launchTerminal(script: script)
        overlayInfo("break-summary: launched delta run for \(minutes)-min break (\(script))")
    }

    /// Resolve the launcher script next to the source tree — same strategy as
    /// `WhisperProcessManager.whisperScriptCandidates` (env root, then the
    /// canonical workspace path, then cwd).
    private static func findScript() -> String? {
        let binaryDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        let envRoot = ProcessInfo.processInfo.environment["VICTOR_ADDONS_ROOT"] ?? ""
        let home = NSHomeDirectory()
        let cwd = FileManager.default.currentDirectoryPath
        var candidates = [
            "\(binaryDir)/../../../summarize-on-break.sh",
            "\(binaryDir)/summarize-on-break.sh",
        ]
        if !envRoot.isEmpty { candidates.append("\(envRoot)/summarize-on-break.sh") }
        candidates.append("\(home)/workspace/victor-macos-addons/summarize-on-break.sh")
        candidates.append("\(cwd)/summarize-on-break.sh")
        for c in candidates {
            let resolved = URL(fileURLWithPath: c).standardized.path
            if FileManager.default.fileExists(atPath: resolved) { return resolved }
        }
        return nil
    }

    /// Open a NEW Terminal window running the script, and auto-close it once the
    /// script finishes. The osascript polls `busy` itself, so we fire it
    /// detached (no waitUntilExit) — that means it also survives an app redeploy
    /// (Terminal is its own process tree).
    private static func launchTerminal(script: String) {
        let osa = """
        tell application "Terminal"
            activate
            set t to do script "bash '\(script)'"
            repeat while busy of t
                delay 1
            end repeat
            delay 2
            close (every window whose tabs contains t) saving no
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", osa]
        // Swallow output; this background helper just waits and closes the window.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            // Intentionally NOT waiting: fire-and-forget.
        } catch {
            overlayError("break-summary: failed to launch Terminal — \(error.localizedDescription)")
        }
    }
}
