import Cocoa

/// ✈️ "Check in now: Ryanair → Otopeni": an orange pill in the bottom-left
/// corner of every screen that **stays until Victor clicks it**. The click opens
/// the airline's mail in his Chrome, on the screen under the mouse, and takes
/// the pill down; a right-click takes it down without opening anything.
///
/// Asked for on 2026-10-08 (Victor: *"I forgot many times to do the check-in"*).
/// Click-only like the 🎤 DJI alarm (`MicDeadAlarm`), not hover-to-dismiss like
/// the roaming pill: the point is that it cannot be brushed away by a hand
/// passing through the corner on the way to the Dock.
///
/// **It survives restarts.** The waiting mails are kept in `UserDefaults`
/// (`checkin.pending`), because the mail has already been marked read by the
/// time the pill shows: if a restart dropped the pill, nothing would be left to
/// remind him. Several at once queue up; the pill shows the oldest with `(+N)`.
final class CheckInAlarm {
    static let color = NSColor.systemOrange.withAlphaComponent(0.9)
    /// The corner pill's 54 pt cuts a sentence on the retina; same as the 🎤 alarm.
    static let fontSize: CGFloat = 34
    private static let pendingKey = "checkin.pending"

    private let screensProvider: () -> [NSScreen]
    private let sound: () -> Void
    /// Opens the mail; injectable so the tests open nothing.
    private let openURL: (String) -> Void
    private let defaults: UserDefaults
    private var banner: BottomLeftBanner?
    private var shownThreadId: String?
    /// Where a *test* pill draws (`/test/checkin/simulate` keeps it off the
    /// projected retina); nil is every screen. Cleared once the queue drains.
    private var screensOverride: (() -> [NSScreen])?

    init(screensProvider: @escaping () -> [NSScreen] = { NSScreen.physical },
         sound: @escaping () -> Void = { NSSound(named: NSSound.Name("Glass"))?.play() },
         openURL: @escaping (String) -> Void = { OfficialChrome.open($0) },
         defaults: UserDefaults = .standard) {
        self.screensProvider = screensProvider
        self.sound = sound
        self.openURL = openURL
        self.defaults = defaults
    }

    private(set) var pending: [CheckInMailPolicy.Hit] {
        get {
            guard let data = defaults.data(forKey: Self.pendingKey) else { return [] }
            return (try? JSONDecoder().decode([CheckInMailPolicy.Hit].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty { defaults.removeObject(forKey: Self.pendingKey) }
            else if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.pendingKey) }
        }
    }

    var isRaised: Bool { !pending.isEmpty }

    /// At launch: whatever was still waiting when the app last quit, silently —
    /// it already rang once.
    func restore() {
        guard isRaised else { return }
        overlayInfo("✈️ check-in alarm restored: \(pending.count) waiting")
        present()
    }

    /// New check-in mails: queue them and ring.
    func raise(_ hits: [CheckInMailPolicy.Hit], screens: (() -> [NSScreen])? = nil) {
        if let screens { screensOverride = screens }
        let known = Set(pending.map(\.threadId))
        let added = hits.filter { !known.contains($0.threadId) }
        guard !added.isEmpty else { return }
        pending += added
        for h in added { overlayInfo("✈️ check-in alarm: \(h.from) — \(h.subject)") }
        present()
        sound()
    }

    /// Show (or refresh) the pill for the oldest waiting mail.
    private func present() {
        guard let first = pending.first else {
            banner?.dismissSinking()
            banner = nil
            shownThreadId = nil
            screensOverride = nil
            return
        }
        let text = CheckInMailPolicy.text(first, alsoPending: pending.count - 1)
        shownThreadId = first.threadId
        if let b = banner, b.isVisible {
            b.updateText(text)
            return
        }
        let b = BottomLeftBanner(screensProvider: screensOverride ?? screensProvider, hoverable: true)
        banner = b
        b.clickOnly = true
        b.onHover = { [weak self] in self?.acknowledge(open: true) }
        // Right-click is the pill's "other exit": seen, but don't open it.
        b.onHoverCountdownExpired = { [weak self] in self?.acknowledge(open: false) }
        b.show(text: text, backgroundColor: Self.color,
               font: NSFont.boldSystemFont(ofSize: Self.fontSize))
    }

    /// The pill was clicked: open that mail (or not) and move to the next one.
    func acknowledge(open: Bool) {
        guard let id = shownThreadId, let hit = pending.first(where: { $0.threadId == id }) else { return }
        overlayInfo("✈️ check-in alarm \(open ? "clicked — opening the mail" : "dismissed"): \(hit.subject)")
        if open { openURL(CheckInMailPolicy.gmailURL(threadId: id)) }
        pending.removeAll { $0.threadId == id }
        // The pill being clicked is spent (its click handler has fired once);
        // the next mail, if any, gets a fresh one.
        banner?.dismissSinking()
        banner = nil
        shownThreadId = nil
        if isRaised { present() } else { screensOverride = nil }
    }

    /// `GET /test/checkin/clear` — drop the whole queue, opening nothing.
    func clearAll() {
        pending = []
        present()
    }

    func stateJSON() -> String {
        let items = pending.map { "{\"threadId\":\"\($0.threadId)\",\"text\":\(Self.quote(CheckInMailPolicy.text($0)))}" }
        return "{\"pending\":[\(items.joined(separator: ","))],\"visible\":\(banner?.isVisible ?? false)}"
    }

    static func quote(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }
}
