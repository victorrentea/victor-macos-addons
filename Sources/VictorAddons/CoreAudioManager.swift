import AppKit
import AudioToolbox
import CoreAudio
import Foundation

class CoreAudioManager {
    // MARK: - Wispr Flow recording-state watcher
    //
    // Continuously poll Wispr Flow's recording state
    // (kAudioProcessPropertyIsRunningInput on com.electron.wispr-flow.helper).
    // When Wispr is recording AND audio is playing on 🔊OS Output, drop the
    // device's volume to 1% and remember the original. When Wispr stops,
    // restore the original — but only if we were the one who dropped it.
    //
    // Race-condition rules (the whole reason this design exists):
    //   1. Loopback "is playing" only decides whether to MUTE. It is never
    //      consulted to decide whether to restore — once we drop to 1%, the
    //      loopback measures near-silence and would falsely un-mute mid-talk.
    //   2. originalVolume is captured ONLY on the false→true transition of
    //      volumePushedDown. We never re-save while pushed down (otherwise
    //      we'd save 1% and lose the real value).
    //   3. All state mutation runs on the serial pollQueue. Even if a tick
    //      overshoots the 300ms interval (the loopback probe sleeps ~150ms),
    //      the next tick queues behind it — no concurrent reads/writes.

    private static let monitoredOutputName = "🔊OS Output"
    private static let dictationVolumeLow: Float = 0.01
    private static let wisprBundlePrefix = "com.electron.wispr-flow"
    private static let normalPollInterval: TimeInterval = 0.3
    private static let boostedPollInterval: TimeInterval = 0.1
    private static let boostDuration: TimeInterval = 1.0

    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "ro.victorrentea.macos-addons.wispr-watch", qos: .userInteractive)
    private var lastWisprRecording = false
    private var volumePushedDown = false
    private var originalVolume: Float = 1.0

    // Boost window: while Date() < boostedUntil, the next tick is scheduled
    // 100ms out instead of 300ms. Mouse-5 (Wispr push-to-talk) press extends
    // this window by 1s — every press resets the deadline to now+1s, so the
    // boost ends exactly 1s after the LAST press.
    //
    // nextDeadline mirrors the timer's scheduled fire time so notifyMouseButton5Pressed
    // can decide whether the upcoming tick is already soon enough or needs pulling
    // forward. All four fields are touched only from pollQueue → no locking.
    private var boostedUntil: Date = .distantPast
    private var nextDeadline: Date = .distantPast

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.setEventHandler { [weak self] in self?.tickAndReschedule() }
        pollTimer = timer
        pollQueue.async { [weak self] in
            self?.scheduleNext(in: Self.normalPollInterval)
        }
        timer.resume()
        overlayInfo("🎤 Wispr-watch started (poll \(Int(Self.normalPollInterval * 1000))ms, boost \(Int(Self.boostedPollInterval * 1000))ms for \(Int(Self.boostDuration * 1000))ms after Mouse5, mute target=\(Self.monitoredOutputName) @ \(Int(Self.dictationVolumeLow * 100))%)")
    }

    /// Called from the event tap when Mouse 5 (Wispr push-to-talk) is pressed.
    /// Bumps the poll into boosted mode for 1s after the last press.
    func notifyMouseButton5Pressed() {
        pollQueue.async { [weak self] in
            guard let self = self else { return }
            let now = Date()
            self.boostedUntil = now.addingTimeInterval(Self.boostDuration)
            // Only pull the next tick forward if the currently-scheduled one
            // is later than 100ms from now. An already-imminent tick will fire
            // on its existing deadline; it will then re-arm at 100ms because
            // boostedUntil is now in the future.
            let desired = now.addingTimeInterval(Self.boostedPollInterval)
            if desired < self.nextDeadline {
                self.scheduleNext(in: Self.boostedPollInterval)
            }
        }
    }

    // Must be called on pollQueue.
    private func scheduleNext(in interval: TimeInterval) {
        nextDeadline = Date().addingTimeInterval(interval)
        pollTimer?.schedule(deadline: .now() + interval, repeating: .never)
    }

    private func tickAndReschedule() {
        tick()
        let interval = (Date() < boostedUntil) ? Self.boostedPollInterval : Self.normalPollInterval
        scheduleNext(in: interval)
    }

    private func tick() {
        let recording = isWisprRecording()
        let prev = lastWisprRecording
        lastWisprRecording = recording

        if recording {
            if !volumePushedDown {
                // Either Wispr just started, or it's been on but no audio
                // was playing yet. Keep checking the loopback every poll
                // until we either mute or Wispr stops.
                let playing = isLoopbackPlaying()
                if !prev {
                    overlayInfo("🟢 Wispr started → isMediaPlaying=\(playing)")
                }
                if playing {
                    pushVolumeDown()
                }
            }
            // If volumePushedDown is already true: do nothing. Loopback would
            // read silent and mislead us.
        } else {
            if volumePushedDown {
                if prev {
                    overlayInfo("🔴 Wispr stopped → restoring volume")
                }
                restoreVolume()
            } else if prev {
                overlayInfo("🔴 Wispr stopped (no volume change to restore)")
            }
        }
    }

    private func pushVolumeDown() {
        guard let deviceID = findAudioDevice(named: Self.monitoredOutputName) else {
            overlayInfo("🛑 push-down: device '\(Self.monitoredOutputName)' not found")
            return
        }
        let current = getDeviceVolume(deviceID: deviceID)
        // Capture BEFORE we change it. This is the only place originalVolume
        // is written while volumePushedDown is false → no risk of saving 1%.
        originalVolume = current
        setDeviceVolume(deviceID: deviceID, volume: Self.dictationVolumeLow)
        volumePushedDown = true
        let fromPct = Int((current * 100).rounded())
        let toPct = Int((Self.dictationVolumeLow * 100).rounded())
        overlayInfo("🔇 \(Self.monitoredOutputName) \(fromPct)% → \(toPct)% (Wispr active)")
    }

    private func restoreVolume() {
        let target = originalVolume
        // Clear the flag first. Even if findAudioDevice or set fails, we
        // don't want to be stuck thinking we still own the volume — the next
        // Wispr-start cycle would skip the save and we'd lose the real value.
        volumePushedDown = false
        guard let deviceID = findAudioDevice(named: Self.monitoredOutputName) else {
            overlayInfo("🛑 restore: device '\(Self.monitoredOutputName)' not found (target was \(Int((target * 100).rounded()))%)")
            return
        }
        setDeviceVolume(deviceID: deviceID, volume: target)
        let pct = Int((target * 100).rounded())
        overlayInfo("🔊 \(Self.monitoredOutputName) → \(pct)% (Wispr stopped)")
    }

    func probeWisprRecording() -> Bool { isWisprRecording() }

    private func isWisprRecording() -> Bool {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &listAddr, 0, nil, &size) == noErr else { return false }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var procs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &listAddr, 0, nil, &size, &procs) == noErr else { return false }
        for p in procs {
            var bidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var bidSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(p, &bidAddr, 0, nil, &bidSize) == noErr else { continue }
            var bid: Unmanaged<CFString>?
            guard AudioObjectGetPropertyData(p, &bidAddr, 0, nil, &bidSize, &bid) == noErr else { continue }
            let bundle = (bid?.takeRetainedValue() as String?) ?? ""
            guard bundle.hasPrefix(Self.wisprBundlePrefix) else { continue }
            var inAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var inSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(p, &inAddr, 0, nil, &inSize, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    // MARK: - Loopback energy detector
    //
    // The "🔊OS Output" loopback (Rogue Amoeba) carries everything macOS plays.
    // Device-level "running" flags are unreliable here because Audio Hijack
    // always holds the loopback open as a listener, and silent-but-open streams
    // keep the flag latched. Tap the loopback's input scope and measure actual
    // sample energy — ground truth for "is anything audible right now".

    private static let silenceRMSThreshold: Float = 0.0002
    private static let silencePeakThreshold: Float = 0.0005
    private static let sampleWindowSeconds: TimeInterval = 0.15

    private func isLoopbackPlaying() -> Bool {
        guard let devID = findAudioDevice(named: Self.monitoredOutputName) else {
            overlayInfo("🛑 RMS: device '\(Self.monitoredOutputName)' not found → assume silent")
            return false
        }
        guard let (rms, peak, sampleCount) = measureLoopbackEnergy(deviceID: devID) else {
            overlayInfo("🛑 RMS: tap failed on '\(Self.monitoredOutputName)' → assume silent")
            return false
        }
        let playing = rms > Self.silenceRMSThreshold || peak > Self.silencePeakThreshold
        overlayInfo(String(format: "📊 RMS=%.5f (thr=%.5f) peak=%.5f (thr=%.5f) samples=%d window=%.0fms → %@",
                           rms, Self.silenceRMSThreshold, peak, Self.silencePeakThreshold,
                           sampleCount, Self.sampleWindowSeconds * 1000,
                           playing ? "PLAYING ⚠️" : "silent"))
        return playing
    }

    struct LoopbackProbe {
        let deviceFound: Bool
        let rms: Float?
        let peak: Float?
        let playing: Bool?
        let deviceName: String
        let rmsThreshold: Float
        let peakThreshold: Float
    }

    func probeOutputLoopback() -> LoopbackProbe {
        guard let devID = findAudioDevice(named: Self.monitoredOutputName) else {
            return LoopbackProbe(deviceFound: false, rms: nil, peak: nil, playing: nil,
                                 deviceName: Self.monitoredOutputName,
                                 rmsThreshold: Self.silenceRMSThreshold,
                                 peakThreshold: Self.silencePeakThreshold)
        }
        guard let (rms, peak, _) = measureLoopbackEnergy(deviceID: devID) else {
            return LoopbackProbe(deviceFound: true, rms: nil, peak: nil, playing: nil,
                                 deviceName: Self.monitoredOutputName,
                                 rmsThreshold: Self.silenceRMSThreshold,
                                 peakThreshold: Self.silencePeakThreshold)
        }
        let playing = rms > Self.silenceRMSThreshold || peak > Self.silencePeakThreshold
        return LoopbackProbe(deviceFound: true, rms: rms, peak: peak, playing: playing,
                             deviceName: Self.monitoredOutputName,
                             rmsThreshold: Self.silenceRMSThreshold,
                             peakThreshold: Self.silencePeakThreshold)
    }

    // MARK: - CoreAudio device helpers

    private func findAudioDevice(named target: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var nameSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &nameAddr, 0, nil, &nameSize) == noErr else { continue }
            var n: Unmanaged<CFString>?
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &n) == noErr else { continue }
            if (n?.takeRetainedValue() as String?) == target { return id }
        }
        return nil
    }

    private func getDeviceVolume(deviceID: AudioObjectID) -> Float {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var volume: Float = 1.0
        var size = UInt32(MemoryLayout<Float>.size)
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &volume)
        return volume
    }

    private func setDeviceVolume(deviceID: AudioObjectID, volume: Float) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var vol = volume
        let size = UInt32(MemoryLayout<Float>.size)
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &vol)
    }

    private final class TapContext {
        var unit: AudioUnit?
        var samples: [Float] = []
        let lock = NSLock()
    }

    private func measureLoopbackEnergy(deviceID: AudioDeviceID) -> (rms: Float, peak: Float, sampleCount: Int)? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var au: AudioUnit?
        guard AudioComponentInstanceNew(comp, &au) == noErr, let unit = au else { return nil }
        defer { AudioComponentInstanceDispose(unit) }

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout.size(ofValue: enable))) == noErr else { return nil }
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout.size(ofValue: disable))) == noErr else { return nil }

        var dev = deviceID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout.size(ofValue: dev))) == noErr else { return nil }

        var sr: Float64 = 48000
        var srSize = UInt32(MemoryLayout<Float64>.size)
        var srAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(deviceID, &srAddr, 0, nil, &srSize, &sr)

        var fmt = AudioStreamBasicDescription(
            mSampleRate: sr,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else { return nil }

        let ctx = TapContext()
        ctx.unit = unit
        let ctxRef = Unmanaged.passUnretained(ctx)

        let cb: AURenderCallback = { (refCon, flags, ts, bus, frames, _) in
            let ctx = Unmanaged<TapContext>.fromOpaque(refCon).takeUnretainedValue()
            guard let unit = ctx.unit else { return -1 }
            let bufSize = Int(frames) * 4
            let raw = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 4)
            defer { raw.deallocate() }
            var abl = AudioBufferList()
            abl.mNumberBuffers = 1
            abl.mBuffers = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bufSize), mData: raw)
            let r = AudioUnitRender(unit, flags, ts, bus, frames, &abl)
            if r != noErr { return r }
            let fp = raw.assumingMemoryBound(to: Float.self)
            ctx.lock.lock()
            for i in 0..<Int(frames) { ctx.samples.append(fp[i]) }
            ctx.lock.unlock()
            return noErr
        }
        var cbStruct = AURenderCallbackStruct(inputProc: cb, inputProcRefCon: ctxRef.toOpaque())
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cbStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr else { return nil }

        guard AudioUnitInitialize(unit) == noErr else { return nil }
        defer { AudioUnitUninitialize(unit) }
        guard AudioOutputUnitStart(unit) == noErr else { return nil }
        Thread.sleep(forTimeInterval: Self.sampleWindowSeconds)
        AudioOutputUnitStop(unit)

        ctx.lock.lock()
        let samples = ctx.samples
        ctx.lock.unlock()
        guard !samples.isEmpty else {
            overlayInfo("⚠️ measureLoopbackEnergy: 0 samples captured (sr=\(Int(sr)))")
            return nil
        }
        var sumSq: Double = 0
        var peak: Float = 0
        for s in samples {
            sumSq += Double(s * s)
            let a = abs(s)
            if a > peak { peak = a }
        }
        let rms = Float(sqrt(sumSq / Double(samples.count)))
        return (rms, peak, samples.count)
    }
}
