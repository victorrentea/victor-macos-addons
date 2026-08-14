import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum KeymapModifier: String, Equatable {
    case option
    case optionShift
    /// The ⌘⌃ cheat-sheet. Unlike the two above it is NOT read from the active
    /// .keylayout — ⌘⌃ combinations are app shortcuts (this app's event tap),
    /// not characters — so its contents come from `CommandControlShortcuts`.
    case commandControl
}

/// What ⌘⌃<key> does, as one word drawn inside that key on the cheat-sheet.
/// Key codes are the same virtual key codes `KeymapOverlayRenderer` draws with,
/// and the entries must stay in sync with the ⌘⌃ branches in `EventTapManager`
/// — with one deliberate exception, marked below: the sheet answers "what does
/// this combination do on THIS Mac", and a ⌘⌃ shortcut owned by another app is
/// still an answer to that question. Leaving it blank would say "nothing here",
/// which is worse than saying who does own it.
enum CommandControlShortcuts {
    static let labels: [Int: String] = [
        0:  "tile",      // A — tile Terminal windows
        8:  "claude",    // C — Claude Code in a new Terminal
        14: "email",     // E — paste Victor's email address
        // G (key 5) is drawn from `artworkNames` below, not from a word.
        40: "catalog",   // K — training Catalog.docx (the 📕 rides in the corner)
        37: "📅",        // L — Google Calendar
        46: "todo",      // M — Gmail draft to myself, clipboard in the body
        // N (key 45) is drawn from `artworkNames` below: it opens the "notes"
        // Google Doc, and the Docs mark says that faster than any word could.
        15: "SRL",       // R — paste the company's invoicing details
        1:  "notes",     // S — send the selection to the training notes
        17: "terminal",  // T — empty Terminal in ~/workspace
        12: "claude",    // Q — Claude Code with permissions bypassed (`cx`)
        6:  "zoom",      // Z — paste Victor's personal Zoom room link
        13: "wispr🎙️",   // W — paste the Wispr transcript. NOT ours: the shortcut
                         // lives in Wispr Flow and we must NOT claim it. The tap's
                         // ⌃W → 🔥 Whip branch requires !hasCmd, so ⌘⌃W passes
                         // straight through to Wispr; this entry is display-only.
                         // The studio 🎙️ says whose paste it is: the listening is
                         // Wispr's job, never this app's.
        // V (key 9) is deliberately ABSENT even though ⌘⌃V is still bound here to
        // the emotional paste. "Paste" now means ⌘⌃W to the hand, and two keys
        // both reading "paste" on the sheet would make the reader pick the wrong
        // one at speed. The tap keeps serving ⌘⌃V; only the hint is gone.
    ]

    /// A small mark in the key's top-right corner, opposite the base letter —
    /// a second, faster read for keys whose word alone ("email", "zoom",
    /// "notes", "SRL", "catalog") names a noun rather than picturing what
    /// happens to it. The word stays: the mark is the glance, the word the
    /// confirmation.
    static let accents: [Int: String] = [
        14: "@",   // E — email
        6:  "🔗",  // Z — the Zoom room link
        1:  "🚀",  // S — the selection is launched into the notes
        15: "📋",  // R — the SRL details are pasted, not opened
        40: "📕",  // K — the training catalog
        46: "✉️",  // M — "todo" is the list; the envelope says it arrives as mail
    ]

    /// Keys whose payload is a bundled picture rather than a word, by key code.
    /// A logo is recognised faster than the word for it, and Gmail's is the one
    /// destination here with a mark everyone already knows by sight.
    static let artworkNames: [Int: String] = [
        5:  "gmail-logo",  // G — Gmail
        45: "gdocs-logo",  // N — open the "notes" Google Doc in Chrome
    ]

    /// The sheet's payload for a key, whatever form it takes — used by the
    /// "every ⌘⌃ branch is on the sheet" checks, which don't care whether the
    /// answer is drawn as a word, an emoji or a logo.
    static var boundKeyCodes: Set<Int> {
        Set(labels.keys).union(artworkNames.keys)
    }

    static func artworkImages(bundle: Bundle = .module) -> [Int: NSImage] {
        var images: [Int: NSImage] = [:]
        for (code, name) in artworkNames {
            guard let url = bundle.url(forResource: name, withExtension: "png"),
                  let image = NSImage(contentsOf: url) else { continue }
            images[code] = image
        }
        return images
    }
}

enum KeymapOverlaySettings {
    static let enabledKey = "EmojiOverlay.enabled"

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }
}

enum KeymapLayoutParser {
    enum ParseError: Error {
        case missingModifierMap
        case missingModifier(KeymapModifier)
        case missingKeyMapSet(String)
        case missingKeyMap(String)
        case missingFirstMapSet
    }

