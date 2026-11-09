import CoreAudio
import Foundation
import os

/// 🎙️ Which input the meeting actually hears Victor through. Pure.
///
/// Victor changes mics (lapel, Bose, the XLR on the Elgato, the built-in) and
/// most of the time goes through **Krisp** ("krisp microphone": a fixed
/// +5.5 dB, no AGC — measured 2026-11-09). So the meter never guesses from
/// what is *open*: Krisp itself holds the Elgato open, and so does Whisper.
/// It asks CoreAudio which devices the **meeting process** is capturing
/// (`kAudioProcessPropertyDevices`, input scope, on a process whose
/// `kAudioProcessPropertyIsRunningInput` is set):
///
/// 1. a test override (`GET /test/voice/device?name=…`) — the proofs feed
///    "From Walkie" as the meeting mic;
/// 2. "krisp microphone", when a meeting app is capturing it;
/// 3. any other device a meeting app is capturing — except the share-sound
///    loopbacks (`ZoomAudioDevice`, `Microsoft Teams Audio`): Zoom reads the
///    Mac's shared sound back through its own device's input, and measuring
///    that would measure the effects, not the voice;
/// 4. the system default input, when no meeting app captures anything (a
///    share with the mic muted at the source, say).
enum VoiceDevicePick {
    static let meetingBundlePrefixes = ["us.zoom.xos", "com.microsoft.teams"]
    static let shareLoopbacks: Set<String> = ["ZoomAudioDevice", "Microsoft Teams Audio"]
    static let krisp = "krisp microphone"

    struct Capture: Equatable {
        var bundleID: String
        var inputs: [String]
    }

    static func choose(captures: [Capture], defaultInput: String?, override: String?) -> (name: String, why: String)? {
        if let override, !override.isEmpty { return (override, "test override") }
        let meeting = captures.filter { c in meetingBundlePrefixes.contains { c.bundleID.hasPrefix($0) } }
        let heard = meeting.flatMap { c in c.inputs.map { ($0, c.bundleID) } }
            .filter { !shareLoopbacks.contains($0.0) }
        if let k = heard.first(where: { $0.0 == krisp }) { return (krisp, "captured by \(k.1)") }
        if let first = heard.first { return (first.0, "captured by \(first.1)") }
        if let d = defaultInput, !d.isEmpty, !shareLoopbacks.contains(d) {
            return (d, meeting.isEmpty ? "default input (no meeting app capturing)" : "default input")
        }
        return nil
    }
}

/// 🎙️📏 The voice meter: Victor's loudness as the meeting hears it, measured
/// **only while he is screen-sharing** (`MeetingShareWatch`), on battery too.
///
/// It adds one more IOProc to the device the meeting uses — a reader beside
/// Zoom/Teams, Krisp and Whisper, never a new default, never hog mode, never a
/// format or rate change — and every 250 ms turns the last 400 ms into a
/// momentary loudness (`MomentaryMeter`), then into the speech gate, normal,
/// top, peak-hold and the ceiling's reference (`VoiceStats`, `VoiceRefPolicy`).
///
/// Readers: `GET /voice/level` (the tablet's red strip, off the main thread),
/// the flat `voiceSharing` key in `/ping`, and victor-effects, which is
/// **pushed** `GET /voice/ref?sharing=&ref=` once a second while sharing and
/// once on each edge (see `pushToEffects` for why push).
final class VoiceMeter {
    static let shared = VoiceMeter()

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.voice-meter", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var tap: InputTap?
    private var stats = VoiceStats()
    private var sharing = false
    private var heldThisShare: Double?
    private var device: (name: String, why: String)?
    private var override: String?
    private var lastMeasureAt: Date?
    private var lastBlocks = 0
    private var ticks = 0
    private var lastPersist = Date.distantPast
    private var cappedLogAt = Date.distantPast

    /// The last snapshot, for readers on other threads.
    private let lock = OSAllocatedUnfairLock(initialState: "")

    private static let lastRefKey = "VoiceMeter.lastRef"
    private static let lastRefAtKey = "VoiceMeter.lastRefAt"

    // MARK: - Control

    /// From `MeetingShareWatch.onChange` (main) — the only switch.
    func setSharing(_ on: Bool) {
        queue.async { [self] in
            guard on != sharing else { return }
            sharing = on
            if on {
                heldThisShare = nil
                startTicking()
            } else {
                persistRef(force: true)
                stopTap()
                timer?.cancel(); timer = nil
                device = nil
                publish()
                pushToEffects()
            }
        }
    }

