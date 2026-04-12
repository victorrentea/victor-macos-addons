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

class PowerPointMonitor {
    var onSlideChange: (([String: Any]) -> Void)?
    var onSlidesViewed: (([[String: Any]]) -> Void)?

    private var timer: Timer?

    // State
    private var currentDeck: String?
    private var currentSlide: Int = 1
    private var currentPresenting: Bool = false
    private var lastProbeTime: Date?

    private var allDurations: [String: [Int: TimeInterval]] = [:]  // deck → slide → cumulative secs
    private var lastSentDurations: [String: [Int: TimeInterval]] = [:]  // deck → slide → secs already sent
    private var sendTimer: Timer?

    init() {
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                DispatchQueue.global(qos: .utility).async { self?.tick() }
            }
            self?.sendTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                DispatchQueue.global(qos: .utility).async { self?.sendDelta() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sendTimer?.invalidate()
        sendTimer = nil
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
            if var deckMap = allDurations[currentDeck!] {
                deckMap[currentSlide, default: 0] += elapsed
                allDurations[currentDeck!] = deckMap
            } else {
                allDurations[currentDeck!] = [currentSlide: elapsed]
            }
        }

        // Deck changed?
        if deck != currentDeck {
            // Start new deck
            currentDeck = deck
            currentSlide = slide
            currentPresenting = isPresenting
            notifySlideChange()
        } else if slide != currentSlide || isPresenting != currentPresenting {
            currentSlide = slide
            currentPresenting = isPresenting
            notifySlideChange()
        }

        currentSlide = slide
        currentPresenting = isPresenting
        lastProbeTime = now
    }

    private func notifySlideChange() {
        guard let deck = currentDeck, currentPresenting else { return }
        onSlideChange?([
            "type": "slide_presenting_now",
            "deck": deck,
            "slide": currentSlide,
            "presenting": currentPresenting
        ])
    }

    private func sendDelta() {
        var entries: [[String: Any]] = []
        for (deck, slides) in allDurations {
            let sentSlides = lastSentDurations[deck] ?? [:]
            for (slideNum, totalSecs) in slides {
                let alreadySent = sentSlides[slideNum] ?? 0
                let delta = totalSecs - alreadySent
                if delta >= 0.5 {
                    entries.append([
                        "fileName": deck,
                        "page": slideNum,
                        "seconds": Int(delta.rounded()),
                    ])
                }
            }
        }
        if !entries.isEmpty {
            onSlidesViewed?(entries)
            // Update lastSent to current
            lastSentDurations = allDurations.mapValues { slideMap in
                slideMap.mapValues { $0 }
            }
        }
    }
}