    static func modifierMapIndex(in text: String, modifier: KeymapModifier) throws -> String {
        let modifierMap = try firstCapture(
            in: text,
            pattern: #"<modifierMap\b[^>]*>([\s\S]*?)</modifierMap>"#,
            error: ParseError.missingModifierMap
        )
        let selects = matches(
            in: modifierMap,
            pattern: #"<keyMapSelect\b[^>]*mapIndex="([^"]+)"[^>]*>([\s\S]*?)</keyMapSelect>"#
        )
        for select in selects {
            guard select.count >= 3 else { continue }
            let index = select[1]
            let block = select[2]
            switch modifier {
            case .option:
                if block.contains(#"<modifier keys="anyOption"/>"#) { return index }
            case .optionShift:
                if block.contains(#"<modifier keys="anyShift caps? anyOption command?"/>"#) { return index }
            case .commandControl:
                // Not a layout modifier — the ⌘⌃ sheet never goes through the parser.
                throw ParseError.missingModifier(modifier)
            }
        }
        throw ParseError.missingModifier(modifier)
    }

    static func firstLayoutMapSet(in text: String) throws -> String {
        try firstCapture(
            in: text,
            pattern: #"<layout\b[^>]*\bmapSet="([^"]+)""#,
            error: ParseError.missingFirstMapSet
        )
    }

    static func outputs(in text: String, mapSet: String, mapIndex: String) throws -> [Int: String] {
        let actions = parseActions(in: text)
        let keyMapSet = try firstCapture(
            in: text,
            pattern: #"<keyMapSet\b[^>]*id="\#(NSRegularExpression.escapedPattern(for: mapSet))"[^>]*>([\s\S]*?)</keyMapSet>"#,
            error: ParseError.missingKeyMapSet(mapSet)
        )
        let keyMap = try firstCapture(
            in: keyMapSet,
            pattern: #"<keyMap\b[^>]*index="\#(NSRegularExpression.escapedPattern(for: mapIndex))"[^>]*>([\s\S]*?)</keyMap>"#,
            error: ParseError.missingKeyMap(mapIndex)
        )

        var result: [Int: String] = [:]
        for key in matches(in: keyMap, pattern: #"<key\b([^>]*)/>"#) {
            guard key.count >= 2 else { continue }
            let attrs = key[1]
            guard let codeText = attr("code", in: attrs), let code = Int(codeText) else { continue }
            if let output = attr("output", in: attrs) {
                result[code] = normalizeOutput(xmlUnescape(output))
            } else if let action = attr("action", in: attrs) {
                result[code] = actions[xmlUnescape(action)] ?? "action \(xmlUnescape(action))"
            }
        }
        return result
    }

    static func outputs(in text: String, modifier: KeymapModifier) throws -> [Int: String] {
        let mapSet = try firstLayoutMapSet(in: text)
        let mapIndex = try modifierMapIndex(in: text, modifier: modifier)
        return try outputs(in: text, mapSet: mapSet, mapIndex: mapIndex)
    }

    private static func parseActions(in text: String) -> [String: String] {
        guard let actionsBlock = try? firstCapture(
            in: text,
            pattern: #"<actions>([\s\S]*?)</actions>"#,
            error: ParseError.missingModifierMap
        ) else { return [:] }

        let terminators = parseTerminators(in: text)
        var actions: [String: String] = [:]
        for action in matches(in: actionsBlock, pattern: #"<action\b[^>]*id="([^"]+)"[^>]*>([\s\S]*?)</action>"#) {
            guard action.count >= 3 else { continue }
            let id = xmlUnescape(action[1])
            let block = action[2]
            guard let whenNone = matches(in: block, pattern: #"<when\b[^>]*state="none"[^>]*/>"#).first?.first else { continue }
            if let output = attr("output", in: whenNone) {
                actions[id] = normalizeOutput(xmlUnescape(output))
            } else if let next = attr("next", in: whenNone) {
                actions[id] = "dead \(terminators[next] ?? next)"
            }
        }
        return actions
    }

    private static func parseTerminators(in text: String) -> [String: String] {
        guard let block = try? firstCapture(
            in: text,
            pattern: #"<terminators>([\s\S]*?)</terminators>"#,
            error: ParseError.missingModifierMap
        ) else { return [:] }
        var result: [String: String] = [:]
        for when in matches(in: block, pattern: #"<when\b([^>]*)/>"#) {
            guard when.count >= 2 else { continue }
            let attrs = when[1]
            if let state = attr("state", in: attrs), let output = attr("output", in: attrs) {
                result[state] = normalizeOutput(xmlUnescape(output))
            }
        }
        return result
    }

    private static func normalizeOutput(_ value: String) -> String {
        if value == "\u{1}" { return "SOH" }
        if value == "\u{3}" { return "Enter" }
        if value == "\u{4}" { return "EOT" }
        if value == "\u{5}" { return "ENQ" }
        if value == "\u{8}" { return "⌫" }
        if value == "\u{9}" { return "Tab" }
        if value == "\u{b}" { return "VT" }
        if value == "\u{c}" { return "FF" }
        if value == "\u{d}" { return "Return" }
        if value == "\u{10}" { return "DLE" }
        if value == "\u{1b}" { return "Esc" }
        if value == "\u{1c}" { return "←" }
        if value == "\u{1d}" { return "→" }
        if value == "\u{1e}" { return "↑" }
        if value == "\u{1f}" { return "↓" }
        if value == "\u{7f}" { return "⌦" }
        if value == "\u{a0}" { return "NBSP" }
        if value.count == 1, let scalar = value.unicodeScalars.first, scalar.value < 32 {
            return String(format: "U+%04X", scalar.value)
        }
        return value
    }

    private static func attr(_ name: String, in text: String) -> String? {
        try? firstCapture(
            in: text,
            pattern: #"\#(NSRegularExpression.escapedPattern(for: name))="([^"]*)""#,
            error: ParseError.missingModifierMap
        )
    }

    private static func firstCapture(in text: String, pattern: String, error: Error) throws -> String {
        guard let match = matches(in: text, pattern: pattern).first, match.count >= 2 else {
            throw error
        }
        return match[1]
    }

    private static func matches(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : nsText.substring(with: range)
            }
        }
    }

    private static func xmlUnescape(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")

        let pattern = #"&#x([0-9A-Fa-f]+);|&#([0-9]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = result as NSString
        var rebuilt = ""
        var cursor = 0
        for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
            rebuilt += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let hexRange = match.range(at: 1)
            let decRange = match.range(at: 2)
            let code: UInt32?
            if hexRange.location != NSNotFound {
                code = UInt32(ns.substring(with: hexRange), radix: 16)
            } else if decRange.location != NSNotFound {
                code = UInt32(ns.substring(with: decRange), radix: 10)
            } else {
                code = nil
            }
            if let code, let scalar = UnicodeScalar(code) {
                rebuilt += String(scalar)
            }
            cursor = match.range.location + match.range.length
        }
        rebuilt += ns.substring(from: cursor)
        result = rebuilt
        return result
    }
}

