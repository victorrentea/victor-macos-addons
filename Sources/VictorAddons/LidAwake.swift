import AppKit
import Foundation
import IOKit
import IOKit.ps

/// Whether the 🔋 lid-closed keep-awake is armed, surviving app restarts — the
/// row under 👩🏻‍💻 Extra. Default **off**: unlike 🔄 Reverse Mouse Wheel this
/// replaces nothing, and a Mac that silently refuses to sleep is not a state to
/// wake up in by accident.
enum LidAwakeSettings {
    static let enabledKey = "LidAwake.enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

/// Keeps the Mac running with the **lid shut, on battery, with nothing plugged
/// in** — the travel case: a `claude` session is mid-loop, the laptop goes in
/// the bag, and the work has to still be there on landing.
///
/// **`caffeinate` cannot do this and neither can an `IOPMAssertion`.** Every
/// assertion in the public power API — including the ones this app and Claude
/// Code already hold, visible in `pmset -g` — blocks *idle* sleep only. Closing
/// the lid is a different event (clamshell sleep) and no assertion vetoes it.
/// The one switch that does is the kernel's `SleepDisabled` flag, set through
/// `pmset -a disablesleep 1`, which `IOPMrootDomain` treats as a veto on sleep
/// *including* the lid-close path. Apple's own clamshell rules (external
/// display + keyboard + power adapter) are bypassed entirely, on battery, with
/// nothing attached. It is undocumented and Apple can take it away; it is also
/// exactly what Amphetamine's Closed-Display Mode is doing behind its UI, so
/// this file is Amphetamine minus the app.
///
/// **Why it needs root, and how little root it gets.** `pmset -a disablesleep`
/// is one of the handful of `pmset` verbs that will not run as the user. Rather
/// than a privileged helper or a deprecated `AuthorizationExecuteWithPrivileges`,
/// the app shells out to `sudo -n` against a single sudoers file,
/// `/etc/sudoers.d/victor-addons-disablesleep`, that whitelists the two exact
/// command lines with their arguments — `disablesleep 0` and `disablesleep 1` —
/// and nothing else. `-n` matters: without it a missing rule would leave the app
/// hanging on an invisible password prompt instead of failing in a log line.
///
/// **The tick is the proof.** The 5-second beep is not decoration. It is the
/// only signal that reaches Victor through a closed lid, and its absence is the
/// failure report: if the beeping stops before the battery floor, the Mac went
/// to sleep and the session died. That is why the beep is driven by the same
/// timer that enforces the floor rather than by a separate one — one timer,
/// one heartbeat, no way for the audible half to keep going after the safety
/// half has stopped running.
///
/// **The floor is enforced here, not by macOS.** With `SleepDisabled` set, the
/// normal low-battery sleep never fires, so a forgotten flag drains to empty.
/// At 20% the flag comes back off and the closed lid puts the Mac to sleep the
/// ordinary way, keeping whatever is left for the trip home.
final class LidAwake {

    /// Every 5 s: one beep if it should beep, and one look at the battery.
    private static let tickInterval: TimeInterval = 5

    /// A quiet tick. `NSSound.volume` is independent of the system output
    /// volume, so 0.2 here is 20% of whatever the speakers are set to — quiet
    /// enough to live in a bag, loud enough to hear in a quiet cabin.
    private static let beepVolume: Float = 0.2

    /// `SleepDisabled` can be cleared from outside (a `pmset restoredefaults`, a
    /// stray terminal). Re-checked once a minute rather than every tick so the
    /// steady state is one `pmset -g` a minute, not twelve.
    private static let verifyEveryTicks = 12

    /// Fires when the battery floor stood us down, so the menu tick can follow
    /// reality instead of claiming the Mac is still being held awake.
    var onAutoDisabled: ((Int) -> Void)?

    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private let queue = DispatchQueue(label: "ro.victorrentea.lidawake")

    // MARK: - Lifecycle

    /// Called once at launch. Re-arms across an app restart, which is the
    /// behaviour the rebuild loop needs: `pkill` + `open` in the middle of a
    /// flight must not drop the lid guard.
    func startIfEnabled() {
        guard LidAwakeSettings.isEnabled else { return }
        setEnabled(true, announce: false)
    }

