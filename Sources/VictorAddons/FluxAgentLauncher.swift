import Foundation

/// Opens a foreground Terminal window running `flux-agent.sh` — an unattended
/// `claude -p` over an email thread from Victor, which mails its answer back as
/// a reply in that thread.
///
/// Mirrors `BreakSummaryLauncher`'s sentinel handshake: the script writes a
/// unique SENTINEL file when it truly finishes and the AppleScript waiter blocks
/// on THAT — Terminal's `busy` flag is unreliable for `do script` tabs, and
/// closing early would SIGHUP claude mid-run.
///
/// Unlike the break summary, the window closes on **any** verdict, success or
/// failure: this runs unattended and must not leave windows piling up. Failures
/// stay diagnosable through the per-day log, and `flux-agent.sh` holds a failed
/// window open ~25s first so a glance still catches it.
///
/// ## Never two agents for one email
///
/// Three independent layers, because a duplicate run means claude doing the same
/// work twice and mailing two answers:
///
/// 1. **The `unread` label is the claim token.** `FluxInboxPoller` only accepts
///    unread mail and marks it read *before* calling here, failing closed if the
///    mark fails. This is the only layer that survives an app reinstall or a
///    wiped watermark, since the state lives server-side.
/// 2. **`inFlight`** here — an in-process set of message ids, so a second call
///    within one app run is a no-op even if the mark-read round trip is slow.
/// 3. **An atomic `mkdir` lock** inside `flux-agent.sh`, keyed by message id.
enum FluxAgentLauncher {
    private static let lock = NSLock()
    private static var inFlight = Set<String>()

    /// Launch the agent for one message. Safe to call twice — the second call
    /// for the same message id is dropped.
    static func launch(messageId: String, threadId: String, subject: String) {
        lock.lock()
        let alreadyRunning = inFlight.contains(messageId)
        if !alreadyRunning { inFlight.insert(messageId) }
        lock.unlock()

        guard !alreadyRunning else {
            overlayInfo("flux-agent: already running for this email — skipping")
            return
        }
        guard let script = findScript() else {
            overlayError("flux-agent: flux-agent.sh not found — skipping")
            release(messageId)
            return
        }
        overlayInfo("flux-agent: launching claude for \"\(subject)\"")
        launchTerminal(script: script, messageId: messageId, threadId: threadId)
    }

    /// Forget a message id once its run has certainly ended, so a later manual
    /// retry is possible. Called on launch failure and by the sentinel waiter.
    private static func release(_ messageId: String) {
        lock.lock()
        inFlight.remove(messageId)
        lock.unlock()
    }

    /// Resolve the script next to the source tree — same strategy as
    /// `BreakSummaryLauncher.findScript`.
    private static func findScript() -> String? {
        let binaryDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        let envRoot = ProcessInfo.processInfo.environment["VICTOR_ADDONS_ROOT"] ?? ""
        let home = NSHomeDirectory()
        let cwd = FileManager.default.currentDirectoryPath
        var candidates = [
            "\(binaryDir)/../../../flux-agent.sh",
            "\(binaryDir)/flux-agent.sh",
        ]
        if !envRoot.isEmpty { candidates.append("\(envRoot)/flux-agent.sh") }
        candidates.append("\(home)/workspace/victor-macos-addons/flux-agent.sh")
        candidates.append("\(cwd)/flux-agent.sh")
        for c in candidates {
            let resolved = URL(fileURLWithPath: c).standardized.path
            if FileManager.default.fileExists(atPath: resolved) { return resolved }
        }
        return nil
    }

    /// Open a NEW foreground Terminal window and auto-close it only on success.
    ///
    /// The message/thread ids are AgentMail identifiers (a Message-ID and a
    /// UUID), and they are single-quoted into the `do script` line, so they are
    /// escaped defensively even though no email *body* text goes near the shell.
    private static func launchTerminal(script: String, messageId: String, threadId: String) {
        let sentinel = "/tmp/flux-agent-\(Int(Date().timeIntervalSince1970)).done"
        let osa = """
        set sentinel to "\(sentinel)"
        do shell script "rm -f " & quoted form of sentinel
        set verdict to ""
        tell application "Terminal"
            activate
            set t to do script "bash '\(script)' '\(sentinel)' '\(shellEscape(messageId))' '\(shellEscape(threadId))'"
        end tell
        -- Wait up to ~60 min: this agent may do real work, not just a summary.
        repeat 1800 times
            delay 2
            try
                set verdict to (do shell script "cat " & quoted form of sentinel & " 2>/dev/null")
            end try
            if verdict is not "" then exit repeat
        end repeat
        -- Close on ANY verdict: the agent is done either way, and flux-agent.sh
        -- already paused long enough for a failure to be readable. Everything is
        -- in the per-day log, so an unattended run never leaves a window behind.
        if verdict is not "" then
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
        p.terminationHandler = { _ in release(messageId) }
        do {
            try p.run()  // fire-and-forget: survives an app redeploy
        } catch {
            overlayError("flux-agent: failed to launch Terminal — \(error.localizedDescription)")
            release(messageId)
        }
    }

    /// Neutralise single quotes for a single-quoted shell word.
    private static func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }
}
