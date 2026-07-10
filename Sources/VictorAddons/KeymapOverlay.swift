import AppKit
import CoreGraphics
import Foundation

enum KeymapModifier: String, Equatable {
    case option
    case optionShift
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
    static func activeLayoutName() -> String? {
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
        let defaults = modifier == .option ? optionDefaults : optionShiftDefaults
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

        guard let external = closestExternal(to: retinaFrame, externalFrames: candidates) else {
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

    private static func closestExternal(to retina: NSRect, externalFrames: [NSRect]) -> NSRect? {
        externalFrames.min { a, b in
            distanceBetween(a, retina) < distanceBetween(b, retina)
        }
    }

    private static func distanceBetween(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let dx = max(max(b.minX - a.maxX, a.minX - b.maxX), 0)
        let dy = max(max(b.minY - a.maxY, a.minY - b.maxY), 0)
        return hypot(dx, dy)
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

    func modifierFlagsChanged(option: Bool, shift: Bool) {
        guard option else {
            reset()
            return
        }

        let modifier: KeymapModifier = shift ? .optionShift : .option
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

    func keyDownWhileOptionHeld() {
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
        KeyDef(row: 2, x: 90, width: 96, label: "a", code: 0),
        KeyDef(row: 2, x: 190, width: 96, label: "s", code: 1),
        KeyDef(row: 2, x: 290, width: 96, label: "d", code: 2),
        KeyDef(row: 2, x: 390, width: 96, label: "f", code: 3),
        KeyDef(row: 2, x: 490, width: 96, label: "g", code: 5),
        KeyDef(row: 2, x: 590, width: 96, label: "h", code: 4),
        KeyDef(row: 2, x: 690, width: 96, label: "j", code: 38),
        KeyDef(row: 2, x: 790, width: 96, label: "k", code: 40),
        KeyDef(row: 2, x: 890, width: 96, label: "l", code: 37),
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

    func render(outputs: [Int: String], scale: CGFloat = 2.0) -> NSImage {
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

        func drawText(_ text: String, in frame: NSRect, fontSize: CGFloat, color: NSColor, alignment: NSTextAlignment) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
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
            let keyRect = rect(key.x, y, key.width, 96).insetBy(dx: 2 * scale, dy: 2 * scale)
            let path = NSBezierPath(roundedRect: keyRect, xRadius: 7 * scale, yRadius: 7 * scale)
            NSColor(calibratedRed: 5 / 255, green: 6 / 255, blue: 9 / 255, alpha: 1).setFill()
            path.fill()
            path.lineWidth = 3 * scale
            NSColor(calibratedRed: 215 / 255, green: 222 / 255, blue: 254 / 255, alpha: 1).setStroke()
            path.stroke()

            let baseLabel = Self.visibleBaseLabel(key.label)
            if !baseLabel.isEmpty {
                let baseFrame = rect(key.x + 10, y - 1, key.width * 0.5, 58)
                drawText(baseLabel, in: baseFrame, fontSize: 58, color: NSColor(calibratedRed: 64 / 255, green: 68 / 255, blue: 77 / 255, alpha: 1), alignment: .left)
            }

            let output = compactOutput(outputs[key.code] ?? "")
            guard !output.isEmpty else { continue }
            let outputFrame = rect(key.x + key.width - key.width * 0.5 - 10, y + 36, key.width * 0.5, 56)
            drawText(output, in: outputFrame, fontSize: compactFontSize(output), color: .white, alignment: .right)
        }

        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = pixelSize
        let image = NSImage(size: pixelSize)
        image.addRepresentation(bitmap)
        return image
    }

    private func compactOutput(_ output: String) -> String {
        output.hasPrefix("dead ") ? "" : output
    }

    private func compactFontSize(_ output: String) -> CGFloat {
        output.count >= 3 ? 34 : 46
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
    private let window = KeymapOverlayWindow()
    private let renderer = KeymapOverlayRenderer()
    private let retinaScreenProvider: () -> NSScreen
    private let screensProvider: () -> [NSScreen]

    init(retinaScreenProvider: @escaping () -> NSScreen, screensProvider: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        self.retinaScreenProvider = retinaScreenProvider
        self.screensProvider = screensProvider
        regenerateImages()
    }

    func regenerateImages() {
        let started = CFAbsoluteTimeGetCurrent()
        guard let name = KeymapLayoutLocator.activeLayoutName(),
              let url = KeymapLayoutLocator.keylayoutURL(named: name),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            overlayError("KeymapOverlay: could not locate active .keylayout")
            return
        }
        do {
            let optionOutputs = try KeymapLayoutParser.outputs(in: text, modifier: .option)
            let optionShiftOutputs = try KeymapLayoutParser.outputs(in: text, modifier: .optionShift)
            images[.option] = renderer.render(outputs: KeymapOverlayOutputFilter.customOutputs(from: optionOutputs, modifier: .option))
            images[.optionShift] = renderer.render(outputs: KeymapOverlayOutputFilter.customOutputs(from: optionShiftOutputs, modifier: .optionShift))
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            overlayInfo(String(format: "KeymapOverlay: regenerated active layout images in %.3fs", elapsed))
        } catch {
            overlayError("KeymapOverlay: failed to parse active .keylayout — \(error)")
        }
    }

    func show(_ modifier: KeymapModifier) {
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
