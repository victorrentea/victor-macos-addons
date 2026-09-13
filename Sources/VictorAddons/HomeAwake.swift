import AppKit
import CoreWLAN
import Foundation

/// Whether 🏠 Home Wi-Fi keeps the screen on is armed, and which networks count
/// as home — the row under 👩🏻‍💻 Extra.
///
/// **Default on**, unlike its neighbour 🔋 Claude prevents sleep, and the two
/// are not comparable. 🔋 defaults off because a ticked row there means a Mac
/// that refuses to sleep *anywhere*, on a kernel flag that survives the app.
/// This one cannot reach past one address: it does nothing at all unless the
/// interface is associated with a configured SSID, it releases itself the moment
/// that stops being true, and the assertion dies with the process. Victor asked
/// for a standing behaviour at home ("de câte ori sunt acasă"), not for a switch
/// to remember to flip, so the honest default is the behaviour he described.
///
/// **The SSID is config, never a branch.** A second home network, a rename, or a
/// visit somewhere that should count is one line here:
///
///     defaults write ro.victorrentea.macos-addons HomeAwake.ssids "tzutze,tzutze5"
///
/// Default `tzutze` — read off this Mac's own interface on 13 Sep 2026 while
/// associated (`SSID_STR = tzutze`, BSSID 60:ce:41:be:14:d8, channel 36). Plain
/// ASCII: spoken it is "Țuțe", but the network is not named that and an exact
/// match is what the policy does.
enum HomeAwakeSettings {
    static let enabledKey = "HomeAwake.enabled"
    static let ssidsKey = "HomeAwake.ssids"

    /// The one network this was asked for. Its band-siblings in the preferred
    /// list (`tzutze5`, `tzutze2.4`, `tzutze_5G`) are deliberately **not**
    /// included: they are real networks that can be joined, and quietly adopting
    /// three SSIDs nobody named is how a feature stops being explainable.
    static let defaultSSIDs = "tzutze"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var ssidsRaw: String {
        get { (UserDefaults.standard.string(forKey: ssidsKey) ?? defaultSSIDs) }
        set { UserDefaults.standard.set(newValue, forKey: ssidsKey) }
    }

    static var ssids: [String] { HomeAwakePolicy.parseSSIDs(ssidsRaw) }
}

/// 🏠 While the Mac is associated with a home Wi-Fi network, the screen does not
/// lock itself. Leave the network and ordinary locking comes back on its own,
/// with nobody clicking anything.
///
/// **What "does not lock" means, exactly**, because the gap between this and
/// "the Mac is unlockable" is where the surprise lives. The mechanism is a
/// `PreventUserIdleDisplaySleep` assertion (`DisplaySleepAssertion`, shared with
/// the ☕️ break screen). The display never idles → the screen saver never
/// starts → "require password after the screen saver starts" never fires. It
/// deliberately does **not** defeat a lock that was asked for: ⌃⌘Q, a hot
/// corner, closing the lid and Lock Screen in the  menu all still lock the Mac
/// at home exactly as they did before. An assertion vetoes an idle timer, never
/// an explicit request — so the first ⌃⌘Q at home behaving normally is the
/// feature working, not a bug.
///
/// **Why it is worth having at all**, beyond not typing a password: a locked
/// session records nothing but the wallpaper. That cost a screen-recording run
/// in `victor-effects`, and an unattended 03:00 capture job is only possible on
/// a Mac that is still logged in and lit when it runs.
///
/// **Why not `caffeinate`.** The app is up all day anyway, so a subprocess would
/// be a second lifetime to keep in step with this one — and a `caffeinate` that
/// outlives a crash keeps the display awake off-network with nothing left to
/// release it. An in-process assertion is reaped by the kernel with the pid.
/// (`LidAwake` is next door and is *not* this machinery: it needs the kernel
/// `SleepDisabled` flag because no assertion in the public API vetoes a closing
/// lid. Different event, different tool — see docs/lid-awake.md.)
///
/// **Why not `networksetup` to read the SSID.** Measured on this Mac on 11 Sep
/// 2026: `networksetup -getairportnetwork en0` answers "You are not associated
/// with an AirPort network" on a healthy, associated interface. CoreWLAN's
/// `CWInterface.ssid()` is the only source of truth, and this app can use it
/// because it already holds Location Services for `HomeGeofence`. `networksetup`
/// is for *acting*, never for *checking*.
final class HomeAwake: NSObject, CWEventDelegate {

    /// The backstop poll. Everything below is edge-driven, and the hotspot
    /// feature has already paid for believing edges: on 27 Aug 2026 an
    /// `NWPathMonitor` edge that never arrived left the Mac offline for five
    /// hours (docs/hotspot-fallback.md, "The night it never asked"). Where a
    /// network *is* a state rather than an event, a clock has to be able to
    /// notice on its own — and here the cost of a missed edge is a display
    /// assertion still held in someone else's building. One in-process
    /// `CWInterface.ssid()` read a minute, no process spawn.
    private static let pollInterval: TimeInterval = 60

    private let queue = DispatchQueue(label: "ro.victorrentea.homeawake")
    private let assertion = DisplaySleepAssertion(
        name: "Victor Addons — home Wi-Fi, screen must not idle-lock",
        logPrefix: "🏠")
    private var timer: DispatchSourceTimer?
    /// Only for logging: a transition is worth a line, sixty restatements an
    /// hour of the same answer are not.
    private var lastSSID: String??

    // MARK: - Lifecycle

