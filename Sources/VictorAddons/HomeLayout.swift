import CoreGraphics

/// Where the home monitors go around the Retina (2026-10-26): the left and the
/// right ones **flush against its sides**, top edges aligned, the one above it
/// **centred** over it — a 1920 above a 1728 overhangs both side monitors by 96.
/// Until then the home layout was kept verbatim, and a 108 pt gap between the
/// Retina and the right DELL let nothing cross: the pointer stopped at the edge.
///
/// Each monitor keeps the role its current position gives it — entirely above
/// the Retina = top, otherwise the side its centre is on — so a monitor moved by
/// hand to another side is placed there, not dragged back. Several on one side
/// are chained outwards in their current order. The Retina stays at (0,0), main.
enum HomeLayout {
    static func origins(retina: CGSize, externals: [CGDirectDisplayID: CGRect]) -> [CGDirectDisplayID: CGPoint] {
        var top: [(CGDirectDisplayID, CGRect)] = []
        var left: [(CGDirectDisplayID, CGRect)] = []
        var right: [(CGDirectDisplayID, CGRect)] = []
        for (id, frame) in externals {
            if frame.maxY <= 0 { top.append((id, frame)) }
            else if frame.midX < retina.width / 2 { left.append((id, frame)) }
            else { right.append((id, frame)) }
        }

        var result: [CGDirectDisplayID: CGPoint] = [:]
        var x: CGFloat = 0
        for (id, frame) in left.sorted(by: { $0.1.midX > $1.1.midX }) {
            x -= frame.width
            result[id] = CGPoint(x: x, y: 0)
        }
        x = retina.width
        for (id, frame) in right.sorted(by: { $0.1.midX < $1.1.midX }) {
            result[id] = CGPoint(x: x, y: 0)
            x += frame.width
        }
        // Above: the row as a whole centred over the Retina.
        let row = top.sorted { $0.1.midX < $1.1.midX }
        x = ((retina.width - row.reduce(0) { $0 + $1.1.width }) / 2).rounded()
        for (id, frame) in row {
            result[id] = CGPoint(x: x, y: -frame.height)
            x += frame.width
        }
        return result
    }
}
