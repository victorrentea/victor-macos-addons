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
    let threadId: String
    /// AgentMail labels. `unread` is the **claim token**: it is cleared the
    /// moment we start processing a message, so no second agent can pick it up.
    let labels: [String]

    /// Not yet claimed by an agent run.
    var isUnprocessed: Bool { labels.contains("unread") }
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
    /// tick entirely rather than deferring it. `force` is the override used by
    /// `/test/email` **and by the 📬 menu item**, which is the one way to look at
    /// the inbox while plugged in: on AC the app assumes Victor is mid-workshop
    /// and must not have a Terminal pop open on the projector, so an email that
    /// lands then waits for him to unplug — or to ask for it from the menu.
    static func shouldPoll(onAC: Bool, force: Bool) -> Bool {
        force || !onAC
    }

    /// The messages a poll should report: trusted senders only, still unclaimed
    /// (`unread`), newer than the watermark, and not already reported.
    ///
    /// The `unread` filter is the one dedupe layer that lives server-side, so it
    /// is what stops a second agent starting after a reinstall or a wiped
    /// watermark — see `FluxAgentLauncher`.
    ///
    /// Oldest first, so a burst of mail is reported in the order it was sent.
    static func newMail(in messages: [FluxMessage],
                        since watermark: Date,
                        seen: Set<String>) -> [FluxMessage] {
        messages
            .filter { $0.timestamp > watermark }
            .filter { !seen.contains($0.messageId) }
            .filter { $0.isUnprocessed }
            .filter { isTrusted($0) }
            .sorted { $0.timestamp < $1.timestamp }
    }
}

// MARK: - Menu presentation (pure, unit-tested)

/// Renders the 📬 menu item's title: `Check task inbox (1m ago, 2🚀)`.
///
/// The suffix is the whole point of the item — it answers "did this thing even
/// look at the inbox, and did it ever do anything?" at a glance, without opening
/// a log. The rocket count is cumulative across restarts (see
/// `FluxAgentLauncher.launchedCount`).
enum FluxInboxMenu {
    static let base = "📬 Check task inbox"

