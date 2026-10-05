import AppKit
import CoreImage
import Vision

/// ✂️ Cut the subject out of a picture — the ⌘⇧V bezel's `Paste w/o bg`.
///
/// **Apple's own subject lift, not a model of ours** (2026-10-05, Victor:
/// *"un tool de tipul remove.bg"*). `VNGenerateForegroundInstanceMaskRequest`
/// is the same on-device model behind Preview's "Remove Background" and the
/// long-press lift in Photos: no download, no Python, ~0.4 s on the M1 Max for
/// a 680×640 crop, measured. BiRefNet (`rembg`, the video skill's engine) cut
/// that same photo cleaner — Vision kept a curtain panel as a second subject
/// and left a thin white halo around the flowers — but it costs a cold start
/// of seconds to a minute and a Python venv inside a menu bar app. The quick
/// one goes on the button; the slow one stays a script for when it matters.
///
/// **Every instance Vision finds is kept**, and the canvas stays the size of
/// the original: what is pasted lines up with what was copied, transparent
/// where the background was.
enum BackgroundRemoval {

    /// PNG with alpha, or nil when Vision saw no subject at all (a screenshot
    /// of a text editor, a flat diagram) — the caller says so rather than
    /// pasting the original as if it had worked.
    static func cutOut(imageAt url: URL) -> Data? {
        // The package still targets an older macOS; this Mac is on 15.
        guard #available(macOS 14, *) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty else { return nil }
            let masked = try observation.generateMaskedImage(ofInstances: observation.allInstances,
                                                             from: handler,
                                                             croppedToInstancesExtent: false)
            return CIContext().pngRepresentation(of: CIImage(cvPixelBuffer: masked),
                                                 format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        } catch {
            overlayError("✂️ Vision failed: \(error.localizedDescription)")
            return nil
        }
    }
}
