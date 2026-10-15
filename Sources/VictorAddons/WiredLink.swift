import Foundation
import SystemConfiguration

/// ‹···› Is the cable giving this Mac a network? — a readout row at the top
/// level of the 💬 menu (2026-10-08 in Extras, top level since 2026-10-10). It replaces **Ethernet Menubar**, a third-party
/// status item whose whole job was this one fact, and which cost a slot in an
/// already crowded menu bar to answer a question asked twice a day: on arrival
/// in a training room, and when the room's Wi-Fi starts dropping.
///
/// Read on every menu open, never polled — the row is only seen with the menu
/// open, so that is the one moment it has to be right.
enum WiredLinkState: Equatable {
    /// Link up and a routable IPv4 address.
    case connected(ip: String)
    /// Cable in, link up, but no address yet — DHCP still asking, or the
    /// network never answered (a 169.254.x.x self-assigned address lands here).
    case noAddress
    /// No wired port has a link: cable out, or no adapter plugged at all.
    case disconnected
}

/// The decision, without the SystemConfiguration reads — so it can be tested.
enum WiredLinkPolicy {

    struct Port: Equatable {
        let displayName: String
        let linkActive: Bool
        let ipv4: [String]
    }

    /// Which ports of type Ethernet are a *cable*. Two kinds are Ethernet to
    /// SystemConfiguration and are not:
    /// - `Thunderbolt 1/2/3` — the member ports of the Thunderbolt Bridge,
    ///   live only on a Mac-to-Mac cable.
    /// - `Ethernet Adapter (en4)` … — the Apple Silicon placeholders paired
    ///   with the `anpi` interfaces, present on every boot with no hardware
    ///   behind them.
    /// A real dongle or dock reports its own name ("USB 10/100/1000 LAN",
    /// "AX88179A", "Thunderbolt Ethernet Slot 0", plain "Ethernet").
    static func isCable(displayName: String) -> Bool {
        let placeholders = [#"^Thunderbolt \d+$"#, #"^Ethernet Adapter \(en\d+\)$"#]
        return !placeholders.contains { displayName.range(of: $0, options: .regularExpression) != nil }
    }

    static func state(of ports: [Port]) -> WiredLinkState {
        let live = ports.filter { isCable(displayName: $0.displayName) && $0.linkActive }
        for port in live {
            if let ip = port.ipv4.first(where: { !$0.hasPrefix("169.254.") }) {
                return .connected(ip: ip)
            }
        }
        return live.isEmpty ? .disconnected : .noAddress
    }

    /// One emoji, like every other row, so the words line up with theirs: the
    /// status dot carries the answer. The `‹···›` glyph Ethernet Menubar drew
    /// used to stand in front of it, but it is text, twice an emoji's width,
    /// and pushed this row out of the column (2026-10-15). The IP went too —
    /// Victor never needed it, only whether the cable works.
    ///
    /// Since 2026-10-15 the dot is no longer in the text: the row's icon is the
    /// Ethernet network symbol (SF Symbol `network`, Victor's pick from an image
    /// search — the system's own, so no licence to carry), tinted with the
    /// colour the dot had (`tint`).
    static func title(_ state: WiredLinkState) -> String {
        switch state {
        case .connected:         return "Wired: connected"
        case .noAddress:         return "Wired: cable in, no IP"
        case .disconnected:      return "Wired: not connected"
        }
    }

    enum Tint { case green, yellow, gray }

    static func tint(_ state: WiredLinkState) -> Tint {
        switch state {
        case .connected:    return .green
        case .noAddress:    return .yellow
        case .disconnected: return .gray
        }
    }
}

/// The live read: SystemConfiguration's interface list for the names, and the
/// dynamic store (`State:/Network/Interface/<bsd>/Link|IPv4`, what `scutil`
/// shows) for the link and the address. No shell-out, no polling.
enum WiredLink {

    static func current() -> WiredLinkState {
        WiredLinkPolicy.state(of: ports())
    }

    static func ports() -> [WiredLinkPolicy.Port] {
        guard let store = SCDynamicStoreCreate(nil, "VictorAddons.WiredLink" as CFString, nil, nil),
              let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        return all.compactMap { iface in
            guard let type = SCNetworkInterfaceGetInterfaceType(iface),
                  type == kSCNetworkInterfaceTypeEthernet,
                  let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { return nil }
            let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? ?? bsd
            let link = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(bsd)/Link" as CFString) as? [String: Any]
            let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(bsd)/IPv4" as CFString) as? [String: Any]
            return WiredLinkPolicy.Port(displayName: name,
                                        linkActive: link?["Active"] as? Bool ?? false,
                                        ipv4: ipv4?["Addresses"] as? [String] ?? [])
        }
    }
}
