import Foundation

/// The whole decision of 🏠 Home Wi-Fi keeps the screen on, pulled out of the
/// CoreWLAN event and the timer that drive it so it can be tested without a
/// Wi-Fi radio, a house, or an idle screen.
///
/// It is one line of logic, and it is written down anyway because the *nil* case
/// is the one that matters and it is not obvious which way it should go.
enum HomeAwakePolicy {

    /// - Parameter ssid: what the interface reports, or `nil` when CoreWLAN will
    ///   not say — Wi-Fi off, no Wi-Fi interface, or Location Services withheld.
    ///   `HotspotFallback` learned the hard way (11 Sep 2026) that "don't know"
    ///   must never be read as a confident answer, so here it resolves to **not
    ///   home**: the wrong way round would hold the display awake indefinitely
    ///   on a Mac that has simply turned its Wi-Fi off, which is precisely the
    ///   leaked-assertion failure this feature must not have. Refusing to hold
    ///   costs a screen that locks at home; holding wrongly costs a screen that
    ///   never locks anywhere.
    /// - Parameter homeSSIDs: the configured home networks. Matched **exactly** —
    ///   no case folding, no prefix. The live network is `tzutze` and its
    ///   neighbours in the preferred list are `tzutze5`, `tzutze2.4` and
    ///   `tzutze_5G`; a prefix match would silently adopt all four, and whether
    ///   those count is a decision for the config, not for this function.
    static func shouldHoldDisplayAwake(enabled: Bool, ssid: String?, homeSSIDs: [String]) -> Bool {
        guard enabled, let ssid, !ssid.isEmpty else { return false }
        return homeSSIDs.contains(ssid)
    }

    /// Parses the `UserDefaults` string into the list above: comma-separated,
    /// trimmed, empties dropped. Kept here rather than in the settings accessor
    /// so the parsing is covered by the same tests as the matching — a stray
    /// space around a comma silently disarming the feature is the sort of thing
    /// nobody would ever think to check by hand.
    static func parseSSIDs(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
