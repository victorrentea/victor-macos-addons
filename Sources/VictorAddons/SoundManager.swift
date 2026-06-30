import AVFoundation
import Foundation

/// Manages sound effects for overlay effects. Prevents overlapping plays of the same sound.
/// All operations run on the main thread (AVAudioPlayer is not thread-safe).
class SoundManager {
    static let shared = SoundManager()

    private var players: [String: AVAudioPlayer] = [:]
    private var overlappingPlayers: [AVAudioPlayer] = []

    /// Player for the single tablet-routed sound. The tablet routes its
    /// soundboard here when "play on Mac" is active: one sound at a time, a
    /// new play preempts the current one (mirrors the tablet's local
    /// MediaPlayer semantics: same button = stop, other button = preempt).
    private var tabletPlayer: AVAudioPlayer?

    /// Playback volume (0..1) for tablet-routed sounds, controlled from the
    /// tablet's volume buttons/wedge. Player-level only — the macOS system
    /// volume is never touched.
    private var tabletVolume: Float = 1.0

    /// Per-sound playback start delay (seconds) for sounds paired with a
    /// visual effect: the animation gets a head start so it is on screen
    /// before the audio kicks in. Applied in the tablet-routed path
    /// (playTabletSound) and the Mac-local path (EmojiAnimator). Sourced from
    /// the shared sound-timing.json (animationLeadMs) so the Mac and tablet
    /// agree; see SoundTimingConfig.
    static var pairedEffectStartDelays: [String: TimeInterval] {
        SoundTimingConfig.shared.animationLeads
    }

    // MARK: - Bluetooth visual sync (tablet-routed path)

    /// When a tablet-routed sound is started with Bluetooth compensation, the
    /// paired Mac visual (delivered as a separate /effect request right after)
    /// must be delayed by the same amount to stay in sync with the
    /// silence-prepended audio. Set by playTabletSound, consumed once by the
    /// next show-effect. Main-thread only — both the sound and the effect HTTP
    /// handlers run inside TabletHttpServer's DispatchQueue.main.sync.
    private static var pendingVisualCompensation: TimeInterval = 0
    private static var pendingVisualCompensationAt: Date?

    /// Returns (and clears) the Bluetooth compensation that the imminent paired
    /// visual `name` should be delayed by, or 0. Only a fresh (<1.5s) pending
    /// compensation tied to a just-routed sound applies, and never to
    /// stop/utility signals (those must fire immediately).
    static func consumePendingVisualCompensation(for name: String) -> TimeInterval {
        guard pendingVisualCompensation > 0,
              let at = pendingVisualCompensationAt,
              Date().timeIntervalSince(at) < 1.5 else { return 0 }
        if name == "stop-all" || name.hasSuffix("/stop")
            || name == "green-flash" || name.hasPrefix("progress-bar/") {
            return 0
        }
        let comp = pendingVisualCompensation
        pendingVisualCompensation = 0
        pendingVisualCompensationAt = nil
        return comp
    }

    private init() {}

    /// Resolve a sound file: shared tablet sounds (Resources/sounds — a
    /// symlink to the Android app's assets folder, dereferenced by
    /// build-app.sh) first, then Mac-only sounds in Resources/.
    func soundURL(for filename: String) -> URL? {
        // bundleURL, not resourceURL: NSBundle reports <bundle>/Resources as
        // the resource dir for this flat SPM bundle, which would double the
        // "Resources" path component.
        let base = Bundle.module.bundleURL
        let shared = base.appendingPathComponent("Resources/sounds/\(filename)")
        if FileManager.default.fileExists(atPath: shared.path) { return shared }
        let local = base.appendingPathComponent("Resources/\(filename)")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        return nil
    }

    /// Duration (seconds) of a bundled sound file, or nil if unavailable.
    func soundDuration(_ filename: String) -> TimeInterval? {
        guard let url = soundURL(for: filename) else { return nil }
        return try? AVAudioPlayer(contentsOf: url).duration
    }