enum KeymapLayoutLocator {
    // Ask Text Input Sources (live, in-process) first and only fall back to the
    // cached HIToolbox preferences. `defaults read` goes through cfprefsd, which
    // lags the actual selection — at login (and right after Ukelele installs a
    // new layout bundle) it can still report the previous/system layout, or the
    // key can be missing entirely. That's how the overlay ended up with no
    // images at all: one failed read at startup and it never tried again.
    static func activeLayoutName() -> String? {
        activeLayoutNameFromInputSource() ?? activeLayoutNameFromPreferences()
    }

    static func activeLayoutNameFromInputSource() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
        let name = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return name.isEmpty ? nil : name
    }

    static func activeLayoutNameFromPreferences() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.HIToolbox", "AppleSelectedInputSources"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let quoted = output.range(of: #""KeyboardLayout Name"\s*=\s*"([^"]+)""#, options: .regularExpression) {
            let segment = String(output[quoted])
            return segment.replacingOccurrences(of: #""KeyboardLayout Name"\s*=\s*""#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #""$"#, with: "", options: .regularExpression)
        }
        if let range = output.range(of: #""KeyboardLayout Name"\s*=\s*([^;]+);"#, options: .regularExpression) {
            let segment = String(output[range])
            return segment.replacingOccurrences(of: #""KeyboardLayout Name"\s*=\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #";$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func keylayoutURL(named name: String, base: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keyboard Layouts")) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "\(name).keylayout" {
                return url
            }
        }
        return nil
    }
}

enum KeymapOverlayOutputFilter {
    // Standard macOS U.S./ABC Option outputs for the physical keys drawn by
    // KeymapOverlayRenderer. Values matching these are baseline characters, not
    // explicit emoji bindings, so the overlay leaves those keys blank.
    private static let optionDefaults: [Int: String] = [
        18: "¡", 19: "™", 20: "£", 21: "¢", 23: "∞", 22: "§", 26: "¶", 28: "•", 25: "ª", 29: "º", 27: "–", 24: "≠",
        12: "œ", 13: "∑", 14: "dead ´", 15: "®", 17: "†", 16: "¥", 32: "dead ¨", 34: "dead ˆ", 31: "ø", 35: "π", 33: "“", 30: "‘", 42: "«",
        0: "å", 1: "ß", 2: "∂", 3: "ƒ", 5: "©", 4: "dead ˙", 38: "∆", 40: "dead ˚", 37: "¬", 41: "…", 39: "æ",
        6: "Ω", 7: "≈", 8: "ç", 9: "√", 11: "∫", 45: "dead ˜", 46: "µ", 43: "≤", 47: "≥", 44: "÷",
    ]