    /// Compact "how long ago", coarse on purpose: below a minute everything is
    /// "just now", because the exact second never changes what you'd do next.
    static func ago(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    static func title(lastCheck: Date?, now: Date = Date(), launches: Int) -> String {
        var parts: [String] = []
        if let lastCheck { parts.append(ago(now.timeIntervalSince(lastCheck))) }
        // A zero count is noise — the absence of rockets says the same thing.
        if launches > 0 { parts.append("\(launches)🚀") }
        guard !parts.isEmpty else { return base }
        return "\(base) (\(parts.joined(separator: ", ")))"
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

    // Diagnostics for the /test/email snapshot and the 📬 menu item.
    //
    // These are read from three threads that are none of them `queue` — the
    // HTTP server's (`/test/email`) and the main one (the menu) — so they get
    // their own lock rather than riding on the poll queue.
    private let statusLock = NSLock()
    private var _lastPollAt: Date?
    private var lastOutcome: String = "never polled"
    private var lastMatchCount = 0
    private var lastError: String?

    /// When the inbox was last *actually looked at*. Deliberately not advanced
    /// by a tick that the battery gate skipped: "we checked" has to mean a round
    /// trip happened, or the menu item would claim freshness it doesn't have.
    var lastCheckedAt: Date? {
        statusLock.lock(); defer { statusLock.unlock() }
        return _lastPollAt
    }

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

    /// Run one poll. `force` bypasses the battery gate (used by `/test/email`
    /// and the 📬 menu item). `completion` fires on `queue` once the poll settles.
    func poll(force: Bool, completion: (() -> Void)?) {
        queue.async { [weak self] in
            guard let self else { completion?(); return }
            guard FluxMailPolicy.shouldPoll(onAC: self.isOnAC(), force: force) else {
                // Note we do NOT stamp `_lastPollAt` here: the timer fired, but
                // nobody looked at the inbox.
                self.setStatus { $0.outcome = "skipped — on AC power" }
                completion?()
                return
            }
            self.fetch { result in
                // `fetch` calls back on URLSession's delegate queue and `claim`
                // on a third one; hop back so every mutation below — watermark,
                // `seen`, the status fields — stays serialized on `queue`.
                self.queue.async {
                    self.setStatus { $0.pollAt = Date() }
                    switch result {
                    case .failure(let error):
                        self.setStatus {
                            $0.outcome = "error"
                            $0.error = error.localizedDescription
                        }
                        overlayError("FluxInboxPoller: \(error.localizedDescription)")
                    case .success(let messages):
                        let fresh = FluxMailPolicy.newMail(
                            in: messages, since: self.watermark, seen: Set(self.seen))
                        self.setStatus {
                            $0.error = nil
                            $0.matchCount = fresh.count
                            $0.outcome = fresh.isEmpty
                                ? "polled — nothing new (\(messages.count) inspected)"
                                : "polled — \(fresh.count) new from \(FluxMailPolicy.trustedSender)"
                        }
                        for message in fresh {
                            self.remember(message)
                            // CLAIM FIRST, notify second — and fail closed. Clearing
                            // `unread` server-side is what guarantees no second agent
                            // ever starts for this email, so if the claim fails we do
                            // NOT hand it on: a missed notification is recoverable,
                            // two agents answering the same mail is not.
                            self.claim(message) { claimed in
                                guard claimed else {
                                    overlayError("FluxInboxPoller: could not claim \(message.messageId) — not launching")
                                    return
                                }
                                DispatchQueue.main.async { self.onTrustedMail?(message) }
                            }
                        }
                    }
                    completion?()
                }
            }
        }
    }

    /// The lock-protected diagnostics, mutated as one unit.
    private struct Status {
        var pollAt: Date?
        var outcome: String
        var matchCount: Int
        var error: String?
    }

    private func setStatus(_ mutate: (inout Status) -> Void) {
        statusLock.lock()
        var s = Status(pollAt: _lastPollAt, outcome: lastOutcome,
                       matchCount: lastMatchCount, error: lastError)
        mutate(&s)
        _lastPollAt = s.pollAt
        lastOutcome = s.outcome
        lastMatchCount = s.matchCount
        lastError = s.error
        statusLock.unlock()
    }

    private func readStatus() -> Status {
        statusLock.lock(); defer { statusLock.unlock() }
        return Status(pollAt: _lastPollAt, outcome: lastOutcome,
                      matchCount: lastMatchCount, error: lastError)
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

    /// Claim a message by clearing its `unread` label, so no other poll — in
    /// this run, a later run, or a reinstalled app — can pick it up again.
    ///
    /// Message ids are Message-IDs (`<...@mail.gmail.com>`), so they must be
    /// percent-encoded into the path.
    private func claim(_ message: FluxMessage, completion: @escaping (Bool) -> Void) {
        let encoded = message.messageId.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics) ?? message.messageId
        guard let url = URL(string: "https://api.agentmail.to/v0/inboxes/\(Self.inboxId)/messages/\(encoded)")
        else { completion(false); return }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["remove_labels": ["unread"]])
        request.timeoutInterval = 20

        session.dataTask(with: request) { _, response, error in
            if let error {
                overlayError("FluxInboxPoller: claim failed — \(error.localizedDescription)")
                completion(false)
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion((200..<300).contains(code))
        }.resume()
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
                authenticationResults: auth,
                threadId: item["thread_id"] as? String ?? "",
                labels: item["labels"] as? [String] ?? [])
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
        let status = readStatus()
        var payload: [String: Any] = [
            "inbox": Self.inboxId,
            "trusted_sender": FluxMailPolicy.trustedSender,
            "match": "exact-address + dkim/dmarc pass",
            "interval_seconds": Int(Self.interval),
            "polls_only_on_battery": true,
            "on_battery_now": !isOnAC(),
            "status": settled ? "settled" : "pending",
            "last_outcome": status.outcome,
            "last_match_count": status.matchCount,
            "launched_tasks": FluxAgentLauncher.launchedCount,
        ]
        payload["watermark"] = Self.isoFormatter.string(from: watermark)
        if let pollAt = status.pollAt {
            payload["last_poll_at"] = Self.isoFormatter.string(from: pollAt)
        }
        if let error = status.error { payload["last_error"] = error }
        guard let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"snapshot encoding failed\"}"
        }
        return json
    }
}