    /// Play a sound from the bundle Resources folder, looping indefinitely.
    /// If the same sound is already playing, does nothing.
    func playLooping(_ filename: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let existing = self.players[filename], existing.isPlaying { return }
            guard let url = self.soundURL(for: filename) else {
                overlayError("Sound file not found: \(filename)")
                return
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = -1
                player.volume = 1.0
                player.prepareToPlay()
                self.players[filename] = player
                player.play()
            } catch {
                overlayError("Sound play failed \(filename): \(error)")
            }
        }
    }

    /// Play a sound from the bundle Resources folder.
    /// If the same sound is already playing, does nothing (no restart).
    func play(_ filename: String, volume: Float = 1.0) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Already playing? Skip.
            if let existing = self.players[filename], existing.isPlaying {
                return
            }

            guard let url = self.soundURL(for: filename) else {
                overlayError("Sound file not found: \(filename)")
                return
            }

            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = max(0.0, min(1.0, volume))
                player.prepareToPlay()
                self.players[filename] = player
                player.play()
            } catch {
                overlayError("Sound play failed \(filename): \(error)")
            }
        }
    }

    /// Play a new instance of the sound every time, layering over any already-playing copies.
    /// The player is released automatically when playback finishes.
    func playOverlapping(_ filename: String, volume: Float = 1.0) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let url = self.soundURL(for: filename) else {
                overlayError("Sound file not found: \(filename)")
                return
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = max(0.0, min(1.0, volume))
                player.prepareToPlay()
                self.overlappingPlayers.append(player)
                player.play()
                // Clean up finished players after this one ends
                DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 0.1) { [weak self] in
                    self?.overlappingPlayers.removeAll { !$0.isPlaying }
                }
            } catch {
                overlayError("Sound play failed \(filename): \(error)")
            }
        }
    }

    /// Play a sound as a fixed-length "clip": it plays for `seconds`, fading out
    /// over the final `fade` seconds so the cut is clean. Layers over other sounds.
    /// `volume` (0..1) sets the playback level; the fade-out goes from it to 0.
    func playClip(_ filename: String, seconds: TimeInterval, fade: TimeInterval = 0.6, volume: Float = 1.0) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let url = self.soundURL(for: filename) else {
                overlayError("Sound file not found: \(filename)")
                return
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = max(0.0, min(1.0, volume))
                player.prepareToPlay()
                self.overlappingPlayers.append(player)
                player.play()
                let fadeStart = max(0, seconds - fade)
                DispatchQueue.main.asyncAfter(deadline: .now() + fadeStart) {
                    if player.isPlaying { player.setVolume(0, fadeDuration: fade) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in
                    player.stop()
                    self?.overlappingPlayers.removeAll { !$0.isPlaying }
                }
            } catch {
                overlayError("Sound clip failed \(filename): \(error)")
            }
        }
    }

    // MARK: - Tablet-routed sounds (GET /sound/play/<file>, /sound/stop)

    /// Play a tablet-routed sound, preempting any currently playing tablet
    /// sound. `volume` (0..1) accompanies each play from the tablet and is
    /// remembered as the new tablet volume. Returns the sound duration in
    /// seconds (the tablet schedules its effect-stop chain from it), or nil
    /// if the file is unknown/unplayable. Synchronous — must be called on the
    /// main thread (TabletHttpServer dispatches handlers via DispatchQueue.main.sync).
    func playTabletSound(_ filename: String, volume: Float? = nil) -> TimeInterval? {
        if let volume { tabletVolume = max(0.0, min(1.0, volume)) }
        tabletPlayer?.stop()
        tabletPlayer = nil
        guard let url = soundURL(for: filename) else {
            overlayError("Tablet sound not found: \(filename)")
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = tabletVolume
            player.prepareToPlay()
            tabletPlayer = player
            let lead = Self.pairedEffectStartDelays[filename] ?? 0
            // When this Mac's own output is Bluetooth, prepend silence to warm
            // the A2DP link (so the sound isn't clipped) and remember the
            // compensation so the paired visual — a separate /effect request
            // right after — is delayed to match. Zero on non-Bluetooth output,
            // leaving the previous behaviour untouched.
            let btComp = SoundTimingConfig.shared.currentBluetoothCompensation
            let total = lead + btComp
            if btComp > 0 {
                BluetoothOutput.playWakeTone(seconds: total)
                Self.pendingVisualCompensation = btComp
                Self.pendingVisualCompensationAt = Date()
            }
            if total > 0 {
                player.play(atTime: player.deviceCurrentTime + total)
            } else {
                player.play()
            }
            // Include the lead + Bluetooth compensation so the tablet's
            // completion timer (durationMs + 100ms → effect-stop chain) doesn't
            // cut the tail of the sound.
            return player.duration + total
        } catch {
            overlayError("Tablet sound play failed \(filename): \(error)")
            return nil
        }
    }

    /// Play a tablet-routed sound that LAYERS over its previous copies instead
    /// of preempting them — used by the 💸 Money tile (53_rain.mp3 →
    /// 57_checkmark.mp3) so rapid repeated presses STACK overlapping "ching"s
    /// (matching the stacking rounds of rising dollars) rather than cutting the
    /// previous sound off. Honours/remembers the tablet volume like
    /// playTabletSound, but routes through the overlapping-players pool — never
    /// the single `tabletPlayer` — so it neither preempts nor is wiped by
    /// stopTabletSound / `/effect/stop-all` (which the tablet fires before every
    /// press). Returns the clip duration for the tablet's effect-stop chain.
    /// Synchronous — main thread only (TabletHttpServer handlers run on it).
    @discardableResult
    func playOverlappingTabletSound(_ filename: String, volume: Float? = nil) -> TimeInterval? {
        if let volume { tabletVolume = max(0.0, min(1.0, volume)) }
        guard let url = soundURL(for: filename) else {
            overlayError("Tablet sound not found: \(filename)")
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = tabletVolume
            player.prepareToPlay()
            overlappingPlayers.append(player)
            player.play()
            let duration = player.duration
            // Release finished players after this one ends (same cleanup as playOverlapping).
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in
                self?.overlappingPlayers.removeAll { !$0.isPlaying }
            }
            return duration
        } catch {
            overlayError("Tablet sound play failed \(filename): \(error)")
            return nil
        }
    }

    /// Live-adjust the tablet-routed volume (applies to the sound currently
    /// playing too) and play the tablet's click tone at the new level as
    /// audible feedback — the same generated 1800Hz tap the tablet uses.
    func setTabletVolume(_ volume: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tabletVolume = max(0.0, min(1.0, volume))
            self.tabletPlayer?.volume = self.tabletVolume
            self.playOverlapping("click.wav", volume: self.tabletVolume)
        }
    }

    /// Stop the tablet-routed sound immediately (mirrors the tablet's abrupt
    /// MediaPlayer.stop on re-press / preempt).
    func stopTabletSound() {
        DispatchQueue.main.async { [weak self] in
            self?.tabletPlayer?.stop()
            self?.tabletPlayer = nil
        }
    }

    /// Whether a tablet-routed sound is currently playing (main thread only —
    /// used by the ping watchdog).
    var isTabletSoundPlaying: Bool {
        tabletPlayer?.isPlaying ?? false
    }

    /// Stop any overlapping instances of a given sound immediately (e.g. interrupt
    /// the break-timer gong when the user closes the watch mid-strike).
    func stopOverlapping(_ filename: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let url = self.soundURL(for: filename) else { return }
            for p in self.overlappingPlayers where p.url == url { p.stop() }
            self.overlappingPlayers.removeAll { !$0.isPlaying }
        }
    }

    /// Fade out over 300ms then stop. Called when the animation finishes —
    /// the sound continues playing (fading) for 300ms after the visual ends.
    func stop(_ filename: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let player = self.players[filename], player.isPlaying else {
                self?.players[filename] = nil
                return
            }
            player.setVolume(0, fadeDuration: 0.3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                player.stop()
                self?.players[filename] = nil
            }
        }
    }
}
