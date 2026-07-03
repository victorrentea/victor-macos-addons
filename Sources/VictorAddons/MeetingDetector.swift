import CoreAudio
import Foundation

/// Detects whether Victor is in a live meeting / stream — Zoom, Teams (app or
/// web), Webex, or Google Meet — so the aggressive silent-transcription warning
/// (`PresentationDetector`) only fires while he's actually presenting.
///
/// **Signal:** a meeting app — or a browser, for web meetings — is *actively
/// capturing the microphone* (`kAudioProcessPropertyIsRunningInput` on that
/// process). We poll every few seconds and report the rising/falling edge.
///
/// An earlier version watched `🎙️TO Zoom`'s `kAudioDevicePropertyDeviceIsRunning
/// Somewhere`, but that virtual device is held open by its own driver / Victor's
/// audio routing and reads "running" even with **no call** — a permanent false
/// positive (verified: it's `started` at every launch with no meeting app alive).
/// Attributing live mic capture to a specific meeting/browser app is the reliable
/// signal. Whisper's own transcription capture (a Python process) and Wispr
/// (`com.electron.wispr-flow`) never match these prefixes, so transcription
/// itself never trips it.
final class MeetingDetector {
    var onMeetingChanged: ((Bool) -> Void)?

    /// Bundle-ID prefixes that mean "in a meeting" when capturing the mic.
    private static let meetingBundlePrefixes = [
        "us.zoom.xos",                 // Zoom (+ its helpers)
        "com.microsoft.teams",         // Teams classic + com.microsoft.teams2
        "com.cisco.webexmeetingsapp",  // Webex app
        "com.webex.meetingmanager",
        "com.cisco.webexmeetings",
    ]
    /// Browsers — a web meeting (Google Meet / Teams-web / Webex-web) surfaces as
    /// the browser capturing the mic.
    private static let browserBundlePrefixes = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
        "com.brave.Browser",
        "org.mozilla.firefox",
    ]

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(
        label: "ro.victorrentea.macos-addons.meeting-detector", qos: .utility)
    private var isMeetingActive = false

    /// Begin polling. (Named for backwards compatibility with the call site.)
    func checkInitialState() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 3)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// True while a meeting app / browser is capturing the mic. Also exposed for
    /// the `/test/presentation` snapshot.
    var meetingActiveNow: Bool { Self.meetingCaptor() != nil }

    deinit { timer?.cancel() }

    private func tick() {
        let captor = Self.meetingCaptor()
        let active = captor != nil
        guard active != isMeetingActive else { return }
        isMeetingActive = active
        overlayInfo("MeetingDetector: meeting \(active ? "started (\(captor ?? "?"))" : "ended")")
        DispatchQueue.main.async { [weak self] in self?.onMeetingChanged?(active) }
    }

    /// Returns the bundle ID of a meeting app / browser currently capturing the
    /// microphone, or nil if none — i.e. "not in a meeting".
    static func meetingCaptor() -> String? {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &listAddr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return nil }
        var procs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &listAddr, 0, nil, &size, &procs) == noErr else { return nil }

        let prefixes = meetingBundlePrefixes + browserBundlePrefixes
        for p in procs {
            guard let bundle = bundleID(of: p),
                  prefixes.contains(where: { bundle.hasPrefix($0) }),
                  isCapturingInput(p) else { continue }
            return bundle
        }
        return nil
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(process, &addr, 0, nil, &sz) == noErr else { return nil }
        var bid: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &sz, &bid) == noErr else { return nil }
        return bid?.takeRetainedValue() as String?
    }

    private static func isCapturingInput(_ process: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &addr, 0, nil, &sz, &running) == noErr && running != 0
    }
}
