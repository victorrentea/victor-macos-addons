import AVFoundation
import XCTest
@testable import VictorAddons

/// 🎙️ The voice meter's math against `ffmpeg -af ebur128=dualmono=true`, and
/// the gate, the percentiles, the peak-hold, the reference policy.
final class VoiceLoudnessTests: XCTestCase {
    private func resource(_ name: String, _ ext: String, _ dir: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources/\(dir)"))
    }

    private func monoSamples(_ url: URL) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buf)
        let ch = try XCTUnwrap(buf.floatChannelData)
        return (Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength))), file.processingFormat.sampleRate)
    }

    /// Speech that jumps from ~−31 to ~−6 LUFS (`speech-dyn-10s.wav`, macOS TTS
    /// at levels set by the Krisp probe of 2026-11-09), measured every 100 ms
    /// and compared with ffmpeg's `M` at the same instants: within 0.5 LU.
    func testMomentaryMatchesFfmpegWithinHalfALU() throws {
        let (samples, rate) = try monoSamples(try resource("speech-dyn-10s", "wav", "voice"))
        XCTAssertEqual(rate, 48000)
        let reference = try String(contentsOf: try resource("speech-dyn-10s.ebur128-M", "txt", "voice"), encoding: .utf8)
            .split(separator: "\n").compactMap { line -> (Double, Double)? in
                let p = line.split(separator: " ")
                guard p.count == 2, let t = Double(p[0]), let m = Double(p[1]) else { return nil }
                return (t, m)
            }
        XCTAssertGreaterThan(reference.count, 90)
        var meter = MomentaryMeter(sampleRate: rate, channels: 1)
        let hop = Int(rate * 0.1)
        var compared = 0, worst = 0.0
        for (i, (t, m)) in reference.enumerated() {
            let start = i * hop, end = min(samples.count, start + hop)
            guard start < end else { break }
            meter.feed(mono: Array(samples[start..<end]))
            XCTAssertEqual(abs(Double(end) / rate - t), 0, accuracy: 0.001)
            guard t >= 0.4, m > -70, let ours = meter.momentary else { continue }
            worst = max(worst, abs(ours - m))
            XCTAssertEqual(ours, m, accuracy: 0.5, "t=\(t)")
            compared += 1
        }
        XCTAssertGreaterThan(compared, 80)
        print("🎙️ momentary vs ffmpeg: \(compared) points, worst \(String(format: "%.3f", worst)) LU")
    }

    /// BS.1770's own check: a 997 Hz sine at 0 dBFS on one channel is −3.01
    /// LUFS — so as dual-mono (both speakers) it is 0.0.
    func testFullScaleSineIsZeroLufsAsDualMono() {
        let rate = 48000.0
        let s = (0..<Int(rate)).map { Float(sin(2 * Double.pi * 997 * Double($0) / rate)) }
        var mono = MomentaryMeter(sampleRate: rate, channels: 1)
        mono.feed(mono: s)
        XCTAssertEqual(mono.momentary ?? -99, 0.0, accuracy: 0.05)
        // A stereo device with the same signal on both channels reads the same.
        var stereo = MomentaryMeter(sampleRate: rate, channels: 2)
        let inter = s.flatMap { [$0, $0] }
        inter.withUnsafeBufferPointer { p in
            stereo.feed(p.baseAddress!, stride0: 2, p.baseAddress! + 1, stride1: 2, frames: s.count)
        }
        XCTAssertEqual(stereo.momentary ?? -99, 0.0, accuracy: 0.05)
        // −20 dBFS reads −20 LUFS, and 44.1 kHz gets its own filter.
        var quiet = MomentaryMeter(sampleRate: 44100, channels: 1)
        quiet.feed(mono: (0..<44100).map { Float(0.1 * sin(2 * Double.pi * 997 * Double($0) / 44100)) })
        XCTAssertEqual(quiet.momentary ?? -99, -20.0, accuracy: 0.1)
    }

    func testNothingBeforeFourHundredMillisecondsAndSilenceIsFloor() {
        var m = MomentaryMeter(sampleRate: 48000, channels: 1)
        m.feed(mono: [Float](repeating: 0, count: 48000 * 3 / 10))
        XCTAssertNil(m.momentary)
        m.feed(mono: [Float](repeating: 0, count: 48000 / 10))
        XCTAssertEqual(m.momentary, -120)
    }
}

