import Foundation

/// The DJI Mic Mini receiver's own status stream, decoded — pure, no USB.
///
/// The receiver (`Wireless Mic Rx`, USB `0x2ca3:0x4011`) has, beside its audio
/// interfaces, a vendor interface (#6, class `0xff`) whose bulk IN endpoint
/// `0x86` pushes status about ten times a second, unasked. The format is the
/// community reverse-engineering in
/// <https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/main/PROTOCOL.md>
/// (also used live on macOS by <https://github.com/dvnkshl/MicShift>), and was
/// confirmed on Victor's own receiver on 2026-09-26 — the fixtures in
/// `DjiReceiverProtocolTests` are frames captured from it.
///
/// Framing: `0x55`, total length, `0x04`, header CRC-8, …, CRC-16. A status
/// frame carries `5b 03` at offset 9 and the firmware generation at offset 11
/// (`0x03` = v2, which is what Victor's receiver speaks; v1's layout carries no
/// battery). The v2 status push is 54 / 86 / 118 bytes for 0 / 1 / 2 linked
/// transmitters:
///   * byte 44 — which transmitters are linked (`0x01` TX1, `0x02` TX2);
///   * from byte 52, one 32-byte slot per linked TX: `+0` = `0x02`,
///     `+1` = the physical unit, `+7` = flags: `0x02` docked/charging and
///     `(b >> 2) & 7` the battery gauge, 1 (full) … 7 (about to shut off).
/// CRCs are not checked: a frame whose shape does not match is ignored, and a
/// corrupt one that happens to match is corrected by the next, 100 ms later.
enum DjiReceiverProtocol {

    struct Transmitter: Equatable {
        let unit: Int
        /// 1 = full … 6 = DJI's own low-battery warning … 7 = about to shut off.
        let level: Int
        let charging: Bool
    }

    struct Status: Equatable {
        /// Bit 0x01 = TX1 linked, 0x02 = TX2 linked.
        let linkedMask: UInt8
        /// One entry per linked transmitter whose slot has arrived. The mask
        /// can run one push ahead of the slot, so a linked TX may briefly have
        /// no entry here — never the reverse.
        let transmitters: [Transmitter]

        var anyLinked: Bool { linkedMask & 0x03 != 0 }
    }

