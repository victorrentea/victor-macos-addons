import AppKit
import Foundation

/// 🧾 **How much ElevenLabs is left** — the readout under 🎬 Live Captions.
///
/// Victor (2026-09-28): *"Eleven labs should show remaining/total and reset
/// date. In menu of addons"*. The same key pays for the 🎬 band here and for
/// Walkie Talkie's Scribe calls, and the plan runs out silently — the first
/// sign used to be a dictation that came back empty.
///
/// **Where each number comes from**, in order:
/// 1. `GET /v1/user/subscription` — `character_count`, `character_limit` and
///    `next_character_count_reset_unix`, all three at once. It needs the key's
///    `user_read` permission, and on 2026-09-28 Victor's key did **not** have
///    it: `401 missing_permissions`.
/// 2. Without it, *used* is `GET /v1/usage/character-stats` summed over the
///    last 30 days (that endpoint works with a scoped key), and *total* is
///    `WT_ELEVEN_QUOTA` from the env file, else 10 000 (his plan).
///
/// **The reset date is never guessed.** Without `user_read` there is no source
/// for it, so the row says `resets ?` and the tooltip says how to fix the key.
/// A made-up date would be read as a promise.
///
/// The key and `WT_ELEVEN_QUOTA` are only **read** from
/// `~/.walkie-talkie/elevenlabs.env` (Walkie Talkie owns that file; this app
/// never writes it — the two apps stay independent).
enum ElevenLabsQuotaPolicy {

    /// Rolling window for the fallback sum. The billing period is unknown
    /// without `user_read`, so this is the closest honest stand-in — and the
    /// tooltip says so.
    static let fallbackWindowDays = 30
    static let defaultQuota = 10_000

    struct Snapshot: Equatable {
        var used: Int
        var total: Int
        var reset: Date?
        /// Which endpoint each number came from — shown in the tooltip and in
        /// `/test/elevenlabs/state`, because "the number is wrong" is first a
        /// question of which of the two sources produced it.
        var usedSource: String
        var totalSource: String
        /// Raw HTTP status of `/v1/user/subscription` (nil = never answered).
        var subscriptionStatus: Int?
        var missingUserRead: Bool

        var remaining: Int { total - used }
        var exhausted: Bool { remaining <= 0 }
    }

    enum SubscriptionRead: Equatable {
        case ok(used: Int?, limit: Int?, reset: Date?)
        case missingUserRead
        case failed(String)
    }

    // MARK: - Env file