    private static let optionShiftDefaults: [Int: String] = [
        18: "⁄", 19: "€", 20: "‹", 21: "›", 23: "ﬁ", 22: "ﬂ", 26: "‡", 28: "°", 25: "·", 29: "‚", 27: "—", 24: "±",
        12: "Œ", 13: "„", 14: "dead ´", 15: "‰", 17: "dead ˇ", 16: "Á", 32: "dead ¨", 34: "dead ˆ", 31: "Ø", 35: "∏", 33: "”", 30: "’", 42: "»",
        0: "Å", 1: "Í", 2: "Î", 3: "Ï", 5: "dead ˝", 4: "Ó", 38: "Ô", 40: "", 37: "Ò", 41: "Ú", 39: "Æ",
        6: "dead ¸", 7: "dead ˛", 8: "Ç", 9: "◊", 11: "ı", 45: "dead ˜", 46: "Â", 43: "dead ¯", 47: "dead ˘", 44: "¿",
    ]

    static func customOutputs(from outputs: [Int: String], modifier: KeymapModifier) -> [Int: String] {
        let defaults: [Int: String]
        switch modifier {
        case .option: defaults = optionDefaults
        case .optionShift: defaults = optionShiftDefaults
        // Nothing baseline to strip: every ⌘⌃ entry is an explicit binding.
        case .commandControl: defaults = [:]
        }
        return outputs.filter { code, output in
            output != defaults[code]
        }
    }
}

enum KeymapOverlayPlacement {
    static func frame(retinaFrame: NSRect, externalFrames: [NSRect], imageAspectRatio: CGFloat, mouseLocation: CGPoint? = nil) -> NSRect {
        // Never place the overlay on the screen the mouse is currently on — the
        // cheat-sheet must not land under the cursor / cover what Victor is
        // actively working on. So drop any external screen containing the mouse
        // from the candidates; if that empties the list (mouse is on the only
        // external), we fall through to the single-monitor retina-corner path.
        let candidates: [NSRect]
        if let mouse = mouseLocation {
            candidates = externalFrames.filter { !$0.contains(mouse) }
        } else {
            candidates = externalFrames
        }

        guard let external = rightmostExternal(among: candidates) else {
            let width = retinaFrame.width / 3.0
            let height = width / imageAspectRatio
            return NSRect(x: retinaFrame.maxX - width, y: retinaFrame.minY, width: width, height: height)
        }

        // When a second monitor is present (and the mouse isn't on it), occupy
        // the ENTIRE external screen. The window covers the whole monitor; the
        // keyboard image is scaled to fit (aspect-preserved, centered) by the
        // image view. Single-monitor placement above is unchanged.
        return external
    }

    // Among the candidate external screens, prefer the RIGHTMOST one (greatest
    // left-edge x). With Victor's 3-monitor home rig (retina + two externals) the
    // cheat-sheet lands on the right monitor, which is where he wants it — not
    // whichever external happens to sit closest to the built-in display. Ties
    // (screens stacked vertically at the same x) resolve to the topmost.
    private static func rightmostExternal(among externalFrames: [NSRect]) -> NSRect? {
        externalFrames.max { a, b in
            if a.minX != b.minX { return a.minX < b.minX }
            return a.minY < b.minY
        }
    }
}

final class KeymapHoldCoordinator {
    // The overlay lands on a secondary screen when one exists, so it's
    // unobtrusive there and can appear quickly; on a single monitor it
    // covers the only screen, so require a longer hold before showing it.
    static let multiMonitorDelay: TimeInterval = 0.3
    static let singleMonitorDelay: TimeInterval = 1.0

    static func delay(monitorCount: Int) -> TimeInterval {
        monitorCount > 1 ? multiMonitorDelay : singleMonitorDelay
    }

    /// Which cheat-sheet a held modifier combination asks for, or nil for
    /// "none of them". Deliberately exact: ⌥ alone (± ⇧) is the character
    /// layout, ⌘⌃ alone is the shortcut sheet. Anything mixed — ⌘⌃⌥ (Dark
    /// Mode), ⌃⌥ (notes) — shows nothing rather than guessing.
    static func sheet(option: Bool, shift: Bool, command: Bool, control: Bool) -> KeymapModifier? {
        if command && control && !option { return .commandControl }
        if option && !command && !control { return shift ? .optionShift : .option }
        return nil
    }

    private let delayProvider: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let cancelScheduled: () -> Void
    private let show: (KeymapModifier) -> Void
    private let hide: () -> Void
    private var pendingModifier: KeymapModifier?
    private var visibleModifier: KeymapModifier?

