import Foundation
import Network

/// Minimal HTTP server on port 55123 for tablet → Mac triggers.
class TabletHttpServer {
    static let port: UInt16 = 55123

    enum Route: Equatable {
        case alarmStart
        case alarmStop
        case effect(String)
        case openUrl(String)
        case ping
        case soundsManifest
        /// Filename + optional volume percent (0–100) from "?vol=".
        case soundPlay(String, Int?)
        case soundVolume(Int)
        case soundStop
        /// Tablet reports a sound button was pressed; the Mac decides (via
        /// SoundEffectMap) whether to trigger a paired overlay effect.
        case soundPressed(String)
        /// Tablet reports a sound finished/stopped; the Mac decides whether to
        /// stop a paired (looping) overlay effect.
        case soundStopped(String)
        case testTranscriptionStart
        case testState
        case testAudioPlaying
        case testWisprRecording
        /// Start/reset the Break countdown overlay for N minutes (test hook).
        case testBreakStart(Int)
        /// Close the Break countdown overlay (test hook).
        case testBreakClose
        /// Open the country picker on the Break overlay, optionally pre-filtered (test hook).
        case testBreakPicker(String?)
        /// Tile Terminal windows — same action as ⌘⌃A (test hook).
        case testTile
        /// Fire the 🔥 WIP Agent whip overlay — same action as ⌃W (test hook).
        case testWhip
        /// Post the 13:00 "Group Photo" notification now, bypassing the time +
        /// connection gates (test hook).
        case testGroupPhoto
        /// Post the "Wispr started but output ≠ 🔊OS Output" notification now,
        /// using the real current default-output name (test hook).
        case testWisprOutputDrift
        case promptCapture
        case intellijFileOpened
        case unknown
    }

