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
    /// Folded (case- and diacritic-insensitive) name words, keyword words, then
    /// the extra synonyms (emojilib, emojibase shortcodes, emojidb votes).
    fileprivate let nameWords: [String]
    fileprivate let keywordWords: [String]
    fileprivate var extraWords: [String] = []
    fileprivate let foldedName: String
    /// The Romanian-only vocabulary words, folded → as written (with their
    /// diacritics), so an explanation can say "jumătate 🇷🇴" rather than
    /// "jumatate". A word both languages share ("text", "30") is not here.
    fileprivate var romanian: [String: String] = [:]

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
        return EmojiCatalog(groups: catalog.groups, entries: catalog.entries + plainArrows + textSymbols)
    }()

    /// The arrows **without** the blue keycap (Victor, 2026-10-04: *"săgețile
    /// care n-au fundal albastru, doar linii în toate direcțiile"*). Not emoji —
    /// Unicode's ← → ↑ ↓ never were, and the diagonals and ↔ ↕ only become the
    /// blue tile with FE0F — so neither `emoji-test.txt` nor CoreEmoji lists
    /// them, and they are added here by hand. The ones that *do* have an emoji
    /// twin carry FE0E (text presentation), which both keeps them distinct from
    /// that twin on the board and asks the app they land in for the plain glyph.
    /// ↗ was left out while it was on ⌥⇧U; Victor gave that key up on
    /// 2026-10-04 (*"il iau din opt-opt"*), so it is here like the rest.
    static let plainArrows: [EmojiEntry] = [
        ("←", "left arrow (plain)", "săgeată stânga (simplă)"),
        ("↑", "up arrow (plain)", "săgeată sus (simplă)"),
        ("↗\u{FE0E}", "up-right arrow (plain)", "săgeată dreapta-sus (simplă)"),
        ("→", "right arrow (plain)", "săgeată dreapta (simplă)"),
        ("↓", "down arrow (plain)", "săgeată jos (simplă)"),
        ("↖\u{FE0E}", "up-left arrow (plain)", "săgeată stânga-sus (simplă)"),
        ("↘\u{FE0E}", "down-right arrow (plain)", "săgeată dreapta-jos (simplă)"),
        ("↙\u{FE0E}", "down-left arrow (plain)", "săgeată stânga-jos (simplă)"),
        ("↔\u{FE0E}", "left-right arrow (plain)", "săgeată stânga-dreapta (simplă)"),
        ("↕\u{FE0E}", "up-down arrow (plain)", "săgeată sus-jos (simplă)"),
        ("↩\u{FE0E}", "right arrow curving left (plain)", "săgeată dreapta curbată spre stânga (simplă)"),
        ("↪\u{FE0E}", "left arrow curving right (plain)", "săgeată stânga curbată spre dreapta (simplă)"),
        ("⤴\u{FE0E}", "right arrow curving up (plain)", "săgeată dreapta curbată în sus (simplă)"),
        ("⤵\u{FE0E}", "right arrow curving down (plain)", "săgeată dreapta curbată în jos (simplă)"),
        ("↺", "counterclockwise open circle arrow", "săgeată circulară în sens antiorar"),
        ("↻", "clockwise open circle arrow", "săgeată circulară în sens orar"),
    ].map { emoji, name, nameRo in
        symbol(emoji, name, nameRo, keywords: "arrow plain line text refresh reload", keywordsRo: "săgeată simplă linie text reîncarcă")
    }

    /// Typographic symbols that are **not** emoji, so neither `emoji-test.txt`
    /// nor CoreEmoji lists them — added by hand like the plain arrows (Victor,
    /// 2026-10-04: "half" did not find ½ at all). The list is what Apple's
    /// picker remembers him using (½ ° × µ … ⋯ · » ∑ ↷ ⓶) plus their obvious
    /// siblings. Drawn in the system font (`EmojiPickerPolicy.isTextSymbol`).
    static let textSymbols: [EmojiEntry] = [
        ("½", "one half", "o jumătate", "fraction half 1 2 1/2", "jumătate fracție"),
        ("⅓", "one third", "o treime", "fraction third 1 3 1/3", "treime fracție"),
        ("⅔", "two thirds", "două treimi", "fraction thirds 2 3 2/3", "treimi fracție"),
        ("¼", "one quarter", "un sfert", "fraction quarter fourth 1 4 1/4", "sfert fracție"),
        ("¾", "three quarters", "trei sferturi", "fraction quarters 3 4 3/4", "sferturi fracție"),
        ("°", "degree", "grad", "degrees temperature celsius angle grade", "temperatură unghi"),
        ("×", "multiplication sign", "semnul înmulțirii", "times multiply cross x", "ori înmulțit"),
        ("÷", "division sign", "semnul împărțirii", "divide divided", "împărțit"),
        ("±", "plus-minus sign", "plus-minus", "plus minus approximately", "aproximativ"),
        ("≈", "almost equal to", "aproximativ egal", "approximately about roughly equal", "aproape egal"),
        ("≠", "not equal to", "diferit de", "not equal different", "inegal diferit"),
        ("≤", "less-than or equal to", "mai mic sau egal", "less equal lte", "mic egal"),
        ("≥", "greater-than or equal to", "mai mare sau egal", "greater equal gte", "mare egal"),
        ("∞", "infinity", "infinit", "infinite forever endless", "infinit"),
        ("∑", "n-ary summation", "sumă", "sum sigma total", "sumă"),
        ("µ", "micro sign", "micro", "micro mu micron", ""),
        ("…", "horizontal ellipsis", "puncte de suspensie", "ellipsis dots three", "suspensie puncte"),
        ("⋯", "midline horizontal ellipsis", "puncte de suspensie la mijloc", "ellipsis dots three middle", "suspensie puncte"),
        ("·", "middle dot", "punct la mijloc", "dot middle bullet interpunct", "punct"),
        ("•", "bullet", "buline", "bullet dot list", "punct listă"),
        ("«", "left-pointing double angle quotation mark", "ghilimele unghiulare stânga", "guillemet quote quotation", "ghilimele"),
        ("»", "right-pointing double angle quotation mark", "ghilimele unghiulare dreapta", "guillemet quote quotation", "ghilimele"),
        ("–", "en dash", "linie de pauză scurtă", "dash hyphen range", "cratimă linie"),
        ("—", "em dash", "linie de pauză", "dash long hyphen", "cratimă linie"),
        ("✓", "check mark (plain)", "bifă (simplă)", "check tick done ok yes", "bifă gata"),
        ("↷", "clockwise top semicircle arrow", "săgeată semicirculară în sens orar", "arrow redo clockwise", "săgeată refă"),
        ("⓶", "double circled digit two", "cifra doi încercuită dublu", "two 2 circled number", "doi"),
    ].map { symbol($0, $1, $2, keywords: $3, keywordsRo: $4) }

    private static func symbol(_ emoji: String, _ name: String, _ nameRo: String, keywords: String, keywordsRo: String) -> EmojiEntry {
        EmojiEntry(emoji: emoji, group: 7, name: name, nameRo: nameRo,
                   nameWords: words(name + " " + nameRo), keywordWords: words(keywords + " " + keywordsRo),
                   foldedName: fold(name), romanian: romanian(nameRo + " " + keywordsRo, english: name + " " + keywords))
    }

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
                extraWords: Self.words(row.count > 6 ? row[6] as? String ?? "" : ""),
                foldedName: Self.fold(name),
                romanian: Self.romanian(nameRo + " " + keywordsRo, english: name + " " + keywords)
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
    /// Every word typed must be the *start* of some word of the emoji's names,
    /// keywords or extra synonyms — "sad fa" finds "sad face" while it is still
    /// being typed — or, from 4 letters on, *almost* the start of one: a typo or
    /// two swapped letters still find it (Victor, 2026-10-04: *"Levenshtein
    /// Distance, să suporte typo-uri și inversiuni"*), so "lfet" and "pizaa"
    /// work. Exact beats prefix beats fuzzy; name beats keyword beats extra
    /// synonym, so "cat" puts 🐈 ahead of every face that merely has a cat ear
    /// somewhere in its tags, and a typo never outranks a correct spelling.
    /// Among equals, the shorter name wins: the query is more of what it is
    /// called ("jumătate" is all of ½'s Romanian name, a fifth of 🕧's "ora
    /// douăsprezece și jumătate"). Then the catalog's order, which is
    /// Unicode's — the order everyone's eye already knows.
    ///
    /// How sure a match is decides how it is drawn and where it lands (Victor,
    /// 2026-10-04: *"opace complet când conțin exact cuvântul … sinonime 80% …
    /// typos 50%, progresiv, minim 20%"*): see `EmojiFuzzy.opacity`. The
    /// surest come first, so the faintest end up on the board's rim.
    func search(_ query: String, limit: Int = 200) -> [EmojiEntry] {
        matches(query, limit: limit).map(\.entry)
    }

    /// `search`, with the opacity each match is drawn at.
    func matches(_ query: String, limit: Int = 200) -> [(entry: EmojiEntry, opacity: Double)] {
        let tokens = Self.words(query)
        guard !tokens.isEmpty else { return [] }
        let whole = Self.fold(query).trimmingCharacters(in: .whitespaces)
        // One distance per distinct vocabulary word per token, not per emoji.
        var costs = tokens.map { _ in [String: Int]() }
        func cost(_ t: Int, _ word: String) -> Int {
            if let known = costs[t][word] { return known }
            let value = EmojiFuzzy.prefixCost(tokens[t], word)
            costs[t][word] = value
            return value
        }
        var scored: [(opacity: Double, score: Int, length: Int, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            var score = 0
            var matched = true
            for t in tokens.indices {
                // name 0, keyword +3, extra +5 — then whatever the word itself costs.
                var best = Int.max
                for word in entry.nameWords { best = min(best, cost(t, word)) }
                if best > 1 { for word in entry.keywordWords { best = min(best, 3 + cost(t, word)) } }
                if best > 4 { for word in entry.extraWords { best = min(best, 5 + cost(t, word)) } }
                guard best < EmojiFuzzy.noMatch else { matched = false; break }
                score += best
            }
            guard matched else { continue }
            if entry.foldedName == whole { score -= 10 }
            else if entry.foldedName.hasPrefix(whole) { score -= 5 }
            // The weakest typed word decides: "sad fsce" is only as sure as "fsce".
            let opacity = tokens.indices.map { t in
                EmojiFuzzy.opacity(token: tokens[t], name: entry.nameWords.map { cost(t, $0) },
                                   keyword: entry.keywordWords.map { cost(t, $0) },
                                   synonym: entry.extraWords.map { cost(t, $0) })
            }.min() ?? 1
            scored.append((opacity, score, entry.nameWords.count, index))
        }
        scored.sort { (-$0.opacity, $0.score, $0.length, $0.index) < (-$1.opacity, $1.score, $1.length, $1.index) }
        return scored.prefix(limit).map { (entries[$0.index], $0.opacity) }
    }

    /// Why `entry` matched `query`: for each typed word, the vocabulary word
    /// it was found in, where that word comes from, and which of its letters
    /// the typed ones landed on — the same costs `search` used, so the
    /// explanation is exactly the reason, not a guess at it (Victor,
    /// 2026-10-04: *"aff"* found 💒 through a crowd synonym, "affection").
    func explain(_ query: String, _ entry: EmojiEntry) -> [EmojiMatch] {
        Self.words(query).compactMap { token in
            var best: (cost: Int, word: String, source: EmojiMatch.Source)?
            for (source, extra, words) in [(EmojiMatch.Source.name, 0, entry.nameWords),
                                           (.keyword, 3, entry.keywordWords), (.synonym, 5, entry.extraWords)] {
                for word in words {
                    let cost = extra + EmojiFuzzy.prefixCost(token, word)
                    if cost < EmojiFuzzy.noMatch, best == nil || cost < best!.cost { best = (cost, word, source) }
                }
            }
            guard let best else { return nil }
            let romanian = best.source == .synonym ? nil : entry.romanian[best.word]
            return EmojiMatch(typed: token, word: romanian ?? best.word, source: best.source,
                              matched: EmojiFuzzy.matchedLetters(token, best.word), romanian: romanian != nil)
        }
    }

    /// Folded → original for the words of `text` that `english` lacks. Only
    /// spellings whose folding keeps the letter count, so the lit offsets
    /// still land on the right letters.
    static func romanian(_ text: String, english: String) -> [String: String] {
        let shared = Set(words(english))
        var out: [String: String] = [:]
        for original in text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) where !original.isEmpty {
            let folded = fold(original)
            guard !shared.contains(folded) else { continue }
            out[folded] = folded.count == original.count ? original : folded
        }
        return out
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

/// One typed word's reason for a match (`EmojiCatalog.explain`).
struct EmojiMatch: Equatable {
    enum Source { case name, keyword, synonym }
    let typed: String
    /// Lower case; a Romanian word keeps its diacritics, an English one is
    /// folded as the search compares it.
    let word: String
    let source: Source
    /// Offsets (in characters) of `word`'s letters the typed ones matched.
    let matched: Set<Int>
    var romanian = false
}

/// How far a typed word is from a vocabulary word, for the search.
enum EmojiFuzzy {
    /// Bigger than any real cost: the word does not match at all.
    static let noMatch = 1_000

    /// 0 = the very word, 1 = a prefix of it, 4 + edits = a prefix of it with
    /// that many typos, `noMatch` = too far. An edit is a wrong, missing or
    /// extra letter, or two neighbours swapped ("lfet" → "left" is one edit:
    /// Damerau-Levenshtein, the optimal-string-alignment variant). Allowed
    /// edits grow with the word: none up to 3 letters (there "cat" ≈ "car" ≈
    /// "hat" and fuzziness would be pure noise), 1 for 4-6, 2 from 7.
    static func prefixCost(_ token: String, _ word: String) -> Int {
        if word == token { return 0 }
        if word.hasPrefix(token) { return 1 }
        let budget = token.count >= 7 ? 2 : token.count >= 4 ? 1 : 0
        guard budget > 0, word.count >= token.count - budget else { return noMatch }
        let edits = prefixDistance(Array(token.unicodeScalars), Array(word.unicodeScalars), budget: budget)
        return edits <= budget ? 4 + edits : noMatch
    }

    /// How opaque a match on `token` is drawn, from the `prefixCost`s it has
    /// against the emoji's name, keyword and extra-synonym words; the best one
    /// counts. Spelled right (whole word or its start) in the name or the
    /// keywords: 1. Spelled right only in a crowd synonym: 0.8. Only with
    /// typos: 0.5 down to 0.2, by the share of the typed letters that are
    /// wrong — 1 in 8 or less is 0.5, 2 in 7 (the most `prefixCost` allows)
    /// is 0.2, so "pizzaa" stays clear and "lfet" is barely there.
    static func opacity(token: String, name: [Int], keyword: [Int], synonym: [Int]) -> Double {
        if (name + keyword).contains(where: { $0 <= 1 }) { return 1 }
        if synonym.contains(where: { $0 <= 1 }) { return 0.8 }
        guard let cost = (name + keyword + synonym).min(), cost < noMatch else { return 0 }
        return typoOpacity(edits: cost - 4, letters: token.count)
    }

    static func typoOpacity(edits: Int, letters: Int) -> Double {
        let share = Double(edits) / Double(max(letters, 1))
        let clear = 1.0 / 8, faint = 2.0 / 7
        return min(0.5, max(0.2, 0.5 - 0.3 * (share - clear) / (faint - clear)))
    }

    /// The letters of `word` that `token` actually lands on: its first
    /// letters for an exact or prefix match, otherwise the letters left equal
    /// by the cheapest alignment against a prefix of it (the OSA table walked
    /// back) — a typo's wrong letter stays unlit.
    static func matchedLetters(_ token: String, _ word: String) -> Set<Int> {
        let a = Array(token), b = Array(word)
        if word.hasPrefix(token) { return Set(0..<a.count) }
        let n = a.count, m = min(b.count, n + 2)
        guard n > 0, m > 0 else { return [] }
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                d[i][j] = min(d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1), d[i - 1][j] + 1, d[i][j - 1] + 1)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        // The prefix of `word` the token is closest to; what follows it is free.
        var j = (0...m).min { d[n][$0] < d[n][$1] }!, i = n
        var lit = Set<Int>()
        while i > 0, j > 0 {
            if a[i - 1] == b[j - 1], d[i][j] == d[i - 1][j - 1] { lit.insert(j - 1); i -= 1; j -= 1 }
            else if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1], d[i][j] == d[i - 2][j - 2] + 1 {
                lit.formUnion([j - 1, j - 2]); i -= 2; j -= 2
            }
            else if d[i][j] == d[i - 1][j - 1] + 1 { i -= 1; j -= 1 }
            else if d[i][j] == d[i - 1][j] + 1 { i -= 1 }
            else { j -= 1 }
        }
        return lit
    }

    /// Fewest edits turning `a` into *some prefix* of `b` — the minimum of the
    /// last row of the OSA table, since what follows the prefix is free while
    /// the word is still being typed. Rows whose minimum already exceeds the
    /// budget stop the scan early.
    static func prefixDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], budget: Int) -> Int {
        let n = a.count, m = min(b.count, a.count + budget)
        var previous2 = [Int](repeating: 0, count: m + 1)
        var previous = Array(0...m)
        var current = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            current[0] = i
            var rowMin = i
            for j in stride(from: 1, through: m, by: 1) {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                var value = min(substitution, previous[j] + 1, current[j - 1] + 1)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > budget { return rowMin }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous.min() ?? n
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
                let chord = prefix(layer) + (KeymapOverlayRenderer.keyLabel(code: code) ?? "?")
                out[key] = chord
                // A key typing ↗ also stands for the board's plain ↗︎ (FE0E):
                // the same glyph, spelt the one way the board tells it apart
                // from the blue ↗️.
                if key.unicodeScalars.count == 1 { out[key + "\u{FE0E}"] = out[key + "\u{FE0E}"] ?? chord }
            }
        }
        return out
    }

    /// Drawn with the system font rather than Apple Color Emoji: the plain
    /// arrows. In the emoji font ↔ comes out as the blue tile even without
    /// FE0F, which is exactly what they are here to avoid.
    static func isTextSymbol(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return text.unicodeScalars.contains("\u{FE0E}") || !first.properties.isEmoji
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
/// Where a newcomer lands: the free cell nearest to its region's anchor.
/// Seven anchors — the four corners, the middle of the top and bottom edges,
/// and the middle of the left edge — so the board grows inward from seven
/// seeds and a face never lands among the flags. Nothing already placed is
/// ever shifted to make room; "recent first" orderings were rejected for
/// exactly that reason, since an emoji that moves is one you have to look for
/// again.
///
/// The board has a **fixed** size in cells (`columns` × `rows`) and is drawn
/// scaled to whatever panel it is in, so the 🦒 is in the same place on the
/// retina corner and on the external screen.
///
/// **25 × 13 since 2026-10-04 evening** (was 20 × 10): Victor wanted the
/// emoji a little smaller on the external screen and the retina corner 25%
/// bigger — both mean more cells, so the board grew rather than the tiles
/// merely shrinking. The old board was laid out again once
/// (`EmojiBoardStore.migrate`), keeping each region's shape.
///
/// **23 × 12 since later that night**: 15% fewer cells (Victor: *"redu
/// numărul căsuțelor cu 15%"*), same proportions, so each one is a little
/// bigger in the same panel. Laid out again once more, the same way.
///
/// **21 × 11** minutes later (*"mai elimină 2 coloane și 1 rând, păstrând
/// dimensiunea ferestrei"*): the panel stays as big, so the cells grow
/// again; both sides odd, so the search spiral has a true centre.
struct EmojiBoard: Equatable {
    static let columns = 21
    static let rows = 11

    private(set) var slots: [EmojiSlot]

    init(slots: [EmojiSlot] = []) { self.slots = slots }

    /// Where a kind of emoji grows from. Mostly Unicode's groups; the arrows
    /// are carved out of Symbols into a corner of their own (Victor,
    /// 2026-10-04: *"mută toate săgețile în colțul stânga jos … săgeți
    /// folosesc des"*), which pushed Food up to the middle of the left edge.
    enum Region: CaseIterable {
        case smileys, people, animals, food, travel, objects, arrows
    }

    static func region(group: Int) -> Region {
        switch group {
        case 0: return .smileys
        case 1: return .people
        case 2: return .animals
        case 3: return .food
        case 4, 5: return .travel
        default: return .objects
        }
    }

    static func region(for entry: EmojiEntry) -> Region {
        // "arrow" / "arrows" in a Symbols name: ⬅️ ↩️ 🔄 🔝 and the plain ones —
        // not 💘 or 🏹, which carry the word but live in other groups.
        let isArrow = entry.group == 7 && EmojiCatalog.words(entry.name).contains { $0.hasPrefix("arrow") }
        return isArrow ? .arrows : region(group: entry.group)
    }

    /// The anchor's cell coordinates (row 0 is the top) on a board of the
    /// given size — parametrised so the 20 × 10 layout can still be read back
    /// for the one-off migration.
    static func anchor(_ region: Region, columns: Int = columns, rows: Int = rows) -> (column: Double, row: Double) {
        let right = Double(columns - 1), bottom = Double(rows - 1)
        let middle = right / 2, halfway = (bottom / 2).rounded(.down)
        switch region {
        case .smileys: return (0, 0)              // top left
        case .people: return (middle, 0)          // top middle
        case .animals: return (right, 0)          // top right
        case .food: return (0, halfway)           // middle of the left edge
        case .arrows: return (0, bottom)          // bottom left
        case .travel: return (middle, bottom)     // Travel & Places, Activities — bottom middle
        case .objects: return (right, bottom)     // Objects, Symbols, Flags — bottom right
        }
    }

    /// Columns count slightly more than rows, so a corner fills as a flat
    /// quarter-disc along its edge rather than diving down the side.
    static func distance(column: Int, row: Int, to anchor: (column: Double, row: Double)) -> Double {
        let dx = Double(column) - anchor.column, dy = (Double(row) - anchor.row) * 1.15
        return dx * dx + dy * dy
    }

    /// The arrow corner is **laid out by hand**, not grown (Victor, 2026-10-04:
    /// *"săgețile în colțul stânga jos să fie puse într-o ordine cu sens"*).
    /// The eight directions sit as **compass roses around an empty centre**
    /// (later the same day: *"față de un centru gol … geografic să arate
    /// bine"*) — each arrow points away from the hole, so ↗ really is up and
    /// to the right of it. Three roses side by side, a free column between
    /// them: the plain ones, the blue ones, the hands. The plain and the blue
    /// rose touch (Victor, 2026-10-04: *"lipește cele 2 zone de săgeți"*);
    /// the hands keep one free column before them. Above them the curved
    /// and the media arrows, each plain one right above its blue twin. Top row
    /// first; the bottom row is the board's last. `""` is a hole: the roses'
    /// centres and the gaps between them. A keyed one (🔼 🔽 👉)
    /// keeps its cell empty — the hole is where it *would* be, and the shape
    /// around it holds. Every cell of the block, holes included, is reserved:
    /// no other emoji ever lands in one, and on a full board none of these is
    /// evicted.
    static let arrowBlock: [[String]] = [
        ["↩\u{FE0E}", "↪\u{FE0E}", "⤴\u{FE0E}", "⤵\u{FE0E}", "↺", "↻", "🔄", "🔃", "⏪", "⏩", "⏫", "⏬", "🔁", "🔂", "🔀"],
        ["↩️", "↪️", "⤴️", "⤵️", "◀️", "▶️", "🔼", "🔽", "↔\u{FE0E}", "↕\u{FE0E}", "↔️", "↕️"],
        ["↖\u{FE0E}", "↑", "↗\u{FE0E}", "↖️", "⬆️", "↗️", "", "", "👆", ""],
        ["←", "", "→", "⬅️", "", "➡️", "", "👈", "", "👉"],
        ["↙\u{FE0E}", "↓", "↘\u{FE0E}", "↙️", "⬇️", "↘️", "", "", "👇", ""],
    ]

    private static func blockRow(_ index: Int) -> Int { rows - arrowBlock.count + index }

    private static let arrowCells: [String: (column: Int, row: Int)] = {
        var cells: [String: (column: Int, row: Int)] = [:]
        for (index, line) in arrowBlock.enumerated() {
            for (column, emoji) in line.enumerated() where !emoji.isEmpty {
                cells[EmojiPickerPolicy.normalized(emoji)] = (column, blockRow(index))
            }
        }
        return cells
    }()

    private static let reservedCells: Set<Int> = Set(arrowBlock.enumerated().flatMap { index, line in
        line.indices.map { blockRow(index) * columns + $0 }
    })

    /// The cell set aside for this emoji in the arrow corner, if any.
    static func reservedCell(for emoji: String) -> (column: Int, row: Int)? {
        arrowCells[EmojiPickerPolicy.normalized(emoji)]
    }

    static func isReserved(column: Int, row: Int) -> Bool {
        reservedCells.contains(row * columns + column)
    }

    func slot(for emoji: String) -> EmojiSlot? {
        let key = EmojiPickerPolicy.normalized(emoji)
        return slots.first { EmojiPickerPolicy.normalized($0.emoji) == key }
    }

    func slot(column: Int, row: Int) -> EmojiSlot? {
        slots.first { $0.column == column && $0.row == row }
    }

    mutating func use(_ entry: EmojiEntry, at now: Date = Date()) {
        use(entry.emoji, region: Self.region(for: entry), at: now)
    }

    mutating func use(_ emoji: String, group: Int, at now: Date = Date()) {
        use(emoji, region: Self.region(group: group), at: now)
    }

    /// Note a use. An emoji already on the board only gets its timestamp
    /// bumped — it does **not** move. A new one takes the free cell nearest its
    /// anchor; on a full board it takes the cell of the least recently used
    /// emoji (which leaves; nothing else moves).
    mutating func use(_ emoji: String, region: Region, at now: Date = Date()) {
        if let index = slots.firstIndex(where: { EmojiPickerPolicy.normalized($0.emoji) == EmojiPickerPolicy.normalized(emoji) }) {
            slots[index].lastUsed = now
            return
        }
        if let cell = Self.reservedCell(for: emoji) {
            slots.removeAll { $0.column == cell.column && $0.row == cell.row }
            slots.append(EmojiSlot(emoji: emoji, column: cell.column, row: cell.row, lastUsed: now))
            return
        }
        let taken = Set(slots.map { $0.row * Self.columns + $0.column }).union(Self.reservedCells)
        let anchor = Self.anchor(region)
        var best: (column: Int, row: Int, distance: Double)?
        for row in 0..<Self.rows {
            for column in 0..<Self.columns where !taken.contains(row * Self.columns + column) {
                let distance = Self.distance(column: column, row: row, to: anchor)
                if best == nil || distance < best!.distance { best = (column, row, distance) }
            }
        }
        if let best {
            slots.append(EmojiSlot(emoji: emoji, column: best.column, row: best.row, lastUsed: now))
        } else if let oldest = slots.indices.filter({ !Self.isReserved(column: slots[$0].column, row: slots[$0].row) })
                    .min(by: { slots[$0].lastUsed < slots[$1].lastUsed }) {
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
            use(entry, at: Date(timeIntervalSince1970: TimeInterval(item.last)))
            added += 1
        }
    }
}

extension EmojiBoard {
    /// A board saved at another size, laid out again on this one — the one
    /// time positions are allowed to change, because the cells themselves did.
    ///
    /// Each region is replayed nearest-to-its-old-anchor first, so what sat in
    /// a corner's prime cells takes the new corner's prime cells and the
    /// cluster comes out the same shape, just moved with its anchor. Emoji
    /// whose region itself moved (the arrows, the food) are replayed the same
    /// way around their new anchor. "Last used" travels with each one.
    static func relaid(_ old: [EmojiSlot], columns oldColumns: Int, rows oldRows: Int, catalog: EmojiCatalog,
                       hadArrowCorner: Bool = false) -> EmojiBoard {
        let placed = old.compactMap { slot -> (slot: EmojiSlot, entry: EmojiEntry, distance: Double)? in
            guard let entry = catalog.entry(for: slot.emoji) else { return nil }
            // The 20 × 10 layout had no arrow corner: they grew with the Symbols.
            let oldRegion = hadArrowCorner ? region(for: entry) : region(group: entry.group)
            let oldAnchor = anchor(oldRegion, columns: oldColumns, rows: oldRows)
            return (slot, entry, distance(column: slot.column, row: slot.row, to: oldAnchor))
        }
        var board = EmojiBoard()
        for item in placed.sorted(by: { $0.distance < $1.distance }) {
            board.use(item.entry.emoji, region: region(for: item.entry), at: item.slot.lastUsed)
        }
        return board
    }

    /// Put these on the board without a use — the plain arrows and 🔄 Victor
    /// asked to find in the arrow corner from the start. Skipped when keyed or
    /// already there. A 1970 "last used", like an import: on a full board
    /// they make room before anything actually picked.
    mutating func place(_ entries: [EmojiEntry], keyed: Set<String>) {
        for entry in entries where !keyed.contains(EmojiPickerPolicy.normalized(entry.emoji)) && slot(for: entry.emoji) == nil {
            use(entry, at: Date(timeIntervalSince1970: 0))
        }
    }
}

extension EmojiBoard {
    /// The arrow block's layout changed: each arrow already on the board
    /// moves to its new reserved cell, all at once (the targets are distinct,
    /// and every one of them was reserved before too, so nothing else is in
    /// the way). Arrows taken off by hand stay off; nothing else moves.
    mutating func relocateArrowBlock() {
        slots = slots.map { slot in
            guard let cell = Self.reservedCell(for: slot.emoji), (cell.column, cell.row) != (slot.column, slot.row) else { return slot }
            return EmojiSlot(emoji: slot.emoji, column: cell.column, row: cell.row, lastUsed: slot.lastUsed)
        }
    }
}

extension EmojiBoard {
    /// Lay out the arrow corner (`arrowBlock`), once. Its arrows leave wherever
    /// they had grown and take their fixed cells, keeping their "last used";
    /// whatever else sat on those cells is moved to the free cell nearest its
    /// own anchor — the one other time something is allowed to move.
    mutating func arrangeArrowBlock(catalog: EmojiCatalog, keyed: Set<String>) {
        let lastUsed = Dictionary(slots.map { (EmojiPickerPolicy.normalized($0.emoji), $0.lastUsed) }, uniquingKeysWith: max)
        let displaced = slots.filter { Self.reservedCell(for: $0.emoji) == nil && Self.isReserved(column: $0.column, row: $0.row) }
        slots.removeAll { Self.reservedCell(for: $0.emoji) != nil || Self.isReserved(column: $0.column, row: $0.row) }
        for emoji in Self.arrowBlock.joined() where !emoji.isEmpty {
            guard let entry = catalog.entry(for: emoji) else { continue }
            let key = EmojiPickerPolicy.normalized(entry.emoji)
            guard !keyed.contains(key) else { continue }
            use(entry.emoji, region: .arrows, at: lastUsed[key] ?? Date(timeIntervalSince1970: 0))
        }
        for slot in displaced {
            guard let entry = catalog.entry(for: slot.emoji) else { continue }
            use(entry.emoji, region: Self.region(for: entry), at: slot.lastUsed)
        }
    }
}

extension EmojiBoard {
    /// The board's cells, centre first, then ring after ring outwards — where
    /// search results go (Victor, 2026-10-04: *"matricea să se umple cu
    /// rezultate … dispuse în jurul centrului, iar selecția să fie pe cel din
    /// centru"*). The best match sits in the middle, already selected, and the
    /// next best are one arrow away from it in every direction. Within a ring:
    /// clockwise from the right, so rank 2 is just right of rank 1, reading
    /// order. Cells are square on screen, so plain distance makes the rings
    /// round.
    static let cellsFromCentre: [(column: Int, row: Int)] = {
        // A real cell, so its four neighbours are exactly one arrow away
        // even when a side has an even count (12 rows: one more above).
        let centre = (column: Double(columns / 2), row: Double(rows / 2))
        var cells: [(column: Int, row: Int, distance: Double, angle: Double)] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let dx = Double(column) - centre.column, dy = Double(row) - centre.row
                // atan2 with y pointing down: 0 = right, then down, left, up.
                var angle = atan2(dy, dx)
                if angle < -1e-9 { angle += 2 * .pi }
                cells.append((column, row, dx * dx + dy * dy, angle))
            }
        }
        cells.sort { abs($0.distance - $1.distance) > 1e-9 ? $0.distance < $1.distance : $0.angle < $1.angle }
        return cells.map { ($0.column, $0.row) }
    }()

    /// Search results laid out from the centre outwards, best first. Only
    /// what fits on the board; a board for showing, never saved.
    static func searchLayout(_ results: [EmojiEntry]) -> EmojiBoard {
        EmojiBoard(slots: zip(results, cellsFromCentre).map { entry, cell in
            EmojiSlot(emoji: entry.emoji, column: cell.column, row: cell.row, lastUsed: .distantPast)
        })
    }
}

