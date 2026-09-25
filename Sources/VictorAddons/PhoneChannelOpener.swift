import Foundation
import IOBluetooth

/// Runs one SDP query + RFCOMM open against the phone, on the run loop of the
/// thread it is started from, and reports what actually happened — including a
/// retry with a freshly queried channel number when the first open is refused.
///
/// It is also the channel's delegate, and it has to be retained by its owner
/// for as long as the channel is meant to stay up: IOBluetooth does not retain
/// the delegate, and a deallocated delegate takes the channel with it.
///
/// Shared by the two things this Mac asks the phone for: `HotspotFallback`
/// (the SPP channel, whose mere opening is the signal) and `PhoneRoamingMonitor`
/// (a channel of its own, which answers with one line of JSON). Every lesson
/// below was paid for by the first; the second gets them for free.
final class PhoneChannelOpener: NSObject, IOBluetoothRFCOMMChannelDelegate {
    enum Outcome {
        case opened(IOBluetoothRFCOMMChannel, BluetoothRFCOMMChannelID)
        case failed(String)
    }

    /// Page timeout for bringing the baseband link up, in 0.625 ms slots:
    /// 0x2000 ≈ 5.1 s. Measured cold, the phone answers in 4.0 s.
    private static let pageTimeout: BluetoothHCIPageTimeout = 0x2000

    /// How long the phone gets to answer one SDP query.
    ///
    /// 6 s was too tight and produced a false negative on the first
    /// automatic attempt of a real test: a query answers in about a second
    /// once the ACL link is up, but when it is cold the phone has to be
    /// paged first, and that is where the seconds go. This is paid only when
    /// the phone is genuinely unreachable.
    private static let sdpTimeout: TimeInterval = 15

    private let device: IOBluetoothDevice
    private let service: IOBluetoothSDPUUID
    /// For the log and the error texts only ("SPP", "roaming status").
    private let serviceName: String
    private var report: ((Outcome) -> Void)?
    /// Bytes the phone sends over the open channel. The hotspot beacon never
    /// sends any; the roaming channel sends its reading.
    var onData: ((Data) -> Void)?
    var onClosed: (() -> Void)?
    private var channel: IOBluetoothRFCOMMChannel?
    private var channelID: BluetoothRFCOMMChannelID = 0
    /// One retry, and only after a *fresh* SDP query — the whole point is to
    /// stop trusting a channel number that has gone stale.
    private var triesLeft = 2
    private var sdpWatchdog: Timer?

    init(device: IOBluetoothDevice, service: IOBluetoothSDPUUID, serviceName: String,
         report: @escaping (Outcome) -> Void) {
        self.device = device
        self.service = service
        self.serviceName = serviceName
        self.report = report
    }

    func start() { querySDP() }

    private func finish(_ outcome: Outcome) {
        sdpWatchdog?.invalidate()
        sdpWatchdog = nil
        let r = report
        report = nil
        r?(outcome)
    }

    /// **The link has to be up before the SDP query, or the query never
    /// comes back at all.** Measured 27 Aug 2026, with the adapter
    /// power-cycled to imitate a lid-close: `performSDPQuery` returns
    /// `kIOReturnSuccess` and `sdpQueryComplete` then simply never fires —
    /// 42 s and counting. macOS will not page the phone on an SDP query's
    /// behalf. `openConnection()` will, and takes **4.0 s** from cold; after
    /// it the query answers in 0.0 s and the channel opens in 0.2 s.
    ///
    /// This is exactly what a lid-open hits, and it is why the chain kept
    /// failing in the one situation it exists for while working perfectly
    /// whenever it was tested with the link already warm.
    private func querySDP() {
        guard triesLeft > 0 else {
            return finish(.failed("the phone refused the RFCOMM channel twice"))
        }
        triesLeft -= 1

        if !device.isConnected() {
            let began = Date()
            // Bounded, so a phone that is out of range or switched off costs
            // one page timeout rather than blocking this thread indefinitely.
            let r = device.openConnection(nil, withPageTimeout: Self.pageTimeout, authenticationRequired: false)
            let took = String(format: "%.1f", Date().timeIntervalSince(began))
            guard r == kIOReturnSuccess else {
                return finish(.failed("the phone did not answer the Bluetooth page in \(took)s (\(r)) — out of range or switched off?"))
            }
            overlayInfo("📶 Bluetooth link to the phone up in \(took)s")
        }

        // A query that never comes back would otherwise hang the attempt for
        // the whole outer budget with nothing in the log to say why.
        sdpWatchdog = Timer.scheduledTimer(withTimeInterval: Self.sdpTimeout, repeats: false) { [weak self] _ in
            self?.finish(.failed("the phone did not answer the SDP query in \(Int(Self.sdpTimeout))s"))
        }
        let status = device.performSDPQuery(self)
        if status != kIOReturnSuccess {
            finish(.failed("performSDPQuery failed (\(status))"))
        }
    }

    /// `IOBluetoothDeviceAsyncCallbacks` — the SDP cache has just been
    /// refreshed, so this is the first moment the channel number can be
    /// trusted.
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        sdpWatchdog?.invalidate()
        sdpWatchdog = nil
        guard status == kIOReturnSuccess else {
            return finish(.failed("SDP query failed (\(status)) — is the phone in range?"))
        }
        guard let rec = self.device.getServiceRecord(for: service) else {
            return finish(.failed("the phone is not publishing the \(serviceName) channel — is victor-phone-addons running (and up to date)?"))
        }
        var chID: BluetoothRFCOMMChannelID = 0
        guard rec.getRFCOMMChannelID(&chID) == kIOReturnSuccess, chID != 0 else {
            return finish(.failed("the \(serviceName) record carries no RFCOMM channel number"))
        }
        channelID = chID

        var ch: IOBluetoothRFCOMMChannel?
        let r = self.device.openRFCOMMChannelAsync(&ch, withChannelID: chID, delegate: self)
        guard r == kIOReturnSuccess, let ch else {
            return finish(.failed("openRFCOMMChannelAsync failed on channel \(chID) (\(r))"))
        }
        channel = ch
    }

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard status == kIOReturnSuccess else {
            // Re-querying on its own would not help: with the link up, macOS
            // answers an SDP query out of its own cache in 0.0 s — the same
            // cache that just gave us a number nobody is listening on. The
            // link has to go down and come back for the record to be fetched
            // from the phone again.
            overlayInfo("📵 channel \(channelID) refused (\(status)) — dropping the link to re-read the phone's SDP record")
            channel = nil
            device.closeConnection()
            return querySDP()
        }
        guard let ch else { return finish(.failed("channel opened with no channel object")) }
        finish(.opened(ch, channelID))
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        overlayInfo("📵 \(serviceName) channel to the phone closed")
        onClosed?()
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        guard let data, length > 0 else { return }
        onData?(Data(bytes: data, count: length))
    }
}
