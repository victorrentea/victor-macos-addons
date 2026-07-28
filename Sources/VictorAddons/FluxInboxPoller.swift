import Foundation

// MARK: - Wire model

/// Metadata of one message in the Flux inbox.
///
/// Message **bodies are deliberately not modelled and never fetched** — see the
/// security note on `FluxInboxPoller`. Everything here is attacker-controlled
/// text (anyone on the internet can mail `victor.flux@agentmail.to`), so it is
/// data to be *displayed*, never instructions to be *followed*.
struct FluxMessage: Equatable {
    let messageId: String
    /// Raw `From:` header, e.g. `Victor Rentea <victorrentea@gmail.com>`.
    let from: String
    let subject: String
    let timestamp: Date
    /// The receiving MTA's `Authentication-Results` stamp, if present.
    let authenticationResults: String?
}

// MARK: - Trust policy (pure, unit-tested)

/// Decides which inbox messages are allowed to trigger anything at all.
///
/// Two independent gates must both pass, so that neither one alone is a single
/// point of failure:
///
/// 1. **Exact sender address.** The address is parsed out of the `From:` header
///    and compared for equality (case-insensitively) against `trustedSender`.
///    Substring matching is explicitly *not* used — `victorrentea@gmail.com.evil.com`
///    and `notvictorrentea@gmail.com` both contain the trusted address as a
///    substring and both must be rejected.
/// 2. **Verified authentication.** A `From:` header is trivially forgeable in
///    SMTP, so the address alone proves nothing. We additionally require the
///    receiving MTA's `Authentication-Results` stamp to show DKIM *and* DMARC
///    passing for `gmail.com`.
enum FluxMailPolicy {
    /// The one and only address whose mail may trigger anything.
    static let trustedSender = "victorrentea@gmail.com"

    /// The domain DKIM/DMARC must have validated for.
    private static let trustedDomain = "gmail.com"

    /// Extract the bare address from a `From:` header.
    ///
    /// RFC 5322 puts the real address in the *last* angle-bracket group, which
    /// is what defeats display-name spoofing: a header of
    /// `victorrentea@gmail.com <attacker@evil.com>` renders in most mail clients
    /// as if it came from Victor, but the address that actually sent it — and
    /// the one this returns — is `attacker@evil.com`.
    static func address(fromHeader header: String) -> String? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let openIdx = trimmed.lastIndex(of: "<") else {
            // No angle brackets: the whole header is the address.
            let bare = trimmed.lowercased()
            return bare.contains("@") && !bare.contains(" ") ? bare : nil
        }
        let afterOpen = trimmed.index(after: openIdx)
        guard let closeIdx = trimmed[afterOpen...].firstIndex(of: ">") else { return nil }
        let addr = trimmed[afterOpen..<closeIdx]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return addr.isEmpty ? nil : addr
    }

    /// Gate 1: the sender address is exactly the trusted one.
    static func isTrustedAddress(_ header: String) -> Bool {
        address(fromHeader: header) == trustedSender
    }

    /// Gate 2: the receiving MTA verified DKIM and DMARC for the trusted domain.
    ///
    /// A missing header fails closed. Note the inherent limit of checking a
    /// flattened header map: we cannot tell the receiving MTA's own stamp apart
    /// from one the sender pasted into their message. This gate is therefore
    /// defence-in-depth, not proof — the load-bearing protection is that nothing
    /// downstream ever *acts* on message content.
    static func isAuthenticated(_ results: String?) -> Bool {
        guard let results = results?.lowercased() else { return false }
        let normalized = results.replacingOccurrences(of: " ", with: "")
        return normalized.contains("dkim=pass")
            && normalized.contains("header.i=@\(trustedDomain)")
            && normalized.contains("dmarc=pass")
            && normalized.contains("header.from=\(trustedDomain)")
    }

    /// Both gates.
    static func isTrusted(_ message: FluxMessage) -> Bool {
        isTrustedAddress(message.from) && isAuthenticated(message.authenticationResults)
    }

    /// Whether a poll may run at all.
    ///
    /// Scheduled ticks run **only on battery** — landing on AC power skips the
    /// tick entirely rather than deferring it. `force` is the `/test/email`
    /// override, the one way to poll while plugged in.
    static func shouldPoll(onAC: Bool, force: Bool) -> Bool {
        force || !onAC
    }

    /// The messages a poll should report: trusted senders only, newer than the
    /// watermark, and not already reported.
    ///
    /// Oldest first, so a burst of mail is reported in the order it was sent.
    static func newMail(in messages: [FluxMessage],
                        since watermark: Date,
                        seen: Set<String>) -> [FluxMessage] {
        messages
            .filter { $0.timestamp > watermark }
            .filter { !seen.contains($0.messageId) }
            .filter { isTrusted($0) }
            .sorted { $0.timestamp < $1.timestamp }
    }
}