    /// Called once at launch. Re-arms across the rebuild loop (`pkill` + `open`),
    /// which matters more here than it looks: the `pkill` half drops the
    /// assertion with the process, so a restart genuinely does hand the screen
    /// back to the idle timer for a moment.
    func startIfEnabled() {
        setEnabled(HomeAwakeSettings.isEnabled, announce: false)
    }

    func setEnabled(_ enabled: Bool, announce: Bool = true) {
        HomeAwakeSettings.isEnabled = enabled
        guard enabled else {
            stopWatching()
            queue.async { [weak self] in self?.assertion.hold(false, reason: "🏠 switched off") }
            if announce { overlayInfo("🏠 Home Wi-Fi keep-awake disarmed") }
            return
        }
        startWatching()
        if announce {
            overlayInfo("🏠 Home Wi-Fi keep-awake armed — home is \(HomeAwakeSettings.ssids.joined(separator: ", "))")
        }
        // Land in the right state now rather than a minute from now.
        queue.async { [weak self] in self?.evaluate(reason: "armed") }
    }

    private func startWatching() {
        guard timer == nil else { return }

        // The event path. `.ssidDidChange` is the direct answer to "did we just
        // change network"; `.powerDidChange` is there because switching Wi-Fi
        // *off* is a departure too and does not necessarily produce an SSID
        // change event — and off-network with the assertion still held is the
        // exact failure this must not have.
        let client = CWWiFiClient.shared()
        client.delegate = self
        do {
            try client.startMonitoringEvent(with: .ssidDidChange)
            try client.startMonitoringEvent(with: .powerDidChange)
        } catch {
            overlayError("🏠 CoreWLAN would not start SSID monitoring (\(error)) — falling back to the \(Int(Self.pollInterval))s poll alone")
        }

        // Waking is the case the event path is least able to cover: the radio
        // re-associates while nothing of ours is listening, so the change can
        // have already happened by the time we are running again.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.evaluate(reason: "wake") }
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway: this is a safety net, not a stopwatch, and letting
        // the scheduler coalesce the wake-up is free.
        t.schedule(deadline: .now() + Self.pollInterval,
                   repeating: Self.pollInterval,
                   leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.evaluate(reason: "poll") }
        t.resume()
        timer = t
    }

    private func stopWatching() {
        timer?.cancel()
        timer = nil
        let client = CWWiFiClient.shared()
        try? client.stopMonitoringEvent(with: .ssidDidChange)
        try? client.stopMonitoringEvent(with: .powerDidChange)
        // The delegate is only ever ours; HotspotFallback shares the singleton
        // but reads `interface()` off it and sets nothing.
        if client.delegate === self { client.delegate = nil }
    }

    // MARK: - CWEventDelegate
    //
    // Delivered on CoreWLAN's own queue, so everything hops onto `queue` — the
    // assertion's held/not-held bit is the one piece of state here and it must
    // have a single owner.

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        queue.async { [weak self] in self?.evaluate(reason: "ssid changed") }
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        queue.async { [weak self] in self?.evaluate(reason: "wifi power changed") }
    }

    // MARK: - The decision

    /// The SSID the interface is **actually** on, or nil when macOS will not say.
    /// See the type comment for why this is CoreWLAN and never `networksetup`.
    static func currentSSID() -> String? {
        let client = CWWiFiClient.shared()
        guard let ssid = client.interface()?.ssid(), !ssid.isEmpty else { return nil }
        return ssid
    }

    /// Serialised on `queue`.
    private func evaluate(reason: String) {
        let ssid = Self.currentSSID()
        let homes = HomeAwakeSettings.ssids
        let wanted = HomeAwakePolicy.shouldHoldDisplayAwake(
            enabled: HomeAwakeSettings.isEnabled, ssid: ssid, homeSSIDs: homes)

        // Log the network only when it moves. The SSID is named in both
        // directions on purpose: "why is my screen still locking" and "why has
        // my screen not locked since Tuesday" are both answered by one line
        // saying which network we thought we were on.
        let changed = lastSSID.map { $0 != ssid } ?? true
        if changed {
            lastSSID = .some(ssid)
            if wanted {
                overlayInfo("🏠 On '\(ssid ?? "?")' — a home network (\(reason))")
            } else {
                overlayInfo("🏠 Not on a home network — SSID \(ssid.map { "'\($0)'" } ?? "unavailable") (\(reason))")
            }
        }

        assertion.hold(wanted, reason: wanted
            ? "on '\(ssid ?? "?")', the screen will not idle-lock (⌃⌘Q still does)"
            : "off '\(homes.joined(separator: "/"))' — normal locking is back")
    }

    // MARK: - Headless hook (see docs/testing.md)

    /// Everything the decision is made from, as JSON, so "why did my screen lock
    /// at home" is one `curl` rather than an hour of waiting for an idle timer.
    func stateJSON() -> String {
        let ssid = Self.currentSSID()
        let homes = HomeAwakeSettings.ssids
        let wanted = HomeAwakePolicy.shouldHoldDisplayAwake(
            enabled: HomeAwakeSettings.isEnabled, ssid: ssid, homeSSIDs: homes)
        let ssidJSON = ssid.map { "\"\($0)\"" } ?? "null"
        let homesJSON = homes.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"enabled\":\(HomeAwakeSettings.isEnabled),"
            + "\"ssid\":\(ssidJSON),"
            + "\"home_ssids\":[\(homesJSON)],"
            + "\"at_home\":\(wanted),"
            + "\"holding\":\(assertion.isHeld),"
            + "\"watching\":\(timer != nil)}"
    }
}
