import AppKit
import AudioToolbox
import CoreAudio
import Foundation

class CoreAudioManager {
    // MARK: - Wispr Flow recording-state watcher
    //
    // Wispr Flow's helper process (com.electron.wispr-flow.helper) flips
    // kAudioProcessPropertyIsRunningInput from 0 to 1 the instant it starts
    // capturing the mic, and back to 0 when it stops — verified by probe.
    // We poll that flag and react to edges, which makes the pause/resume
    // behavior independent of how Wispr was triggered (Mouse 5, hotkey,
    // Wispr UI button, ESC cancellation, VAD timeout) and immune to the
    // toggle-drift bugs we hit when counting Mouse 5 clicks ourselves.

    private static let wisprBundlePrefix = "com.electron.wispr-flow"
    private static let pollInterval: TimeInterval = 0.5
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "ro.victorrentea.macos-addons.wispr-watch", qos: .userInteractive)
    private var lastWisprRecording = false
    private var wePaused = false

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        pollTimer = timer
        overlayInfo("🎤 Wispr-watch started (poll every \(Int(Self.pollInterval * 1000))ms)")
    }

    private func tick() {
        let recording = isWisprRecording()
        defer { lastWisprRecording = recording }
        guard recording != lastWisprRecording else { return }
        if recording {
            // 0 → 1: Wispr just started recording. Pause if music actually playing.
            if isMediaPlaying() {
                postPlayPauseKey()
                wePaused = true
                overlayInfo("🟢 Wispr started → ⏸ media paused")
            } else {
                overlayInfo("🟡 Wispr started → silence on loopback, nothing to pause")
            }
        } else {
            // 1 → 0: Wispr stopped. Resume only if we actually paused something.
            if wePaused {
                postPlayPauseKey()
                wePaused = false
                overlayInfo("🔴 Wispr stopped → ▶ media resumed")
            }
        }
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

    private static let monitoredOutputName = "🔊OS Output"
    private static let silenceRMSThreshold: Float = 0.0002
    private static let silencePeakThreshold: Float = 0.0005
    private static let sampleWindowSeconds: TimeInterval = 0.15

    private func isMediaPlaying() -> Bool {
        guard let devID = findAudioDevice(named: Self.monitoredOutputName) else {
            overlayInfo("🛑 RMS: device '\(Self.monitoredOutputName)' not found → assume playing")
            return true
        }
        guard let (rms, peak) = measureLoopbackEnergy(deviceID: devID) else {
            overlayInfo("🛑 RMS: tap failed on '\(Self.monitoredOutputName)' → assume playing")
            return true
        }
        let playing = rms > Self.silenceRMSThreshold || peak > Self.silencePeakThreshold
        overlayInfo(String(format: "📊 RMS=%.5f peak=%.5f → %@", rms, peak, playing ? "PLAYING" : "silent"))
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
        guard let (rms, peak) = measureLoopbackEnergy(deviceID: devID) else {
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

    private final class TapContext {
        var unit: AudioUnit?
        var samples: [Float] = []
        let lock = NSLock()
    }

    private func measureLoopbackEnergy(deviceID: AudioDeviceID) -> (rms: Float, peak: Float)? {
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
        guard !samples.isEmpty else { return nil }
        var sumSq: Double = 0
        var peak: Float = 0
        for s in samples {
            sumSq += Double(s * s)
            let a = abs(s)
            if a > peak { peak = a }
        }
        let rms = Float(sqrt(sumSq / Double(samples.count)))
        return (rms, peak)
    }

    // MARK: - Media key

    // NX_KEYTYPE_PLAY=16 — same signal the hardware Play/Pause key sends.
    // Works for YouTube in browsers, Spotify, Music, etc. — anything that
    // listens for the system media key. Replaces nowplaying-cli which is
    // broken on macOS 15+ because Apple locked down MediaRemote.framework.
    private func postPlayPauseKey() {
        let NX_KEYTYPE_PLAY: Int32 = 16
        for flagsDown in [0xA00, 0xB00] {
            let data1 = (Int(NX_KEYTYPE_PLAY) << 16) | flagsDown
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flagsDown)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