    /// Arm or disarm. Returns whether the kernel agreed — a `false` means the
    /// sudoers rule is missing and the caller must not tick the row.
    @discardableResult
    func setEnabled(_ enabled: Bool, announce: Bool = true) -> Bool {
        LidAwakeSettings.isEnabled = enabled

        guard Self.setSleepDisabled(enabled) else {
            overlayError("LidAwake: pmset refused — is /etc/sudoers.d/victor-addons-disablesleep installed?")
            LidAwakeSettings.isEnabled = false
            stopTimer()
            return false
        }

        if enabled {
            overlayInfo("LidAwake armed — SleepDisabled=1, floor \(LidAwakePolicy.batteryFloorPercent)%")
            startTimer()
            if announce { beep(named: "Tink") }
        } else {
            overlayInfo("LidAwake disarmed — SleepDisabled=0")
            stopTimer()
        }
        return true
    }

    private func startTimer() {
        stopTimer()
        ticks = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        // A whole second of leeway on a 5-second timer lets the scheduler
        // coalesce this wake-up with others instead of waking the CPU alone,
        // which is the difference that matters when the point is battery life.
        t.schedule(deadline: .now() + Self.tickInterval,
                   repeating: Self.tickInterval,
                   leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - The tick

    private func tick() {
        ticks += 1

        let battery = Self.batteryPercent()
        let action = LidAwakePolicy.decide(
            enabled: LidAwakeSettings.isEnabled,
            lidClosed: Self.isLidClosed(),
            onAC: PowerMonitor.isOnAC(),
            battery: battery)

        switch action {
        case .quiet:
            break

        case .beep:
            beep(named: "Tink")

        case .standDown:
            let pct = battery ?? -1
            overlayInfo("LidAwake: battery \(pct)% below floor — letting the lid sleep the Mac")
            // Three beeps, then silence: the pattern says "this was the floor",
            // not "the Mac died", which is what a plain stop would have sounded
            // like from inside a closed bag.
            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) { [weak self] in
                    self?.beep(named: "Basso")
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.setEnabled(false, announce: false)
                self?.onAutoDisabled?(pct)
            }
            return
        }

        // Cheap paranoia, once a minute: if something else cleared the flag we
        // are beeping a lie, and the next lid close would sleep the machine.
        if ticks % Self.verifyEveryTicks == 0, LidAwakeSettings.isEnabled, !Self.isSleepDisabled() {
            overlayError("LidAwake: SleepDisabled was cleared behind our back — re-asserting")
            _ = Self.setSleepDisabled(true)
        }
    }

    private func beep(named name: String) {
        DispatchQueue.main.async {
            // A fresh NSSound per beep: a shared instance that is still playing
            // ignores `play()`, and a swallowed beep here reads as a Mac that
            // has gone to sleep.
            guard let sound = NSSound(named: NSSound.Name(name)) else { return }
            sound.volume = Self.beepVolume
            sound.play()
        }
    }

    // MARK: - The kernel flag

    /// `sudo -n pmset -a disablesleep 0|1`, then read the flag back rather than
    /// trusting the exit status — the menu tick must mean what it says.
    @discardableResult
    static func setSleepDisabled(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            overlayError("LidAwake: could not run pmset — \(error)")
            return false
        }
        guard p.terminationStatus == 0 else { return false }
        return isSleepDisabled() == on
    }

    /// Reading the flag needs no privileges — `pmset -g` prints `SleepDisabled`
    /// only once it has been set, so a missing line is a clear 0.
    static func isSleepDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return false }
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(separator: " ").last == "1"
        }
        return false
    }

    // MARK: - Lid and battery

    /// `AppleClamshellState` on `IOPMrootDomain` — true while the lid is shut.
    /// The registry is read directly rather than shelling out to `ioreg`,
    /// because this runs every five seconds for hours on a battery.
    static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool else { return false }
        return value
    }

    /// Charge as a percentage, or `nil` if no battery answered.
    static func batteryPercent() -> Int? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as! [CFTypeRef]
        for src in list {
            guard let desc = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int,
                  max > 0 else { continue }
            return Int((Double(current) / Double(max) * 100).rounded())
        }
        return nil
    }
}