    init(
        delayProvider: @escaping () -> TimeInterval,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
        cancelScheduled: @escaping () -> Void,
        show: @escaping (KeymapModifier) -> Void,
        hide: @escaping () -> Void
    ) {
        self.delayProvider = delayProvider
        self.schedule = schedule
        self.cancelScheduled = cancelScheduled
        self.show = show
        self.hide = hide
    }

    func modifierFlagsChanged(option: Bool, shift: Bool, command: Bool = false, control: Bool = false) {
        guard let modifier = Self.sheet(option: option, shift: shift, command: command, control: control) else {
            reset()
            return
        }

        if visibleModifier != nil {
            if visibleModifier != modifier {
                visibleModifier = modifier
                show(modifier)
            }
            return
        }

        if pendingModifier == modifier { return }
        cancelScheduled()
        pendingModifier = modifier
        schedule(delayProvider()) { [weak self] in
            guard let self, self.pendingModifier == modifier, self.visibleModifier == nil else { return }
            self.visibleModifier = modifier
            self.show(modifier)
        }
    }

    /// A key was pressed while a sheet's modifiers were held — the hold was a
    /// real shortcut, not a "what's on this layer?" pause, so drop the overlay.
    func keyDownWhileModifierHeld() {
        let hadOverlayState = pendingModifier != nil || visibleModifier != nil
        cancelScheduled()
        pendingModifier = nil
        visibleModifier = nil
        if hadOverlayState { hide() }
    }

    func reset() {
        cancelScheduled()
        pendingModifier = nil
        if visibleModifier != nil {
            visibleModifier = nil
            hide()
        }
    }
}

final class KeymapOverlayRenderer {
    /// How a key's payload is drawn.
    /// - `glyph`: one emoji/character, right-aligned next to the base letter
    ///   (the ⌥ layout cheat-sheet).
    /// - `word`: a whole word wrapped across the bottom of the key, and keys
    ///   with nothing bound dimmed right down so the bound ones stand out
    ///   (the ⌘⌃ shortcut cheat-sheet).
    enum Style {
        case glyph
        case word
    }

    struct KeyDef {
        let row: Int
        let x: CGFloat
        let width: CGFloat
        let label: String
        let code: Int
    }

    static let logicalSize = NSSize(width: 1298, height: 398)
    static let imageAspectRatio = logicalSize.width / logicalSize.height

    private static let keys: [KeyDef] = [
        KeyDef(row: 0, x: 0, width: 96, label: "§", code: 10),
        KeyDef(row: 0, x: 100, width: 96, label: "1", code: 18),
        KeyDef(row: 0, x: 200, width: 96, label: "2", code: 19),
        KeyDef(row: 0, x: 300, width: 96, label: "3", code: 20),
        KeyDef(row: 0, x: 400, width: 96, label: "4", code: 21),
        KeyDef(row: 0, x: 500, width: 96, label: "5", code: 23),
        KeyDef(row: 0, x: 600, width: 96, label: "6", code: 22),
        KeyDef(row: 0, x: 700, width: 96, label: "7", code: 26),
        KeyDef(row: 0, x: 800, width: 96, label: "8", code: 28),
        KeyDef(row: 0, x: 900, width: 96, label: "9", code: 25),
        KeyDef(row: 0, x: 1000, width: 96, label: "0", code: 29),
        KeyDef(row: 0, x: 1100, width: 96, label: "-", code: 27),
        KeyDef(row: 0, x: 1200, width: 96, label: "=", code: 24),
        KeyDef(row: 1, x: 50, width: 96, label: "q", code: 12),
        KeyDef(row: 1, x: 150, width: 96, label: "w", code: 13),
        KeyDef(row: 1, x: 250, width: 96, label: "e", code: 14),
        KeyDef(row: 1, x: 350, width: 96, label: "r", code: 15),
        KeyDef(row: 1, x: 450, width: 96, label: "t", code: 17),
        KeyDef(row: 1, x: 550, width: 96, label: "y", code: 16),
        KeyDef(row: 1, x: 650, width: 96, label: "u", code: 32),
        KeyDef(row: 1, x: 750, width: 96, label: "i", code: 34),
        KeyDef(row: 1, x: 850, width: 96, label: "o", code: 31),
        KeyDef(row: 1, x: 950, width: 96, label: "p", code: 35),
        // The five punctuation keys carry the Romanian diacritics (ă î â ș ț)
        // and were missing from this list entirely — `visibleBaseLabel` already
        // anticipated them, but with no KeyDef it never ran, so the sheet drew a
        // keyboard that stopped at P and L and simply had nowhere to show them.
        KeyDef(row: 1, x: 1050, width: 96, label: "[", code: 33),
        KeyDef(row: 1, x: 1150, width: 96, label: "]", code: 30),
        KeyDef(row: 2, x: 90, width: 96, label: "a", code: 0),
        KeyDef(row: 2, x: 190, width: 96, label: "s", code: 1),
        KeyDef(row: 2, x: 290, width: 96, label: "d", code: 2),
        KeyDef(row: 2, x: 390, width: 96, label: "f", code: 3),
        KeyDef(row: 2, x: 490, width: 96, label: "g", code: 5),
        KeyDef(row: 2, x: 590, width: 96, label: "h", code: 4),
        KeyDef(row: 2, x: 690, width: 96, label: "j", code: 38),
        KeyDef(row: 2, x: 790, width: 96, label: "k", code: 40),
        KeyDef(row: 2, x: 890, width: 96, label: "l", code: 37),
        KeyDef(row: 2, x: 990, width: 96, label: ";", code: 41),
        KeyDef(row: 2, x: 1090, width: 96, label: "'", code: 39),
        // \ sits at the end of the home row on this Mac's ISO keyboard, not
        // after ] the way an ANSI board has it.
        KeyDef(row: 2, x: 1190, width: 96, label: "\\", code: 42),
        KeyDef(row: 3, x: 130, width: 96, label: "`", code: 50),
        KeyDef(row: 3, x: 230, width: 96, label: "z", code: 6),
        KeyDef(row: 3, x: 330, width: 96, label: "x", code: 7),
        KeyDef(row: 3, x: 430, width: 96, label: "c", code: 8),
        KeyDef(row: 3, x: 530, width: 96, label: "v", code: 9),
        KeyDef(row: 3, x: 630, width: 96, label: "b", code: 11),
        KeyDef(row: 3, x: 730, width: 96, label: "n", code: 45),
        KeyDef(row: 3, x: 830, width: 96, label: "m", code: 46),
        KeyDef(row: 3, x: 930, width: 96, label: ",", code: 43),
        KeyDef(row: 3, x: 1030, width: 96, label: ".", code: 47),
        KeyDef(row: 3, x: 1130, width: 96, label: "/", code: 44),
    ]

