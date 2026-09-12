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
/// The one exception is the `interactive` verdict: when Victor's mail asked for
/// an interactive session, the script mails its reply and then reopens the very
/// same claude session as a live terminal in that window. Closing it would kill
/// the conversation he asked for, so that verdict instead brings the window
/// forward and resizes it to something you can actually talk in
/// (`FluxAgentVerdict`).
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

    /// How many Terminal agents we have ever opened, for the 📬 menu item's
    /// rocket count. Persisted, because this app restarts several times a day
    /// (redeploys, replacements) and a counter that resets to 0 each time would
    /// answer "did any mail turn into work?" with a permanent "no".
    private static let launchedCountKey = "flux.agent.launched.count"

    static var launchedCount: Int {
        UserDefaults.standard.integer(forKey: launchedCountKey)
    }

    private static func recordLaunch() {
        UserDefaults.standard.set(launchedCount + 1, forKey: launchedCountKey)
    }

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
    /// The window is pushed onto an external screen (`TerminalWindowPlacement`):
    /// mail can land mid-workshop, and the built-in Retina is what the projector
    /// mirrors — an agent window opening there would appear on the wall in front
    /// of the room. With no external screen connected it stays wherever macOS
    /// puts it.
    ///
    /// The message/thread ids are AgentMail identifiers (a Message-ID and a
    /// UUID), and they are single-quoted into the `do script` line, so they are
    /// escaped defensively even though no email *body* text goes near the shell.
    private static func launchTerminal(script: String, messageId: String, threadId: String) {
        let sentinel = "/tmp/flux-agent-\(Int(Date().timeIntervalSince1970)).done"
        let osa = appleScript(script: script, sentinel: sentinel,
                              messageId: messageId, threadId: threadId)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", osa]
        // The AppleScript's result is the verdict it saw. Captured (rather than
        // dropped on the floor as before) for one reason: an interactive
        // handoff is the only outcome that leaves something on screen waiting
        // for Victor, and it deserves to say so in the overlay.
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            let verdict = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            if FluxAgentVerdict.parse(verdict) == .interactive {
                overlayInfo("flux-agent: 💬 interactive session waiting in Terminal")
            }
            release(messageId)
        }
        do {
            try p.run()  // fire-and-forget: survives an app redeploy
            recordLaunch()
        } catch {
            overlayError("flux-agent: failed to launch Terminal — \(error.localizedDescription)")
            release(messageId)
        }
    }

    /// The whole AppleScript, built as a pure string so the window rules are
    /// unit-testable instead of only observable by receiving an email.
    ///
    /// The message/thread ids are AgentMail identifiers (a Message-ID and a
    /// UUID), and they are single-quoted into the `do script` line, so they are
    /// escaped defensively even though no email *body* text goes near the shell.
    static func appleScript(script: String,
                            sentinel: String,
                            messageId: String,
                            threadId: String,
                            screens: [TerminalWindowPlacement.ScreenBox]? = nil) -> String {
        let interactive = FluxAgentVerdict.interactive.rawValue
        return """
        set sentinel to "\(sentinel)"
        do shell script "rm -f " & quoted form of sentinel
        set verdict to ""
        tell application "Terminal"
            activate
            set t to do script "bash '\(script)' '\(sentinel)' '\(shellEscape(messageId))' '\(shellEscape(threadId))'"
        \(TerminalWindowPlacement.appleScriptSnippet(tabVar: "t", screens: screens))
        end tell
        -- Wait up to ~60 min: this agent may do real work, not just a summary.
        repeat 1800 times
            delay 2
            try
                set verdict to (do shell script "cat " & quoted form of sentinel & " 2>/dev/null")
            end try
            if verdict is not "" then exit repeat
        end repeat
        -- Close on any verdict EXCEPT "\(interactive)": the agent is done either
        -- way, and flux-agent.sh already paused long enough for a failure to be
        -- readable. Everything is in the per-day log, so an unattended run never
        -- leaves a window behind. An interactive run is the opposite case — the
        -- script has just reopened its own claude session in that window for
        -- Victor to talk to, so it is brought to the front and given room.
        if verdict is "\(interactive)" then
            try
                tell application "Terminal"
                    activate
                    set w to (first window whose tabs contains t)
        \(TerminalWindowPlacement.appleScriptSnippet(tabVar: "t", screens: screens, areaFraction: 0.45))
                    set frontmost of w to true
                end tell
            end try
        else if verdict is not "" then
            try
                tell application "Terminal" to close (every window whose tabs contains t) saving no
            end try
        end if
        try
            do shell script "rm -f " & quoted form of sentinel
        end try
        return verdict
        """
    }

    /// Neutralise single quotes for a single-quoted shell word.
    private static func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }
}

/// What the sentinel `flux-agent.sh` writes means for its Terminal window.
///
/// Tiny, but deliberately a type: the *default* has to be "close it". An
/// unattended agent that leaves a window per email buries the desktop within a
/// day, so anything unrecognised — a truncated write, a verdict from a future
/// version of the script — must still close. Only the one verdict that means
/// "a human is expected at this window" keeps it open.
enum FluxAgentVerdict: String {
    case ok
    case fail
    case interactive

    /// `nil` for an empty/unknown verdict — including the empty string that
    /// means the script has not finished yet.
    static func parse(_ raw: String) -> FluxAgentVerdict? {
        FluxAgentVerdict(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Whether a window showing this verdict should be closed. Unknown
    /// verdicts close (see above); a not-yet-written verdict does not.
    static func closesWindow(rawVerdict: String) -> Bool {
        let trimmed = rawVerdict.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        return parse(trimmed) != .interactive
    }
}
