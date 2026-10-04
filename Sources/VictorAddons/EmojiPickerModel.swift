import Foundation

/// The ⌥⌥ picker's data: every emoji this Mac can draw, searchable in
/// English *and* Romanian ("piersică" finds 🍑 as surely as "peach" does).
///
/// Built offline by `tools/build-emoji-catalog.py` into `emoji-catalog.json`:
/// Unicode's order and groups, Apple's own names (CoreEmoji's AppleName, which
/// is also the filter for "this font can draw it"), CLDR keywords. Reading
/// CoreEmoji live at runtime was the alternative — it is private framework
/// data with no keyword-to-emoji map we can decode — so the join happens once,
/// at build time, and the app only ever reads a file it shipped with.
struct EmojiEntry: Equatable {
    let emoji: String
    let group: Int
    let name: String
    let nameRo: String
    /// Folded (case- and diacritic-insensitive) name words, then keyword words.
    fileprivate let nameWords: [String]
    fileprivate let keywordWords: [String]
    fileprivate let foldedName: String

    static func == (a: EmojiEntry, b: EmojiEntry) -> Bool { a.emoji == b.emoji }
}

final class EmojiCatalog {
    let groups: [String]
    let entries: [EmojiEntry]
    private let byKey: [String: EmojiEntry]

    static let shared: EmojiCatalog = {
        guard let url = Bundle.module.url(forResource: "Resources/emoji-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = EmojiCatalog(json: data) else {
            overlayError("EmojiPicker: emoji-catalog.json missing or unreadable — the picker opens empty")
            return EmojiCatalog(groups: [], entries: [])
        }
        return catalog
    }()

    init(groups: [String], entries: [EmojiEntry]) {
        self.groups = groups
        self.entries = entries
        var index: [String: EmojiEntry] = [:]
        for entry in entries { index[EmojiPickerPolicy.normalized(entry.emoji)] = entry }
        byKey = index
    }

    convenience init?(json: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let groups = root["groups"] as? [String],
              let rows = root["emoji"] as? [[Any]] else { return nil }
        var entries: [EmojiEntry] = []
        entries.reserveCapacity(rows.count)
        for row in rows {
            guard row.count >= 6,
                  let emoji = row[0] as? String, let group = row[1] as? Int,
                  let name = row[2] as? String, let nameRo = row[3] as? String,
                  let keywords = row[4] as? String, let keywordsRo = row[5] as? String else { continue }
            entries.append(EmojiEntry(
                emoji: emoji, group: group, name: name, nameRo: nameRo,
                nameWords: Self.words(name + " " + nameRo),
                keywordWords: Self.words(keywords + " " + keywordsRo),
                foldedName: Self.fold(name)
            ))
        }
        self.init(groups: groups, entries: entries)
    }

    func entry(for emoji: String) -> EmojiEntry? {
        byKey[EmojiPickerPolicy.normalized(emoji)]
    }

    // MARK: - Search

