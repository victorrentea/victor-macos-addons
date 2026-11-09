import AVFoundation
import XCTest
@testable import VictorAddons

/// ＋ A video made louder on disk: the louder audio is laid over the original
/// on the same timeline — louder inside the played window, untouched outside
/// it, and not shifted by a single sample's worth that anyone could hear.
final class VideoBoostAudioTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vboost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private let rate = 44100.0

    /// A stereo WAV whose sample i is `f(i)`.
    private func wav(_ name: String, seconds: Double, _ f: (Int) -> Float) throws -> URL {
        let url = root.appendingPathComponent(name)
        let n = Int(seconds * rate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for c in 0..<2 { for i in 0..<n { buf.floatChannelData![c][i] = f(i) } }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buf)
        return url
    }

    /// The composition's audio, its left channel.
    private func samples(_ asset: AVAsset) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: asset.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        ])
        reader.add(out)
        reader.startReading()
        var all: [Float] = []
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb)
            var chunk = [Float](repeating: 0, count: len / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            all += chunk
        }
        return stride(from: 0, to: all.count, by: 2).map { all[$0] }
    }

    private func rms(_ s: ArraySlice<Float>) -> Double {
        sqrt(s.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, s.count)))
    }

    func testTheRenderReplacesTheWindowOnlyAtItsOwnLevelAndInPlace() throws {
        // Original: a 440 Hz sine at 0.1 for 6 s. Render: the window 2…5 s,
        // the same sine (same phase) at 0.2, i.e. +6 dB.
        let tone: (Int, Float) -> Float = { i, a in a * Float(sin(2 * Double.pi * 440 * Double(i) / 44100)) }
        let original = try wav("o.wav", seconds: 6) { tone($0, 0.1) }
        let start = 2 * Int(rate)
        let render = try wav("r.wav", seconds: 3) { tone($0 + start, 0.2) }
        let comp = try VideoBoostAudio.composition(original: original, render: render, at: 2)
        XCTAssertEqual(CMTimeGetSeconds(comp.duration), 6, accuracy: 0.01)
        let s = try samples(comp)
        let r = Int(rate)
        let before = rms(s[(r / 2)..<(3 * r / 2)]), inside = rms(s[(5 * r / 2)..<(9 * r / 2)]), after = rms(s[(21 * r / 4)..<(23 * r / 4)])
        XCTAssertEqual(20 * log10(inside / before), 6.02, accuracy: 0.1, "the window plays the louder render")
        XCTAssertEqual(after, before, accuracy: 0.001, "after the window the original is back")
        // In phase with where the original would be: the boosted half is exactly 2× the original sample.
        for i in stride(from: start + 1000, to: start + 1100, by: 7) {
            XCTAssertEqual(s[i], 2 * tone(i, 0.1), accuracy: 0.002, "sample \(i)")
        }
    }

    func testTheEffectsAnswerIsParsed() {
        XCTAssertEqual(VideoBoostAudio.parse(Data(#"{"key":"video:x","db":3,"audio":{"path":"/a/b.wav","start":145}}"#.utf8)),
                       .init(path: "/a/b.wav", start: 145))
        XCTAssertNil(VideoBoostAudio.parse(Data(#"{"key":"video:x","db":0,"audio":null}"#.utf8)))
        XCTAssertNil(VideoBoostAudio.parse(Data("garbage".utf8)))
    }
}
