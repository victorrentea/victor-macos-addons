import Foundation

/// Which agent the human typed the prompt into.
///
/// The two capture hooks (`~/.claude/hooks/capture-prompt.sh` and
/// `~/.copilot/hooks/capture-prompt.sh`) POST the same body to the same route;
/// the only thing that tells them apart is the `?src=` they append. An older
/// hook that doesn't send one still captures — it lands as `.unknown` rather
/// than being dropped, because a prompt with no badge is still a prompt.
enum PromptSource: String, Codable {
    case claude
    case copilot
    case unknown

    /// The one glyph the panel shows in front of a prompt. Deliberately a
    /// letter in a circle rather than a logo: it reads at a glance in a list
    /// and it carries no brand asset into the binary.
    var badge: String {
        switch self {
        case .claude:  return "🅒"
        case .copilot: return "🅖"
        case .unknown: return "🤖"
        }
    }

    var name: String {
        switch self {
        case .claude:  return "Claude"
        case .copilot: return "Copilot"
        case .unknown: return "agent"
        }
    }

    /// Tolerant of case and of anything unexpected on the wire — a query
    /// parameter is not a contract worth crashing over.
    static func parse(_ raw: String?) -> PromptSource {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return .unknown }
        return PromptSource(rawValue: raw) ?? .unknown
    }
}

/// One intercepted prompt, as it is kept on disk between the moment the hook
/// forwards it and the moment Victor decides whether the room should see it.
struct CapturedPrompt: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    let date: Date
    let source: PromptSource
    /// Whether this prompt has already been written into the session notes —
    /// by hovering the bottom-left offer pill, or by the Send button in the
    /// history panel. The panel greys a sent row and disables its button; this
    /// flag is the whole reason the store exists rather than a plain log.
    var sent: Bool

    init(id: UUID = UUID(), text: String, date: Date = Date(),
         source: PromptSource, sent: Bool = false) {
        self.id = id
        self.text = text
        self.date = date
        self.source = source
        self.sent = sent
    }
}

/// Pure rules behind the 🤖 prompt history: what is worth keeping, how long,
/// and how the kept prompts are grouped for the panel. No AppKit, no disk —
/// `PromptCaptureStore` owns those, `PromptHistoryPanel` owns the pixels.
enum PromptCapturePolicy {
    /// Calendar days kept, today included. Seven, not thirty: the list is a
    /// "what did I ask this week that the room never saw" shelf, and anything
    /// older is a transcript question, not a thing to still send to the notes.
    static let retentionDays = 7

    /// Prompt texts starting with any of these are machine noise that the
    /// harness injects as if it were typed. Shared with `SessionNotesAppender`
    /// so the offer pill and the history agree on what never happened.
    static let blockedPrefixes: [String] = [
        "<task-notification>",
    ]

    /// Longest prompt kept verbatim. A pasted stack trace is still a prompt,
    /// but past a few thousand characters the store stops being a store and
    /// becomes a copy of the transcript; the tail is dropped with an ellipsis
    /// so the row still says what it was.
    static let maxTextLength = 4000

    /// What the store records, already trimmed — or nil when there is nothing
    /// worth a row.
    static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !blockedPrefixes.contains(where: { trimmed.hasPrefix($0) }) else { return nil }
        guard trimmed.count > maxTextLength else { return trimmed }
        return String(trimmed.prefix(maxTextLength)) + "…"
    }

    /// Drop everything older than `retentionDays` **calendar** days (today plus
    /// the six before it), not a rolling 7×24h window: "Monday's prompts" is
    /// how the list is read, so a day should not half-disappear at lunchtime.
    static func prune(_ entries: [CapturedPrompt],
                      now: Date = Date(),
                      calendar: Calendar = .current) -> [CapturedPrompt] {
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: today) else {
            return entries
        }
        return entries.filter { $0.date >= cutoff }
    }

    /// One day's worth of prompts, newest first, under the heading the panel
    /// prints.
    struct DaySection: Equatable {
        let title: String
        let prompts: [CapturedPrompt]
    }

    /// Newest day first, newest prompt first inside it. The pill that was just
    /// missed is the one most likely to be wanted, so it must be the row the
    /// panel opens on — the scroll goes backwards in time, never forwards.
    static func sections(from entries: [CapturedPrompt],
                         now: Date = Date(),
                         calendar: Calendar = .current,
                         locale: Locale = .current) -> [DaySection] {
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { day in
            DaySection(title: dayTitle(day, now: now, calendar: calendar, locale: locale),
                       prompts: byDay[day]!.sorted { $0.date > $1.date })
        }
    }

    static func dayTitle(_ day: Date,
                         now: Date = Date(),
                         calendar: Calendar = .current,
                         locale: Locale = .current) -> String {
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(day, inSameDayAs: today) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.setLocalizedDateFormatFromTemplate("EEEE d MMM")
        return f.string(from: day)
    }

    /// Flatten a multi-line prompt onto one line so a row shows its beginning
    /// instead of its first (often empty) line. Same treatment the offer pill
    /// gives the same text.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
