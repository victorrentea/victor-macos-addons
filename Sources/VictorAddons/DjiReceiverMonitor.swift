import Foundation
import IOKit
import IOUSBHost

/// 🎤 Reads the DJI receiver's vendor status stream over USB: is a transmitter
/// linked, and how full is its battery. Decoding and decisions are in
/// `DjiReceiverProtocol` / `DjiReceiverPolicy`; this is the IOKit plumbing.
///
/// **Only interface 6 is opened.** The audio interfaces belong to CoreAudio and
/// are never touched; interface 6 (class `0xff`) has no kernel driver, so a
/// plain `IOUSBHostInterface` user client gets it without root, without an
/// entitlement and without disturbing the recording. It is exclusive, though:
/// while this app holds it, DJI's own tools (or `tools/dji-rx-status.py`,
/// MicShift, …) cannot, and the reverse — a failed open is logged once and
/// retried.
///
/// One background thread does it all: look for the receiver every
/// `searchInterval` seconds, and once found, sit in a blocking bulk read. The
/// receiver pushes ~10 status frames a second plus a 1 Hz keep-alive, so the
/// thread wakes a few dozen times a second to do almost nothing; the main
/// thread only hears about *changes*. Independent of whisper and of AC power —
/// the battery is worth knowing on battery too.
final class DjiReceiverMonitor {
    static let searchInterval: TimeInterval = 5
    /// No status push for this long while open = the stream is dead; reopen.
    static let staleAfter: TimeInterval = 3

    /// Called on the main thread with each policy event.
    var onEvent: ((DjiReceiverPolicy.Event) -> Void)?

    private let lock = NSLock()
    private var _status: DjiReceiverProtocol.Status?
    private var _lastStatusAt: Date?
    private var _present = false
    private var _openError: String?
    private var policy = DjiReceiverPolicy()   // reader thread only
    private var thread: Thread?

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "dji-receiver"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    /// True while status pushes are actually arriving — the moment this is
    /// true, the receiver's own "no transmitter linked" is the signal, and
    /// whisper's digital-silence guess is only a fallback.
    var isLive: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = _lastStatusAt else { return false }
        return Date().timeIntervalSince(at) < Self.staleAfter
    }

    func stateJSON() -> String {
        lock.lock(); defer { lock.unlock() }
        let live = _lastStatusAt.map { Date().timeIntervalSince($0) < Self.staleAfter } ?? false
        var tx = "[]"
        if let s = _status {
            tx = "[" + s.transmitters.map { t in
                let pct = DjiReceiverProtocol.percent(level: t.level).map(String.init) ?? "null"
                return "{\"unit\":\(t.unit),\"level\":\(t.level),\"percent\":\(pct),\"charging\":\(t.charging)}"
            }.joined(separator: ",") + "]"
        }
        let mask = _status.map { String($0.linkedMask) } ?? "null"
        let err = _openError.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? "null"
        return "{\"present\":\(_present),\"live\":\(live),\"linked_mask\":\(mask),\"transmitters\":\(tx),\"open_error\":\(err)}"
    }

    // MARK: - Reader thread

    private func run() {
        var loggedOpenError: String?
        while true {
            let service = Self.findInterface()
            setPresent(service != 0)
            guard service != 0 else {
                Thread.sleep(forTimeInterval: Self.searchInterval)
                continue
            }
            do {
                let intf = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
                loggedOpenError = nil
                setOpenError(nil)
                overlayInfo("🎤 DJI receiver: reading its status on USB interface 6")
                readLoop(intf)
                intf.destroy()
                overlayInfo("🎤 DJI receiver: status stream ended (unplugged?)")
            } catch {
                IOObjectRelease(service)
                let msg = "\(error)"
                setOpenError(msg)
                if loggedOpenError != msg {
                    overlayError("🎤 DJI receiver present but its status interface would not open (another app holding it?): \(msg)")
                    loggedOpenError = msg
                }
            }
            policy.receiverGone()
            lock.lock(); _status = nil; _lastStatusAt = nil; lock.unlock()
            Thread.sleep(forTimeInterval: Self.searchInterval)
        }
    }

    private func readLoop(_ intf: IOUSBHostInterface) {
        guard let pipe = try? intf.copyPipe(withAddress: 0x86) else {
            overlayError("🎤 DJI receiver: no bulk IN endpoint 0x86 on interface 6")
            return
        }
        var buffer: [UInt8] = []
        var lastPush = Date()
        let data = NSMutableData(length: 512)!
        var loggedV1 = false
        while true {
            var got = 0
            do {
                try pipe.__sendIORequest(with: data, bytesTransferred: &got, completionTimeout: 1.5)
            } catch {
                // A timeout on a live device is just a quiet moment; a gone
                // device errors every time, and the staleness check ends it.
                if Date().timeIntervalSince(lastPush) > Self.staleAfter { return }
                continue
            }
            buffer.append(contentsOf: UnsafeRawBufferPointer(start: data.bytes, count: got))
            for frame in DjiReceiverProtocol.takeFrames(&buffer) {
                if let status = DjiReceiverProtocol.decodeStatus(frame) {
                    lastPush = Date()
                    handle(status, at: lastPush)
                } else if !loggedV1, DjiReceiverProtocol.isV1Heartbeat(frame) {
                    loggedV1 = true
                    lastPush = Date()
                    overlayError("🎤 DJI receiver speaks the v1 protocol — no battery on that firmware; update it in DJI Mimo")
                }
            }
            if Date().timeIntervalSince(lastPush) > Self.staleAfter { return }
        }
    }

    private func handle(_ status: DjiReceiverProtocol.Status, at now: Date) {
        lock.lock()
        let changed = status != _status
        _status = status
        _lastStatusAt = now
        lock.unlock()
        // The policy has to see every push (the link-loss grace is a clock),
        // but a push identical to the last one can only matter to that clock.
        let events = policy.feed(status, now: now)
        if changed {
            let txs = status.transmitters.map { "TX\($0.unit) level \($0.level)\($0.charging ? " charging" : "")" }
            overlayInfo("🎤 DJI status: linked=0x\(String(status.linkedMask, radix: 16)) \(txs.joined(separator: ", "))")
        }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            events.forEach { self?.onEvent?($0) }
        }
    }

    private func setPresent(_ p: Bool) {
        lock.lock(); _present = p; lock.unlock()
    }

    private func setOpenError(_ e: String?) {
        lock.lock(); _openError = e; lock.unlock()
    }

    /// Interface 6 of the receiver, or 0. Caller owns the returned reference.
    private static func findInterface() -> io_service_t {
        let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
        match["idVendor"] = 0x2ca3
        match["idProduct"] = 0x4011
        match["bInterfaceNumber"] = 6
        // Required: IOUSBHostInterface only matches on the USB-spec key sets,
        // and vendor+product+interface is one only WITH the configuration.
        // Without it the lookup silently finds nothing (seen 2026-09-26).
        match["bConfigurationValue"] = 1
        return IOServiceGetMatchingService(kIOMainPortDefault, match)
    }
}
