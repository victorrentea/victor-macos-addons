import AppKit
import ApplicationServices
import Foundation

/// Plays a downloaded video fullscreen in **IINA** and manages its lifetime:
/// a new play **replaces** the previous one (never stacks a second window), and
/// the player is **auto-killed ~60s after playback starts** so a snippet left
/// running doesn't linger on the projected screen.
///
/// We orchestrate the external IINA player rather than embedding an AVPlayer:
/// IINA gives precise `--mpv-start=<sec>` seeking + fullscreen for free, and is
/// trivially replaced/killed by process name — matching "the media player should
/// be killed by the macos-addons".
///
/// Three things IINA does *not* give for free, and which this class therefore
/// takes over — each one learned from watching it misbehave in a room:
///
/// 1. **Which screen.** The clip must land on the **built-in Retina**, whatever
///    macOS currently calls the main display — the Retina is what a venue
///    projector mirrors, and at a venue the *ASUS* is made primary (see
///    `DisplayArrangementManager`), so "the main screen" is exactly the wrong
///    answer there. mpv's own `--fs-screen` is **ignored** (verified: IINA
///    manages its NSWindow itself and never passes it on), and IINA otherwise
///    restores wherever its window was last. So the window is launched
///    *windowed*, moved onto the Retina through the **Accessibility API** — the
///    same in-process grant `TerminalTiler` uses, no Automation consent — and
///    only then fullscreened by setting `AXFullScreen`. A fullscreen window
///    cannot be moved between displays afterwards, which is why the order is
///    place-then-fullscreen and why we don't just pass `--mpv-fullscreen=yes`.
///
/// 2. **What plays next: nothing, ever.** IINA loads the *containing folder* as
///    a playlist, so finishing one snippet rolled straight into the next file in
///    `videos/` — mid-workshop, on the projector (observed: "Papaguera" handing
///    over to "Feel it coming"). Turning that off is not reliably reachable from
///    the CLI (`playlistAutoPlayNext` was already `0` when it happened, and
///    `--mpv-autocreate-playlist=no` didn't stop it), so instead the file is
///    played from a **staging folder that contains exactly one file** —
///    `videos/.play/`, a hardlink, rebuilt per play. A playlist built from that
///    folder has nowhere to go. It's a hardlink, not a symlink, precisely so
///    that resolving it can't lead back to the real folder full of siblings.
///
/// 3. **What happens at the end: rewind and pause.** With `--keep-open=yes` mpv
///    stops at the last frame, which leaves a frozen still on the projector and
///    needs a seek before it can be replayed. So the player is watched over
///    mpv's JSON IPC socket and, the moment it reports EOF, told to seek back to
///    the snippet's start second and pause — leaving it primed so **SPACE
///    replays the clip**. Resuming re-arms both the watch and the auto-kill, so
///    a replay gets a full 60s of its own rather than being cut off by the
///    original deadline.
final class VideoPlayer {
    static let shared = VideoPlayer()

    /// IINA's CLI launcher (installed at /Applications/IINA.app).
    private let iinaCLI = "/Applications/IINA.app/Contents/MacOS/iina-cli"
    private let playerProcessName = "IINA"
    private let iinaBundleId = "com.colliderli.iina"
    /// mpv's control socket. One player at a time, so one fixed path.
    private let ipcSocket = "/tmp/victor-addons-iina.sock"

    /// Seconds after which the player is force-quit (0 disables auto-kill).
    var autoKillAfter: TimeInterval = 60

    private var autoKill: DispatchWorkItem?
    /// EOF watch. Lives on `watchQueue`; `startSeconds` is where a rewind lands.
    private let watchQueue = DispatchQueue(label: "ro.victorrentea.macos-addons.video-eof", qos: .utility)
    private var eofWatch: DispatchSourceTimer?
    private var watchStartSeconds = 0
    private var rewound = false

    /// Launch (or replace) the player at `startSeconds`, fullscreen on the Retina.
    /// Returns false if the file is missing or IINA isn't installed.
    @discardableResult
    func play(fileURL: URL, startSeconds: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            overlayError("VideoPlayer: file not found: \(fileURL.path)")
            return false
        }
        guard FileManager.default.isExecutableFile(atPath: iinaCLI) else {
            overlayError("VideoPlayer: IINA CLI not found at \(iinaCLI)")
            return false
        }

