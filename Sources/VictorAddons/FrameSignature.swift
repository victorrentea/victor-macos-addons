import CoreFoundation
import CoreVideo
import Dispatch
import IOSurface

/// A cheap fingerprint of a captured frame: one pixel in 64 (every 8th of every 8th
/// row), mixed into 64 bits. Two ScreenCaptureKit streams here receive frames whose
/// pixels did not change — 🔎 `ShareZoom` films the display its own window covers, and
/// every frame it shows damages that display again, so the stream answered with
/// another full-screen frame ~50×/s for a desktop that changed ~3×/s (measured
/// 2026-10-15; `dirtyRects` reported the whole screen each time, so they cannot tell
/// the echo from a real change).
enum FrameSignature {
    static func of(_ surface: IOSurface) -> UInt64 {
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return 0 }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        var hash: UInt64 = 0xcbf29ce484222325
        var row = 0
        while row < height {
            let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt32.self)
            var x = 0
            while x < width {
                hash = (hash ^ UInt64(line[x])) &* 0x100000001b3
                x += 8
            }
            row += 8
        }
        return hash
    }
}

/// Lets a frame through only if its `FrameSignature` changed — which breaks the
/// self-feeding loop — **plus one trailing delivery** 250 ms after each real change.
///
/// The grid misses what falls between its samples (a typed `.`, a 1 px underline, a
/// caret). Such a change arrives as a frame that looks identical and is skipped; on a
/// still screen nothing else may ever arrive, so the room would watch a stale picture.
/// The newest skipped frame is therefore kept (its pixel buffer retained, so the pool
/// cannot hand the surface out again) and shown once, 250 ms after the last real
/// change, unless a newer change got there first. That delivery's own echo is
/// identical and does **not** re-arm it: armed at most once per real change, so the
/// loop stays broken.
///
/// All calls on `queue`, the stream's sample-handler queue.
final class EchoGate {
    static let trailingDelay: CFTimeInterval = 0.25

    private let queue: DispatchQueue
    private let deliver: (IOSurface) -> Void
    private var last: UInt64?
    /// Bumped on every real change; the trailing delivery is armed once per value.
    private var change = 0
    private var armedFor = -1
    private var held: (buffer: CVPixelBuffer, surface: IOSurface)?
    private(set) var shown = 0
    private(set) var skipped = 0
    private(set) var trailing = 0

    init(queue: DispatchQueue, deliver: @escaping (IOSurface) -> Void) {
        self.queue = queue
        self.deliver = deliver
    }

    func offer(_ buffer: CVPixelBuffer, _ surface: IOSurface) {
        let signature = FrameSignature.of(surface)
        if signature != last {
            last = signature
            change += 1
            held = nil
            shown += 1
            deliver(surface)
            return
        }
        skipped += 1
        held = (buffer, surface)
        guard armedFor != change else { return }
        armedFor = change
        let armed = change
        queue.asyncAfter(deadline: .now() + Self.trailingDelay) { [weak self] in
            guard let self, self.change == armed, let held = self.held else { return }
            self.held = nil
            self.trailing += 1
            self.deliver(held.surface)
        }
    }

    func reset() {
        last = nil
        change += 1
        held = nil
        shown = 0; skipped = 0; trailing = 0
    }

    var json: String { "{\"shown\":\(shown),\"skipped\":\(skipped),\"trailing\":\(trailing)}" }
}
