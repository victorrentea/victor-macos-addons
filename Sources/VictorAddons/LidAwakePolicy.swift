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
        /// Nothing is working *and the pulse was audible* — lid shut, on
        /// battery, someone listening through a bag. Sound the 🫀 Pulse
        /// effect's flatline, then release exactly as above. The Mac is about
        /// to sleep and the pulse is the only thing that can say so: without
        /// this, the last thing the bag hears is a beat that is simply never
        /// followed by another, which is indistinguishable from the Mac having
        /// died.
        case farewell
        /// The battery floor. Clear the flag *and* untick the row.
        case standDown
    }

    /// - Parameter battery: percentage, or `nil` when it could not be read.
    ///   An unreadable battery is deliberately **not** a stand-down: the reader
    ///   failing is not evidence the charge is low, and taking the machine down
    ///   mid-flight on a missing number would be the worse of the two mistakes.
    /// - Parameter beating: whether the audible pulse was running as of the
    ///   previous tick. It is the only reason `.farewell` and `.release` differ:
    ///   the flatline is owed to an ear that was already being talked to, and
    ///   defaulting it to `false` keeps every caller that does not care on the
    ///   plain release.
    static func decide(
        enabled: Bool,
        claudeWorking: Bool,
        lidClosed: Bool,
        onAC: Bool,
        battery: Int?,
        beating: Bool = false,
        floor: Int = batteryFloorPercent
    ) -> Action {
        guard enabled else { return .release }

        // The floor is checked first, before anything can decide to hold or to
        // beat, so the tick that stands down does not also sound like a healthy
        // pulse. It does not apply on AC: at 4% and plugged in the number is
        // going up, and cutting the flag there would sleep the Mac for nothing.
        if !onAC, let battery, battery < floor { return .standDown }

        // The last Claude finished. If the pulse was audible right up to this
        // tick, the release is announced before it happens; otherwise there is
        // nobody to announce it to and the flag just comes off. Note this is
        // reached only while armed, so a deliberate disarm never sounds — the
        // flatline is for the sleep nobody asked for, not the one that was
        // clicked.
        guard claudeWorking else { return (beating && lidClosed && !onAC) ? .farewell : .release }

        return (lidClosed && !onAC) ? .beat : .hold
    }
}
