import Foundation

/// The whole decision of the 🔋 lid-closed keep-awake, pulled out of the timer
/// that drives it so it can be tested without a lid, a battery or a beep.
///
/// Three inputs, three outcomes, and the ordering between them is the part that
/// matters: **the battery floor is checked before the beep**, so the last tick
/// before standing down does not also emit a tick that suggests all is well.
enum LidAwakePolicy {

    /// Below this, the kernel flag comes back off and the Mac is allowed to
    /// fall asleep on its closed lid — the point of the whole exercise is a
    /// flight, and a flight that ends with a flat battery has failed.
    static let batteryFloorPercent = 20

    enum Action: Equatable {
        /// Lid shut, running off the battery: emit the quiet tick that says
        /// "still awake, still working".
        case beep
        /// Nothing to do — the lid is open, or we are on AC, or the feature is
        /// off. Awake either way; just not audibly.
        case quiet
        /// Clear `SleepDisabled` and untick the row: the battery has dropped to
        /// the floor.
        case standDown
    }

    /// - Parameter battery: percentage, or `nil` when it could not be read.
    ///   An unreadable battery is deliberately **not** a stand-down: the reader
    ///   failing is not evidence the charge is low, and taking the machine down
    ///   mid-flight on a missing number would be the worse of the two mistakes.
    static func decide(
        enabled: Bool,
        lidClosed: Bool,
        onAC: Bool,
        battery: Int?,
        floor: Int = batteryFloorPercent
    ) -> Action {
        guard enabled else { return .quiet }

        // On AC the floor is meaningless (the number only goes up) and the beep
        // would be pointless noise on a desk — this is the plugged-in clamshell
        // case macOS supports natively anyway.
        if onAC { return .quiet }

        if let battery, battery < floor { return .standDown }

        return lidClosed ? .beep : .quiet
    }
}
