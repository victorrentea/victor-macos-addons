import CoreAudio
import Foundation

/// Is anything **other than this app** playing sound out of the Mac right now?
///
/// One question, asked by `LidAwake` before it parks the system output at 100%
/// for the heartbeat. Taking the volume all the way up is safe on a silent
/// machine and violent on a playing one — the music Victor was listening to
/// when the lid came down would come back at full blast, into a bag or into a
/// room. So the boost only happens on silence, and this is what "silence"
/// means.
///
/// **Our own sounds do not count.** The pulse itself is an output stream, and
/// arming plays a lub-dub one line before the first tick asks this question, so
/// the app's own process is skipped by pid — otherwise the heartbeat would be
/// the very thing that vetoes its own volume.
///
/// **The always-open plumbing had to be filtered out, and that is the whole
/// difficulty of the question** (measured 2026-09-10 on a silent machine):
/// `com.rogueamoeba.audiohijack` and `ai.krisp.krispMac` both report
/// `IsRunningOutput = 1` permanently — Audio Hijack holds the `🔊OS Output`
/// loopback open as a listener (the same latching `CoreAudioManager` documents
/// for the device-level flags) and Krisp keeps its virtual device open the same
/// way. Taken at face value, "someone is playing" would be true forever on this
/// Mac and the heartbeat would never once raise its volume. Neither app is ever
/// *the music*, so both are skipped by bundle prefix. A real player is caught:
/// with one `afplay` running, its process — and only it — appeared alongside the
/// two above.
///
/// The list is a liability if some future app latches the flag the same way, so
/// the refusal is logged with the name of whoever caused it: one line in the log
/// says which app to add here, instead of a heartbeat that is quietly never
/// boosted again.
///
/// **Process objects, not the loopback tap.** `CoreAudioManager` already
/// answers "is anything audible" by measuring sample energy, but only through
/// the named `🔊OS Output` aggregate from Rogue Amoeba — which is not what the
/// Mac plays through in a rucksack. `kAudioHardwarePropertyProcessObjectList`
/// asks the system directly and needs no device to be present; it is the same
/// list `recordingDictationApp()` walks for the microphone, read for
/// `IsRunningOutput` instead of `IsRunningInput`.
enum SystemAudioActivity {

    /// The bundle id of some other process currently running an output stream
    /// (or `pid N` for one that has no bundle), or `nil` when the Mac is quiet.
    ///
    /// A list that cannot be read also answers `nil`: a failed read is not
    /// evidence that music is playing, the same way `LidAwake` treats an
    /// unreadable battery as no evidence of a low charge.
    static func otherAppPlayingOutput() -> String? {
        guard let procs = processObjects() else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        for object in procs {
            guard isRunningOutput(object) else { continue }
            if processPID(object) == mine { continue }
            let bundle = bundleID(object) ?? ""
            // A process with no bundle id is identified by its binary instead —
            // both to skip the headless plumbing and so the refusal names
            // something a human can act on.
            let path = bundle.isEmpty ? processPID(object).flatMap(ClaudeActivity.executablePath(of:)) : nil
            guard !isAlwaysOpenPlumbing(bundleID: bundle, executablePath: path) else { continue }
            if !bundle.isEmpty { return bundle }
            if let path, let pid = processPID(object) {
                return "pid \(pid) (\((path as NSString).lastPathComponent))"
            }
            return processPID(object).map { "pid \($0)" } ?? "an app"
        }
        return nil
    }

    /// Is this process plumbing that holds an output stream open whether or not
    /// anything is playing, rather than something that is actually the music?
    ///
    /// Separated out so the list is testable without a sound card.
    static func isAlwaysOpenPlumbing(bundleID: String, executablePath: String?) -> Bool {
        if !bundleID.isEmpty { return alwaysOpenPrefixes.contains(where: bundleID.hasPrefix) }
        guard let executablePath else { return false }
        return alwaysOpenBinaries.contains { executablePath.contains($0) }
    }

    /// Audio plumbing that holds an output stream open whether or not anything
    /// is playing through it — see the note on the enum. Prefixes, so the whole
    /// family (`arkaudiod`, `audiohijack`, Loopback) goes with the parent.
    ///
    /// **Walkie Talkie joined the list on 2026-09-15**, and it is the reason the
    /// heartbeat's volume boost had quietly never fired on this Mac: sampled
    /// every 3 s for a minute on a silent machine, `ro.victorrentea.wispr-relay`
    /// reports `IsRunningOutput = 1` permanently at an RMS of exactly 0 — its
    /// dictation engine holds the stream open the way Audio Hijack holds the
    /// loopback. It is spelled in full rather than as `ro.victorrentea.`,
    /// because the *other* app in that family, `victor-effects`, is the
    /// soundboard: it is quite literally the music, and skipping it would put
    /// the room's playlist at full blast.
    /// **Wispr Flow itself joined on 2026-09-21**, for the same reason and
    /// after the same symptom: Victor shut the lid with a remote session
    /// working and heard no heartbeat at all. Sampled every 4 s on a silent
    /// machine, `com.electron.wispr-flow.helper` reports `IsRunningOutput = 1`
    /// permanently at RMS 0 — the dictation app holds the output stream open
    /// the way its relay does, and it is running all day on this Mac. So the
    /// boost *and* the mute lift had been refused on every single tick: the
    /// pulse went out at whatever the slider happened to be, and on a muted Mac
    /// it would have gone out as nothing. It is the microphone app, never the
    /// music.
    static let alwaysOpenPrefixes = [
        "com.rogueamoeba.",
        "ai.krisp.",
        "ro.victorrentea.wispr-relay",
        "com.electron.wispr-flow",
    ]

    /// The same thing for processes with **no bundle id at all**, matched on the
    /// binary's path. Playwright's headless Chromium — the one the WhatsApp and
    /// LinkedIn skills leave running — spawns an audio utility child that holds
    /// an output stream open at RMS 0; measured beside Wispr Flow on
    /// 2026-09-21, both at once, which is why the boost never fired even when
    /// Wispr was closed. A headless browser is automation, not the room's sound.
    static let alwaysOpenBinaries = [
        "chrome-headless-shell",
    ]

    private static func processObjects() -> [AudioObjectID]? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var procs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &procs) == noErr else { return nil }
        return procs
    }

    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private static func processPID(_ object: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    private static func bundleID(_ object: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return nil }
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
