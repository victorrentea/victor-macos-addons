import CoreAudio
import Foundation

/// **The system's microphone is the one this app listens on.**
///
/// Victor (2026-11-13), after ChatGPT's voice turned out to listen on the
/// MacBook's microphone with the XLR on the desk: *"vreau ca addons să mențină
/// doar el microfonul sistemului pe ce ascultă și el, după regulile noastre.
/// Nu walkie"* — Walkie Talkie did it for an hour that evening; it is this
/// app's alone now.
///
/// *Our rules* are the ones Whisper's source already follows: the pick in
/// `~/.walkie-talkie/mic/choice` (`MicPreference`) when that microphone is
/// plugged in, else the first rung of `MicRoster` that is — XLR ▸ DJI ▸ Stage
/// ▸ Bose ▸ Mac — and never a `HeadphoneMicGuard`-banned or
/// `MicRoster.neverRecord` headset. With none of the roster present the
/// default is left where it is (the guard alone moves it off a banned one).
///
/// So everything that listens on "the system microphone" — ChatGPT's voice, a
/// browser tab, Zoom/Teams on *Same as System* — hears the microphone the
/// transcription hears, and macOS promoting whatever was plugged in last no
/// longer sticks.
///
/// Driven by `MicSourceAnnouncer` (the default moved, the device list
/// changed) and by `adoptMicChoice` (the pick changed). **Hands off** while
/// `~/.walkie-talkie/mic/default-hold` is younger than ten minutes: Walkie
/// Talkie's desk harness (`POST /test/input`) points the default at a device
/// on purpose and touches that file. Three moves in ten seconds means
/// something else insists on another input — then it is left alone a minute.
/// Off: `defaults write ro.victorrentea.macos-addons systemMicFollows -bool false`.
enum SystemMicKeeper {

    static var isOn: Bool { UserDefaults.standard.object(forKey: "systemMicFollows") as? Bool ?? true }

    static var holdFile: URL { MicPreference.folder.appendingPathComponent("default-hold") }
    static let holdFor: TimeInterval = 600

    /// The input the system default should be on, or nil to leave it alone.
    /// Pure, so the choice is testable.
    static func target(choice: String, inputs: [String]) -> String? {
        let allowed = inputs.filter { !HeadphoneMicGuard.isBanned($0) && !MicRoster.isNeverRecord($0) }
        if let picked = MicRoster.byId(choice), let hit = allowed.first(where: { $0.contains(picked.pattern) }) {
            return hit
        }
        for mic in MicRoster.all {
            if let hit = allowed.first(where: { $0.contains(mic.pattern) }) { return hit }
        }
        return nil
    }

    static func held(now: Date = Date()) -> Bool {
        guard let touched = (try? FileManager.default.attributesOfItem(atPath: holdFile.path))?[.modificationDate] as? Date
        else { return false }
        return now.timeIntervalSince(touched) < holdFor
    }

    private static let lock = NSLock()
    private static var recent: [Date] = []
    private static var quietUntil = Date.distantPast

    /// Put the default input on the target. Returns whether it moved it — the
    /// move re-fires the announcer's listener.
    @discardableResult
    static func enforce(why: String) -> Bool {
        guard isOn, !held() else { return false }
        let inputs = HeadphoneMicGuard.inputDevices()
        guard let name = target(choice: MicPreference.read(), inputs: inputs.map(\.name)),
              let targetId = inputs.first(where: { $0.name == name })?.id else { return false }
        let currentId = MicSourceAnnouncer.defaultInputId()
        guard currentId != targetId else { return false }
        let now = Date()
        lock.lock()
        if now < quietUntil { lock.unlock(); return false }
        recent = recent.filter { now.timeIntervalSince($0) < 10 }
        if recent.count >= 3 {
            quietUntil = now.addingTimeInterval(60)
            lock.unlock()
            overlayError("🎙️ System mic: moved back 3 times in 10 s — something else wants \(MicSourceAnnouncer.name(of: currentId) ?? "another input"); left alone for a minute")
            return false
        }
        recent.append(now)
        lock.unlock()
        let was = MicSourceAnnouncer.name(of: currentId) ?? "none"
        guard HeadphoneMicGuard.setDefaultInput(targetId) else {
            overlayError("🎙️ System mic: could not move the default input from \(was) to \(name)")
            return false
        }
        overlayInfo("🎙️ System mic: \(was) → \(name) (\(why))")
        return true
    }
}
