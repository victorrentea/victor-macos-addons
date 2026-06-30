import Foundation

/// Fires the incremental training-summary delta on demand (manual trigger only).
///
/// A coffee break is the "a section just ended, I have slack now" signal, and this
/// amortizes the expensive transcript read across the day: it opens a self-closing
/// Terminal window running `summarize-on-break.sh`, which runs an unattended
/// `claude` that appends the new section(s) to Discussion.md ONLY. By wrap-up
/// Discussion.md is ~complete, so the manual summary run is a tiny delta + a cheap
/// distill instead of reading the whole day at once.
///
/// Note: this used to auto-fire whenever a >= 5 min break started; that hook was
/// removed, so the only entry point now is `launchNow` (the /test/break-summary
/// HTTP hook).
enum BreakSummaryLauncher {
    /// Force a delta run NOW. Backs the `/test/break-summary` hook so the run can
    /// be triggered on the live app without clicking the ☕️ menu.
    static func launchNow(reason: String) {
        guard let script = findScript() else {
            overlayError("break-summary: summarize-on-break.sh not found — skipping")
            return
        }
        launchTerminal(script: script)
        overlayInfo("break-summary: \(reason) — launched delta run (\(script))")
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

    /// Open a NEW Terminal window running the script, and auto-close it ONLY when
    /// the run succeeded.
    ///
    /// We do NOT poll Terminal's `busy` flag anymore: for a `do script` tab it
    /// reads false during the command's startup, so the old `repeat while busy …
    /// close` loop fell straight through and closed the window ~1s in — SIGHUP-
    /// killing claude before it wrote anything (the 2026-06-30 "terminal
    /// immediately exited" bug). Instead the script writes a unique SENTINEL file
    /// with "ok"/"fail" when it truly finishes, and we wait on THAT. On "ok" we
    /// close the window; on "fail" (or timeout) we leave it open so the failure is
    /// readable. Fired detached (no waitUntilExit) so it survives an app redeploy.
    private static func launchTerminal(script: String) {
        let sentinel = "/tmp/break-summary-\(Int(Date().timeIntervalSince1970)).done"
        let osa = """
        set sentinel to "\(sentinel)"
        do shell script "rm -f " & quoted form of sentinel
        set verdict to ""
        tell application "Terminal"
            activate
            set t to do script "bash '\(script)' '\(sentinel)'"
        end tell
        -- Wait up to ~30 min for the script to report its verdict.
        repeat 900 times
            delay 2
            try
                set verdict to (do shell script "cat " & quoted form of sentinel & " 2>/dev/null")
            end try
            if verdict is not "" then exit repeat
        end repeat
        -- Auto-close only on success; leave failures (and timeouts) on screen.
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
