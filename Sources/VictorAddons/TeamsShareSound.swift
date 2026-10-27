import AppKit
import ApplicationServices

enum TeamsShareSoundSettings {
    static let enabledKey = "TeamsShareSound.enabled"

    /// On by default: Victor asked for it (2026-10-27).
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

/// 🔊 Ticks **Include sound** in Microsoft Teams' *Share content* flyout as soon
/// as it opens — the Teams half of what `ZoomSharePrep` does with Zoom's "Share
/// sound". Teams has no setting that remembers it (Victor looked, 2026-10-27).
///
/// Dumped from new Teams (`com.microsoft.teams2`) with the flyout open:
///
/// ```
/// AXWindow Subrole=AXStandardWindow  Title="<meeting>"
///   … AXGroup    AXApplicationDialog  Title="Share content"     (depth 13)
///       … AXCheckBox AXSwitch Title="Include sound" dom=switch-r178 v=0
/// ```
///
/// Found by **title**, not DOM id: the id is React's generated `switch-r<n>`
/// and changes between builds. The title is the English UI, which is Victor's.
///
/// **Trigger: a click or ⌘⇧E in Teams, not a poll.** Chromium posts no window-
/// created notification for a flyout inside the page, and walking the meeting
/// window's tree (~60 ms, most of it video tiles) every second of an all-day
/// training is cost for a gesture made twice a day. So a mouse-up (or Teams'
/// share shortcut) while Teams is frontmost starts a 3 s look for the switch.
///
/// The web tree exists only with `AXEnhancedUserInterface` raised (see
/// `TeamsMeetingLayout`), and presses are ignored for about a second after it
/// goes up — hence the retries. The flag is **left up**: lowering it would buy
/// that second back on every share. `TeamsMeetingLayout` already lowers it
/// around its own frame write.
///
/// One tick per flyout: a dialog already handled is not touched again, so
/// unticking by hand sticks until the flyout is closed and reopened.
final class TeamsShareSound {

    private static let switchTitle = "Include sound"
    private static let enhancedUI = "AXEnhancedUserInterface" as CFString

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.teams-share-sound",
                                      qos: .userInitiated)
    private var monitors: [Any] = []
    private var looking = false
    /// The `Share content` dialogs already ticked, so a manual untick sticks.
    private var handled: [AXUIElement] = []

    func start() {
        let mouse = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.teamsGesture()
        }
        // ⌘⇧E: Teams' own "Share content" shortcut.
        let key = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == [.command, .shift], e.charactersIgnoringModifiers?.lowercased() == "e" else { return }
            self?.teamsGesture()
        }
        monitors = [mouse, key].compactMap { $0 }
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    private func teamsGesture() {
        guard TeamsShareSoundSettings.isEnabled,
              let front = NSWorkspace.shared.frontmostApplication,
              TeamsMeetingLayout.bundleIDs.contains(front.bundleIdentifier ?? "") else { return }
        let pid = front.processIdentifier
        queue.async { [weak self] in self?.look(pid: pid) }
    }

    /// **On `queue`.** Up to 3 s for the flyout to appear, tick it, verify.
    private func look(pid: pid_t) {
        guard !looking else { return }
        looking = true
        defer { looking = false }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        AXUIElementSetAttributeValue(axApp, Self.enhancedUI, kCFBooleanTrue)
        handled.removeAll { !Self.alive($0) }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let (dialog, toggle) = Self.findSwitch(axApp) {
                if handled.contains(where: { CFEqual($0, dialog) }) { return }
                if Self.isOn(toggle) {
                    handled.append(dialog)
                    return
                }
                AXUIElementPerformAction(toggle, kAXPressAction as CFString)
                // Measured: the value reads 1 about 0.4 s after an accepted press.
                Thread.sleep(forTimeInterval: 0.4)
                if Self.isOn(toggle) {
                    handled.append(dialog)
                    overlayInfo("🔊 TeamsShareSound: ticked Include sound")
                    return
                }
            } else {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    // MARK: - AX

    /// The switch and the dialog holding it, breadth-first across the windows.
    private static func findSwitch(_ axApp: AXUIElement) -> (AXUIElement, AXUIElement)? {
        for window in elements(axApp, kAXWindowsAttribute) {
            var level: [(el: AXUIElement, dialog: AXUIElement?)] = [(window, nil)]
            for _ in 0..<30 where !level.isEmpty {
                var next: [(el: AXUIElement, dialog: AXUIElement?)] = []
                for (el, dialog) in level {
                    let subrole = string(el, kAXSubroleAttribute)
                    if subrole == "AXSwitch", string(el, kAXTitleAttribute) == switchTitle {
                        return (dialog ?? window, el)
                    }
                    let d = subrole == "AXApplicationDialog" ? el : dialog
                    next += elements(el, kAXChildrenAttribute).map { ($0, d) }
                }
                level = next
            }
        }
        return nil
    }

    private static func isOn(_ el: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &raw) == .success else { return false }
        return (raw as? NSNumber)?.boolValue ?? false
    }

    private static func alive(_ el: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &raw) == .success
    }

    private static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &raw) == .success else { return [] }
        return (raw as? [AXUIElement]) ?? []
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &raw) == .success else { return nil }
        return raw as? String
    }
}
