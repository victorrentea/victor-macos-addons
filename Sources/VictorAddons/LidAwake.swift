import AppKit
import AVFoundation
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
/// **The heartbeat is the proof.** The lub-dub every 10 seconds is not
/// decoration. It is the only signal that reaches Victor through a closed lid,
/// and its absence is the failure report: if the pulse stops before the battery
/// floor, the Mac went to sleep and the session died. That is why it is driven
/// by the same timer that enforces the floor rather than by a separate one —
/// one timer, one heartbeat, no way for the audible half to keep going after
/// the safety half has stopped running.
///
/// **A proof nobody can hear is not a proof, so the beats set their own
/// volume** (2026-09-09). The moment the pulse starts — lid shut, on battery, a
/// Claude working — the system output goes **all the way up** and whatever it
/// was before is remembered; the moment it stops, for any reason, that number
/// goes back. The laptop is in a bag by then and nobody is going to reach in
/// and turn it up, and the level it happened to be left at when the lid came
/// down has nothing to do with how loud a bag needs. **Only onto silence,
/// though**: if another app is playing, the volume is left alone rather than
/// turning the lid close into a full-blast concert. See `boostForBeats`.
///
/// **It follows Claude, it does not just switch sleep off.** Every tick asks
/// whether any Claude Code session is actually working (`ClaudeActivity` — a
/// live `caffeinate` with a `claude` parent). While one is, the flag is up and
/// the lid stays open; when the last one finishes, the flag comes down and the
/// Mac is free to sleep on its own. The row stays ticked through that, because
/// the next session to start work should re-arm it with nobody clicking
/// anything. Arming therefore means "watch", not "hold awake now".
///
/// **The floor is enforced here, not by macOS.** With `SleepDisabled` set, the
/// normal low-battery sleep never fires, so a forgotten flag drains to empty.
/// At 20% the flag comes off *and the row unticks* — unlike the Claude gate,
/// this one is a hard stop, because continuing to watch would mean re-arming at
/// 19%.
final class LidAwake {

    /// Every 10 s: one heartbeat if it should beat, and one look at the battery.
    private static let tickInterval: TimeInterval = 10

    /// **A real heartbeat, not two synthesised blips.** The 💓 desktop effect
    /// already ships one — `13_heartbeat.mp3`, 7.1 s of continuous pulse in the
    /// tablet's shared sounds folder — and a recording of an actual heart is
    /// unmistakably a heart, where two system `Pop`s are two clicks that have
    /// to be *explained* as a heartbeat.
    ///
    /// **A single repeating blip is a machine noise** and the ear files it away
    /// with the fridge; a lub-dub is a *pulse*, and a pulse that stops is
    /// noticed without anyone having to listen for it. That is the entire job
    /// of this sound — a liveness signal for a laptop nobody can see into, so
    /// it has to be the kind of sound whose absence registers.
    private static let beatFile = "13_heartbeat.mp3"

    /// One lub-dub cut out of that loop. The onsets are in
    /// `heartbeat_beats.json`, the same file the 💓 effect zooms to: the first
    /// pair lands at 0.59 s and 0.805 s, and the next at 1.335 s. So 0.50 →
    /// 1.05 is exactly one beat with a little air either side and no clipping
    /// of the one that follows.
    private static let beatStart: TimeInterval = 0.50
    private static let beatLength: TimeInterval = 0.55

    /// **The flatline**, played once when the work finishes and the flag is
    /// about to come off — `15_flatline.mp3`, the sound behind the 🫀 Pulse
    /// desktop effect (`SoundEffectMap`: `15_flatline.mp3` → `"pulse"`), played
    /// whole rather than cut: two last QRS beats and then the long tone.
    ///
    /// **Because it is the one ending a pulse can have.** Every beat above
    /// means "still alive" and the *absence* of one is the failure report, so
    /// the healthy finish needed a sound of its own — and a run of more beats,
    /// whatever its length, is still the same lub-dub the bag has been hearing
    /// all along, told apart from a live pulse only by counting. A flatline is
    /// not a quantity of heartbeats, it is the opposite of one: unmistakable
    /// through a closed bag on the first hearing, with no counting and nothing
    /// to explain.
    private static let farewellFile = "15_flatline.mp3"