    /// Matches for what has been typed so far, best first.
    ///
    /// Every word typed must be the *start* of some word of the emoji's names
    /// or keywords — "sad fa" finds "sad face" while it is still being typed —
    /// and an emoji whose own name starts with the query outranks one that
    /// only carries it as a keyword, so "cat" puts 🐈 ahead of every face that
    /// merely has a cat ear somewhere in its tags. Ties keep the catalog's
    /// order, which is Unicode's — the order everyone's eye already knows.
    func search(_ query: String, limit: Int = 200) -> [EmojiEntry] {
        let tokens = Self.words(query)
        guard !tokens.isEmpty else { return [] }
        let whole = Self.fold(query).trimmingCharacters(in: .whitespaces)
        var scored: [(score: Int, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            var score = 0
            var matched = true
            for token in tokens {
                if entry.nameWords.contains(token) { score += 0 }
                else if entry.nameWords.contains(where: { $0.hasPrefix(token) }) { score += 1 }
                else if entry.keywordWords.contains(where: { $0.hasPrefix(token) }) { score += 3 }
                else { matched = false; break }
            }
            guard matched else { continue }
            if entry.foldedName == whole { score -= 10 }
            else if entry.foldedName.hasPrefix(whole) { score -= 5 }
            scored.append((score, index))
        }
        scored.sort { $0.score != $1.score ? $0.score < $1.score : $0.index < $1.index }
        return scored.prefix(limit).map { entries[$0.index] }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func words(_ text: String) -> [String] {
        fold(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// The rules the picker's grid lives by, kept pure so they can be tested.
enum EmojiPickerPolicy {
    /// Two spellings of one emoji compare equal: with and without the FE0F
    /// presentation selector (☁️ vs ☁), and with or without a skin tone —
    /// 👴🏻 on a key means the old man is on a key, whatever his tone.
    static func normalized(_ emoji: String) -> String {
        String(String.UnicodeScalarView(emoji.unicodeScalars.filter {
            $0.value != 0xFE0F && !(0x1F3FB...0x1F3FF).contains($0.value)
        }))
    }

    /// Every emoji already on a key, mapped to the chord that types it
    /// ("⌃⌥F"). These are the emoji the grid must **never** show: a key you
    /// already have is the faster way in, and a grid that repeats the keyboard
    /// spends its cells on the emoji you need least. The search strip still
    /// finds them — with the chord printed under them — because searching for
    /// one you forgot is exactly when the chord is worth seeing.
    static func keyedEmoji(_ layers: [EmojiKeyLayer.Layer: [Int: String]]) -> [String: String] {
        var out: [String: String] = [:]
        // ⌥ first, so an emoji bound twice reports the shortest chord.
        for layer in [EmojiKeyLayer.Layer.option, .optionShift, .controlOption] {
            for (code, text) in (layers[layer] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let key = normalized(text)
                guard out[key] == nil else { continue }
                out[key] = prefix(layer) + (KeymapOverlayRenderer.keyLabel(code: code) ?? "?")
            }
        }
        return out
    }

    static func liveKeyedEmoji() -> [String: String] {
        var layers: [EmojiKeyLayer.Layer: [Int: String]] = [:]
        for layer in EmojiKeyLayer.Layer.allCases { layers[layer] = EmojiKeyLayer.snapshot(layer).bindings }
        return keyedEmoji(layers)
    }

    private static func prefix(_ layer: EmojiKeyLayer.Layer) -> String {
        switch layer {
        case .option: return "⌥"
        case .optionShift: return "⌥⇧"
        case .controlOption: return "⌃⌥"
        }
    }
}

/// One emoji's place on the board: where it landed the first time it was
/// used, and when it was last used (only ever consulted to evict when full).
struct EmojiSlot: Codable, Equatable {
    let emoji: String
    let column: Int
    let row: Int
    var lastUsed: Date
}

/// The picker's board — **a map you learn, not a list you scroll** (Victor,
/// 2026-10-04: "niciodată nu voi da scroll prin toate"). It starts empty; an
/// emoji appears on it the first time it is used and from then on **never
/// moves**, so after a few days the hand goes to where the 🦒 lives without
/// reading anything. Everything else is reached through the search.
///
/// Where a newcomer lands: the free cell nearest to its group's anchor. Six
/// anchors — the four corners plus the middle of the top and bottom edges —
/// so the board grows inward from six seeds and a face never lands among
/// the flags. Nothing already placed is ever shifted to make room; "recent
/// first" orderings were rejected for exactly that reason, since an emoji that
/// moves is one you have to look for again.
///
/// The board has a **fixed** size in cells (`columns` × `rows`) and is drawn
/// scaled to whatever panel it is in, so the 🦒 is in the same place on the
/// retina corner and on the external screen.
struct EmojiBoard: Equatable {
    static let columns = 20
    static let rows = 10

    private(set) var slots: [EmojiSlot]

    init(slots: [EmojiSlot] = []) { self.slots = slots }

    /// Where each catalog group grows from, in cell coordinates (row 0 is the
    /// top). Nine Unicode groups over six anchors: the rarely used ones share.
    static func anchor(forGroup group: Int) -> (column: Double, row: Double) {
        let right = Double(columns - 1), bottom = Double(rows - 1), middle = right / 2
        switch group {
        case 0: return (0, 0)              // Smileys & Emotion — top left
        case 1: return (middle, 0)         // People & Body — top middle
        case 2: return (right, 0)          // Animals & Nature — top right
        case 3: return (0, bottom)         // Food & Drink — bottom left
        case 4, 5: return (middle, bottom) // Travel & Places, Activities — bottom middle
        default: return (right, bottom)    // Objects, Symbols, Flags — bottom right
        }
    }

    func slot(for emoji: String) -> EmojiSlot? {
        let key = EmojiPickerPolicy.normalized(emoji)
        return slots.first { EmojiPickerPolicy.normalized($0.emoji) == key }
    }

    func slot(column: Int, row: Int) -> EmojiSlot? {
        slots.first { $0.column == column && $0.row == row }
    }

    /// Note a use. An emoji already on the board only gets its timestamp
    /// bumped — it does **not** move. A new one takes the free cell nearest its
    /// anchor; on a full board it takes the cell of the least recently used
    /// emoji (which leaves; nothing else moves).
    mutating func use(_ emoji: String, group: Int, at now: Date = Date()) {
        if let index = slots.firstIndex(where: { EmojiPickerPolicy.normalized($0.emoji) == EmojiPickerPolicy.normalized(emoji) }) {
            slots[index].lastUsed = now
            return
        }
        let taken = Set(slots.map { $0.row * Self.columns + $0.column })
        let anchor = Self.anchor(forGroup: group)
        var best: (column: Int, row: Int, distance: Double)?
        for row in 0..<Self.rows {
            for column in 0..<Self.columns where !taken.contains(row * Self.columns + column) {
                // Columns count slightly more than rows, so a corner fills as a
                // flat quarter-disc along its edge rather than diving down the side.
                let dx = Double(column) - anchor.column, dy = (Double(row) - anchor.row) * 1.15
                let distance = dx * dx + dy * dy
                if best == nil || distance < best!.distance { best = (column, row, distance) }
            }
        }
        if let best {
            slots.append(EmojiSlot(emoji: emoji, column: best.column, row: best.row, lastUsed: now))
        } else if let oldest = slots.indices.min(by: { slots[$0].lastUsed < slots[$1].lastUsed }) {
            let freed = slots.remove(at: oldest)
            slots.append(EmojiSlot(emoji: emoji, column: freed.column, row: freed.row, lastUsed: now))
        }
    }

    /// Taken off by hand (the hover ✕). Its cell is free for the next
    /// newcomer; nothing else moves. Picking it again later lands it afresh.
    mutating func remove(_ emoji: String) {
        let key = EmojiPickerPolicy.normalized(emoji)
        slots.removeAll { EmojiPickerPolicy.normalized($0.emoji) == key }
    }

    /// Emoji that have since been put on a key leave the board — the grid must
    /// never show one — and their cell is free again. Nothing else moves.
    mutating func removeKeyed(_ keyed: Set<String>) {
        slots.removeAll { keyed.contains(EmojiPickerPolicy.normalized($0.emoji)) }
    }
}

/// What Apple's own emoji picker remembers — Victor used it for years before
/// this board existed (*"dacă mai poți extrage din macOS și altele mai vechi
/// folosite"*). `com.apple.EmojiPreferences` → `EMFDefaultsKey` →
/// `EMFUsageHistoryKey` maps each emoji to the sequence numbers of its uses (a
/// counter shared by every pick; 627 on 2026-10-04), so it gives both how
/// often and how recently — more than `EMFRecentsKey`, which is only an order.
enum MacEmojiHistory {
    struct Use: Equatable {
        let emoji: String
        let count: Int
        let last: Int
    }

    static func read() -> [Use] {
        guard let root = CFPreferencesCopyAppValue("EMFDefaultsKey" as CFString, "com.apple.EmojiPreferences" as CFString) as? [String: Any],
              let history = root["EMFUsageHistoryKey"] as? [String: [Int]] else { return [] }
        return history.map { Use(emoji: $0.key, count: $0.value.count, last: $0.value.max() ?? 0) }
    }
}

extension EmojiBoard {
    static let importCap = 140

    /// Seed the board from Apple's history, **once**. Most used first, ties to
    /// the most recent, so the emoji he reaches for most get the cells nearest
    /// their anchors — the prime spots — and the long tail lands further out.
    /// Emoji already on the board stay exactly where they are (they are only
    /// skipped), keyed ones and anything the catalogue can't draw (←, °, µ —
    /// Apple's picker also hands out symbols) are left out, and at most
    /// `importCap` cells are taken so the board still has room to grow.
    ///
    /// Imported emoji get a "last used" from Apple's sequence number, i.e. a
    /// date in 1970: older than any real pick, so on a full board they are the
    /// first to make room, oldest first.
    mutating func importHistory(_ uses: [MacEmojiHistory.Use], catalog: EmojiCatalog, keyed: Set<String>) {
        var added = 0
        let ranked = uses.sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
        for item in ranked where added < Self.importCap {
            guard let entry = catalog.entry(for: item.emoji),
                  !keyed.contains(EmojiPickerPolicy.normalized(entry.emoji)),
                  slot(for: entry.emoji) == nil,
                  slots.count < Self.columns * Self.rows else { continue }
            use(entry.emoji, group: entry.group, at: Date(timeIntervalSince1970: TimeInterval(item.last)))
            added += 1
        }
    }
}

/// The board, in `UserDefaults`.
enum EmojiBoardStore {
    static let defaultsKey = "EmojiPicker.board"

    static let importedKey = "EmojiPicker.importedMacHistory"

    /// The board as it should open: Apple's history folded in the first time.
    static func boardSeedingOnce(catalog: EmojiCatalog, keyed: Set<String>) -> EmojiBoard {
        var current = board
        guard !UserDefaults.standard.bool(forKey: importedKey) else { return current }
        let history = MacEmojiHistory.read()
        current.importHistory(history, catalog: catalog, keyed: keyed)
        board = current
        UserDefaults.standard.set(true, forKey: importedKey)
        overlayInfo("EmojiPicker: seeded the board from macOS history (\(history.count) emoji there, \(current.slots.count) on the board now)")
        return current
    }

    static var board: EmojiBoard {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let slots = try? JSONDecoder().decode([EmojiSlot].self, from: data) else { return EmojiBoard() }
            return EmojiBoard(slots: slots)
        }
        set {
            if let data = try? JSONEncoder().encode(newValue.slots) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }
}

/// Left ⌥ tapped twice, alone — what opens the picker (Victor, 2026-10-04).
///
/// A tap is a press and release of the **left** ⌥ with nothing else held and
/// nothing typed in between, short enough not to be a hold (a hold is the ⌥
/// cheat-sheet's gesture, 0.3 s on a multi-monitor desk). Any other key, any
/// other modifier, or the right ⌥ breaks the sequence, so ⌥-typing an emoji
/// twice in a row — ⌥ down, key, ⌥ up — never counts.
struct OptionDoubleTap {
    static let leftOptionKeyCode = 58
    static let maxHold: TimeInterval = 0.35
    static let maxGap: TimeInterval = 0.45

    private var downAt: TimeInterval?
    private var lastTapAt: TimeInterval?

    /// Feed every flagsChanged event; true when it completes the second tap.
    mutating func flagsChanged(keyCode: Int, optionDown: Bool, optionAlone: Bool, at time: TimeInterval) -> Bool {
        guard keyCode == Self.leftOptionKeyCode else { interrupt(); return false }
        if optionDown {
            if optionAlone { downAt = time } else { interrupt() }
            return false
        }
        guard let down = downAt, time - down <= Self.maxHold else { interrupt(); return false }
        downAt = nil
        if let last = lastTapAt, time - last <= Self.maxGap {
            lastTapAt = nil
            return true
        }
        lastTapAt = time
        return false
    }

    /// A key was pressed: whatever ⌥ was doing, it was not a tap.
    mutating func interrupt() {
        downAt = nil
        lastTapAt = nil
    }
}

/// What a keystroke means to the open picker. The picker never takes the
/// keyboard focus (see `EmojiPickerController`), so the event tap swallows
/// keystrokes while it is up and hands them over as one of these.
enum EmojiPickerKey: Equatable {
    case escape, enter, backspace, left, right, up, down
    case text(String)
    /// Swallowed, does nothing (Tab, function keys, ⌥ chords).
    case ignore
    /// A ⌘ or ⌃ chord: a shortcut for the app underneath. It goes through
    /// untouched and the picker closes — you reached for something else.
    case passThrough

    static func from(keyCode: Int, characters: String, command: Bool, control: Bool, option: Bool) -> EmojiPickerKey {
        if command || control { return .passThrough }
        switch keyCode {
        case 53: return .escape
        case 36, 76: return .enter
        case 51: return .backspace
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 48: return .ignore
        default: break
        }
        if option { return .ignore }
        // Function keys arrive as private-use characters (0xF700…), control
        // characters below space: neither belongs in a search box.
        let printable = String(String.UnicodeScalarView(characters.unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
        }))
        return printable.isEmpty ? .ignore : .text(printable)
    }
}