    /// `KEY=value`, `KEY="value"` or `KEY='value'`; comments and blanks skipped.
    static func envValue(_ name: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            var row = line.trimmingCharacters(in: .whitespaces)
            if row.hasPrefix("export ") { row = String(row.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard !row.hasPrefix("#"), let eq = row.firstIndex(of: "=") else { continue }
            guard row[..<eq].trimmingCharacters(in: .whitespaces) == name else { continue }
            var value = String(row[row.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func quota(fromEnv text: String?) -> Int? {
        guard let text, let raw = envValue("WT_ELEVEN_QUOTA", in: text) else { return nil }
        return Int(raw.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: ""))
    }

    // MARK: - Responses

    static func parseSubscription(status: Int, body: Data) -> SubscriptionRead {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if status == 200, let json {
            let reset = (json["next_character_count_reset_unix"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            return .ok(used: (json["character_count"] as? NSNumber)?.intValue,
                       limit: (json["character_limit"] as? NSNumber)?.intValue,
                       reset: reset)
        }
        let detail = json?["detail"] as? [String: Any]
        if (status == 401 || status == 403), detail?["status"] as? String == "missing_permissions" {
            return .missingUserRead
        }
        let message = detail?["message"] as? String
            ?? String(data: body.prefix(200), encoding: .utf8) ?? ""
        return .failed("HTTP \(status) \(message)")
    }

    /// `{"time":[…],"usage":{"All":[…]}}` → the sum of every series.
    static func sumCharacterStats(_ body: Data) -> Int? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else { return nil }
        var total = 0.0
        for case let series as [Any] in usage.values {
            for case let n as NSNumber in series { total += n.doubleValue }
        }
        return Int(total.rounded())
    }

    // MARK: - Drawing

    /// `10000` → `10 000`, `-33` → `−33`.
    static func group(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(" ") }
            out.append(c)
        }
        return (n < 0 ? "−" : "") + out
    }

    /// `10000` → `10k`, `1500` → `1.5k`, `100000` → `100k`; under 1000 as is.
    static func kilo(_ n: Int) -> String {
        guard abs(n) >= 1000 else { return String(n) }
        let k = Double(n) / 1000
        let text = k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)
        return text.replacingOccurrences(of: ".0", with: "") + "k"
    }

    /// `Oct 30`, or `?` when the reset date is unknown.
    static func resetText(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "?" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    /// Compact on purpose (2026-09-28, Victor: *"33 / 10k / Oct 30"*):
    /// remaining / total / reset. The words live in the tooltip.
    static func title(_ s: Snapshot?, error: String?, timeZone: TimeZone = .current) -> String {
        guard let s else {
            return error == nil ? "🧾 ElevenLabs …" : "🧾 ElevenLabs ?"
        }
        let remaining = (s.remaining < 0 ? "−" : "") + String(abs(s.remaining))
        return "🧾 ElevenLabs \(remaining) / \(kilo(s.total)) / \(resetText(s.reset, timeZone: timeZone))"
    }

    static func tooltip(_ s: Snapshot?, error: String?, fetchedAt: Date?, now: Date = Date()) -> String {
        var lines: [String] = []
        if let s {
            lines.append("Used \(group(s.used)) of \(group(s.total)) characters — \(group(s.remaining)) left.")
            if let reset = s.reset { lines.append("Resets \(resetText(reset)).") }
            lines.append("Used: \(s.usedSource). Total: \(s.totalSource).")
            if s.missingUserRead {
                lines.append("Reset date unknown: the API key lacks the user_read permission "
                             + "(/v1/user/subscription answered \(s.subscriptionStatus.map(String.init) ?? "?")). "
                             + "Add it to the key at elevenlabs.io → API keys, and the real period and reset date appear here.")
            } else if s.reset == nil {
                lines.append("Reset date unknown: /v1/user/subscription gave none.")
            }
        }
        if let error { lines.append("Last check failed: \(error)") }
        if let fetchedAt {
            let mins = Int(now.timeIntervalSince(fetchedAt) / 60)
            lines.append(mins < 1 ? "Checked just now." : "Checked \(mins) min ago.")
        }
        lines.append("Click to open ElevenLabs.")
        return lines.joined(separator: "\n")
    }
}

/// Fetches off the main thread, caches, and hands the menu a finished title.
/// Refreshed on menu open when older than 5 min, and every 30 min regardless.
/// `@unchecked Sendable`: every stored property is touched on the main thread
/// only — the detached fetch reads none of them and hands its result back there.
final class ElevenLabsQuotaMonitor: @unchecked Sendable {
    static let menuMaxAge: TimeInterval = 5 * 60
    static let backgroundEvery: TimeInterval = 30 * 60

    private(set) var snapshot: ElevenLabsQuotaPolicy.Snapshot?
    private(set) var lastError: String?
    private(set) var fetchedAt: Date?
    private var inFlight = false
    private var timer: Timer?

    /// Main thread, after every fetch.
    var onChange: (() -> Void)?

    var title: String { ElevenLabsQuotaPolicy.title(snapshot, error: lastError) }
    var tooltip: String { ElevenLabsQuotaPolicy.tooltip(snapshot, error: lastError, fetchedAt: fetchedAt) }
    var exhausted: Bool { snapshot?.exhausted ?? false }

    /// Where a click goes: the key page when the fix is a permission there,
    /// the subscription page otherwise.
    var clickURL: URL {
        URL(string: snapshot?.missingUserRead == true
            ? "https://elevenlabs.io/app/settings/api-keys"
            : "https://elevenlabs.io/app/subscription")!
    }

    func start() {
        refresh()
        let t = Timer(timeInterval: Self.backgroundEvery, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refreshIfStale() {
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.menuMaxAge { return }
        refresh()
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        Task.detached(priority: .utility) {
            let (snap, error) = await Self.fetch()
            // `.common`, not `DispatchQueue.main.async`: the menu is usually
            // open while this lands, and its tracking loop does not drain the
            // main queue — the row would only update after it closed.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                guard let self else { return }
                self.inFlight = false
                if let snap { self.snapshot = snap }
                self.lastError = error
                self.fetchedAt = Date()
                self.onChange?()
            }
        }
    }

    func stateJSON() -> String {
        var d: [String: Any] = [
            "title": title,
            "tooltip": tooltip,
            "exhausted": exhausted,
            "in_flight": inFlight,
        ]
        if let s = snapshot {
            d["used"] = s.used
            d["total"] = s.total
            d["remaining"] = s.remaining
            d["reset"] = s.reset.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
            d["used_source"] = s.usedSource
            d["total_source"] = s.totalSource
            d["subscription_status"] = s.subscriptionStatus ?? NSNull()
            d["missing_user_read"] = s.missingUserRead
        }
        d["error"] = lastError ?? NSNull()
        d["fetched_at"] = fetchedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Network (off the main thread)

    private static func envFileText() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".walkie-talkie/elevenlabs.env")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func get(_ url: URL, key: String) async -> (Int?, Data) {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode, data)
        } catch {
            return (nil, Data(error.localizedDescription.utf8))
        }
    }

    static func fetch() async -> (ElevenLabsQuotaPolicy.Snapshot?, String?) {
        // Same precedence as the 🎬 band, so the row reports the account the
        // band bills — which, with no override, is the Walkie Talkie key.
        guard let key = LiveCaptionsStream.apiKey() else {
            return (nil, "no ELEVENLABS_API_KEY in ~/.walkie-talkie/elevenlabs.env")
        }
        let base = "https://api.elevenlabs.io/v1"
        let (subStatus, subBody) = await get(URL(string: "\(base)/user/subscription")!, key: key)

        var used: Int?, limit: Int?, reset: Date?
        var missingUserRead = false
        var subError: String?
        if let subStatus {
            switch ElevenLabsQuotaPolicy.parseSubscription(status: subStatus, body: subBody) {
            case let .ok(u, l, r): used = u; limit = l; reset = r
            case .missingUserRead: missingUserRead = true
            case let .failed(msg): subError = msg
            }
        } else {
            subError = String(data: subBody, encoding: .utf8)
        }

        var usedSource = "/v1/user/subscription"
        if used == nil {
            let end = Date()
            let start = end.addingTimeInterval(-Double(ElevenLabsQuotaPolicy.fallbackWindowDays) * 86_400)
            var c = URLComponents(string: "\(base)/usage/character-stats")!
            c.queryItems = [
                URLQueryItem(name: "start_unix", value: String(Int64(start.timeIntervalSince1970 * 1000))),
                URLQueryItem(name: "end_unix", value: String(Int64(end.timeIntervalSince1970 * 1000))),
                URLQueryItem(name: "breakdown_type", value: "none"),
            ]
            let (status, body) = await get(c.url!, key: key)
            guard status == 200, let sum = ElevenLabsQuotaPolicy.sumCharacterStats(body) else {
                let msg = String(data: body.prefix(200), encoding: .utf8) ?? ""
                return (nil, "character-stats HTTP \(status.map(String.init) ?? "—") \(msg)"
                        + (subError.map { "; subscription: \($0)" } ?? ""))
            }
            used = sum
            usedSource = "/v1/usage/character-stats, last \(ElevenLabsQuotaPolicy.fallbackWindowDays) days"
        }

        let total: Int
        let totalSource: String
        if let limit, limit > 0 {
            total = limit; totalSource = "/v1/user/subscription"
        } else if let q = ElevenLabsQuotaPolicy.quota(fromEnv: envFileText()) {
            total = q; totalSource = "WT_ELEVEN_QUOTA"
        } else {
            total = ElevenLabsQuotaPolicy.defaultQuota; totalSource = "default 10 000"
        }

        let snap = ElevenLabsQuotaPolicy.Snapshot(
            used: used ?? 0, total: total, reset: reset,
            usedSource: usedSource, totalSource: totalSource,
            subscriptionStatus: subStatus, missingUserRead: missingUserRead)
        return (snap, subError)
    }
}
