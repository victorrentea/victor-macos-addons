import Foundation

/// 🎙️📏 Victor's voice, measured the way the effects are: EBU R128 /
/// ITU-R BS.1770 loudness (K-weighting, LUFS), so "an effect is no louder than
/// the voice" compares two numbers in the same unit (victor-effects measures
/// every clip's loudest 3 s with the same filter, `Loudness.swift` there).
///
/// Pure, no CoreAudio: `VoiceMeter` feeds it from the device's IO thread and
/// `VoiceLoudnessTests` feeds it a WAV and compares with `ffmpeg -af ebur128`.
///
/// **Channels count like the effects count them: as heard on two speakers.**
/// A mono mic is measured as dual-mono (ffmpeg's `dualmono=true`, +3 dB over
/// plain mono), a stereo device as the sum of its first two channels — the
/// effects side counts a mono clip the same way, so neither number is 3 dB off
/// the other for being mono.

/// The BS.1770 K-weighting pre-filter (high shelf + RLB high-pass), streaming,
/// for any sample rate — libebur128's derivation from the analog prototypes,
/// which is ffmpeg's too.
struct KWeightingFilter {
    private let b: [Double]   // shelf b0 b1 b2, high-pass b0 b1 b2
    private let a: [Double]   // shelf a1 a2, high-pass a1 a2
    private var s1 = 0.0, s2 = 0.0, h1 = 0.0, h2 = 0.0

    init(sampleRate fs: Double) {
        var f0 = 1681.974450955533
        let G = 3.999843853973347
        var Q = 0.7071752369554196
        var K = tan(Double.pi * f0 / fs)
        let Vh = pow(10, G / 20)
        let Vb = pow(Vh, 0.4996667741545416)
        var a0 = 1 + K / Q + K * K
        let shelfB = [(Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0]
        let shelfA = [2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
        f0 = 38.13547087602444
        Q = 0.5003270373238773
        K = tan(Double.pi * f0 / fs)
        a0 = 1 + K / Q + K * K
        let hpA = [2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
        b = shelfB + [1, -2, 1]
        a = shelfA + hpA
    }

    /// One sample through both sections (transposed direct form II).
    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y1 = b[0] * x + s1
        s1 = b[1] * x - a[0] * y1 + s2
        s2 = b[2] * x - a[1] * y1
        let y2 = b[3] * y1 + h1
        h1 = b[4] * y1 - a[2] * y2 + h2
        h2 = b[5] * y1 - a[3] * y2
        return y2
    }
}

/// Momentary loudness (400 ms window) over a stream: K-weighted energy is
/// summed in 50 ms blocks, and the window is the last eight. `feed` is meant
/// for an audio IO thread (no allocation after `init`); `momentary` may be
/// read from another thread through `VoiceMeter`'s lock.
struct MomentaryMeter {
    static let blockSeconds = 0.05
    static let blocksPerWindow = 8          // 400 ms

    let sampleRate: Double
    /// 1 = a mono device (counted twice, dual-mono); 2 = stereo (summed).
    let channels: Int
    private var filters: [KWeightingFilter]
    private let blockLength: Int
    private var blockEnergy = 0.0
    private var blockFill = 0
    private var ring = [Double](repeating: 0, count: MomentaryMeter.blocksPerWindow)
    private var ringIndex = 0
    private(set) var blocksSeen = 0

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = max(1, min(2, channels))
        filters = (0..<max(1, min(2, channels))).map { _ in KWeightingFilter(sampleRate: sampleRate) }
        blockLength = max(1, Int((sampleRate * Self.blockSeconds).rounded()))
    }

    /// `frames` samples of channel 0 (and channel 1, if stereo), each read
    /// with its own stride — one call covers interleaved and planar buffers.
    mutating func feed(_ ch0: UnsafePointer<Float>, stride0: Int,
                       _ ch1: UnsafePointer<Float>?, stride1: Int, frames: Int) {
        let stereo = channels == 2 && ch1 != nil
        for i in 0..<frames {
            let y0 = filters[0].process(Double(ch0[i * stride0]))
            var e = y0 * y0
            if stereo, let ch1 {
                let y1 = filters[1].process(Double(ch1[i * stride1]))
                e += y1 * y1
            } else {
                e *= 2            // dual-mono
            }
            blockEnergy += e
            blockFill += 1
            if blockFill == blockLength { closeBlock() }
        }
    }

    /// Convenience for tests: a mono run of samples.
    mutating func feed(mono samples: [Float]) {
        samples.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            feed(base, stride0: 1, nil, stride1: 0, frames: p.count)
        }
    }

    private mutating func closeBlock() {
        ring[ringIndex] = blockEnergy / Double(blockLength)
        ringIndex = (ringIndex + 1) % Self.blocksPerWindow
        blocksSeen += 1
        blockEnergy = 0
        blockFill = 0
    }

    /// LUFS over the last 400 ms; nil before 400 ms of audio has been seen.
    /// −∞ for digital silence is reported as −120.
    var momentary: Double? {
        guard blocksSeen >= Self.blocksPerWindow else { return nil }
        let mean = ring.reduce(0, +) / Double(Self.blocksPerWindow)
        return Self.lufs(meanSquare: mean)
    }

    static func lufs(meanSquare: Double) -> Double {
        guard meanSquare > 0 else { return -120 }
        return max(-120, -0.691 + 10 * log10(meanSquare))
    }
}