    /// Its full length, 5.25 s (`afinfo`), rounded up so the tone is never cut
    /// off by the release that follows it.
    private static let farewellLength: TimeInterval = 5.30

    /// **Never quieter than the pulse.** It was 0.8 against a pulse of 0.2 —
    /// louder, deliberately, because it plays once and is the last thing the
    /// bag ever says. Now that the pulse itself is at full scale (below), 0.8
    /// would make the ending *quieter* than the beats it ends, which is the one
    /// thing this sound cannot be.
    private static let farewellVolume: Float = 1.0

    /// The two QRS beats the flatline opens with, at the recording's own
    /// spacing — used only by the fallback below.
    private static let farewellBeatPeriod: TimeInterval = 1.40

    /// Fallback if the shared sounds folder is not there (it is a symlink into
    /// the Android app's assets, dereferenced into the bundle by
    /// `build-app.sh`, so it can go missing in a dev build). Two `Pop`s 0.28 s
    /// apart — where real hearts sit; much tighter reads as a stutter, much
    /// wider as two separate events rather than one pulse.
    private static let fallbackBeatSound = "Pop"
    private static let beatGap: TimeInterval = 0.28

    /// **Full scale** (2026-09-10). `NSSound.volume` is a fraction of the system
    /// output volume, and the pulse used to take a discreet fifth of it: the
    /// beats were parking the output at 100% themselves, so a fifth of a machine
    /// turned all the way up was still plenty. That premise is gone — the boost
    /// is now refused whenever something else is playing, and 20% of an output
    /// left at 13 is nothing at all. The file is a recording of a heart, not a
    /// tone, so at 1.0 it is a heartbeat rather than an alarm, and this is the
    /// only volume that behaves the same whether or not the boost happened.
    private static let beepVolume: Float = 1.0
    /// The second beat is quieter than the first, the way a real one is — the
    /// same 0.7 of the first it has always been. Fallback only: the real
    /// recording has both beats in it.
    private static let secondBeatVolume: Float = 0.7

    /// Where the **system** output volume is parked while the beats are running:
    /// **all the way up**. `beepVolume` above is a fraction *of* this, so the
    /// two multiply — and with the beat now at 1.0, a boosted pulse is the
    /// machine at full scale, which is the only setting that makes sense for a
    /// laptop that is already in the bag. 80% was the first number here and it
    /// was not enough: there is no volume knob inside a rucksack, and a proof
    /// nobody can hear is not a proof.
    private static let beatSystemVolume: Float = 1.0

    /// `SleepDisabled` can be cleared from outside (a `pmset restoredefaults`, a
    /// stray terminal). Re-checked once a minute rather than every tick so the
    /// steady state is one `pmset -g` a minute, not six.
    private static let verifyEveryTicks = 6

    /// Fires when the battery floor stood us down, so the menu tick can follow
    /// reality instead of claiming the Mac is still being held awake.
    var onAutoDisabled: ((Int) -> Void)?