// MARK: - Poller

/// Polls the Flux AgentMail inbox for new mail from Victor every 10 minutes,
/// **only while the Mac is on battery**.
///
/// ## Security posture
///
/// `victor.flux@agentmail.to` is a public address: anyone can send it anything.
/// Every string reaching this class is therefore hostile input, and the design
/// rule is deliberately narrow:
///
/// - **This poller notifies. It never acts.** It shows a banner and writes a log
///   line. It does not run shell commands, does not launch agents, and does not
///   pass any message-derived string to an LLM, an interpreter, or a file path.
/// - **Bodies are never fetched.** Only metadata (sender, subject, timestamp) is
///   requested, so message content cannot reach the process at all.
/// - **Two independent sender gates** (exact address + DKIM/DMARC) — see
///   `FluxMailPolicy`.
/// - **Subjects are truncated** before display, so a pathological subject cannot
///   paper over the screen, and are emitted through `JSONSerialization` rather
///   than string interpolation, so they cannot break out of the JSON snapshot.
///
/// If this is ever extended to *do* something with an email — the obvious next
/// step being "hand it to Claude" — that step reintroduces prompt injection in
/// full, and the sender gates below are not sufficient mitigation on their own.
/// Treat it as a separate, deliberately human-approved decision.
final class FluxInboxPoller {
    /// Fired on the main queue for each new trusted message, oldest first.
    ///
    /// The payload is **untrusted data**: display it, never execute it.
    var onTrustedMail: ((FluxMessage) -> Void)?

    static let inboxId = "victor.flux@agentmail.to"
    static let interval: TimeInterval = 600  // 10 minutes

    /// How many recent messages each poll inspects. Comfortably more than a
    /// 10-minute window can hold, so nothing is missed between ticks.
    private static let fetchLimit = 25

    private let apiKey: String
    private let session: URLSession
    private let isOnAC: () -> Bool
    private let queue = DispatchQueue(
        label: "ro.victorrentea.macos-addons.flux-inbox-poller", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Only mail newer than this is reported. Persisted so that restarts do not
    /// replay old mail, and so mail that arrived while the app was down is still
    /// picked up on the next launch.
    private var watermark: Date
    private static let watermarkKey = "flux.inbox.poller.watermark"

    /// Message ids already reported — belt-and-braces against same-second
    /// timestamps at the watermark boundary. Bounded to avoid unbounded growth.
    private var seen: [String] = []

    // Diagnostics for the /test/email snapshot.
    private var lastPollAt: Date?
    private var lastOutcome: String = "never polled"
    private var lastMatchCount = 0
    private var lastError: String?

    init(apiKey: String,
         session: URLSession = .shared,
         isOnAC: @escaping () -> Bool = { PowerMonitor.isOnAC() }) {
        self.apiKey = apiKey
        self.session = session
        self.isOnAC = isOnAC
        if let stored = UserDefaults.standard.object(forKey: Self.watermarkKey) as? Date {
            self.watermark = stored
        } else {
            // First ever run: start from "now" so the inbox's existing history
            // does not fire a burst of notifications on launch.
            self.watermark = Date()
            UserDefaults.standard.set(self.watermark, forKey: Self.watermarkKey)
        }
    }

    /// Arm the 10-minute timer. The first tick happens one full interval from
    /// now, so launching the app never fires a poll immediately.
    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        overlayInfo("FluxInboxPoller armed: every \(Int(Self.interval))s, battery-only")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Scheduled tick — skipped entirely while on AC power (see
    /// `FluxMailPolicy.shouldPoll`).
    private func tick() {
        poll(force: false, completion: nil)
    }

    /// Run one poll. `force` bypasses the battery gate (used by `/test/email`).
    /// `completion` fires on `queue` once the poll settles.
    func poll(force: Bool, completion: (() -> Void)?) {
        queue.async { [weak self] in
            guard let self else { completion?(); return }
            guard FluxMailPolicy.shouldPoll(onAC: self.isOnAC(), force: force) else {
                self.lastPollAt = Date()
                self.lastOutcome = "skipped — on AC power"
                completion?()
                return
            }
            self.fetch { result in
                self.lastPollAt = Date()
                switch result {
                case .failure(let error):
                    self.lastOutcome = "error"
                    self.lastError = error.localizedDescription
                    overlayError("FluxInboxPoller: \(error.localizedDescription)")
                case .success(let messages):
                    self.lastError = nil
                    let fresh = FluxMailPolicy.newMail(
                        in: messages, since: self.watermark, seen: Set(self.seen))
                    self.lastMatchCount = fresh.count
                    self.lastOutcome = fresh.isEmpty
                        ? "polled — nothing new (\(messages.count) inspected)"
                        : "polled — \(fresh.count) new from \(FluxMailPolicy.trustedSender)"
                    for message in fresh {
                        self.remember(message)
                        DispatchQueue.main.async { self.onTrustedMail?(message) }
                    }
                }
                completion?()
            }
        }
    }

    /// Advance the watermark and record the id. Always on `queue`.
    private func remember(_ message: FluxMessage) {
        if message.timestamp > watermark {
            watermark = message.timestamp
            UserDefaults.standard.set(watermark, forKey: Self.watermarkKey)
        }
        seen.append(message.messageId)
        if seen.count > 200 { seen.removeFirst(seen.count - 200) }
    }

    // MARK: Networking

    private enum FluxError: LocalizedError {
        case badStatus(Int)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "AgentMail returned HTTP \(code)"
            case .malformedResponse: return "AgentMail returned an unreadable response"
            }
        }
    }