/// What was picked for what was typed (Victor, 2026-10-04: *"să rețină ce am
/// ales când am scris ce texte, să aibă precedență … ex: mic > 🎙️"*). A pick
/// made from a search is remembered under the folded query; the next search
/// for that same text puts it first, the board's centre. A query that is
/// still on its way to a remembered one ("mi" towards "mic") lifts it too,
/// just after the exact ones — from two letters on, so "m" alone does not
/// reorder everything. Only among what the search found anyway, so the
/// match explanation still holds; most picked first, then most recent.
struct EmojiQueryMemory: Codable, Equatable {
    struct Pick: Codable, Equatable {
        var count: Int
        var last: Date
    }

    /// Folded query → normalized emoji → its picks.
    private(set) var picks: [String: [String: Pick]] = [:]

    static let maxQueries = 500

    static func key(_ query: String) -> String {
        EmojiCatalog.words(query).joined(separator: " ")
    }

    mutating func record(query: String, emoji: String, at now: Date = Date()) {
        let q = Self.key(query)
        guard !q.isEmpty else { return }
        let e = EmojiPickerPolicy.normalized(emoji)
        var forQuery = picks[q] ?? [:]
        forQuery[e] = Pick(count: (forQuery[e]?.count ?? 0) + 1, last: now)
        picks[q] = forQuery
        if picks.count > Self.maxQueries {
            // Forget the query whose latest pick is the oldest.
            let stalest = picks.min { a, b in
                (a.value.values.map(\.last).max() ?? .distantPast) < (b.value.values.map(\.last).max() ?? .distantPast)
            }
            if let stalest { picks[stalest.key] = nil }
        }
    }

