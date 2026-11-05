import AppKit

/// 💾 What the badge says and where it sits. Pure, so both are unit-tested.
enum PowerPointSavedBadgePolicy {
    /// PowerPoint's status bar, measured on 16.114.
    static let statusBarHeight: CGFloat = 26

    /// Answers "is everything saved?" first. The time is only a detail: an age like "35 min ago"
    /// read as a warning on a deck with nothing left to save.
    static func text(savedAt: Date, unsaved: Bool, now: Date, calendar: Calendar = .current) -> String {
        let clock = DateFormatter()
        clock.calendar = calendar
        clock.timeZone = calendar.timeZone
        clock.locale = Locale(identifier: "en_GB")
        clock.dateFormat = calendar.isDate(savedAt, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
        let time = clock.string(from: savedAt)
        return unsaved ? "● Unsaved · last save \(time)" : "✓ Saved · \(time)"
    }

    /// Bottom-left corner of the badge in Cocoa coordinates, centered on PowerPoint's status bar.
    /// `window` is in Accessibility coordinates: y down from the top of the primary screen.
    static func origin(window: CGRect, badge: CGSize, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: (window.midX - badge.width / 2).rounded(),
                y: (primaryScreenHeight - window.maxY + (statusBarHeight - badge.height) / 2).rounded())
    }
}

/// 💾 Whether the open deck is saved, in PowerPoint's own status bar.
///
/// An add-in can't do this: Office.js has no save event and no last-save time, and can't write
/// to the status bar, the title bar or a ribbon label. So this is a click-through panel of ours
/// that follows PowerPoint's main window, only while PowerPoint is in front and no slide show runs.
final class PowerPointSavedBadge {
    private struct Reading {
        let savedAt: Date
        let unsaved: Bool
    }

    private static let bundleID = "com.microsoft.Powerpoint"
    private static let followEvery: DispatchTimeInterval = .milliseconds(250)

    private let queue = DispatchQueue(label: "ro.victorrentea.ppt-saved-badge", qos: .utility)
    private var follower: DispatchSourceTimer?
    private var reading: Reading?
    private var windowFrame: CGRect?

    private lazy var label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        return label
    }()

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let pill = NSView()
        pill.wantsLayer = true
        // Its own background: readable whichever theme Office is in.
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        pill.layer?.cornerRadius = 5
        panel.contentView = pill
        pill.addSubview(label)
        return panel
    }()

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    /// Called on `PowerPointMonitor`'s queue, so the file read never touches the main thread.
    func consume(_ s: PowerPointSample) {
        var reading: Reading?
        // A deck never saved has a bare "Presentation1" for a path: nothing to report.
        if !s.presenting, let path = s.path, path.hasPrefix("/"),
           let savedAt = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
            reading = Reading(savedAt: savedAt, unsaved: !s.saved)
        }
        DispatchQueue.main.async { [self] in
            self.reading = reading
            refresh()
        }
    }

    private func refresh() {
        let front = NSWorkspace.shared.frontmostApplication
        guard let reading, let pid = front?.processIdentifier, front?.bundleIdentifier == Self.bundleID else {
            stopFollowing()
            return
        }
        label.stringValue = PowerPointSavedBadgePolicy.text(savedAt: reading.savedAt, unsaved: reading.unsaved, now: Date())
        label.textColor = reading.unsaved ? .systemOrange : .white
        follow(pid)
        place()
    }

    /// AX round trips run off the main thread: Presenter View can keep PowerPoint busy for seconds.
    private func follow(_ pid: pid_t) {
        guard follower == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.followEvery)
        timer.setEventHandler { [weak self] in
            let frame = AXWindows.mainWindow(pid: pid).flatMap(AXWindows.frame(of:))
            DispatchQueue.main.async {
                self?.windowFrame = frame
                self?.place()
            }
        }
        timer.resume()
        follower = timer
    }

    private func stopFollowing() {
        follower?.cancel()
        follower = nil
        windowFrame = nil
        panel.orderOut(nil)
    }

    private func place() {
        guard follower != nil, let windowFrame, let primary = NSScreen.screens.first?.frame.height else {
            panel.orderOut(nil)
            return
        }
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 12, height: 18)
        label.setFrameOrigin(CGPoint(x: 6, y: ((size.height - label.frame.height) / 2).rounded()))
        panel.setContentSize(size)
        panel.setFrameOrigin(PowerPointSavedBadgePolicy.origin(window: windowFrame, badge: size,
                                                               primaryScreenHeight: primary))
        panel.orderFrontRegardless()
    }
}
