import Foundation

/// The whole decision of 🔋 Claude prevents sleep, pulled out of
/// the timer that drives it so it can be tested without a lid, a battery, a
/// process table or a beep.
///
/// **Two kinds of "stop", and they are not the same.** Claude going quiet is a
/// *soft* release: the kernel flag comes off, the Mac is allowed to sleep, and
/// the row **stays ticked** because the feature is still watching — the next
/// session to start work re-arms it without Victor touching anything. The
/// battery floor is a *hard* stand-down: the flag comes off and the feature
/// disarms itself, because continuing to watch would mean re-arming at 19%.
enum LidAwakePolicy {

    /// Below this, the flag comes off for good and the Mac is allowed to fall
    /// asleep on its closed lid — the point of the whole exercise is a flight,
    /// and a flight that ends with a flat battery has failed.
    static let batteryFloorPercent = 20

    enum Action: Equatable {
        /// A Claude is working, the lid is shut and we are on battery: hold the
        /// flag and sound the heartbeat.
        case beat
        /// A Claude is working, but the lid is open or we are on AC. Hold the
        /// flag, stay silent — a pulse every 10 s at the desk would make the
        /// feature unusable, and on AC this is the clamshell case macOS
        /// supports natively anyway.
        case hold
        /// Nothing is working. Clear the flag and let the Mac sleep, but keep
        /// watching: this is the ordinary end of a session, not a fault.
        case release
        /// The battery floor. Clear the flag *and* untick the row.
        case standDown
    }

    /// - Parameter battery: percentage, or `nil` when it could not be read.
    ///   An unreadable battery is deliberately **not** a stand-down: the reader
    ///   failing is not evidence the charge is low, and taking the machine down
    ///   mid-flight on a missing number would be the worse of the two mistakes.
    static func decide(
        enabled: Bool,
        claudeWorking: Bool,
        lidClosed: Bool,
        onAC: Bool,
        battery: Int?,
        floor: Int = batteryFloorPercent
    ) -> Action {
        guard enabled else { return .release }

        // The floor is checked first, before anything can decide to hold or to
        // beat, so the tick that stands down does not also sound like a healthy
        // pulse. It does not apply on AC: at 4% and plugged in the number is
        // going up, and cutting the flag there would sleep the Mac for nothing.
        if !onAC, let battery, battery < floor { return .standDown }

        guard claudeWorking else { return .release }

        return (lidClosed && !onAC) ? .beat : .hold
    }
}
