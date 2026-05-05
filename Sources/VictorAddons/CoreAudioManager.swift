import AppKit
import AudioToolbox
import CoreAudio
import Foundation

class CoreAudioManager {
    private var isDictationActive = false
    private var dictationStartedAt: Date?
    // Dictation rarely lasts more than ~5 min; after 10 min assume the
    // pause-for-dictation flag is stale (e.g. media stopped on its own,
    // user closed the player) and clear it so the next Mouse 5 click
    // doesn't blindly resume audio that no longer exists.
    private let dictationStaleAfter: TimeInterval = 10 * 60

    // Toggle media pause/resume: call from EventTapManager.onDictationMute callback.
    // The dictation flag is the source of truth on resume — we paused it, we resume it,
    // regardless of current detected energy (the loopback is silent *because* we paused).
    func toggleDictationMute() {
        expireStaleDictation()
        if isDictationActive {
            resumeMedia()
        } else {
            pauseMedia()
        }
    }

    // Called on global ESC: if we paused media for dictation, Wispr was cancelled → resume.
    func resumeIfDictationActive() {
        expireStaleDictation()
        guard isDictationActive else { return }
        resumeMedia()
    }

    private func expireStaleDictation() {
        guard isDictationActive, let started = dictationStartedAt,
              Date().timeIntervalSince(started) > dictationStaleAfter else { return }
        isDictationActive = false
        dictationStartedAt = nil
        overlayInfo("🟡 Dictation flag expired (>10 min) — cleared")
    }

    private func pauseMedia() {
        guard isMediaPlaying() else {
            overlayInfo("🟡 Dictation: no media playing, skipping mute")
            return
        }
        postPlayPauseKey()
        isDictationActive = true
        dictationStartedAt = Date()
        overlayInfo("🟢 Dictation: ⏸ media paused")
    }

    // The "🔊OS Output" loopback (Rogue Amoeba) carries everything macOS plays.
    // Device-level "running" flags are unreliable here because Audio Hijack always
    // holds the loopback open as a listener, and silent-but-open streams keep the
    // flag latched. Instead, briefly tap the loopback's input scope and measure the
    // actual sample energy — ground truth for "is anything audible right now".
    private static let monitoredOutputName = "🔊OS Output"
    private static let silenceRMSThreshold: Float = 0.0005
    private static let silencePeakThreshold: Float = 0.001
    private static let sampleWindowSeconds: TimeInterval = 0.15

    private func isMediaPlaying() -> Bool {
        guard let devID = findAudioDevice(named: Self.monitoredOutputName) else {
            return true  // conservative: device missing → assume playing
        }
        guard let (rms, peak) = measureLoopbackEnergy(deviceID: devID) else {
            return true  // conservative on any tap failure
        }
        return rms > Self.silenceRMSThreshold || peak > Self.silencePeakThreshold
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

    private func resumeMedia() {
        postPlayPauseKey()
        isDictationActive = false
        dictationStartedAt = nil
        overlayInfo("🔴 Dictation: ▶ media resumed")
    }

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