        // Replace: quit any player already up so we never stack windows.
        killPlayer()
        stopEofWatch()

        // Play from a folder holding this file alone (see the class comment):
        // whatever playlist IINA builds around it has nowhere to continue to.
        let playURL = stagedURL(for: fileURL) ?? fileURL
        try? FileManager.default.removeItem(atPath: ipcSocket)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: iinaCLI)
        // `--no-stdin` makes iina-cli return immediately after launching IINA
        // (without it, it blocks reading stdin). NB no `--mpv-fullscreen`: the
        // window has to stay movable until it is on the Retina.
        p.arguments = [
            "--no-stdin",
            "--mpv-start=\(max(0, startSeconds))",
            "--mpv-force-window=yes",
            "--mpv-keep-open=yes",
            "--mpv-input-ipc-server=\(ipcSocket)",
            playURL.path,
        ]
        do {
            try p.run()
        } catch {
            overlayError("VideoPlayer: failed to launch IINA: \(error)")
            return false
        }
        overlayInfo("VideoPlayer: playing \(fileURL.lastPathComponent) from \(startSeconds)s")
        scheduleRetinaFullscreen(attemptsLeft: 40)
        startEofWatch(startSeconds: max(0, startSeconds))
        scheduleAutoKill()
        return true
    }

    /// Stop playback now (tablet stop / test hook) and cancel the pending auto-kill.
    func stop() {
        autoKill?.cancel()
        autoKill = nil
        stopEofWatch()
        killPlayer()
    }

    // MARK: - One file, one folder

    /// Hardlink the clip into `videos/.play/`, emptied first, and return the link.
    /// Nil when the staging fails, in which case the caller falls back to the
    /// real path (auto-advance risk beats not playing at all).
    private func stagedURL(for fileURL: URL) -> URL? {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent().appendingPathComponent(".play")
        do {
            if fm.fileExists(atPath: dir.path) {
                for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                    try? fm.removeItem(at: dir.appendingPathComponent(name))
                }
            } else {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let link = dir.appendingPathComponent(fileURL.lastPathComponent)
            try fm.linkItem(at: fileURL, to: link)
            return link
        } catch {
            overlayInfo("VideoPlayer: could not stage \(fileURL.lastPathComponent) (\(error)) — playing in place")
            return nil
        }
    }

    // MARK: - Retina placement

    /// Poll for IINA's window and place it. Fast cadence (0.15s) because until it
    /// lands the clip is visible on whatever screen IINA opened on.
    ///
    /// **The request is repeated until it is confirmed**, not fired once: IINA
    /// puts a window up before it is ready to be fullscreened, and an
    /// `AXFullScreen` write that lands in that gap returns success and does
    /// nothing (observed — the window merely covered the Retina's visible frame,
    /// menu bar still showing). So each attempt re-asserts the frame, asks for
    /// fullscreen, and **reads the attribute back**; only a true read stops the
    /// loop.
    private func scheduleRetinaFullscreen(attemptsLeft: Int) {
        guard attemptsLeft > 0 else {
            overlayError("VideoPlayer: IINA never confirmed fullscreen — the window covers the Retina instead")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            if self.placeOnRetinaAndFullscreen() { return }
            self.scheduleRetinaFullscreen(attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Move IINA's window onto the Retina and fullscreen it there. Main thread
    /// (NSScreen). Returns true only once fullscreen is **confirmed**; false
    /// while there is no window yet or the request hasn't taken, so the caller
    /// keeps polling.
    private func placeOnRetinaAndFullscreen() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: iinaBundleId).first else {
            return false
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement],
              let win = Self.playerWindow(among: windows) else {
            return false
        }
        let target = Self.axFrame(of: AppDelegate.findRetinaScreen())
        var size = target.size
        if let v = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
        }
        var origin = target.origin
        if let v = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
        }
        // Fullscreen goes to the display the window is now on — hence the order.
        AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, kCFBooleanTrue)
        var isFull: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &isFull) == .success,
              (isFull as? Bool) == true else {
            return false   // not taken yet — the caller asks again
        }
        return true
    }

    /// IINA exposes **more than one** AX window, and the first one is not the
    /// player: it is a 1728×37 strip with subrole `AXUnknown` whose
    /// `AXFullScreen` isn't even settable. Writing the frame and the fullscreen
    /// flag to it silently did nothing while looking like it worked — the clip
    /// stayed wherever IINA had remembered it. The player is the
    /// `AXStandardWindow`; when several qualify, the largest is the video.
    private static func playerWindow(among windows: [AXUIElement]) -> AXUIElement? {
        var best: (win: AXUIElement, area: CGFloat)?
        for w in windows {
            var subrole: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &subrole) == .success,
                  (subrole as? String) == (kAXStandardWindowSubrole as String) else { continue }
            var raw: CFTypeRef?
            var size = CGSize.zero
            if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &raw) == .success, let v = raw {
                AXValueGetValue(v as! AXValue, .cgSize, &size)
            }
            let area = size.width * size.height
            if best == nil || area > best!.area { best = (w, area) }
        }
        return best?.win
    }

    /// Cocoa screen frame → Accessibility coordinates. The two disagree: AppKit
    /// measures y **up** from the bottom of the primary screen, AX measures it
    /// **down** from the top — identical only for the primary screen itself,
    /// which is exactly the case that stops being true at a venue.
    static func axFrame(of screen: NSScreen) -> CGRect {
        axFrame(screenFrame: screen.frame, primaryTopY: (NSScreen.screens.first ?? screen).frame.maxY)
    }

    /// Pure half of the conversion, so the case that matters — the Retina *not*
    /// being the primary screen, where the two systems actually differ — is
    /// unit-tested rather than only ever exercised at a venue.
    static func axFrame(screenFrame f: CGRect, primaryTopY: CGFloat) -> CGRect {
        CGRect(x: f.origin.x, y: primaryTopY - f.maxY, width: f.width, height: f.height)
    }

    // MARK: - End of playback: rewind + pause, never advance

    private func startEofWatch(startSeconds: Int) {
        watchQueue.async { [weak self] in
            guard let self else { return }
            self.watchStartSeconds = startSeconds
            self.rewound = false
            let t = DispatchSource.makeTimerSource(queue: self.watchQueue)
            t.schedule(deadline: .now() + 1.0, repeating: 0.3)
            t.setEventHandler { [weak self] in self?.eofTick() }
            t.resume()
            self.eofWatch = t
        }
    }

    private func stopEofWatch() {
        watchQueue.async { [weak self] in
            self?.eofWatch?.cancel()
            self?.eofWatch = nil
            self?.rewound = false
        }
    }

    /// On `queue`. Two edges matter: playback reaching the end (rewind + pause),
    /// and Victor pressing SPACE afterwards (re-arm, and give the replay its own
    /// full auto-kill window instead of the one the first play started).
    private func eofTick() {
        let eof = MpvIPC.boolProperty(socketPath: ipcSocket, "eof-reached") ?? false
        let paused = MpvIPC.boolProperty(socketPath: ipcSocket, "pause") ?? false
        if eof, !rewound {
            MpvIPC.send(socketPath: ipcSocket, command: ["seek", watchStartSeconds, "absolute"])
            MpvIPC.send(socketPath: ipcSocket, command: ["set_property", "pause", true])
            rewound = true
            overlayInfo("VideoPlayer: clip ended — rewound to \(watchStartSeconds)s and paused (SPACE replays)")
            return
        }
        if rewound, !paused {
            rewound = false
            DispatchQueue.main.async { [weak self] in self?.scheduleAutoKill() }
        }
    }

    // MARK: - Lifetime

    private func scheduleAutoKill() {
        autoKill?.cancel()
        autoKill = nil
        guard autoKillAfter > 0 else { return }
        let after = autoKillAfter
        let work = DispatchWorkItem { [weak self] in
            self?.stopEofWatch()
            self?.killPlayer()
            overlayInfo("VideoPlayer: auto-killed player after \(Int(after))s")
        }
        autoKill = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }

    /// Quit IINA by process name (AppleScript-free, no Automation permission).
    private func killPlayer() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-x", playerProcessName]
        try? p.run()
        p.waitUntilExit()
    }
}
