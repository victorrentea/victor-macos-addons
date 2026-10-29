import AppKit
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
    set presentationPath to ""
    try
        set presentationPath to full name of active presentation as text
    end try
    set slideNumber to 1
    set isPresenting to "false"
    set slideIdent to ""
    try
        if (count of slide show windows) > 0 then
            set isPresenting to "true"
            set slideNumber to current show position of slide show view of slide show window 1
            try
                set slideIdent to slide ID of slide of slide show view of slide show window 1
            on error
                try
                    set slideIdent to slide ID of slide slideNumber of active presentation
                end try
            end try
        else
            try
                set slideNumber to slide index of slide of view of active window
                try
                    set slideIdent to slide ID of slide of view of active window
                end try
            on error
                try
                    set slideNumber to slide index of slide of view of document window 1
                    try
                        set slideIdent to slide ID of slide of view of document window 1
                    end try
                on error
                    set slideNumber to "__SLIDE_UNKNOWN__"
                end try
            end try
        end if
    on error
        set slideNumber to "__SLIDE_UNKNOWN__"
    end try
    set isSaved to "true"
    try
        set isSaved to (saved of active presentation) as string
    end try
    return presentationName & tab & isPresenting & tab & (slideNumber as string) & tab & presentationPath & tab & (slideIdent as string) & tab & isSaved
end tell
"""

class PowerPointMonitor {
    var onSlideChange: (([String: Any]) -> Void)?
    var onSlidesViewed: (([[String: Any]]) -> Void)?
    /// Every probe, raw: the 📑 slides-seen recorder decides what was "shown".
    var onSample: ((PowerPointSample) -> Void)?

    private var timer: Timer?

    // State
    private var currentDeck: String?
    private var currentDeckPath: String?
    private var currentSlide: Int = 1
    private var currentPresenting: Bool = false
    private var lastProbeTime: Date?

    private var allDurations: [String: [Int: TimeInterval]] = [:]  // deck → slide → cumulative secs
    private var lastSentDurations: [String: [Int: TimeInterval]] = [:]  // deck → slide → secs already sent
    private var sendTimer: Timer?
    private var lastWasFrontmost: Bool = false
    // PowerPoint coming to the front is news even without a slide change: the
    // training daemon switches the talk phones from the trainer's notes (VS Code)
    // back to the slides. Kept apart from lastWasFrontmost, which times slides.
    private var announcedFrontmost: Bool = false

    // Serial queue ensures tick()/sendDelta() never race on the duration
    // dictionaries — a concurrent global queue caused EXC_BAD_ACCESS in
    // Dictionary._Variant.setValue when the 2s tick and the 60s sender
    // overlapped (crash 2026-05-13 23:19).
    private let queue = DispatchQueue(label: "ro.victorrentea.ppt-monitor", qos: .utility)

    init() {
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.queue.async { self?.tick() }
            }
            self?.sendTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                self?.queue.async { self?.sendDelta() }
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
            onSample?(.gone(at: now))
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
        let deckPath: String? = {
            guard parts.count >= 4 else { return nil }
            let p = parts[3].trimmingCharacters(in: .whitespaces)
            return p.isEmpty ? nil : p
        }()

        // Only count time when PowerPoint was frontmost at the previous probe
        let isFrontmostNow = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased().contains("powerpoint") == true

        let field = { (i: Int) -> String in parts.count > i ? parts[i].trimmingCharacters(in: .whitespaces) : "" }
        onSample?(PowerPointSample(at: now, deck: deck, path: deckPath, slide: slide,
                                   slideID: Int(field(4)), presenting: isPresenting,
                                   frontmost: isFrontmostNow, saved: field(5) != "false"))

        // Accumulate time on previous slide
        if let lastTime = lastProbeTime, currentDeck != nil, lastWasFrontmost {
            let elapsed = now.timeIntervalSince(lastTime)
            if var deckMap = allDurations[currentDeck!] {
                deckMap[currentSlide, default: 0] += elapsed
                allDurations[currentDeck!] = deckMap
            } else {
                allDurations[currentDeck!] = [currentSlide: elapsed]
            }
        }
        lastWasFrontmost = isFrontmostNow
        let cameToFront = isFrontmostNow && !announcedFrontmost
        announcedFrontmost = isFrontmostNow

        // Deck changed?
        if deck != currentDeck {
            // Start new deck
            currentDeck = deck
            currentDeckPath = deckPath
            currentSlide = slide
            currentPresenting = isPresenting
            notifySlideChange()
        } else if slide != currentSlide || isPresenting != currentPresenting {
            currentDeckPath = deckPath
            currentSlide = slide
            currentPresenting = isPresenting
            notifySlideChange()
        } else if cameToFront {
            notifySlideChange(frontmost: true)
        }

        currentSlide = slide
        currentPresenting = isPresenting
        lastProbeTime = now
    }

    private func notifySlideChange(frontmost: Bool = false) {
        guard let deck = currentDeck else { return }
        var payload: [String: Any] = [
            "type": "slide_presenting_now",
            "deck": deck,
            "slide": currentSlide,
            "presenting": currentPresenting
        ]
        if frontmost { payload["frontmost"] = true }
        if let path = currentDeckPath {
            payload["path"] = path
        }
        onSlideChange?(payload)
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
