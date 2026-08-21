import Foundation

/// One "hands off" claim: an agent has said it is about to drive the mouse and
/// keyboard, so Victor should stop typing until it says it is done.
///
/// Kept separate from the AppKit overlay because everything interesting here is
/// arithmetic and string composition — the two things worth a test.
///
/// The `ttl` is a **safety cap, not an estimate**. An agent that crashes, is
/// killed mid-run, or simply forgets to call `/hands-off/end` would otherwise
/// leave the frame up forever, and a warning that never clears is a warning
/// nobody reads the second time. It is deliberately not shown as a countdown:
/// a number on screen reads as "this is how long it will take", and this number
/// is only "this is when I stop believing you".
struct HandsOffSession: Equatable {
    /// Who is driving — "codex", "claude", whatever the caller says it is.
    let agent: String
    /// What it is doing, one short phrase. May be empty.
    let what: String
    let startedAt: Date
    let ttl: TimeInterval

    /// Long enough for a slow GUI dance (a settings dialog, a few menus), short
    /// enough that a dead agent's frame is gone before it becomes furniture.
    static let defaultTTL: TimeInterval = 120
    /// Hard ceiling, so a typo in `?ttl=` can't park the frame for an afternoon.
    static let maxTTL: TimeInterval = 900
    static let fallbackAgent = "agent"

    init(agent: String?, what: String?, ttl: TimeInterval?, startedAt: Date) {
        let trimmedAgent = (agent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.agent = trimmedAgent.isEmpty ? Self.fallbackAgent : trimmedAgent
        self.what = (what ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.startedAt = startedAt
        let asked = ttl ?? Self.defaultTTL
        // A non-positive ttl is a caller bug, not a request for "expire now":
        // treat it as "you didn't say" rather than dropping the frame instantly.
        self.ttl = asked <= 0 ? Self.defaultTTL : min(asked, Self.maxTTL)
    }

    /// What the badge riding the cursor says. The palm is the whole message —
    /// the words only answer "which agent, doing what", for the case where two
    /// things are running and Victor wants to know which one to wait out.
    var label: String {
        what.isEmpty ? "✋ \(agent)" : "✋ \(agent) — \(what)"
    }

    func isExpired(at now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= ttl
    }

    func remaining(at now: Date) -> TimeInterval {
        max(0, ttl - now.timeIntervalSince(startedAt))
    }
}