    func setOverride(_ name: String?) {
        queue.sync {
            override = (name?.isEmpty ?? true) ? nil : name
            overlayInfo("🎙️ voice device override: \(override ?? "none")")
            if sharing { reselect() }
        }
    }

    func reset() {
        queue.sync {
            stats = VoiceStats()
            heldThisShare = nil
            publish()
        }
    }

    var isSharing: Bool { queue.sync { sharing } }

    /// `GET /voice/level` — small JSON, any thread.
    var levelJSON: String {
        let s = lock.withLock { $0 }
        return s.isEmpty ? "{\"sharing\":false,\"speaking\":false}" : s
    }

    // MARK: - The 250 ms loop

    private func startTicking() {
        reselect()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        publish()
        pushToEffects()
    }

    private func tick() {
        guard sharing else { return }
        ticks += 1
        if ticks % 8 == 0 { reselect() }               // every 2 s: did the meeting switch mics?
        if let tap, let reading = tap.read(), reading.blocks != lastBlocks, let m = reading.momentary {
            lastBlocks = reading.blocks
            let now = Date()
            stats.add(m, at: now.timeIntervalSinceReferenceDate)
            lastMeasureAt = now
            if let live = stats.liveRef(now: now.timeIntervalSinceReferenceDate) { heldThisShare = live }
            persistRef(force: false)
        }
        publish()
        if ticks % 4 == 0 { pushToEffects() }          // 1 Hz
    }

    // MARK: - Device

    private func reselect() {
        let pick = VoiceDevicePick.choose(captures: CoreAudioQuery.meetingCaptures(),
                                          defaultInput: CoreAudioQuery.defaultInputName(),
                                          override: override)
        guard pick?.name != device?.name || (pick != nil && tap == nil) else { return }
        stopTap()
        device = pick
        guard let pick else {
            overlayInfo("🎙️ voice meter: no input to measure")
            return
        }
        guard let id = CoreAudioQuery.deviceID(named: pick.name), let t = InputTap(device: id) else {
            overlayError("🎙️ voice meter: cannot open '\(pick.name)'")
            return
        }
        tap = t
        lastBlocks = 0
        overlayInfo("🎙️ voice meter on '\(pick.name)' (\(pick.why)), \(Int(t.sampleRate)) Hz × \(t.channels)")
    }

    private func stopTap() {
        tap?.stop()
        tap = nil
    }

    // MARK: - Reference + publishing

    private func previousRef() -> (value: Double, at: Date)? {
        let d = UserDefaults.standard
        guard let at = d.object(forKey: Self.lastRefAtKey) as? Date,
              let v = d.object(forKey: Self.lastRefKey) as? Double else { return nil }
        return (v, at)
    }

    private func persistRef(force: Bool) {
        guard let held = heldThisShare, force || Date().timeIntervalSince(lastPersist) > 10 else { return }
        lastPersist = Date()
        UserDefaults.standard.set(held, forKey: Self.lastRefKey)
        UserDefaults.standard.set(Date(), forKey: Self.lastRefAtKey)
    }

    private func currentRef(now: Date) -> (value: Double, source: VoiceRefPolicy.Source) {
        VoiceRefPolicy.resolve(live: stats.liveRef(now: now.timeIntervalSinceReferenceDate),
                               heldThisShare: heldThisShare, previous: previousRef(), now: now)
    }

    private func publish() {
        let now = Date()
        func n(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "null" }
        let json: String
        if sharing {
            let ref = currentRef(now: now)
            let age = lastMeasureAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
            json = "{\"sharing\":true,\"speaking\":\(stats.speaking && age >= 0 && age < 1000)"
                + ",\"momentary\":\(n(stats.momentary)),\"peakHold\":\(n(stats.peak))"
                + ",\"normal\":\(n(stats.normal)),\"top\":\(n(stats.top)),\"gate\":\(n(stats.gate))"
                + ",\"voiceRef\":\(n(ref.value)),\"voiceRefSource\":\"\(ref.source.rawValue)\""
                + ",\"device\":\(TabletHttpServer.jsonString(device?.name ?? ""))"
                + ",\"deviceWhy\":\(TabletHttpServer.jsonString(device?.why ?? ""))"
                + ",\"ageMs\":\(age)}"
        } else {
            json = "{\"sharing\":false,\"speaking\":false}"
        }
        lock.withLock { $0 = json }
    }