    private var timer: DispatchSourceTimer?
    private var cachedBeatPlayer: AVAudioPlayer?
    /// Kept alive only while the flatline is playing — see `lastBeats()`.
    private var farewellPlayer: AVAudioPlayer?
    /// What we believe the kernel flag is, so `hold` can skip a `sudo` spawn
    /// when nothing has changed. Seeded from the kernel, never assumed.
    private var holding = false
    /// The system volume as it was before the beats raised it — `nil` whenever we
    /// have not raised it, which is also what makes the restore idempotent.
    private var volumeBeforeBeats: Float?
    /// Set while the boost is being refused because something else is playing,
    /// so the reason is logged once per streak rather than six times a minute.
    private var boostRefused = false
    /// Whether the audible pulse was running as of the last tick — the one
    /// input that tells a release owed five last beats from a release nobody
    /// could have heard (lid open, on AC, or never beating at all).
    private var wasBeating = false
    /// Set while the five last beats are in the air, so a tick landing in the
    /// middle of them cannot start a second set on top of the first.
    private var farewellInFlight = false
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
    ///
    /// Note what arming does **not** mean: it does not mean "hold the Mac awake
    /// now". It means "watch, and hold it awake whenever a Claude is working".
    /// The first tick runs inline, so if nothing is working the flag is back
    /// down before the click has finished — the row ticked, the Mac free to
    /// sleep, which is the honest state.
    @discardableResult
    func setEnabled(_ enabled: Bool, announce: Bool = true) -> Bool {
        LidAwakeSettings.isEnabled = enabled
        // The flag can already be up from before an app restart, so start from
        // what the kernel says rather than from an assumption.
        holding = Self.isSleepDisabled()

        guard enabled else {
            hold(false)
            boostForBeats(false)
            wasBeating = false
            stopTimer()
            overlayInfo("LidAwake disarmed")
            return true
        }

        // Arming is the only moment there is a person watching, so it is the
        // only moment a missing sudoers rule can be reported. Prove the flag
        // actually moves before ticking the row.
        guard Self.setSleepDisabled(true) else {
            overlayError("LidAwake: pmset refused — is /etc/sudoers.d/victor-addons-disablesleep installed?")
            LidAwakeSettings.isEnabled = false
            boostForBeats(false)
            stopTimer()
            return false
        }
        holding = true
        overlayInfo("LidAwake armed — watching for working Claude sessions, floor \(LidAwakePolicy.batteryFloorPercent)%")
        startTimer()
        // Arming plays the same lub-dub the bag will hear, not a different
        // confirmation chime: the click is also the volume check.
        if announce { heartbeat() }
        // Land in the right state now rather than ten seconds from now.
        tick()
        return true
    }

    private func startTimer() {
        stopTimer()
        ticks = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        // A whole second of leeway on a 10-second timer lets the scheduler
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
            claudeWorking: ClaudeActivity.isClaudeWorking(),
            lidClosed: Self.isLidClosed(),
            onAC: PowerMonitor.isOnAC(),
            battery: battery,
            beating: wasBeating)

