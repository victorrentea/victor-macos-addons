import AppKit
import QuartzCore

/// 🔍/🔎 What the `ZoomEngine` flip looks like, at the cursor (Victor, 2026-10-26):
/// *"explozia subtilă a lupei la trecerea la macOS zoom nativ, respectiv dissolve in
/// la trecerea la zoom sintetic"*.
///
/// - → `system`: the magnifier is there for a beat, then breaks into a grid of shards
///   that drift a little outward, turn and fade — subtle, half a second.
/// - → `share`: the magnifier **dissolves in** the PowerPoint way — its cells appear one
///   by one in random order — holds, and fades.
///
/// One borderless panel above everything (ShareZoom included), click-through, made
/// per play and ordered out when the animation is over. Main thread only.
final class ZoomSwitchEffect {
    private var panel: NSPanel?
    private var cleanup: DispatchWorkItem?

    private static let side: CGFloat = 144
    private static let canvas: CGFloat = 400

    func play(_ engine: ZoomEngine, at point: CGPoint) {
        stop()
        let canvas = Self.canvas
        let screen = NSScreen.physical.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        guard let image = Self.lensImage(side: Self.side, scale: scale) else { return }

        let panel = NSPanel(contentRect: NSRect(x: point.x - canvas / 2, y: point.y - canvas / 2,
                                                width: canvas, height: canvas),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: canvas, height: canvas))
        view.wantsLayer = true
        panel.contentView = view
        guard let root = view.layer else { return }
        root.contentsScale = scale

        let duration: TimeInterval
        switch engine {
        case .system: duration = explode(image, in: root, scale: scale)
        case .share: duration = dissolveIn(image, in: root, scale: scale)
        }
        self.panel = panel
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in self?.stop() }
        cleanup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func stop() {
        cleanup?.cancel()
        cleanup = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - The two animations

    /// The lens's cells, each a layer showing its own slice of the image.
    private func tiles(_ image: CGImage, grid n: Int, in root: CALayer, scale: CGFloat) -> [CALayer] {
        let side = Self.side, cell = side / CGFloat(n)
        let origin = (Self.canvas - side) / 2
        var out: [CALayer] = []
        for row in 0..<n {
            for col in 0..<n {
                let tile = CALayer()
                tile.contents = image
                tile.contentsScale = scale
                tile.contentsGravity = .resize
                // Unit rect of the slice. A layer's y grows up and so does the
                // image's unit space here, so row 0 is the bottom row in both.
                tile.contentsRect = CGRect(x: CGFloat(col) / CGFloat(n), y: CGFloat(row) / CGFloat(n),
                                           width: 1 / CGFloat(n), height: 1 / CGFloat(n))
                tile.frame = CGRect(x: origin + CGFloat(col) * cell, y: origin + CGFloat(row) * cell,
                                    width: cell, height: cell)
                root.addSublayer(tile)
                out.append(tile)
            }
        }
        return out
    }

    /// Whole for 0.18 s, then 6×6 shards fly 25–45 pt outward, turn up to ±50° and
    /// fade over 0.5 s.
    private func explode(_ image: CGImage, in root: CALayer, scale: CGFloat) -> TimeInterval {
        let hold: CFTimeInterval = 0.18, fly: CFTimeInterval = 0.5
        let center = CGPoint(x: Self.canvas / 2, y: Self.canvas / 2)
        let start = CACurrentMediaTime() + hold
        for tile in tiles(image, grid: 6, in: root, scale: scale) {
            let dx = tile.position.x - center.x, dy = tile.position.y - center.y
            let len = max(hypot(dx, dy), 1)
            let push = CGFloat.random(in: 25...45)
            let to = CGPoint(x: tile.position.x + dx / len * push + .random(in: -6...6),
                             y: tile.position.y + dy / len * push + .random(in: -6...6))

            let move = CABasicAnimation(keyPath: "position")
            move.toValue = NSValue(point: to)
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.toValue = CGFloat.random(in: -0.9...0.9)
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.toValue = 0.55
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.toValue = 0

            let group = CAAnimationGroup()
            group.animations = [move, turn, shrink, fade]
            group.beginTime = start + .random(in: 0...0.04)
            group.duration = fly
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            tile.add(group, forKey: "explode")
        }
        return hold + fly + 0.1
    }

    /// 8×8 cells switch on in random order over 0.4 s, the lens holds 0.45 s, then
    /// fades in 0.25 s.
    private func dissolveIn(_ image: CGImage, in root: CALayer, scale: CGFloat) -> TimeInterval {
        let spread: CFTimeInterval = 0.4, hold: CFTimeInterval = 0.45, out: CFTimeInterval = 0.25
        let now = CACurrentMediaTime()
        for tile in tiles(image, grid: 8, in: root, scale: scale) {
            tile.opacity = 0
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.beginTime = now + .random(in: 0...spread)
            appear.duration = 0.05
            appear.fillMode = .forwards
            appear.isRemovedOnCompletion = false
            tile.add(appear, forKey: "dissolve")
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = now + spread + 0.05 + hold
        fade.duration = out
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        root.add(fade, forKey: "fade")
        return spread + 0.05 + hold + out + 0.05
    }

    // MARK: - Artwork

    /// The magnifier the zoom draws at the cursor (`ShareZoom`'s ⊕/⊖), plain: white
    /// edged in black, nothing behind it — the same artwork, twice the 72 pt it
    /// had on its dark disc until 2026-10-27.
    static func lensImage(side: CGFloat, scale: CGFloat) -> CGImage? {
        ShareZoom.lensArtwork(sign: 0, side: side, scale: scale)
    }
}
