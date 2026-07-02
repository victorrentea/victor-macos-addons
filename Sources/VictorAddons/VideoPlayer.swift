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
final class VideoPlayer {
    static let shared = VideoPlayer()

    /// IINA's CLI launcher (installed at /Applications/IINA.app).
    private let iinaCLI = "/Applications/IINA.app/Contents/MacOS/iina-cli"
    private let playerProcessName = "IINA"

    /// Seconds after which the player is force-quit (0 disables auto-kill).
    var autoKillAfter: TimeInterval = 60

    private var autoKill: DispatchWorkItem?

    /// Launch (or replace) the player at `startSeconds`, fullscreen.
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

        let p = Process()
        p.executableURL = URL(fileURLWithPath: iinaCLI)
        // `--no-stdin` makes iina-cli return immediately after launching IINA
        // (without it, it blocks reading stdin). mpv options do the seek + fullscreen.
        p.arguments = [
            "--no-stdin",
            "--mpv-start=\(max(0, startSeconds))",
            "--mpv-fullscreen=yes",
            "--mpv-force-window=yes",
            "--mpv-keep-open=no",
            fileURL.path,
        ]
        do {
            try p.run()
        } catch {
            overlayError("VideoPlayer: failed to launch IINA: \(error)")
            return false
        }
        overlayInfo("VideoPlayer: playing \(fileURL.lastPathComponent) from \(startSeconds)s")
        scheduleAutoKill()
        return true
    }

    /// Stop playback now (tablet stop / test hook) and cancel the pending auto-kill.
    func stop() {
        autoKill?.cancel()
        autoKill = nil
        killPlayer()
    }

    private func scheduleAutoKill() {
        autoKill?.cancel()
        autoKill = nil
        guard autoKillAfter > 0 else { return }
        let after = autoKillAfter
        let work = DispatchWorkItem { [weak self] in
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