    /// Pops every complete frame off the front of `buffer`, dropping garbage.
    static func takeFrames(_ buffer: inout [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        while true {
            guard let start = buffer.firstIndex(of: 0x55) else { buffer.removeAll(); return out }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 3 else { return out }
            let length = Int(buffer[1])
            if buffer[2] != 0x04 || length < 14 {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= length else { return out }
            out.append(Array(buffer[0..<length]))
            buffer.removeFirst(length)
        }
    }

    /// The v2 status push, or nil for anything else (ACKs, the identity push,
    /// the audio-level push, v1 heartbeats).
    static func decodeStatus(_ f: [UInt8]) -> Status? {
        guard [54, 86, 118].contains(f.count), f[0] == 0x55, f[9] == 0x5b, f[10] == 0x03, f[11] == 0x03
        else { return nil }
        var txs: [Transmitter] = []
        for i in 0..<((f.count - 54) / 32) {
            let s = 52 + 32 * i
            guard f[s] == 0x02 else { return nil }
            txs.append(Transmitter(unit: Int(f[s + 1]),
                                   level: Int((f[s + 7] >> 2) & 0x07),
                                   charging: f[s + 7] & 0x02 != 0))
        }
        return Status(linkedMask: f[44], transmitters: txs)
    }

    /// Does this frame come from v1 firmware (a heartbeat with marker 0x00)?
    /// Only for the log: v1 has no battery, and this app does not decode it.
    static func isV1Heartbeat(_ f: [UInt8]) -> Bool {
        [56, 70, 84].contains(f.count) && f[9] == 0x5b && f[10] == 0x03 && f[11] == 0x00
    }

    /// What the menu's `🎙️ Transcribing: 🎤 DJI` row appends, or nil for
    /// nothing: `≈80 %` (one per linked transmitter, `≈80 % / ≈40 %` for two),
    /// `— no TX` when the receiver says none is linked. Nil when the status
    /// stream is not live — a stale number is worse than none.
    static func menuSuffix(_ status: Status?, live: Bool) -> String? {
        guard live, let status else { return nil }
        guard status.anyLinked else { return "— no TX" }
        let pcts = status.transmitters.compactMap { percent(level: $0.level) }.map { "≈\($0) %" }
        return pcts.isEmpty ? nil : pcts.joined(separator: " / ")
    }

    /// The gauge as an approximate percentage. **A 7-step level, not a
    /// measurement**: the receiver never says more than this, so every value
    /// here is shown as `≈NN %`, and the raw level goes to the log beside it.
    ///
    /// Mapping (the one dji-mic-battery-tray uses for the same gauge,
    /// <https://github.com/chenleshu/dji-mic-battery-tray>): the five green
    /// steps are 100/80/60/40/20, then DJI's own low warning (6) and the
    /// shutdown step (7) are both below that fifth. What matters for the
    /// "under 20 %" rule is that it is exactly levels 6 and 7 — the two the
    /// DJI app itself treats as low.
    static func percent(level: Int) -> Int? {
        switch level {
        case 1: return 100
        case 2: return 80
        case 3: return 60
        case 4: return 40
        case 5: return 20
        case 6: return 10
        case 7: return 5
        default: return nil   // 0 has never been seen; treat as unknown
        }
    }
}

/// What the app does with successive status pushes. Pure: fed readings and a
/// clock, returns the announcements — the IOKit reader and the banners are
/// plumbing around it.
struct DjiReceiverPolicy {
    /// Below this, every change of the reading is shown (Victor: "să o afișezi
    /// din % în % pentru 5 sec când e sub 20 %"). On a 7-step gauge that is
    /// levels 6 and 7.
    static let lowPercent = 20
    /// How long "no transmitter linked" must last before the sticky alarm.
    /// A transmitter re-links in a second or two after a radio hiccup; a dead
    /// one never does. 5 s is far past the first and costs nothing on the
    /// second — the alarm's own text carries the moment it began.
    static let linkLossGrace: TimeInterval = 5

    enum Event: Equatable {
        /// Show the 5-second battery tab.
        case lowBattery(unit: Int, level: Int, percent: Int)
        /// Every level change, for the log (the only place the raw level goes).
        case levelChanged(unit: Int, level: Int, charging: Bool)
        /// Link lost for longer than the grace: raise the sticky alarm.
        /// `lastLevel` is the last gauge seen before it went, to word the alarm.
        case linkLost(since: Date, lastLevel: Int?)
        case linkBack
    }

    private var lastLevel: [Int: Int] = [:]
    private var lastCharging: [Int: Bool] = [:]
    private var wasLinked = false
    private var lastLinkedLevel: Int?
    private var lastLinkedCharging = false
    private var unlinkedSince: Date?
    private var linkLossReported = false

    mutating func feed(_ s: DjiReceiverProtocol.Status, now: Date) -> [Event] {
        var events: [Event] = []
        for tx in s.transmitters {
            if lastLevel[tx.unit] != tx.level || lastCharging[tx.unit] != tx.charging {
                events.append(.levelChanged(unit: tx.unit, level: tx.level, charging: tx.charging))
                if !tx.charging, let pct = DjiReceiverProtocol.percent(level: tx.level),
                   pct < Self.lowPercent, lastLevel[tx.unit] != tx.level {
                    events.append(.lowBattery(unit: tx.unit, level: tx.level, percent: pct))
                }
                lastLevel[tx.unit] = tx.level
                lastCharging[tx.unit] = tx.charging
            }
            lastLinkedLevel = tx.level
            lastLinkedCharging = tx.charging
        }
        if s.anyLinked {
            if linkLossReported { events.append(.linkBack) }
            wasLinked = true
            unlinkedSince = nil
            linkLossReported = false
        } else if wasLinked {
            // Put back in its case to charge is not a death: the last push
            // before the link went said "charging", so say nothing.
            if lastLinkedCharging {
                wasLinked = false
            } else {
                let since = unlinkedSince ?? now
                unlinkedSince = since
                if !linkLossReported, now.timeIntervalSince(since) >= Self.linkLossGrace {
                    linkLossReported = true
                    events.append(.linkLost(since: since, lastLevel: lastLinkedLevel))
                }
            }
        }
        return events
    }

    /// The receiver itself went away (unplugged): forget the link, so plugging
    /// it back in with no transmitter on does not read as a death.
    mutating func receiverGone() {
        self = DjiReceiverPolicy()
    }
}