final class VoiceStatsTests: XCTestCase {
    /// 4 Hz, like the meter's loop.
    private func feed(_ s: inout VoiceStats, _ values: [Double], from t0: Double) -> Double {
        var t = t0
        for v in values { s.add(v, at: t); t += 0.25 }
        return t
    }

    func testGateSeparatesSpeechFromRoomNoiseAndPauses() {
        var s = VoiceStats()
        var t = feed(&s, Array(repeating: -62, count: 40), from: 0)       // 10 s of room noise
        XCTAssertFalse(s.speaking)
        XCTAssertNil(s.normal)
        XCTAssertEqual(s.gate, -55, accuracy: 0.01)                         // flat room: nothing is speech
        XCTAssertFalse(s.speaking)
        t = feed(&s, [-30, -28, -31, -29, -27, -30, -32, -29, -30, -28], from: t)
        XCTAssertTrue(s.speaking)
        t = feed(&s, [-61, -63], from: t)                                   // a pause
        XCTAssertFalse(s.speaking)
        XCTAssertEqual(s.normal ?? 0, -29.5, accuracy: 0.6)
        _ = t
    }

    /// The gate follows the room's noise, never climbs into the voice, and a
    /// window with no pauses is all voice or all room depending on its level.
    func testGateFollowsNoiseButNotIntoTheVoice() {
        // pauses at −45 (a noisy room), voice at −30: gate −40 (10 under the voice)
        XCTAssertEqual(VoiceStats.gate(window: Array(repeating: -45, count: 50) + Array(repeating: -30, count: 50)), -40, accuracy: 0.01)
        // a very quiet room (−90) and a voice at −28: the absolute −55
        XCTAssertEqual(VoiceStats.gate(window: Array(repeating: -90, count: 50) + Array(repeating: -28, count: 50)), -55, accuracy: 0.01)
        // noise close under the voice (−34 vs −28): the gate stays ≥ 10 dB under the voice
        XCTAssertEqual(VoiceStats.gate(window: Array(repeating: -40, count: 50) + Array(repeating: -28, count: 50)), -38, accuracy: 0.01)
        // two minutes of steady room noise at −48: none of it is speech
        var room = VoiceStats()
        _ = feed(&room, Array(repeating: -48, count: 480), from: 0)
        XCTAssertFalse(room.speaking)
        XCTAssertNil(room.normal)
        // two minutes of talking with no pause at all: still speech
        var s = VoiceStats()
        _ = feed(&s, (0..<480).map { -26 + Double($0 % 5) - 2 }, from: 0)
        XCTAssertTrue(s.speaking)
        XCTAssertEqual(s.normal ?? 0, -26, accuracy: 1.1)
    }

    /// "top" is the 95th percentile: one cough at −5 does not move it.
    func testTopIgnoresOneCough() {
        var s = VoiceStats()
        var values = (0..<200).map { -30 + Double($0 % 9) }               // −30 … −22
        values[100] = -5
        _ = feed(&s, values, from: 0)
        XCTAssertEqual(s.top ?? 0, -22, accuracy: 0.6)
        XCTAssertEqual(s.normal ?? 0, -26, accuracy: 0.6)
    }

    func testSpeechOlderThanTenMinutesIsForgotten() {
        var s = VoiceStats()
        var t = feed(&s, Array(repeating: -20, count: 40), from: 0)
        t = feed(&s, Array(repeating: -35, count: 40), from: 700)          // 11+ min later
        XCTAssertEqual(s.normal ?? 0, -35, accuracy: 0.01)
        _ = t
    }

