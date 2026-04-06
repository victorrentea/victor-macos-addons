import Foundation

private let pptScript = """
if application "Microsoft PowerPoint" is not running then
    return "__NO_PPT__"
end if
tell application "Microsoft PowerPoint"
    if (count of presentations) is 0 then
        return "__NO_PRESENTATION__"
    end if
    set presentationName to name of active presentation
    set slideNumber to 1
    set isPresenting to "false"
    try
        if (count of slide show windows) > 0 then
            set isPresenting to "true"
            set slideNumber to current show position of slide show view of slide show window 1
        else
            try
                set slideNumber to slide index of slide of view of active window
            on error
                try
                    set slideNumber to slide index of slide of view of document window 1
                on error
                    set slideNumber to "__SLIDE_UNKNOWN__"
                end try
            end try
        end if
    on error
        set slideNumber to "__SLIDE_UNKNOWN__"
    end try
    return presentationName & tab & isPresenting & tab & (slideNumber as string)
end tell
"""

private func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    if s < 60 {
        return "\(s)s"
    }
    let m = s / 60
    let rem = s % 60
    return rem > 0 ? "\(m)m\(rem)s" : "\(m)m"
}

class PowerPointMonitor {
    var onSlideChange: (([String: Any]) -> Void)?

    private let outputDir: URL
    private var timer: Timer?

    // State
    private var currentDeck: String?
    private var currentSlide: Int = 1
    private var currentPresenting: Bool = false
    private var slideDurations: [Int: TimeInterval] = [:]  // slide# -> seconds (insertion-ordered via ordered keys)
    private var slideOrder: [Int] = []  // preserve insertion order
    private var lastProbeTime: Date?
    private var lineStartTime: String = ""  // HH:MM:SS

    init(outputDir: URL) {
        self.outputDir = outputDir
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                DispatchQueue.global(qos: .utility).async { self?.tick() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let raw = AppleScriptRunner.run(pptScript, timeout: 5.0) else { return }

        let now = Date()

        if raw == "__NO_PPT__" || raw == "__NO_PRESENTATION__" {
            lastProbeTime = nil
            return
        }

        let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map { String($0) }
        guard parts.count >= 3 else { return }

        let deck = parts[0].trimmingCharacters(in: .whitespaces)
        guard !deck.isEmpty else { return }

        let isPresenting = parts[1].trimmingCharacters(in: .whitespaces) == "true"
        let slideRaw = parts[2].trimmingCharacters(in: .whitespaces)
        let slide: Int
        if slideRaw == "__SLIDE_UNKNOWN__" || slideRaw.isEmpty || slideRaw.lowercased() == "missing value" {
            slide = 1
        } else {
            slide = max(1, Int(slideRaw) ?? 1)
        }

        // Accumulate time on previous slide
        if let lastTime = lastProbeTime, currentDeck != nil {
            let elapsed = now.timeIntervalSince(lastTime)
            if slideDurations[currentSlide] == nil {
                slideOrder.append(currentSlide)
                slideDurations[currentSlide] = 0
            }
            slideDurations[currentSlide]! += elapsed
        }

        // Deck changed?
        if deck != currentDeck {
            if currentDeck != nil {
                writeFile()  // finalize previous deck line
            }
            // Start new deck
            currentDeck = deck
            currentSlide = slide
            currentPresenting = isPresenting
            slideDurations = [:]
            slideOrder = []
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            lineStartTime = formatter.string(from: now)
            notifySlideChange()
        } else if slide != currentSlide || isPresenting != currentPresenting {
            currentSlide = slide
            currentPresenting = isPresenting
            notifySlideChange()
        }

        currentSlide = slide
        currentPresenting = isPresenting
        lastProbeTime = now
        writeFile()
    }

    private func writeFile() {
        guard let deck = currentDeck else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())

        let filepath = outputDir.appendingPathComponent("\(dateStr)-slides.txt")

        // Ensure output directory exists
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Read existing lines
        var lines: [String] = []
        if let content = try? String(contentsOf: filepath, encoding: .utf8) {
            lines = content.components(separatedBy: "\n")
            // Remove trailing empty line from splitlines behavior
            if lines.last == "" {
                lines.removeLast()
            }
        }

        // Strip current activity line if it matches our deck (last line starting with same timestamp)
        if let last = lines.last, last.hasPrefix(lineStartTime) {
            lines.removeLast()
        }

        // Build activity line
        var timings: [String] = []
        for slideNum in slideOrder {
            if let secs = slideDurations[slideNum], secs >= 0.5 {
                timings.append("s\(slideNum):\(formatDuration(secs))")
            }
        }

        var activityLine = "\(lineStartTime) \(deck)"
        if !timings.isEmpty {
            activityLine += " - " + timings.joined(separator: ", ")
        }

        lines.append(activityLine)

        let output = lines.joined(separator: "\n") + "\n"
        try? output.write(to: filepath, atomically: true, encoding: .utf8)
    }

    private func notifySlideChange() {
        guard let deck = currentDeck else { return }
        onSlideChange?([
            "type": "slide",
            "deck": deck,
            "slide": currentSlide,
            "presenting": currentPresenting
        ])
    }
}
