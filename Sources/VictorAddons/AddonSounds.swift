import AVFoundation
import Foundation

/// The handful of sounds **this** app still plays itself, now that the
/// soundboard, every desktop effect and their `SoundManager` live in the
/// separate Victor Effects app.
///
/// Three callers, all of them things that must ring even when the effects app
/// is stopped:
///   - `BreakTimerOverlay` — the ☕️ break gong (two full strikes at expiry, and
///     the interrupt when the watch is closed mid-strike);
///   - `LidAwake` — 💓 `13_heartbeat.mp3` and 🫀 `15_flatline.mp3`;
///   - `TrainingEndSequence` — 🏁 `82_over_and_out.mp3`.
///
/// Going over HTTP for these was rejected: "the break is over" must be audible
/// whatever else is running, and a gong that depends on a second process is a
/// gong that will one day not ring. So addons keeps its own thin player and its
/// own `Resources/sounds` symlink into the tablet's assets.
///
/// What it deliberately does NOT keep from `SoundManager`: the tablet-routed
/// player, the preempt/fade semantics, the paired-effect lead table, the
/// pending-visual compensation. Those belong to the soundboard, which moved.
final class AddonSounds {
    static let shared = AddonSounds()
    private init() {}

    /// Overlapping one-shots (the gong strikes), kept alive until they finish.
    /// Main thread only — AVAudioPlayer is not thread-safe.
    private var overlapping: [AVAudioPlayer] = []
    /// Named one-shots, so `play` of a sound already playing is a no-op.
    private var players: [String: AVAudioPlayer] = [:]
    /// Players that are mid-fade and no longer reachable from the pools above.
    /// They live here purely so ARC does not deallocate them — a released
    /// AVAudioPlayer stops dead, which is the hard cut the fade exists to avoid.
    private var fadingOut: [AVAudioPlayer] = []

    // MARK: - Where the files are

    /// The shared tablet-sounds folder (the Android app's assets, reached
    /// through `Resources/sounds`).
    ///
    /// `build-app.sh` replaces that symlink with a dereferenced copy — but any
    /// later `swift build` / `swift test` puts the verbatim symlink back
    /// (`../../../../victor-vibe-board/app/src/main/assets`, which resolves in the
    /// source tree and NOT from inside `.build/`). So when the bundle copy
    /// doesn't resolve we fall back to the source tree, where the same symlink
    /// does. Not cached: the folder flips between the two forms with every
    /// build, so each lookup asks the disk.
    static func sharedSoundsDir() -> URL? {
        let bundled = Bundle.module.bundleURL.appendingPathComponent("Resources/sounds")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: bundled.path, isDirectory: &isDir), isDir.boolValue {
            return bundled
        }
        let binaryDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        let envRoot = ProcessInfo.processInfo.environment["VICTOR_ADDONS_ROOT"] ?? ""
        let home = NSHomeDirectory()
        var candidates = ["\(binaryDir)/../../../Sources/VictorAddons/Resources/sounds"]
        if !envRoot.isEmpty { candidates.append("\(envRoot)/Sources/VictorAddons/Resources/sounds") }
        candidates.append("\(home)/workspace/victor-macos-addons/Sources/VictorAddons/Resources/sounds")
        for c in candidates {
            let url = URL(fileURLWithPath: c).standardized
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return nil
    }