    func testPeakHoldsTwoSecondsThenFalls() {
        var s = VoiceStats()
        var t = feed(&s, [-30, -30, -10], from: 0)                          // peak −10 at 0.5 s
        t = feed(&s, Array(repeating: -30, count: 8), from: t)              // until 2.5 s: held
        XCTAssertEqual(s.peak ?? 0, -10, accuracy: 0.01)
        t = feed(&s, Array(repeating: -30, count: 4), from: t)              // 1 s past the hold
        XCTAssertLessThan(s.peak ?? 0, -10)
        XCTAssertGreaterThan(s.peak ?? 0, -30)
        t = feed(&s, Array(repeating: -30, count: 20), from: t)
        XCTAssertEqual(s.peak ?? 0, -30, accuracy: 0.01)                    // fell to the signal
        _ = t
    }

    func testLiveRefIsTheMedianOfTheLastThirtySecondsOfSpeech() {
        var s = VoiceStats()
        var t = feed(&s, Array(repeating: -20, count: 200), from: 0)        // 50 s at −20
        t = feed(&s, Array(repeating: -28, count: 100), from: t)            // then 25 s at −28
        XCTAssertEqual(s.liveRef(now: t) ?? 0, -28, accuracy: 0.01)         // 30 s: 25 of them −28
        XCTAssertNil(VoiceStats().liveRef(now: 0))
        var short = VoiceStats()
        let end = feed(&short, Array(repeating: -25, count: 5), from: 0)    // 1.25 s: not enough
        XCTAssertNil(short.liveRef(now: end))
    }

    func testPercentileInterpolates() {
        XCTAssertEqual(VoiceStats.percentile([1, 2, 3, 4], 50), 2.5)
        XCTAssertEqual(VoiceStats.percentile([5], 95), 5)
        XCTAssertNil(VoiceStats.percentile([], 50))
    }

    func testRefPolicy() {
        let now = Date()
        XCTAssertEqual(VoiceRefPolicy.resolve(live: -25, heldThisShare: -30, previous: nil, now: now).source, .live)
        XCTAssertEqual(VoiceRefPolicy.resolve(live: nil, heldThisShare: -30, previous: (-20, now), now: now).value, -30)
        let prev = VoiceRefPolicy.resolve(live: nil, heldThisShare: nil, previous: (-27, now.addingTimeInterval(-3600)), now: now)
        XCTAssertEqual(prev.value, -27)
        XCTAssertEqual(prev.source, .previous)
        let old = VoiceRefPolicy.resolve(live: nil, heldThisShare: nil, previous: (-27, now.addingTimeInterval(-3 * 3600)), now: now)
        XCTAssertEqual(old.value, -23)
        XCTAssertEqual(old.source, .defaultValue)
    }
}

final class VoiceDevicePickTests: XCTestCase {
    typealias C = VoiceDevicePick.Capture

    func testKrispWinsWhenTheMeetingCapturesIt() {
        let pick = VoiceDevicePick.choose(captures: [C(bundleID: "us.zoom.xos", inputs: ["ZoomAudioDevice", "krisp microphone"])],
                                          defaultInput: "Elgato Wave XLR", override: nil)
        XCTAssertEqual(pick?.name, "krisp microphone")
    }

    /// Whisper and Krisp hold the Elgato open; only the meeting's own capture counts.
    func testTheMeetingsOwnDeviceNotWhateverIsOpen() {
        let captures = [C(bundleID: "", inputs: ["Elgato Wave XLR"]),
                        C(bundleID: "com.microsoft.teams2", inputs: ["MacBook Pro Microphone"])]
        XCTAssertEqual(VoiceDevicePick.choose(captures: captures, defaultInput: "Elgato Wave XLR", override: nil)?.name,
                       "MacBook Pro Microphone")
    }

    func testShareLoopbacksAreNeverTheVoice() {
        let pick = VoiceDevicePick.choose(captures: [C(bundleID: "us.zoom.xos", inputs: ["ZoomAudioDevice"])],
                                          defaultInput: "Elgato Wave XLR", override: nil)
        XCTAssertEqual(pick?.name, "Elgato Wave XLR")
        XCTAssertNil(VoiceDevicePick.choose(captures: [], defaultInput: "ZoomAudioDevice", override: nil))
    }

