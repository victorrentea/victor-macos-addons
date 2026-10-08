import Foundation

/// ✈️ Which mails mean "online check-in is open now", and what the pill says
/// about them. Pure: no Gmail, no clock of its own — `CheckInMailWatch` feeds it.
///
/// The query was built on 2026-10-08 from the airlines' real mails in Victor's
/// inbox, one clause per airline, each pinned to the **sender** *and* the
/// **subject** that only the check-in mail uses. Over the year before it matched
/// 34 threads, all of them check-in mails and nothing else. The traps it steps
/// around, each one seen in that inbox:
///
/// - **Ryanair** sends three mails before a flight: "Manage your booking"
///   (~8 days), "It's almost time for your flight" (~2 days) and "Check in online
///   for your flight to X" (~24 h, when the free check-in opens). Only the last.
/// - **Lufthansa group** (Lufthansa, Brussels, Austrian, Swiss) also sends
///   "Check in carry-on baggage free of charge", which is about bags at the
///   airport, not online check-in. Their check-in mail is "Your flight is ready
///   for check-in", hence the phrase without a sender.
/// - **Wizz Air**'s check-in nudge comes from the *marketing* domain
///   (`wizznews.com`), while `wizzair.com` sends "Check-in contact", which is a
///   form about your phone number.
/// - **LOT** sends "Prepare for your flight" days ahead; the check-in one is
///   "It's time to check-in".
/// - **Tarom** sends no check-in mail at all (only invoices and the Amadeus
///   e-ticket), so it has no clause. Nor does easyJet, which never sent one.
enum CheckInMailPolicy {

    /// The airline clauses, OR-ed by Gmail's `{ }`. Kept as a list so the test
    /// can name each airline and a new one is a single line.
    static let clauses: [String] = [
        #"(from:ryanairemail.com subject:("check in online" OR "check-in-ul online"))"#,
        #"(from:wizznews.com subject:("time to check in" OR "timpul să faceți check-in"))"#,
        #"(from:(infos-klm.com OR klm-info.com) subject:("check-in is open" OR "check in for your flight"))"#,
        #"subject:"ready for check-in""#,
        #"(from:service-airfrance.com subject:check-in)"#,
        #"(from:lot.com subject:"time to check-in")"#,
        #"(from:mailinganimawings.com subject:"time to check-in")"#,
    ]

    /// How far back each poll looks. The check-in mail lands ~24–48 h before
    /// departure and the poll is hourly, so a day is ample; anything older is a
    /// flight already boarding, and on the very first run it keeps the alarm
    /// from ringing for trips already flown.
    static let window = "newer_than:1d"

    static var query: String { "{" + clauses.joined(separator: " ") + "} " + window }

    /// The same mails, still unread: what `gmail-cli read` opens to mark them read.
    static var unreadQuery: String { query + " is:unread" }

    /// One row of `gmail-cli search --json`. `email` is null on some rows (Gmail
    /// shows only the display name for a sender it already introduced).
    struct Hit: Codable, Equatable {
        let threadId: String
        let unread: Bool
        let from: String
        let email: String?
        let subject: String
        let date: String?
    }

    static func decode(_ data: Data) -> [Hit]? {
        try? JSONDecoder().decode([Hit].self, from: data)
    }

    /// Hits not alarmed about before. A thread that keeps matching for a whole
    /// day must ring once, not once an hour.
    static func fresh(_ hits: [Hit], seen: Set<String>) -> [Hit] {
        var out: [Hit] = []
        var taken = seen
        for h in hits where !taken.contains(h.threadId) {
            out.append(h)
            taken.insert(h.threadId)
        }
        return out
    }

    /// Whether the next poll is due. Ticked every few minutes rather than
    /// scheduled once an hour, so a Mac that slept through the hour checks as
    /// soon as it wakes instead of an hour later.
    static func isDue(lastCheck: Date?, now: Date, every interval: TimeInterval) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// "Ryanair", "KLM", "Brussels Airlines": the display name, trimmed of the
    /// tails Gmail truncates to ("KLM Royal Dutch Air.").
    static func airline(_ h: Hit) -> String {
        let name = h.from.trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasPrefix("klm") { return "KLM" }
        if name.isEmpty { return h.email ?? "Airline" }
        return name
    }

    /// The destination, when the subject says it: "…for your flight to Otopeni",
    /// "…zborul tău către  Palma", "From Brussels to London on 07 October",
    /// "…Flug nach Paris am 23/04". Nil otherwise (KLM's "Check-in is open!").
    static func destination(_ subject: String) -> String? {
        let patterns = [
            #"(?i)\bflight to\s+(.+?)(?:\s+on\s+\d|\s*\||\s*$)"#,
            #"(?i)\bcătre\s+(.+?)(?:\s*\||\s*$)"#,
            #"(?i)\bfrom\s+.+?\s+to\s+(.+?)(?:\s+on\s+\d|\s*\||\s*$)"#,
            #"(?i)\bnach\s+(.+?)(?:\s+am\s+\d|\s*\||\s*$)"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let range = NSRange(subject.startIndex..., in: subject)
            if let m = re.firstMatch(in: subject, range: range),
               let r = Range(m.range(at: 1), in: subject) {
                let city = subject[r].trimmingCharacters(in: .whitespacesAndNewlines)
                if !city.isEmpty { return city }
            }
        }
        return nil
    }

    /// The pill: `✈️ Check in now: Ryanair → Otopeni`, plus `(+2)` when more
    /// are waiting behind it.
    static func text(_ h: Hit, alsoPending: Int = 0) -> String {
        var s = "✈️ Check in now: \(airline(h))"
        if let d = destination(h.subject) { s += " → \(d)" }
        if alsoPending > 0 { s += "  (+\(alsoPending))" }
        return s
    }

    /// The thread in Gmail's web UI. `gmail-cli` reports the legacy hex id,
    /// which Gmail still resolves in the fragment. `u/0` is the first signed-in
    /// account of the browser profile the link opens in.
    static func gmailURL(threadId: String) -> String {
        "https://mail.google.com/mail/u/0/#all/\(threadId)"
    }
}
