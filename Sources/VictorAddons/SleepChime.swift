import AVFoundation
import Foundation

/// Whether the 😴 chime may take the output up before it sounds, pulled out of
/// the runtime so the table is a test rather than a lid, a battery and a
/// CoreAudio device.
///
/// It is deliberately **not** a decision about whether to chime at all: that
/// one has no inputs. The Mac entering sleep always says so.
enum SleepChimePolicy {

    enum Boost: Equatable {
        /// Lid shut, on battery, nothing else sounding — the bag. Lift the mute
        /// and take the level up, exactly like `LidAwake.boostForBeats`.
        case boost
        /// Victor is at the machine and the screen is in front of him; the
        /// chime is a courtesy, not a proof, and it plays at whatever level he
        /// chose.
        case asIs
        /// Something else is playing. Its name, for the log line.
        case refuse(String)
    }

    /// - Parameter otherAppPlaying: the bundle id of any *other* app holding an
    ///   output stream, `nil` or empty when none — `SystemAudioActivity`'s
    ///   answer, passed in so the table is testable.
    static func boost(lidClosed: Bool, onAC: Bool, otherAppPlaying: String?) -> Boost {
        // On AC or with the lid open there is nothing to prove: the Mac is on a
        // desk, the sound carries at any level, and hijacking the volume of a
        // machine somebody is looking at is worse than a quiet chime.
        guard lidClosed, !onAC else { return .asIs }
        // Same refusal as the heartbeat's: unmuting a Mac with a stream open
        // ends with Victor's playlist at full blast in a bag.
        if let other = otherAppPlaying, !other.isEmpty { return .refuse(other) }
        return .boost
    }
}

/// **The sound the Mac makes as it falls asleep** (2026-09-22).
///
/// `LidAwake`'s heartbeat is the proof that the Mac is *staying up*: lid shut,
/// on battery, a Claude working, a lub-dub every ten seconds. What it never
/// had was the other half. Closing the lid and hearing nothing meant any of
/// four different things — the Mac slept; 😴 Claude insomnia was off; it was
/// armed but no session counted as working; or the feature itself was broken —
/// and Victor had to stand there for three or four seconds guessing which,
/// with the only distinguishing evidence being a silence he could not tell
/// apart from a silence.
///
/// One sound closes that. After the lid comes down there are now exactly two
/// audible outcomes, and **silence is no longer one of them**:
///
/// - 💓 the heartbeat → the Mac is awake and the session is running;
/// - 🚪 this door → the Mac is asleep, whatever the reason.
///
/// Silence now means something has actually gone wrong, which is the only
/// thing a missing signal should ever mean.
///
/// **It blocks the sleep, on purpose.** `NSWorkspace.willSleepNotification` is
/// delivered *before* the machine goes down and the system waits for its
/// observers to return, so the handler sounds the file and sits on the main
/// thread until it has finished. `AddonSounds.play` cannot be used for this:
/// it hops to the main queue with `async`, which here schedules the playback
/// for after the handler has returned — i.e. for a Mac that is already asleep.
///
/// **And it restores the audio before returning, not after.** The same trap
/// `LidAwake.hold` documents: a mute put back on the line after the sleep is a
/// mute that may never be put back, and a Mac that wakes at full volume in the
/// next meeting. Everything this touches is undone inside the handler, while
/// the machine is still awake to obey.
enum SleepChime {

    /// A heavy door closing. Picked against 🫀 `15_flatline.mp3` and 💓
    /// `13_heartbeat.mp3` on **confusability**, not on taste: through a closed
    /// bag the three signals have to be told apart by someone not looking, and
    /// a door is neither a lub-dub nor a continuous tone.
    static let file = "25_dark_door.mp3"

    /// Where the output goes for the bag case — the same 100% the heartbeat
    /// uses, and for the same reason: nobody is going to reach into a bag and
    /// turn it up.
    static let chimeSystemVolume: Float = 1.0

    /// Hard ceiling on how long sleep is made to wait. The file is ~1.5 s and
    /// the Bluetooth warm-up at most 1.2 s on top; the cap exists so a swapped
    /// file can never turn closing the lid into a wait.
    static let maxBlock: TimeInterval = 3.0

    /// Sound it. Call from `NSWorkspace.willSleepNotification`, on the main
    /// thread, and let it block.
    static func sound() {
        guard let url = AddonSounds.shared.soundURL(for: file) else {
            overlayError("SleepChime: \(file) not found — the Mac sleeps without a word")
            return
        }

        let decision = SleepChimePolicy.boost(
            lidClosed: LidAwake.isLidClosed(),
            onAC: PowerMonitor.isOnAC(),
            otherAppPlaying: SystemAudioActivity.otherAppPlayingOutput())

        var volumeToRestore: Float?
        var remuteOnTheWayOut = false

        switch decision {
        case .refuse(let who):
            overlayInfo("SleepChime: \(who) is playing — chiming at the level it is")
        case .asIs:
            break
        case .boost:
            // The mute first, for the reason `LidAwake.liftMute` gives: a level
            // parked at 100% on a muted Mac is 100% of silence, and a muted
            // lid-close is the ordinary one.
            if SystemOutputVolume.isMuted() == true, SystemOutputVolume.setMuted(false) {
                remuteOnTheWayOut = true
            }
            if let current = SystemOutputVolume.get(), current < chimeSystemVolume {
                volumeToRestore = current
                SystemOutputVolume.set(chimeSystemVolume)
            }
        }

        // Undone before the handler returns, whatever happens to the playback —
        // including the `catch` below.
        defer {
            if let volumeToRestore { SystemOutputVolume.set(volumeToRestore) }
            if remuteOnTheWayOut { SystemOutputVolume.setMuted(true) }
        }

        // A Bluetooth amp that has gone to sleep swallows the first half second,
        // which for a 1.5 s door is the half with the sound in it.
        let warmUp = AddonSounds.shared.currentBluetoothCompensation
        if warmUp > 0 { BluetoothOutput.playWakeTone(seconds: warmUp) }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 1.0
            player.prepareToPlay()
            player.play(atTime: player.deviceCurrentTime + warmUp)
            // Playback runs on CoreAudio's own thread, so parking this one is
            // what keeps the machine awake long enough to hear it.
            Thread.sleep(forTimeInterval: min(warmUp + player.duration + 0.15, maxBlock))
        } catch {
            overlayError("SleepChime: \(file) failed to play — \(error)")
        }
    }
}