    /// Why `emoji` is lifted for `query`, if it is: the remembered query and
    /// its picks.
    func reason(_ query: String, _ emoji: String) -> (query: String, pick: Pick)? {
        let q = Self.key(query), e = EmojiPickerPolicy.normalized(emoji)
        if let pick = picks[q]?[e] { return (q, pick) }
        guard q.count >= 2 else { return nil }
        return picks.filter { $0.key.hasPrefix(q) && $0.value[e] != nil }
            .map { ($0.key, $0.value[e]!) }
            .max { ($0.1.count, $0.1.last) < ($1.1.count, $1.1.last) }
    }

    /// `results` with the remembered picks moved to the front: exact query
    /// first, then the ones it is a prefix of; the rest keep their order.
    func reorder(_ results: [EmojiEntry], for query: String) -> [EmojiEntry] {
        let q = Self.key(query)
        guard !q.isEmpty, !picks.isEmpty else { return results }
        func rank(_ entry: EmojiEntry) -> (tier: Int, count: Int, last: Date)? {
            guard let found = reason(query, entry.emoji) else { return nil }
            return (found.query == q ? 0 : 1, found.pick.count, found.pick.last)
        }
        let ranked = results.enumerated().compactMap { index, entry in rank(entry).map { (index, $0) } }
        guard !ranked.isEmpty else { return results }
        let lifted = ranked.sorted { a, b in
            if a.1.tier != b.1.tier { return a.1.tier < b.1.tier }
            if a.1.count != b.1.count { return a.1.count > b.1.count }
            return a.1.last > b.1.last
        }.map(\.0)
        let liftedSet = Set(lifted)
        return lifted.map { results[$0] } + results.indices.filter { !liftedSet.contains($0) }.map { results[$0] }
    }
}