    static func visibleBaseLabel(_ label: String) -> String {
        [";", "'", "\\", "[", "]"].contains(label) ? "" : label.uppercased()
    }

    func render(outputs: [Int: String], style: Style = .glyph, artwork: [Int: NSImage] = [:], accents: [Int: String] = [:], scale: CGFloat = 2.0) -> NSImage {
        let pixelSize = NSSize(width: Self.logicalSize.width * scale, height: Self.logicalSize.height * scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return NSImage(size: pixelSize)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.shouldAntialias = true

        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x * scale, y: (Self.logicalSize.height - y - h) * scale, width: w * scale, height: h * scale)
        }

        func drawText(_ text: String, in frame: NSRect, fontSize: CGFloat, color: NSColor, alignment: NSTextAlignment, wraps: Bool = false) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = wraps ? .byWordWrapping : .byClipping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fontSize * scale),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            (text as NSString).draw(in: frame, withAttributes: attrs)
        }

        NSGraphicsContext.current?.cgContext.clear(NSRect(origin: .zero, size: pixelSize))

        for key in Self.keys {
            let y = CGFloat(key.row) * 100
            let output = compactOutput(outputs[key.code] ?? "")
            let picture = style == .word ? artwork[key.code] : nil
            // In word style an unbound key is not worth reading: dim its outline
            // and its letter so the eye lands only on the keys that do something.
            let bound = style == .glyph || !output.isEmpty || picture != nil

            let keyRect = rect(key.x, y, key.width, 96).insetBy(dx: 2 * scale, dy: 2 * scale)
            let path = NSBezierPath(roundedRect: keyRect, xRadius: 7 * scale, yRadius: 7 * scale)
            NSColor(calibratedRed: 5 / 255, green: 6 / 255, blue: 9 / 255, alpha: 1).setFill()
            path.fill()
            path.lineWidth = 3 * scale
            NSColor(calibratedRed: 215 / 255, green: 222 / 255, blue: 254 / 255, alpha: bound ? 1 : 0.22).setStroke()
            path.stroke()

            let baseLabel = Self.visibleBaseLabel(key.label)
            if !baseLabel.isEmpty {
                switch style {
                case .glyph:
                    let baseFrame = rect(key.x + 10, y - 1, key.width * 0.5, 58)
                    drawText(baseLabel, in: baseFrame, fontSize: 58, color: NSColor(calibratedRed: 64 / 255, green: 68 / 255, blue: 77 / 255, alpha: 1), alignment: .left)
                case .word:
                    // The word needs the bottom half of the key, so the letter
                    // shrinks and moves to the top-left corner.
                    let baseFrame = rect(key.x + 10, y + 2, key.width - 20, 44)
                    let ink = bound
                        ? NSColor(calibratedRed: 150 / 255, green: 156 / 255, blue: 172 / 255, alpha: 1)
                        : NSColor(calibratedRed: 64 / 255, green: 68 / 255, blue: 77 / 255, alpha: 0.55)
                    drawText(baseLabel, in: baseFrame, fontSize: 42, color: ink, alignment: .left)
                }
            }

            // The accent shares the letter's row, pinned to the far corner, and
            // is drawn smaller so it reads as a hint about the key rather than
            // as a second key label competing with the letter.
            if style == .word, let accent = accents[key.code], !accent.isEmpty {
                let accentFrame = rect(key.x + key.width * 0.4, y + 6, key.width * 0.6 - 10, 34)
                drawText(accent, in: accentFrame, fontSize: 28, color: .white, alignment: .right)
            }

            // A logo answers "what is this key" faster than any word, so it gets
            // the whole payload area — drawn straight onto the key, no plate
            // behind it: the sheet's keys are one flat black and a white card
            // under one of them is the loudest thing on the whole keyboard.
            // Gmail's mark survives it because the M is the coloured part; the
            // envelope body it normally paints white is simply left as key.
            if let picture {
                let box = rect(key.x + 14, y + 34, key.width - 28, 58)
                picture.draw(in: aspectFit(picture.size, in: box))
                continue
            }

            guard !output.isEmpty else { continue }
            switch style {
            case .glyph:
                // The punctuation keys draw no base letter (`visibleBaseLabel`),
                // so their payload gets the whole key instead of being pushed
                // into the right half against a letter that isn't there.
                if baseLabel.isEmpty {
                    let glyphFrame = rect(key.x + 5, y + 22, key.width - 10, 60)
                    drawText(output, in: glyphFrame, fontSize: compactFontSize(output), color: .white, alignment: .center)
                } else {
                    let outputFrame = rect(key.x + key.width - key.width * 0.5 - 10, y + 36, key.width * 0.5, 56)
                    drawText(output, in: outputFrame, fontSize: compactFontSize(output), color: .white, alignment: .right)
                }
            case .word:
                // An emoji label is a picture, not a word: it says what the key
                // does at a glance, so it is drawn big and centred in the whole
                // payload area rather than shrunk to word size at the bottom.
                if Self.isPictogram(output) {
                    let glyphFrame = rect(key.x + 5, y + 34, key.width - 10, 58)
                    drawText(output, in: glyphFrame, fontSize: 46, color: .white, alignment: .center)
                } else {
                    let wordFrame = rect(key.x + 5, y + 46, key.width - 10, 46)
                    drawText(output, in: wordFrame, fontSize: Self.wordFontSize(output), color: .white, alignment: .center, wraps: true)
                }
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = pixelSize
        let image = NSImage(size: pixelSize)
        image.addRepresentation(bitmap)
        return image
    }

    /// A label that is nothing but emoji (📕, 📅) — never a word that merely
    /// contains one ("wispr🎙️", which still has to read as a word).
    static func isPictogram(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 2 else { return false }
        return label.unicodeScalars.allSatisfy { $0.properties.isEmoji && !$0.isASCII }
    }

    /// The largest rect of `size`'s aspect ratio that fits inside `bounds`,
    /// centred — a logo squashed to a square would stop being the logo.
    private func aspectFit(_ size: NSSize, in bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private func compactOutput(_ output: String) -> String {
        output.hasPrefix("dead ") ? "" : output
    }

    private func compactFontSize(_ output: String) -> CGFloat {
        output.count >= 3 ? 34 : 46
    }

    /// A key is 96 wide with 10 of padding, so a word has ~86 to live in and the
    /// font has to shrink as it grows — word-wrapping cannot break a single word,
    /// so anything too wide spills over the key's border instead of wrapping.
    /// 8 characters ("terminal", "calendar") is the longest word here; 18pt bold
    /// measures ~79 for those, which clears the border.
    static func wordFontSize(_ word: String) -> CGFloat {
        switch word.count {
        case ...4: return 26
        case ...6: return 22
        case ...8: return 18
        default: return 15
        }
    }
}

final class KeymapOverlayWindow: NSPanel {
    static let visibleOpacity: CGFloat = 1.0

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        alphaValue = Self.visibleOpacity
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    func display(image: NSImage, frame: NSRect) {
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.image = image
        // Scale the keyboard image up to fill the window, preserving its aspect
        // ratio and centering it. On a single monitor the frame already matches
        // the image aspect (fills exactly); on a full external monitor the wider
        // keyboard fits to width and is centered vertically over the desktop.
        imageView.imageScaling = .scaleProportionallyUpOrDown
        contentView = imageView
        setFrame(frame, display: true)
        // Appear at full opacity immediately — no initial fade-in.
        alphaValue = Self.visibleOpacity
        orderFrontRegardless()
    }
}

final class KeymapOverlayController {
    private var images: [KeymapModifier: NSImage] = [:]
    /// `EmojiKeyLayer.generation` these images were drawn from — see `show`.
    private var renderedGeneration = -1
    private let window = KeymapOverlayWindow()
    private let renderer = KeymapOverlayRenderer()
    private let retinaScreenProvider: () -> NSScreen
    private let screensProvider: () -> [NSScreen]

    // Startup can lose the race against the keyboard-layout selection being
    // restored (login, or Ukelele reinstalling a bundle): the read fails, images
    // stay empty and every Option hold silently no-ops until the next relaunch.
    // So a failed generation retries with a backoff instead of giving up.
    private static let retryDelays: [TimeInterval] = [2, 5, 15, 60, 300]
    private var retryIndex = 0

    init(retinaScreenProvider: @escaping () -> NSScreen, screensProvider: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        self.retinaScreenProvider = retinaScreenProvider
        self.screensProvider = screensProvider
        // The ⌘⌃ sheet is a static map of this app's own shortcuts, so it is
        // built once here and is unaffected by whether the .keylayout can be
        // found — that failure must not take the shortcut cheat-sheet with it.
        images[.commandControl] = renderer.render(
            outputs: CommandControlShortcuts.labels,
            style: .word,
            artwork: CommandControlShortcuts.artworkImages(),
            accents: CommandControlShortcuts.accents
        )
        if !regenerateImages() { scheduleRetry() }
        // Switching input source (or saving a new layout in Ukelele, which
        // re-selects it) must re-render — the cheat-sheet has to match the
        // layout actually in effect.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func inputSourceChanged() {
        // cfprefsd/TIS settle a beat after the notification; a short hop avoids
        // rendering the layout we're switching away from.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.retryIndex = 0
            if !self.regenerateImages() { self.scheduleRetry() }
        }
    }

    private func scheduleRetry() {
        guard retryIndex < Self.retryDelays.count else {
            overlayError("KeymapOverlay: giving up on layout images until the next input-source change")
            return
        }
        let delay = Self.retryDelays[retryIndex]
        retryIndex += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // `images` is never empty (the ⌘⌃ sheet is always there), so the
            // "did the layout ever render?" question is asked of ⌥ specifically.
            guard let self, self.images[.option] == nil else { return }
            if !self.regenerateImages() { self.scheduleRetry() }
        }
    }

    /// The ⌥ / ⌥⇧ sheets are drawn from `EmojiKeyLayer` — the same map the event
    /// tap types from — rather than from the active `.keylayout`.
    ///
    /// They used to be parsed out of the layout file, which was correct only for
    /// as long as the layout was what produced the characters. Now that the app
    /// types them, parsing the layout would draw a keyboard nobody is using:
    /// with the system layout back on stock ABC the sheet would come up empty,
    /// and any binding added to the map would be missing from it. Reading the
    /// map instead also removes the whole "could not locate active .keylayout"
    /// failure path — there is no longer a file to fail to find.
    ///
    /// No `KeymapOverlayOutputFilter` here either: the map holds *only* the
    /// custom bindings, so there is no ABC baseline left to strip out.
    @discardableResult
    func regenerateImages() -> Bool {
        let started = CFAbsoluteTimeGetCurrent()
        let option = EmojiKeyLayer.snapshot(shift: false)
        let optionShift = EmojiKeyLayer.snapshot(shift: true)
        images[.option] = renderer.render(outputs: option.bindings)
        images[.optionShift] = renderer.render(outputs: optionShift.bindings)
        renderedGeneration = option.generation
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        overlayInfo(String(format: "KeymapOverlay: drew %d ⌥ + %d ⌥⇧ bindings in %.3fs",
                           option.bindings.count, optionShift.bindings.count, elapsed))
        return true
    }

    func show(_ modifier: KeymapModifier) {
        // Redraw when the map file has been edited since these images were baked,
        // so a binding added mid-session shows up on the very next hold — the
        // sheet has to keep pace with what the keys actually type. (The ⌘⌃ sheet
        // is built in `init` from `CommandControlShortcuts` and is unaffected.)
        if modifier != .commandControl,
           EmojiKeyLayer.snapshot(shift: false).generation != renderedGeneration {
            regenerateImages()
        }
        // Last-chance rebuild: if we still have no images (startup read failed),
        // try once more now rather than no-opping the hold.
        if images[modifier] == nil { regenerateImages() }
        guard let image = images[modifier] else { return }
        let retina = retinaScreenProvider()
        let retinaID = screenID(retina)
        let externals = screensProvider().filter { screenID($0) != retinaID }.map(\.frame)
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina.frame,
            externalFrames: externals,
            imageAspectRatio: KeymapOverlayRenderer.imageAspectRatio,
            mouseLocation: NSEvent.mouseLocation
        )

        window.display(image: image, frame: frame)
    }

    func hide() {
        window.orderOut(nil)
    }

    private func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
