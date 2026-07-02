import Foundation

/// Loads the shared `sound-timing.json` that the Mac add-on and the Android
/// LaunchBreak tablet both read. The file lives in the canonical sounds folder
/// (`Resources/sounds` is a symlink to the Android app's `assets/`), so it is a
/// single source of truth for:
///   - `bluetoothCompensationMs`: silence prepended before a sound, and the
///     matching delay applied to its paired animation, **only** when the
///     current output is Bluetooth (see `BluetoothOutput`).
///   - per-sound `animationLeadMs`: how long an animation leads its sound
///     (backs `SoundManager.pairedEffectStartDelays`).
///
/// Loaded once, lazily. If the file is missing or malformed we fall back to the
/// values baked in below, which match the tablet's current behaviour — so a bad
/// config never breaks playback, it just reverts to the previous constants.
final class SoundTimingConfig {
    static let shared = SoundTimingConfig()

    /// Seconds of silence to prepend (and to delay the paired animation by)
    /// when the current default output is Bluetooth. Default 0.55s mirrors the
    /// tablet's `BT_WAKE_MS`.
    let bluetoothCompensationSeconds: TimeInterval

    /// `animationLeadMs` per sound file, in seconds.
    let animationLeads: [String: TimeInterval]

    private init() {
        // Same resolution as SoundManager.soundURL's shared-sounds branch.
        let url = Bundle.module.bundleURL.appendingPathComponent("Resources/sounds/sound-timing.json")

        var comp: TimeInterval = 0.55
        var leads: [String: TimeInterval] = ["67_sfx_109.mp3": 0.30]

        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let ms = obj["bluetoothCompensationMs"] as? NSNumber {
                comp = ms.doubleValue / 1000.0
            }
            // Mac-only override: the Mac's BT output needs a longer warm-up than
            // the tablet's own BT speaker. Prefer macBluetoothCompensationMs when
            // present; the tablet ignores this key.
            if let ms = obj["macBluetoothCompensationMs"] as? NSNumber {
                comp = ms.doubleValue / 1000.0
            }
            if let sounds = obj["sounds"] as? [String: Any] {
                var parsed: [String: TimeInterval] = [:]
                for (file, raw) in sounds {
                    if let entry = raw as? [String: Any],
                       let lead = entry["animationLeadMs"] as? NSNumber {
                        parsed[file] = lead.doubleValue / 1000.0
                    }
                }
                leads = parsed  // authoritative once the file parses
            }
            overlayInfo("⏱️ sound-timing.json loaded: BT compensation \(Int(comp * 1000))ms, \(leads.count) paired-delay entr\(leads.count == 1 ? "y" : "ies")")
        } else {
            overlayInfo("⏱️ sound-timing.json not found; using built-in defaults (BT compensation \(Int(comp * 1000))ms)")
        }

        bluetoothCompensationSeconds = comp
        animationLeads = leads
    }

    /// The animation→sound lead for a file (0 if none).
    func animationLead(for file: String) -> TimeInterval { animationLeads[file] ?? 0 }

    /// Compensation to apply **right now**: the configured seconds when the
    /// current default output is Bluetooth, otherwise 0.
    var currentBluetoothCompensation: TimeInterval {
        BluetoothOutput.isDefaultOutputBluetooth ? bluetoothCompensationSeconds : 0
    }
}