enum EmojiQueryMemoryStore {
    static let defaultsKey = "EmojiPicker.queryPicks"

    static var memory: EmojiQueryMemory {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let memory = try? JSONDecoder().decode(EmojiQueryMemory.self, from: data) else { return EmojiQueryMemory() }
            return memory
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: defaultsKey) }
        }
    }
}

/// The board, in `UserDefaults`.
enum EmojiBoardStore {
    static let defaultsKey = "EmojiPicker.board"

    static let importedKey = "EmojiPicker.importedMacHistory"

    /// Which board size the saved positions belong to: absent = the first
    /// 20 × 10 board, 2 = 25 × 13 with the arrow corner, 3 = the arrow corner
    /// laid out by hand (`EmojiBoard.arrowBlock`), 4 = its compass roses,
    /// 5 = ↗ back in them once it left ⌥⇧U (plain and blue, into their
    /// reserved cells; nothing else moves), 6 = the blue rose glued to the
    /// plain one, the hands one column closer (`relocateArrowBlock`), 7 =
    /// 23 × 12, every region replayed from its old anchor (`relaid`), 8 =
    /// 21 × 11, the same way.
    static let layoutKey = "EmojiPicker.boardLayout"
    static let layoutVersion = 8

    /// Lay a 20 × 10 board out again at 25 × 13 and drop the plain arrows and
    /// 🔄 into the new arrow corner. Once: from then on nothing moves.
    static func migrate(catalog: EmojiCatalog, keyed: Set<String>) {
        let version = UserDefaults.standard.integer(forKey: layoutKey)
        guard version < layoutVersion else { return }
        var current = board
        if version < 2 {
            current = EmojiBoard.relaid(current.slots, columns: 20, rows: 10, catalog: catalog)
            overlayInfo("EmojiPicker: board laid out again at \(EmojiBoard.columns)×\(EmojiBoard.rows), \(current.slots.count) on it")
        }
        if version < 4 {
            current.arrangeArrowBlock(catalog: catalog, keyed: keyed)
        } else if version < 5 {
            // Only ↗ is new: laying the whole block out again would bring back
            // arrows taken off it by hand.
            current.place(["↗\u{FE0E}", "↗️"].compactMap(catalog.entry(for:)), keyed: keyed)
        }
        if version < 6 { current.relocateArrowBlock() }
        if version < 8 {
            // Saved on 25 × 13 (versions 2–6) or 23 × 12 (7) — a 20 × 10 one
            // was just relaid straight onto the current size above.
            if version >= 2 {
                let old = version == 7 ? (columns: 23, rows: 12) : (columns: 25, rows: 13)
                current = EmojiBoard.relaid(current.slots, columns: old.columns, rows: old.rows, catalog: catalog, hadArrowCorner: true)
            }
            overlayInfo("EmojiPicker: board laid out again at \(EmojiBoard.columns)×\(EmojiBoard.rows), \(current.slots.count) on it")
        }
        board = current
        UserDefaults.standard.set(layoutVersion, forKey: layoutKey)
        overlayInfo("EmojiPicker: arrow corner laid out by hand, \(current.slots.count) on the board")
    }