    /// Resolve a sound file: the shared tablet sounds first, then anything left
    /// in this app's own `Resources/`.
    func soundURL(for filename: String) -> URL? {
        if let dir = Self.sharedSoundsDir() {
            let shared = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: shared.path) { return shared }
        }
        // bundleURL, not resourceURL: NSBundle reports <bundle>/Resources as the
        // resource dir for this flat SPM bundle, which would double the
        // "Resources" path component.
        let local = Bundle.module.bundleURL.appendingPathComponent("Resources/\(filename)")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        return nil
    }

    /// Duration (seconds) of a sound file, or nil if unavailable.
    func soundDuration(_ filename: String) -> TimeInterval? {
        guard let url = soundURL(for: filename) else { return nil }
        return try? AVAudioPlayer(contentsOf: url).duration
    }

    // MARK: - Bluetooth wake-up compensation

    /// Seconds of silence to prepend (and to delay anything paired with the
    /// sound by) when the default output is Bluetooth.
    ///
    /// **The file default only.** The tablet's header slider used to override
    /// this at runtime; that override now lives in the effects app with the
    /// soundboard, and asking for it over HTTP would reintroduce the dependency
    /// the gong exists to avoid. The accepted cost is a desync of ≤1.2 s — and
    /// only on the break gong's auto-close margin, which already carries 0.6 s
    /// of slack.
    private lazy var fileCompensationSeconds: TimeInterval = {
        var comp: TimeInterval = 0.55
        guard let dir = Self.sharedSoundsDir() else {
            overlayInfo("⏱️ sound-timing.json not found; addons uses \(Int(comp * 1000))ms BT compensation")
            return comp
        }
        let url = dir.appendingPathComponent("sound-timing.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            overlayInfo("⏱️ sound-timing.json unreadable; addons uses \(Int(comp * 1000))ms BT compensation")
            return comp
        }
        if let ms = obj["bluetoothCompensationMs"] as? NSNumber { comp = ms.doubleValue / 1000.0 }
        // Mac-only override: the Mac's BT output needs a longer warm-up than the
        // tablet's own speaker. The tablet ignores this key.
        if let ms = obj["macBluetoothCompensationMs"] as? NSNumber { comp = ms.doubleValue / 1000.0 }
        overlayInfo("⏱️ addons BT compensation \(Int(comp * 1000))ms (sound-timing.json)")
        return comp
    }()

    /// Hard ceiling, matching the tablet slider's 0–1.2 s range.
    static let maxCompensationSeconds: TimeInterval = 1.2

    /// The compensation to apply **right now**: the file default when the
    /// current default output is Bluetooth, otherwise 0.
    var currentBluetoothCompensation: TimeInterval {
        BluetoothOutput.isDefaultOutputBluetooth
            ? max(0, min(Self.maxCompensationSeconds, fileCompensationSeconds))
            : 0
    }

    /// Start `player` with the A2DP warm-up + start shift when the Mac's output
    /// is Bluetooth, so the leading edge isn't clipped during codec/amp spin-up.
    /// Returns the applied delay so callers can shift their own follow-up timers.
    @discardableResult
    private func startCompensated(_ player: AVAudioPlayer) -> TimeInterval {
        let comp = currentBluetoothCompensation
        if comp > 0 {
            BluetoothOutput.playWakeTone(seconds: comp)
            player.play(atTime: player.deviceCurrentTime + comp)
        } else {
            player.play()
        }
        return comp
    }

    // MARK: - Playing

    /// Play a sound once. If the same file is already playing, does nothing.
    func play(_ filename: String, volume: Float = 1.0) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let existing = self.players[filename], existing.isPlaying { return }
            guard let url = self.soundURL(for: filename) else {
                overlayError("Sound file not found: \(filename)")
                return
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = max(0, min(1, volume))
                player.prepareToPlay()
                self.players[filename] = player
                self.startCompensated(player)
            } catch {
                overlayError("Sound play failed \(filename): \(error)")
            }
        }
    }

    /// Play a copy that layers over anything already sounding — including over
    /// other copies of itself (the gong's two strikes).
    func playOverlapping(_ filename: String, volume: Float = 1.0) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let url = self.soundURL(for: filename) else {
                overlayError("Sound file not found: \(filename)")
                return
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = max(0, min(1, volume))
                player.prepareToPlay()
                self.overlapping.append(player)
                let comp = self.startCompensated(player)
                DispatchQueue.main.asyncAfter(deadline: .now() + comp + player.duration + 0.1) { [weak self] in
                    self?.overlapping.removeAll { !$0.isPlaying }
                }
            } catch {
                overlayError("Sound play failed \(filename): \(error)")
            }
        }
    }

    /// Stop every overlapping copy of one file. A `fade` of 0 stops it dead;
    /// the break timer passes one when it closes mid-strike, because an abrupt
    /// cut of a decaying gong is a hard edge the whole room hears.
    func stopOverlapping(_ filename: String, fade: TimeInterval = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let url = self.soundURL(for: filename) else { return }
            let matching = self.overlapping.filter { $0.url == url }
            // Dropped from the pool FIRST, then faded: `fadeOutAndStop` is what
            // keeps them alive now, and leaving them in the pool as well would
            // have the next `removeAll { !$0.isPlaying }` decide their fate.
            self.overlapping.removeAll { $0.url == url }
            for p in matching { self.fadeOutAndStop(p, over: fade) }
            self.overlapping.removeAll { !$0.isPlaying }
        }
    }

    private func fadeOutAndStop(_ player: AVAudioPlayer, over seconds: TimeInterval) {
        guard seconds > 0, player.isPlaying else {
            player.stop()
            return
        }
        fadingOut.append(player)
        player.setVolume(0, fadeDuration: seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in
            player.stop()
            self?.fadingOut.removeAll { $0 === player }
        }
    }
}