    /// **Push, not pull.** This app is the one that knows when a share starts
    /// and stops, so the effects app hears the edge at once instead of on its
    /// next poll; outside a share it is sent nothing and polls nothing; and it
    /// never waits on this app at play time — it caps with the last value it was
    /// given (which it lets go after 60 s, so a dead addons cannot leave the
    /// soundboard muffled). Fire-and-forget, like every addons → effects call.
    private func pushToEffects() {
        let path: String
        if sharing {
            let ref = currentRef(now: Date())
            path = "/voice/ref?sharing=1&ref=\(String(format: "%.2f", ref.value))&src=\(ref.source.rawValue)"
        } else {
            path = "/voice/ref?sharing=0"
        }
        EffectsProxy.fire(path)
    }
}

/// One extra IOProc on an input device, feeding a `MomentaryMeter`. The IO
/// block only filters and sums; the 250 ms loop reads the result under a lock.
final class InputTap {
    let device: AudioDeviceID
    let sampleRate: Double
    let channels: Int
    private var procID: AudioDeviceIOProcID?
    private let state: OSAllocatedUnfairLock<MomentaryMeter>

    init?(device: AudioDeviceID) {
        self.device = device
        guard let rate = CoreAudioQuery.nominalRate(device), rate > 0,
              let format = CoreAudioQuery.inputVirtualFormat(device),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return nil }
        sampleRate = rate
        let total = CoreAudioQuery.inputChannelCount(device)
        guard total > 0 else { return nil }
        channels = min(2, total)
        state = OSAllocatedUnfairLock(initialState: MomentaryMeter(sampleRate: rate, channels: min(2, total)))
        let st = state
        var proc: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard abl.count > 0, let d0 = abl[0].mData else { return }
            let b0 = abl[0]
            let ch0 = UnsafePointer(d0.assumingMemoryBound(to: Float.self))
            let stride0 = max(1, Int(b0.mNumberChannels))
            let frames = Int(b0.mDataByteSize) / (MemoryLayout<Float>.size * stride0)
            let second: (UnsafePointer<Float>, Int)?
            if b0.mNumberChannels >= 2 {
                second = (ch0 + 1, stride0)                       // interleaved
            } else if abl.count >= 2, let d1 = abl[1].mData {
                second = (UnsafePointer(d1.assumingMemoryBound(to: Float.self)), max(1, Int(abl[1].mNumberChannels)))
            } else {
                second = nil
            }
            st.withLock { m in m.feed(ch0, stride0: stride0, second?.0, stride1: second?.1 ?? 1, frames: frames) }
        }
        guard err == noErr, let proc else { return nil }
        procID = proc
        guard AudioDeviceStart(device, proc) == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            return nil
        }
    }

    func read() -> (momentary: Double?, blocks: Int)? {
        state.withLock { ($0.momentary, $0.blocksSeen) }
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }

    deinit { stop() }
}

/// The few CoreAudio reads the meter needs.
enum CoreAudioQuery {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return [] }
        return out
    }

    private static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func uint32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func name(_ device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    static func deviceID(named name: String) -> AudioDeviceID? {
        ids(system, kAudioHardwarePropertyDevices).first { self.name($0) == name && inputChannelCount($0) > 0 }
    }

    static func defaultInputName() -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return name(id)
    }

    /// Every process that is capturing input right now, with the input devices it uses.
    static func meetingCaptures() -> [VoiceDevicePick.Capture] {
        guard #available(macOS 14.0, *) else { return [] }
        return ids(system, kAudioHardwarePropertyProcessObjectList).compactMap { p in
            guard uint32(p, kAudioProcessPropertyIsRunningInput) == 1,
                  let bundle = string(p, kAudioProcessPropertyBundleID), !bundle.isEmpty,
                  VoiceDevicePick.meetingBundlePrefixes.contains(where: { bundle.hasPrefix($0) }) else { return nil }
            let inputs = ids(p, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput)
                .filter { inputChannelCount($0) > 0 }.compactMap(name)
            return VoiceDevicePick.Capture(bundleID: bundle, inputs: inputs)
        }
    }

    static func nominalRate(_ device: AudioDeviceID) -> Double? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var v: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                           mScope: kAudioObjectPropertyScopeInput,
                                           mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func inputVirtualFormat(_ device: AudioDeviceID) -> AudioStreamBasicDescription? {
        let streams = ids(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        guard let s = streams.first else { return nil }
        var a = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var f = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(s, &a, 0, nil, &size, &f) == noErr ? f : nil
    }
}