    /// The board as it should open: Apple's history folded in the first time.
    static func boardSeedingOnce(catalog: EmojiCatalog, keyed: Set<String>) -> EmojiBoard {
        migrate(catalog: catalog, keyed: keyed)
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
///
/// **The second ⌥ does not have to come back up** (Victor, 2026-10-05: "I
/// sometimes forget to let go of ⌥ the second time"). Held alone for
/// `secondHoldFire`, it counts as the tap it was meant to be — the tap asks
/// for that check (`secondPressHeld`) on a timer. It is shorter than the
/// cheat-sheet's 0.3 s on purpose, so the picker wins that race and the
/// sheet never flashes up first.
struct OptionDoubleTap {
    static let leftOptionKeyCode = 58
    static let maxHold: TimeInterval = 0.35
    static let maxGap: TimeInterval = 0.45
    static let secondHoldFire: TimeInterval = 0.25

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

    /// ⌥ is down alone right after a tap — the press that would complete the
    /// gesture, worth a `secondPressHeld` check `secondHoldFire` from now.
    var isSecondPressDown: Bool {
        guard let down = downAt, let last = lastTapAt else { return false }
        return down - last <= Self.maxGap
    }

    /// True when that second press is still down, alone, `secondHoldFire`
    /// after it began: the double tap whose ⌥ was never let go. A check left
    /// over from an earlier press finds a younger `downAt` and does nothing.
    mutating func secondPressHeld(at time: TimeInterval) -> Bool {
        guard isSecondPressDown, let down = downAt, time - down >= Self.secondHoldFire else { return false }
        interrupt()
        return true
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
