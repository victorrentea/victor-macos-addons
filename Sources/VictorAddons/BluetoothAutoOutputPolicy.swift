import Foundation

/// Pure decision for "the JBL speakers just connected — take over the output".
///
/// The trigger is a **device-list edge**, not a steady state: a Bluetooth
/// speaker only shows up among CoreAudio's devices while it is connected, so a
/// name that wasn't in the previous snapshot and is in the current one *is* a
/// fresh connection (a reconnect counts, since the device disappears in
/// between).
///
/// Acting on the edge — and only on the edge — is what keeps this from
/// fighting the user: once the JBL is connected, switching the output by hand
/// to the headphones or to the `🔊OS Output` loopback changes no device list,
/// so nothing pulls it back. The seed snapshot taken at startup is likewise an
/// edge we deliberately ignore, so relaunching the app never hijacks a chosen
/// output.
enum BluetoothAutoOutputPolicy {
    /// Shared with `BluetoothKeepAlive` — see `BluetoothOutput.speakerNameMatch`.
    static let nameMatch = BluetoothOutput.speakerNameMatch

    static func matches(_ name: String) -> Bool {
        name.range(of: nameMatch, options: .caseInsensitive) != nil
    }

    /// - Parameters:
    ///   - previous: matching output-device names in the last snapshot.
    ///   - current: matching output-device names now.
    ///   - defaultOutput: current default-output device name (`nil` if unreadable).
    /// - Returns: the device name to make default, or `nil` to do nothing.
    static func evaluate(previous: Set<String>, current: Set<String>, defaultOutput: String?) -> String? {
        // Sorted so a two-device appearance resolves deterministically.
        guard let appeared = current.subtracting(previous).sorted().first else { return nil }
        if let defaultOutput, defaultOutput == appeared { return nil }  // already there
        return appeared
    }
}