        switch action {
        case .beat:
            hold(true)
            boostForBeats(true)
            heartbeat()
            wasBeating = true

        case .hold:
            // The lid is open (or we are on AC): nobody is listening through a
            // bag any more, so the volume goes back to whatever it was — and
            // no five last beats are owed, for the same reason.
            hold(true)
            boostForBeats(false)
            wasBeating = false

        case .release:
            // The ordinary end of a session: the work is done, so stop holding
            // the lid open. The row stays ticked — the next session to start
            // work re-arms this without Victor touching anything.
            hold(false)
            boostForBeats(false)
            wasBeating = false

        case .farewell:
            // Same release, announced first: the pulse was audible right up to
            // this tick, so the bag is told the Mac is going down instead of
            // just never hearing another beat.
            wasBeating = false
            farewell()

        case .standDown:
            let pct = battery ?? -1
            wasBeating = false
            overlayInfo("LidAwake: battery \(pct)% below floor — letting the lid sleep the Mac")
            // Three beeps, then silence: the pattern says "this was the floor",
            // not "the Mac died", which is what a plain stop would have sounded
            // like from inside a closed bag.
            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) { [weak self] in
                    self?.beep(named: "Basso")
                }
            }
            // The disarm waits for the beeps rather than racing them: it is
            // `setEnabled(false)` that puts the volume back, and these three
            // Bassos are the last thing the bag ever says — they have to go out
            // at the volume the beats were going out at.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.setEnabled(false, announce: false)
                self?.onAutoDisabled?(pct)
            }
            return
        }

        // Cheap paranoia, once a minute: if something else cleared the flag
        // while we believe we are holding it, we are beating a lie and the next
        // lid close would sleep the machine mid-session.
        if ticks % Self.verifyEveryTicks == 0, holding, !Self.isSleepDisabled() {
            overlayError("LidAwake: SleepDisabled was cleared behind our back — re-asserting")
            _ = Self.setSleepDisabled(true)
        }
    }

    /// Raise or drop the kernel flag, **only on a change**. The tick runs every
    /// ten seconds; `sudo pmset` is a process spawn, and spawning one six times
    /// a minute to re-state a value that has not moved is exactly the kind of
    /// waste that shows up in the only number this feature is judged by.
    private func hold(_ wanted: Bool) {
        guard wanted != holding else { return }
        guard Self.setSleepDisabled(wanted) else {
            overlayError("LidAwake: pmset refused while trying to set disablesleep=\(wanted ? 1 : 0)")
            return
        }
        holding = wanted
        overlayInfo(wanted
            ? "LidAwake: a Claude is working — holding the lid open"
            : "LidAwake: no Claude working — releasing, the Mac may sleep")
        // Clearing the flag is *permission* to sleep, not a sleep. The kernel
        // decides about a lid at the moment it closes; a veto withdrawn any
        // time after that is not a second close, so the Mac can sit awake in a
        // bag with the lid shut until some idle timer eventually gets to it.
        // With the lid already down and nothing left holding it open, the sleep
        // it was promised is asked for explicitly.
        if !wanted, Self.isLidClosed(), !PowerMonitor.isOnAC() { Self.sleepNow() }
    }

    /// `pmset sleepnow` — the one `pmset` verb here that needs no privileges,
    /// so no sudoers rule and no `-n` games.
    ///
    /// Only ever called with **the lid shut and on battery**, which is the state
    /// macOS itself sleeps a Mac in: this only gets there first. On AC it is
    /// never called, because clamshell-on-power is the case Apple supports
    /// natively and a projector plugged into a closed laptop mid-workshop must
    /// not be put to sleep by a heartbeat feature.
    private static func sleepNow() {
        overlayInfo("LidAwake: lid is shut and nothing is holding it — pmset sleepnow")
        do {
            try Process.run(URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["sleepnow"])
        } catch {
            overlayError("LidAwake: pmset sleepnow failed — \(error)")
        }
    }

    /// Park the **system** output volume at maximum for as long as the beats
    /// run, and put back exactly what was there when they stop.
    ///
    /// Only the false→true edge captures the old value, the same discipline
    /// `CoreAudioManager.pushVolumeDown` follows and for the same reason: a second
    /// capture while already raised would save 80% as "the original" and the
    /// restore would then be a no-op forever.
    ///
    /// **Raise only**, which at 100% now only ever means "already there": the
    /// guard stays because it is what keeps the restore symmetric, and because
    /// the target is a constant that has moved once already.
    ///
    /// **And only onto silence** (2026-09-10). If any other app is running an
    /// output stream, the volume is left exactly where it is and the beats play
    /// at that level: taking a machine that is *playing music* to 100% is not a
    /// louder proof, it is Victor's playlist at full blast in a bag or in the
    /// room. Nothing is captured either, so this is retried on every tick — the
    /// moment the music stops, the boost happens by itself.
    ///
    /// Restoring is one tick behind the lid, up to ten seconds: opening the lid is
    /// not an event this watches, the timer notices it. One loud beat may land in
    /// the room before the volume comes down, which is the same resolution the
    /// whole feature runs at.
    ///
    /// A device with no settable volume (some aggregates, some interfaces) leaves
    /// `volumeBeforeBeats` nil and the beats simply play at whatever the machine
    /// is set to — the pulse is worth more than the level.
    private func boostForBeats(_ wanted: Bool) {
        if wanted {
            guard volumeBeforeBeats == nil else { return }
            // Never raise the volume onto something that is already playing.
            if let playing = SystemAudioActivity.otherAppPlayingOutput() {
                if !boostRefused {
                    boostRefused = true
                    overlayInfo("LidAwake: \(playing) is playing — leaving the output volume where it is")
                }
                return
            }
            boostRefused = false
            guard let current = SystemOutputVolume.get() else { return }
            volumeBeforeBeats = current
            guard current < Self.beatSystemVolume else { return }
            SystemOutputVolume.set(Self.beatSystemVolume)
            overlayInfo("LidAwake: output \(Int((current * 100).rounded()))% → \(Int(Self.beatSystemVolume * 100))% so the heartbeat carries")
        } else {
            boostRefused = false
            guard let previous = volumeBeforeBeats else { return }
            volumeBeforeBeats = nil
            SystemOutputVolume.set(previous)
            overlayInfo("LidAwake: output back to \(Int((previous * 100).rounded()))%")
        }
    }

    /// One lub-dub, cut live out of the 💓 effect's loop.
    ///
    /// The player is built once and rewound, not recreated per beat: this fires
    /// every ten seconds for hours on a battery, and decoding the same 42 KB
    /// file 360 times an hour to hear half a second of it is the kind of waste
    /// that shows up in the only number this feature is judged by.
    private func heartbeat() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            guard let player = self.beatPlayer() else {
                // No shared sounds folder — fall back to two system clicks.
                self.beep(named: Self.fallbackBeatSound, volume: Self.beepVolume)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.beatGap) { [weak self] in
                    self?.beep(named: Self.fallbackBeatSound, volume: Self.secondBeatVolume)
                }
                return
            }

            player.stop()
            player.currentTime = Self.beatStart
            player.volume = Self.beepVolume
            player.play()
            // AVAudioPlayer has no "play this range", so the beat is ended by
            // the clock. Without this it would run on into the next four beats
            // of the loop and the 10-second silence — the part that carries the
            // signal — would never arrive.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.beatLength) { [weak player] in
                player?.stop()
            }
        }
    }

    /// The flatline, then the flag comes off.
    ///
    /// **Why the release is announced at all.** Every other beat means "still
    /// alive"; the *absence* of a beat is what carries the failure report, and
    /// from inside a closed bag a healthy finish and a dead Mac sound exactly
    /// the same — silence. So the ordinary end of the work gets its own sound,
    /// and the 🫀 Pulse effect's flatline is the one sound that cannot be
    /// mistaken for the pulse it ends: two last beats and a long tone. That is
    /// a heart stopping on purpose, distinguishable from one that was
    /// interrupted, the same way the three `Basso`s make the battery floor
    /// distinguishable from both.
    ///
    /// **The tone goes out before the flag drops, not after.** `hold(false)` is
    /// what lets macOS sleep the closed lid, and it can take effect
    /// immediately — releasing first would cut the announcement off partway
    /// through, and a flatline that stops early is exactly the truncated shape
    /// that reads as a crash. Same discipline as the floor's three beeps, which
    /// delay their disarm rather than race it.
    private func farewell() {
        guard !farewellInFlight else { return }
        farewellInFlight = true
        overlayInfo("LidAwake: no Claude working — flatline, then the Mac may sleep")
        lastBeats()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.farewellLength + 0.2) { [weak self] in
            guard let self else { return }
            self.farewellPlayer = nil
            self.queue.async {
                self.farewellInFlight = false
                // A session that woke up while the flatline was playing keeps
                // the lid open: the flag must never come off underneath a
                // Claude that is working again, and five seconds is long enough
                // for that to happen. Leaving `holding` alone here is the whole
                // fix — the next tick sees `.beat` and simply carries on.
                guard !ClaudeActivity.isClaudeWorking() else {
                    overlayInfo("LidAwake: a Claude started again during the flatline — still holding")
                    return
                }
                self.hold(false)
                // Only now does the system volume go back: the flatline is the
                // last thing the bag ever says and has to go out at the level
                // the pulse was going out at.
                self.boostForBeats(false)
            }
        }
    }

    /// The 🫀 Pulse effect's flatline, played whole, once.
    ///
    /// Nothing is cut here and nothing is stopped by the clock: unlike the
    /// heartbeat loop, this file *is* the event — two QRS beats and then the
    /// tone that does not end in another beat — so it plays start to finish and
    /// the release simply waits for it.
    ///
    /// Built fresh rather than cached like `beatPlayer()`: this runs once at the
    /// end of a session, not 360 times an hour, and holding a decoded 72 KB file
    /// for hours to use it once is the waste the cache exists to avoid.
    private func lastBeats() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            guard let url = SoundManager.shared.soundURL(for: Self.farewellFile),
                  let player = try? AVAudioPlayer(contentsOf: url) else {
                // No shared sounds folder (a dev build — it is a symlink into
                // the Android app's assets). macOS ships no flat tone, so the
                // fallback is the two beats the recording opens with, at its
                // own spacing, and then `Submarine` held under them as the
                // nearest thing to a long low note.
                overlayError("LidAwake: \(Self.farewellFile) not found — falling back to system sounds")
                for i in 0..<2 {
                    let at = Double(i) * Self.farewellBeatPeriod
                    DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                        self?.beep(named: Self.fallbackBeatSound, volume: Self.farewellVolume)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + at + Self.beatGap) { [weak self] in
                        self?.beep(named: Self.fallbackBeatSound, volume: Self.farewellVolume)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.farewellBeatPeriod * 2) { [weak self] in
                    self?.beep(named: "Submarine", volume: Self.farewellVolume)
                }
                return
            }

            // Held for the length of the clip: an AVAudioPlayer nobody retains
            // is deallocated the moment this closure returns and the sound
            // never arrives.
            self.farewellPlayer = player
            player.volume = Self.farewellVolume
            player.play()
        }
    }

    /// Lazily built, then kept. `nil` means the file could not be resolved.
    private func beatPlayer() -> AVAudioPlayer? {
        if let cached = cachedBeatPlayer { return cached }
        guard let url = SoundManager.shared.soundURL(for: Self.beatFile),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            overlayError("LidAwake: \(Self.beatFile) not found — falling back to system clicks")
            return nil
        }
        player.prepareToPlay()
        cachedBeatPlayer = player
        return player
    }

    private func beep(named name: String, volume: Float = LidAwake.beepVolume) {
        DispatchQueue.main.async {
            // A fresh NSSound per beat: a shared instance that is still playing
            // ignores `play()`, which would silently swallow the second beat —
            // and here a swallowed beat reads as a Mac that has gone to sleep.
            guard let sound = NSSound(named: NSSound.Name(name)) else { return }
            sound.volume = volume
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
        guard isSleepDisabled() == on else {
            // pmset exited 0 but the flag does not agree. Whatever went wrong,
            // do not walk away having armed a kernel flag the menu is about to
            // report as off — an unticked row over a live SleepDisabled is a
            // Mac that never sleeps again and nothing on screen to say so.
            if on { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/sudo"),
                                         arguments: ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]) }
            return false
        }
        return true
    }

    /// Reading the flag needs no privileges. `pmset -g` prints `SleepDisabled`
    /// only once it has been set at least once since boot, so a missing line is
    /// a clear 0 — and once present it stays, reading `0` after a clear.
    ///
    /// **The columns are tab-separated, not space-separated** (` SleepDisabled
    /// \t\t 1`). Splitting on `" "` alone yields one token for the whole line,
    /// whose `last` is never `"1"` — which is the bug that shipped in the first
    /// version: the flag was set correctly, the read-back said otherwise, the
    /// toggle reported failure and left the row unticked over a live flag.
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
        return parseSleepDisabled(fromPmsetOutput: out)
    }

    /// The parse, separated from the process so the tab format is pinned by a
    /// test rather than by a shell one-liner that happened to use `grep`.
    static func parseSleepDisabled(fromPmsetOutput out: String) -> Bool {
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1"
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