    func testOverrideAndDefault() {
        XCTAssertEqual(VoiceDevicePick.choose(captures: [C(bundleID: "us.zoom.xos", inputs: ["krisp microphone"])],
                                              defaultInput: nil, override: "From Walkie")?.name, "From Walkie")
        XCTAssertEqual(VoiceDevicePick.choose(captures: [], defaultInput: "MacBook Pro Microphone", override: "")?.name,
                       "MacBook Pro Microphone")
    }
}

final class ShareDetectionTests: XCTestCase {
    struct Fixture: Decodable {
        struct W: Decodable { let name: String; let bounds: [Double]; let onScreen: Bool }
        struct Case: Decodable { let label: String; let sharing: Bool; let otherOwner: Bool?; let windows: [W] }
        let displays: [[Double]]
        let teamsPID: Int32
        let cases: [Case]
    }

    private func rect(_ a: [Double]) -> CGRect { CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }

    /// Fixtures reconstructed from Teams' own logs of the 26–28 Oct shares.
    func testTeamsSharingControlBarFixtures() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "teams-windows", withExtension: "json",
                                                  subdirectory: "Resources/share"))
        let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let displays = fx.displays.map(rect)
        for c in fx.cases {
            let owner = c.otherOwner == true ? fx.teamsPID + 1 : fx.teamsPID
            let windows = c.windows.map { ShareWindowInfo(ownerPID: owner, name: $0.name, bounds: rect($0.bounds), onScreen: $0.onScreen) }
            XCTAssertEqual(TeamsShareWindows.isSharing(windows: windows, teamsPIDs: [fx.teamsPID], displays: displays),
                           c.sharing, c.label)
        }
    }

    func testTeamsBarByTitle() {
        let w = ShareWindowInfo(ownerPID: 1, name: "Sharing control bar | Microsoft Teams",
                                bounds: CGRect(x: 10, y: 400, width: 100, height: 20), onScreen: true)
        XCTAssertTrue(TeamsShareWindows.isSharing(windows: [w], teamsPIDs: [1], displays: []))
    }

    /// The Zoom half: names read off a live share on 2026-10-01 (Zoom 6.6).
    func testZoomShareWindows() {
        XCTAssertTrue(ZoomShareWindows.isSharing(windowNames: ["Zoom Meeting", "zoom share statusbar window"]))
        XCTAssertFalse(ZoomShareWindows.isSharing(windowNames: ["Zoom Meeting", "Zoom Workplace"]))
    }

    func testDebounceIgnoresAFlicker() {
        var d = ShareDebouncer()
        XCTAssertFalse(d.feed(true, at: 0))
        XCTAssertFalse(d.feed(false, at: 1))           // a one-second blip
        XCTAssertFalse(d.feed(true, at: 2))
        XCTAssertFalse(d.feed(true, at: 3))
        XCTAssertTrue(d.feed(true, at: 4))             // 2 s of yes
        XCTAssertTrue(d.feed(false, at: 5))
        XCTAssertTrue(d.feed(false, at: 9))            // 4 s of no: still on
        XCTAssertTrue(d.feed(true, at: 10))            // the bar came back
        XCTAssertTrue(d.feed(false, at: 11))
        XCTAssertFalse(d.feed(false, at: 17))          // 6 s of no
    }

    func testTheRelayNeverCarriesTheVoiceMeter() {
        XCTAssertTrue(HttpAccessPolicy.tabletMayCall("/voice/level"))
        XCTAssertFalse(HttpAccessPolicy.relayMayCall("/voice/level"))
        XCTAssertFalse(HttpAccessPolicy.relayMayCall("/voice/level?x=1"))
        XCTAssertTrue(HttpAccessPolicy.relayMayCall("/ping"))
        XCTAssertFalse(HttpAccessPolicy.tabletMayCall("/test/sharing/force/on"))
    }

    func testVideoCeilingAnswer() throws {
        let r = try XCTUnwrap(VideoCeiling.parse(Data("{\"volume\":0.316,\"maxVolume\":0.316,\"takenDb\":6.0}".utf8)))
        XCTAssertEqual(r.volume, 0.316, accuracy: 0.001)
        XCTAssertEqual(r.takenDb, 6.0)
        XCTAssertNil(VideoCeiling.parse(Data("nope".utf8)))
    }
}
