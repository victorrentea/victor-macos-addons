import Foundation

/// 🎙️ The HTTP face of the voice meter and the share state, answered on the
/// server queue (`TabletHttpServer.onVoiceRoute`) — never through the main
/// thread except for the one-line force of the share state.
///
/// - `GET /voice/level` — the tablet's red strip (USB/LAN only: the relay
///   refuses `/voice/`, `HttpAccessPolicy.relayMayCall`).
/// - `GET /test/sharing` · `/test/sharing/force/on|off|auto` — the share state,
///   and the hook every proof uses instead of a real Zoom/Teams share.
/// - `GET /test/voice/device?name=From%20Walkie` — measure that input whatever the
///   meeting captures (empty `name` = back to automatic).
/// - `GET /test/voice/reset` — forget the measured history (normal/top/ref).
/// - `GET /test/voice/state` — `/voice/level` plus the hit counters.
enum VoiceRoutes {
    /// `/voice/` requests that arrived over the Railway relay and were refused.
    static var relayRefused = 0
    /// `/voice/level` answers given (USB or LAN — the only ways in).
    static var levelHits = 0
    static weak var share: MeetingShareWatch?

    static func handle(_ path: String) -> (status: Int, body: String)? {
        let comps = URLComponents(string: "http://x" + path)
        let pathOnly = comps?.path ?? path
        guard pathOnly.hasPrefix("/voice/") || pathOnly.hasPrefix("/test/sharing") || pathOnly.hasPrefix("/test/voice/")
        else { return nil }
        switch pathOnly {
        case "/voice/level":
            levelHits += 1
            return (200, VoiceMeter.shared.levelJSON)
        case "/test/sharing":
            return (200, DispatchQueue.main.sync { share?.stateJSON ?? "{}" })
        case let p where p.hasPrefix("/test/sharing/force/"):
            guard let f = MeetingShareWatch.Force(rawValue: String(p.dropFirst("/test/sharing/force/".count))) else {
                return (400, "{\"ok\":false,\"reason\":\"on|off|auto\"}")
            }
            return (200, DispatchQueue.main.sync { share?.setForce(f); return share?.stateJSON ?? "{}" })
        case "/test/voice/device":
            let name = comps?.queryItems?.first { $0.name == "name" }?.value
            VoiceMeter.shared.setOverride(name)
            return (200, "{\"ok\":true,\"override\":\(TabletHttpServer.jsonString(name ?? ""))}")
        case "/test/voice/reset":
            VoiceMeter.shared.reset()
            return (200, "{\"ok\":true}")
        case "/test/voice/state":
            let level = VoiceMeter.shared.levelJSON
            return (200, "{\"levelHits\":\(levelHits),\"relayRefused\":\(relayRefused),\"level\":\(level)}")
        default:
            return (404, "{\"ok\":false}")
        }
    }
}