    var onAlarmStart: (() -> Void)?
    var onAlarmStop: (() -> Void)?
    /// Generic effect handler: receives the effect name (e.g. "fireworks", "applause", "applause/stop")
    var onEffect: ((String) -> Void)?
    /// Open a URL in a fullscreen Chrome window on the primary display.
    var onOpenUrl: ((String) -> Void)?
    /// Tablet connectivity ping (every 5s); returns JSON with the sounds manifest hash.
    var onPing: (() -> String)?
    /// Full sounds manifest JSON — fetched by the tablet on a hash mismatch.
    var onSoundsManifest: (() -> String)?
    /// Play a tablet-routed sound by filename at an optional volume percent;
    /// returns JSON with durationMs, or nil if the sound is unknown (→ 404,
    /// tablet falls back to local playback).
    var onSoundPlay: ((String, Int?) -> String?)?
    /// Tablet volume change (0–100): adjust tablet-routed playback volume and
    /// play a feedback click at the new level.
    var onSoundVolume: ((Int) -> Void)?
    var onSoundStop: (() -> Void)?
    /// Tablet reports a sound press by bare filename; the Mac maps it to a
    /// paired overlay effect (or ignores it). Mapping lives on the Mac.
    var onSoundPressed: ((String) -> Void)?
    /// Tablet reports a sound stop by bare filename; the Mac maps it to a
    /// paired effect-stop (or ignores it).
    var onSoundStopped: ((String) -> Void)?
    var onTestTranscriptionStart: (() -> Void)?
    var onTestState: (() -> String)?
    var onTestAudioPlaying: (() -> String)?
    var onTestWisprRecording: (() -> String)?
    var onTestBreakStart: ((Int) -> Void)?
    var onTestBreakClose: (() -> Void)?
    var onTestBreakPicker: ((String?) -> Void)?
    var onTestTile: (() -> Void)?
    var onTestWhip: (() -> Void)?
    var onTestGroupPhoto: (() -> Void)?
    var onTestWisprOutputDrift: (() -> Void)?
    /// Receives the prompt body; returns JSON describing whether it was captured.
    var onPromptCapture: ((String) -> String)?
    /// Receives the IntelliJ plugin's open-file JSON body; returns JSON describing whether it was accepted.
    var onIntellijFileOpened: ((String) -> String)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "tablet-http", qos: .utility)

    func start() {
        let tcpParams = NWParameters.tcp
        tcpParams.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: tcpParams, on: NWEndpoint.Port(rawValue: Self.port)!) else {
            overlayError("TabletHttpServer: failed to bind port \(Self.port)")
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:   overlayInfo("Tablet HTTP server on :\(Self.port)")
            case .failed(let err): overlayError("TabletHttpServer failed: \(err)")
            default: break
            }
        }
        listener.start(queue: queue)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = Self.parsePath(raw)
            let route = Self.route(forPath: path)

            var statusCode = 200
            var body = "ok"
            var contentType = "text/plain; charset=utf-8"

            DispatchQueue.main.sync {
                switch route {
                case .alarmStart:
                    self?.onAlarmStart?()
                case .alarmStop:
                    self?.onAlarmStop?()
                case .effect(let name):
                    self?.onEffect?(name)
                case .openUrl(let url):
                    self?.onOpenUrl?(url)
                case .ping:
                    contentType = "application/json"
                    body = self?.onPing?() ?? "{\"ok\":true}"
                case .soundsManifest:
                    contentType = "application/json"
                    body = self?.onSoundsManifest?() ?? "{\"error\":\"manifest unavailable\"}"
                    if self?.onSoundsManifest == nil {
                        statusCode = 503
                    }
                case .soundPlay(let name, let volumePct):
                    contentType = "application/json"
                    if let json = self?.onSoundPlay?(name, volumePct) {
                        body = json
                    } else {
                        statusCode = 404
                        body = "{\"ok\":false,\"reason\":\"unknown-sound\"}"
                    }
                case .soundVolume(let pct):
                    self?.onSoundVolume?(pct)
                case .soundStop:
                    self?.onSoundStop?()
                case .soundPressed(let name):
                    self?.onSoundPressed?(name)
                case .soundStopped(let name):
                    self?.onSoundStopped?(name)
                case .testTranscriptionStart:
                    self?.onTestTranscriptionStart?()
                case .testState:
                    contentType = "application/json"
                    body = self?.onTestState?() ?? "{\"error\":\"state unavailable\"}"
                    if self?.onTestState == nil {
                        statusCode = 503
                    }
                case .testAudioPlaying:
                    contentType = "application/json"
                    body = self?.onTestAudioPlaying?() ?? "{\"error\":\"audio probe unavailable\"}"
                    if self?.onTestAudioPlaying == nil {
                        statusCode = 503
                    }
                case .testWisprRecording:
                    contentType = "application/json"
                    body = self?.onTestWisprRecording?() ?? "{\"error\":\"wispr probe unavailable\"}"
                    if self?.onTestWisprRecording == nil {
                        statusCode = 503
                    }
                case .testBreakStart(let minutes):
                    self?.onTestBreakStart?(minutes)
                case .testBreakClose:
                    self?.onTestBreakClose?()
                case .testBreakPicker(let q):
                    self?.onTestBreakPicker?(q)
                case .testTile:
                    self?.onTestTile?()
                case .testWhip:
                    self?.onTestWhip?()
                case .testGroupPhoto:
                    self?.onTestGroupPhoto?()
                case .testWisprOutputDrift:
                    self?.onTestWisprOutputDrift?()
                case .promptCapture:
                    contentType = "application/json"
                    let promptBody = Self.extractBody(raw)
                    body = self?.onPromptCapture?(promptBody) ?? "{\"captured\":false,\"reason\":\"handler-missing\"}"
                case .intellijFileOpened:
                    contentType = "application/json"
                    let fileBody = Self.extractBody(raw)
                    body = self?.onIntellijFileOpened?(fileBody) ?? "{\"ok\":false,\"reason\":\"handler-missing\"}"
                case .unknown:
                    statusCode = 404
                    body = "not found"
                }
            }

            let response = Self.httpResponse(statusCode: statusCode, contentType: contentType, body: body)
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    /// Extract the body from a raw HTTP request — everything after the blank
    /// line that terminates the headers. Returns "" if no body present.
    static func extractBody(_ raw: String) -> String {
        if let range = raw.range(of: "\r\n\r\n") {
            return String(raw[range.upperBound...])
        }
        if let range = raw.range(of: "\n\n") {
            return String(raw[range.upperBound...])
        }
        return ""
    }

    static func parsePath(_ request: String) -> String {
        let parts = request.split(separator: " ", maxSplits: 2)
        return parts.count > 1 ? String(parts[1]) : "/"
    }

    static func route(forPath path: String) -> Route {
        let (pathOnly, queryItems) = parsePathAndQuery(path)
        switch pathOnly {
        case "/alarm/start":
            return .alarmStart
        case "/alarm/stop":
            return .alarmStop
        case "/ping":
            return .ping
        case "/sounds/manifest":
            return .soundsManifest
        case "/sound/stop":
            return .soundStop
        case "/test/transcription/start":
            return .testTranscriptionStart
        case "/test/state":
            return .testState
        case "/test/audio/playing":
            return .testAudioPlaying
        case "/test/wispr/recording":
            return .testWisprRecording
        case "/test/break/close":
            return .testBreakClose
        case "/test/break/picker":
            return .testBreakPicker(queryItems.first(where: { $0.name == "q" })?.value)
        case "/test/tile":
            return .testTile
        case "/test/whip":
            return .testWhip
        case "/test/sonar":
            return .effect("sonar")
        case "/test/phoenix":
            return .effect("phoenix")
        case "/test/group-photo":
            return .testGroupPhoto
        case "/test/wispr-output-drift":
            return .testWisprOutputDrift
        case "/training/prompt-capture":
            return .promptCapture
        case "/intellij/file-opened":
            return .intellijFileOpened
        case "/open":
            if let url = queryItems.first(where: { $0.name == "url" })?.value, !url.isEmpty {
                return .openUrl(url)
            }
            return .unknown
        default:
            if pathOnly.hasPrefix("/effect/") {
                return .effect(String(pathOnly.dropFirst("/effect/".count)))
            }
            if pathOnly.hasPrefix("/sound/play/") {
                let name = String(pathOnly.dropFirst("/sound/play/".count))
                let vol = queryItems.first(where: { $0.name == "vol" })?.value.flatMap(Int.init)
                if !name.isEmpty { return .soundPlay(name, vol) }
            }
            if pathOnly.hasPrefix("/sound/pressed/") {
                let name = String(pathOnly.dropFirst("/sound/pressed/".count))
                if !name.isEmpty { return .soundPressed(name) }
            }
            if pathOnly.hasPrefix("/sound/stopped/") {
                let name = String(pathOnly.dropFirst("/sound/stopped/".count))
                if !name.isEmpty { return .soundStopped(name) }
            }
            if pathOnly.hasPrefix("/sound/volume/") {
                if let pct = Int(pathOnly.dropFirst("/sound/volume/".count)) {
                    return .soundVolume(pct)
                }
            }
            if pathOnly.hasPrefix("/test/break/") {
                if let minutes = Int(pathOnly.dropFirst("/test/break/".count)) {
                    return .testBreakStart(minutes)
                }
            }
            return .unknown
        }
    }

    private static func parsePathAndQuery(_ raw: String) -> (String, [URLQueryItem]) {
        guard let comps = URLComponents(string: "http://x" + raw) else { return (raw, []) }
        return (comps.path, comps.queryItems ?? [])
    }

    private static func httpResponse(statusCode: Int, contentType: String, body: String) -> String {
        let reason: String
        switch statusCode {
        case 200: reason = "OK"
        case 404: reason = "Not Found"
        case 503: reason = "Service Unavailable"
        default: reason = "OK"
        }
        let bytes = body.utf8.count
        return "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bytes)\r\n\r\n\(body)"
    }
}