    /// Fetch recent message **metadata**. Bodies are never requested.
    private func fetch(completion: @escaping (Result<[FluxMessage], Error>) -> Void) {
        var components = URLComponents(
            string: "https://api.agentmail.to/v0/inboxes/\(Self.inboxId)/messages")!
        components.queryItems = [URLQueryItem(name: "limit", value: String(Self.fetchLimit))]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completion(.failure(FluxError.badStatus(http.statusCode)))
                return
            }
            guard let data, let parsed = Self.parse(data) else {
                completion(.failure(FluxError.malformedResponse))
                return
            }
            completion(.success(parsed))
        }.resume()
    }

    /// Decode AgentMail's list response.
    ///
    /// Hand-rolled with `JSONSerialization` rather than `Codable` because the
    /// payload is snake_cased, carries a free-form `headers` map, and must
    /// tolerate unexpected shapes without throwing away the whole poll.
    static func parse(_ data: Data) -> [FluxMessage]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["messages"] as? [[String: Any]] else { return nil }

        return raw.compactMap { item -> FluxMessage? in
            guard let id = item["message_id"] as? String,
                  let from = item["from"] as? String,
                  let stamp = item["timestamp"] as? String,
                  let timestamp = isoFormatter.date(from: stamp)
                    ?? isoFormatterNoFraction.date(from: stamp) else { return nil }
            let headers = item["headers"] as? [String: String] ?? [:]
            let auth = headers.first {
                $0.key.caseInsensitiveCompare("Authentication-Results") == .orderedSame
            }?.value
            return FluxMessage(
                messageId: id,
                from: from,
                subject: item["subject"] as? String ?? "(no subject)",
                timestamp: timestamp,
                authenticationResults: auth)
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: Diagnostics

    /// Force a poll and return a JSON snapshot — the `/test/email` hook.
    ///
    /// Waits briefly for the poll to settle so the response reflects it (the API
    /// answers in well under a second in practice); on timeout it reports
    /// `pending` and the result still lands in the log, the banner, and the next
    /// snapshot.
    func forcePollAndSnapshot(waitingUpTo timeout: TimeInterval = 2.5) -> String {
        let done = DispatchSemaphore(value: 0)
        poll(force: true) { done.signal() }
        let settled = done.wait(timeout: .now() + timeout) == .success
        return snapshotJSON(settled: settled)
    }

    /// Attacker-controlled strings go through `JSONSerialization`, never string
    /// interpolation, so a crafted subject cannot forge JSON structure.
    private func snapshotJSON(settled: Bool) -> String {
        var payload: [String: Any] = [
            "inbox": Self.inboxId,
            "trusted_sender": FluxMailPolicy.trustedSender,
            "match": "exact-address + dkim/dmarc pass",
            "interval_seconds": Int(Self.interval),
            "polls_only_on_battery": true,
            "on_battery_now": !isOnAC(),
            "status": settled ? "settled" : "pending",
            "last_outcome": lastOutcome,
            "last_match_count": lastMatchCount,
        ]
        payload["watermark"] = Self.isoFormatter.string(from: watermark)
        if let lastPollAt {
            payload["last_poll_at"] = Self.isoFormatter.string(from: lastPollAt)
        }
        if let lastError { payload["last_error"] = lastError }
        guard let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"snapshot encoding failed\"}"
        }
        return json
    }
}
