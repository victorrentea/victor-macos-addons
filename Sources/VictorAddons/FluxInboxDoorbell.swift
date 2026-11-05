import Foundation

// MARK: - Policy (pure, unit-tested)

/// The decisions behind the doorbell, kept free of sockets so they can be tested.
enum FluxDoorbellPolicy {
    static let endpoint = "wss://ws.agentmail.to/v0"
    /// Exactly one event type. `message.received.spam|blocked|unauthenticated`
    /// are separate types, and nothing in them could pass the sender gates.
    static let eventType = "message.received"

    /// AgentMail documents only the `api_key` query parameter for sockets, so
    /// **this URL is a credential: never log it**, nor an error that embeds it.
    static func socketURL(apiKey: String) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        return components.url
    }

    static func subscribeFrame(inboxId: String) -> String? {
        let payload: [String: Any] = [
            "type": "subscribe",
            "event_types": [eventType],
            "inbox_ids": [inboxId],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    enum Frame: Equatable {
        case subscribed
        case newMail
        case other
    }

    /// Reads **two fields and nothing else**. A `message.received` frame carries
    /// the whole hostile email, body included; it rings the bell and is dropped.
    /// Sender, subject and the auth stamp are read only by the REST poll that
    /// follows, so the trust gates have exactly one way in.
    static func classify(_ text: String) -> Frame {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return .other }
        if type == "subscribed" { return .subscribed }
        if type == "event", json["event_type"] as? String == eventType { return .newMail }
        return .other
    }

    /// 2, 4, 8, … capped at a minute. The cap is what makes "internet is back"
    /// need no network watcher: the Mac is reconnected a minute later at worst.
    static func reconnectDelay(failures: Int) -> TimeInterval {
        let exponent = min(max(failures, 1), 6)
        return min(60, pow(2, Double(exponent)))
    }

    /// A socket that dies right after subscribing must keep backing off rather
    /// than looking like a fresh start, so only a connection that lasted counts
    /// as having worked.
    static func failuresAfterDrop(previous: Int, upFor: TimeInterval?, stableAfter: TimeInterval) -> Int {
        if let upFor, upFor >= stableAfter { return 1 }
        return previous + 1
    }

    /// When to run the REST poll for a ring: after `settle`, and never closer
    /// than `minGap` to the previous ring's poll. The inbox is a public address,
    /// so a mail bomb must not turn into one list call per mail.
    static func pollDelay(lastPoll: Date?, now: Date, settle: TimeInterval, minGap: TimeInterval) -> TimeInterval {
        guard let lastPoll else { return settle }
        return max(settle, minGap - now.timeIntervalSince(lastPoll))
    }

    /// Describes a socket failure for the log. Only the numeric code: the text of
    /// a URL error can quote the failing URL, and that URL holds the API key.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}

// MARK: - Doorbell

/// Holds a WebSocket to AgentMail while the Mac is on AC, and rings when mail
/// lands, so an email becomes an agent in about a second instead of up to 10
/// minutes later, with no traffic in between.
///
/// **It only says "look now".** `onRing` tells `FluxInboxPoller` to run its usual
/// REST poll, which alone reads senders and subjects. It rings on each
/// (re)connection as well, because mail may have landed while the socket was
/// down; the poller's 10-minute tick stays as the safety net.
final class FluxInboxDoorbell {
    enum State: String {
        case off, connecting, connected, retrying
    }

    /// A socket can die silently (Wi-Fi roam, NAT timeout, sleep): nothing errors,
    /// mail simply stops ringing. An unanswered ping is the only way to notice.
    static let pingInterval: TimeInterval = 30
    static let stableAfter: TimeInterval = 60

    /// Fired on the doorbell's private queue.
    var onRing: ((String) -> Void)?

    private let apiKey: String
    private let inboxId: String
    private let isOnAC: () -> Bool
    private let session: URLSession
    private let queue = DispatchQueue(
        label: "ro.victorrentea.macos-addons.flux-inbox-doorbell", qos: .utility)

    private var task: URLSessionWebSocketTask?
    /// Bumped by every connect and teardown, so a callback from a dead socket can
    /// tell it is dead and do nothing.
    private var generation = 0
    private var pingTimer: DispatchSourceTimer?
    private var retry: DispatchWorkItem?
    private var awaitingPong = false
    private var connectedAt: Date?
    private var failures = 0

    private let statusLock = NSLock()
    private var _state = State.off
    private var _rings = 0

    init(apiKey: String,
         inboxId: String,
         isOnAC: @escaping () -> Bool,
         session: URLSession = URLSession(configuration: .default)) {
        self.apiKey = apiKey
        self.inboxId = inboxId
        self.isOnAC = isOnAC
        self.session = session
    }

    /// For `/test/email`, read from other threads.
    var snapshot: (state: String, rings: Int) {
        statusLock.lock(); defer { statusLock.unlock() }
        return (_state.rawValue, _rings)
    }

    /// Connect or disconnect to match the power source. Safe to call at any time.
    func reevaluate() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.isOnAC() {
                if self.task == nil && self.retry == nil { self.connect() }
            } else if self.task != nil || self.retry != nil {
                self.teardown()
                self.failures = 0
                self.setState(.off)
                overlayInfo("📬 doorbell off — on battery")
            }
        }
    }

    /// After a wake the socket is usually dead but still looks connected, and a
    /// pending retry may be most of a minute away. Start over.
    func reconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardown()
            self.failures = 0
            self.setState(.off)
            if self.isOnAC() { self.connect() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.teardown()
            self?.setState(.off)
        }
    }

    // MARK: Socket lifecycle (all on `queue`)

    private func connect() {
        guard let url = FluxDoorbellPolicy.socketURL(apiKey: apiKey),
              let subscribe = FluxDoorbellPolicy.subscribeFrame(inboxId: inboxId) else { return }
        generation += 1
        let current = generation
        let socket = session.webSocketTask(with: url)
        task = socket
        awaitingPong = false
        setState(.connecting)
        socket.resume()
        socket.send(.string(subscribe)) { [weak self] error in
            guard let error else { return }
            self?.queue.async { self?.dropped(generation: current, error) }
        }
        listen(on: socket, generation: current)
        armPings(on: socket, generation: current)
    }

    private func listen(on socket: URLSessionWebSocketTask, generation listening: Int) {
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard listening == self.generation else { return }
                switch result {
                case .failure(let error):
                    self.dropped(generation: listening, error)
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handle(text)
                    case .data(let data):
                        self.handle(String(decoding: data, as: UTF8.self))
                    @unknown default:
                        break
                    }
                    self.listen(on: socket, generation: listening)
                }
            }
        }
    }

    private func handle(_ text: String) {
        switch FluxDoorbellPolicy.classify(text) {
        case .subscribed:
            connectedAt = Date()
            setState(.connected)
            overlayInfo("📬 doorbell connected")
            onRing?("doorbell connected")
        case .newMail:
            statusLock.lock(); _rings += 1; statusLock.unlock()
            onRing?("doorbell rang")
        case .other:
            break
        }
    }

    private func armPings(on socket: URLSessionWebSocketTask, generation pinging: Int) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, pinging == self.generation else { return }
            if self.awaitingPong {
                self.dropped(generation: pinging, FluxDoorbellError.pongTimeout)
                return
            }
            self.awaitingPong = true
            socket.sendPing { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard pinging == self.generation else { return }
                    if let error {
                        self.dropped(generation: pinging, error)
                    } else {
                        self.awaitingPong = false
                    }
                }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func dropped(generation dropping: Int, _ error: Error) {
        guard dropping == generation else { return }
        let upFor = connectedAt.map { Date().timeIntervalSince($0) }
        // One line per outage: a Mac offline for a day must not log every retry.
        if snapshot.state == State.connected.rawValue || failures == 0 {
            overlayInfo("📬 doorbell lost (\(FluxDoorbellPolicy.describe(error))), retrying")
        }
        failures = FluxDoorbellPolicy.failuresAfterDrop(
            previous: failures, upFor: upFor, stableAfter: Self.stableAfter)
        teardown()
        guard isOnAC() else {
            failures = 0
            setState(.off)
            return
        }
        setState(.retrying)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retry = nil
            if self.isOnAC() {
                self.connect()
            } else {
                self.failures = 0
                self.setState(.off)
            }
        }
        retry = work
        queue.asyncAfter(deadline: .now() + FluxDoorbellPolicy.reconnectDelay(failures: failures),
                         execute: work)
    }

    private func teardown() {
        generation += 1
        retry?.cancel()
        retry = nil
        pingTimer?.cancel()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectedAt = nil
        awaitingPong = false
    }

    private func setState(_ state: State) {
        statusLock.lock(); _state = state; statusLock.unlock()
    }
}

enum FluxDoorbellError: Error {
    case pongTimeout
}