/// What the room hears of Victor, as numbers: fed one momentary loudness every
/// 250 ms, it keeps the speech gate, his normal and top level, the peak-hold
/// and the reference the effects' ceiling is pinned to. Pure; time is passed in.
struct VoiceStats {
    /// Below this nothing counts as speech, whatever the room's noise.
    static let absoluteGate = -55.0
    /// Speech must stand this far above the noise floor (10th percentile)…
    static let noiseMargin = 8.0
    /// …and the gate never sits closer than this under the loud end of the
    /// window (90th percentile), so it cannot climb into the voice itself.
    static let loudMargin = 10.0
    /// A window whose 10th and 90th percentiles are closer than this has no
    /// pauses in it: it is all voice (above −40 LUFS) or all room (below).
    static let flatSpread = 10.0
    static let flatVoiceAbove = -40.0
    static let flatVoiceMargin = 12.0
    static let noiseWindow: TimeInterval = 120
    static let speechWindow: TimeInterval = 600     // "normal" and "top": ~10 min
    static let refWindow: TimeInterval = 30         // the ceiling's voiceRef
    static let minSpeechSamples = 8                 // 2 s of speech at 4 Hz
    static let peakHold: TimeInterval = 2
    static let peakFallDbPerSecond = 10.0

    private(set) var all: [(t: TimeInterval, m: Double)] = []
    private(set) var speech: [(t: TimeInterval, m: Double)] = []
    private(set) var momentary: Double?
    private(set) var speaking = false
    private(set) var gate = absoluteGate
    private(set) var peak: Double?
    private var peakAt: TimeInterval = 0
    private var lastAt: TimeInterval?

    mutating func add(_ m: Double, at t: TimeInterval) {
        let dt = lastAt.map { max(0, t - $0) } ?? 0
        lastAt = t
        momentary = m
        all.append((t, m))
        all.removeAll { t - $0.t > Self.noiseWindow }
        gate = Self.gate(window: all.map(\.m))
        speaking = m >= gate
        if speaking {
            speech.append((t, m))
        }
        speech.removeAll { t - $0.t > Self.speechWindow }

        if let p = peak, m < p {
            if t - peakAt > Self.peakHold { peak = max(m, p - Self.peakFallDbPerSecond * dt) }
        } else {
            peak = m
            peakAt = t
        }
    }

    /// The speech gate over the last 2 min of momentary values:
    /// - with pauses in it (p90 − p10 ≥ 10 dB): max(−55, min(p10 + 8, p90 − 10));
    /// - without (two minutes of talking with no gap, or of room noise alone):
    ///   above −40 LUFS it is all voice → max(−55, median − 12); below, it is
    ///   all room → nothing in it counts.
    static func gate(window: [Double]) -> Double {
        guard let p10 = percentile(window, 10), let p90 = percentile(window, 90),
              let p50 = percentile(window, 50) else { return absoluteGate }
        if p90 - p10 >= flatSpread {
            return max(absoluteGate, min(p10 + noiseMargin, p90 - loudMargin))
        }
        if p50 >= flatVoiceAbove { return max(absoluteGate, p50 - flatVoiceMargin) }
        return max(absoluteGate, p90 + 1)
    }

    /// Median speech level over ~10 min; nil under 2 s of speech.
    var normal: Double? {
        speech.count >= Self.minSpeechSamples ? Self.percentile(speech.map(\.m), 50) : nil
    }

    /// The robust recent maximum: 95th percentile of speech over ~10 min, so
    /// one cough does not squash the scale.
    var top: Double? {
        speech.count >= Self.minSpeechSamples ? Self.percentile(speech.map(\.m), 95) : nil
    }

    /// Median speech level over the last 30 s, at `now`; nil under 2 s of it.
    func liveRef(now: TimeInterval) -> Double? {
        let recent = speech.filter { now - $0.t <= Self.refWindow }.map(\.m)
        return recent.count >= Self.minSpeechSamples ? Self.percentile(recent, 50) : nil
    }

    /// Linear interpolation between closest ranks; nil for an empty list.
    static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let rank = max(0, min(1, p / 100)) * Double(s.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
    }
}

/// The level the effects are held under: Victor's voice over the last ~30 s.
///
/// **Before any speech has been measured in this share**, the last reference
/// from the past 2 h is used — the same mic, the same gain, most likely the
/// same room — and failing that a conservative −23 LUFS (EBU R128's programme
/// target: a voice that is not quiet; a quiet one is then *under* the cap,
/// which only means the first effects of a new day play a little louder than
/// they should until Victor has spoken for two seconds). Once he has spoken
/// in this share, a pause keeps the last measured value: silence is not a
/// quieter voice.
enum VoiceRefPolicy {
    static let defaultRef = -23.0
    static let previousMaxAge: TimeInterval = 2 * 3600

    enum Source: String { case live, held, previous, defaultValue = "default" }

    static func resolve(live: Double?, heldThisShare: Double?,
                        previous: (value: Double, at: Date)?, now: Date) -> (value: Double, source: Source) {
        if let live { return (live, .live) }
        if let heldThisShare { return (heldThisShare, .held) }
        if let previous, now.timeIntervalSince(previous.at) <= previousMaxAge, now >= previous.at {
            return (previous.value, .previous)
        }
        return (defaultRef, .defaultValue)
    }
}
