import AppKit
import XCTest
@testable import VictorAddons

final class BrainEnergyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testFullRightAfterTheBreak() {
        XCTAssertEqual(BrainEnergy.state(reference: t0, now: t0),
                       .draining(level: 1, remaining: 75 * 60))
    }

    func testHalfwayAfterThirtySevenAndAHalfMinutes() {
        guard case let .draining(level, _) = BrainEnergy.state(reference: t0, now: t0 + 37.5 * 60) else {
            return XCTFail("should still be draining")
        }
        XCTAssertEqual(level, 0.5, accuracy: 0.0001)
    }

    func testEmptyAtOneHourFifteenAndCountsTheOverdue() {
        XCTAssertEqual(BrainEnergy.state(reference: t0, now: t0 + 75 * 60), .depleted(overdue: 0))
        XCTAssertEqual(BrainEnergy.state(reference: t0, now: t0 + 90 * 60), .depleted(overdue: 15 * 60))
    }

    func testNoReferenceIsIdle() {
        XCTAssertEqual(BrainEnergy.state(reference: nil, now: t0), .idle)
    }

    /// Three hours after the last break the battery hides, until the next one ends.
    func testThreeHoursAfterTheBreakItGoesIdle() {
        XCTAssertNotNil(BrainEnergy.reference(breakEndedAt: t0 - 3 * 3600 + 60, refilledAt: nil, now: t0))
        XCTAssertNil(BrainEnergy.reference(breakEndedAt: t0 - 3 * 3600 - 60, refilledAt: nil, now: t0))
        XCTAssertEqual(BrainEnergy.state(reference: nil, now: t0), .idle)
    }

    /// A manual refill and a break end: whichever happened last filled the battery.
    func testTheLaterOfBreakEndAndRefillWins() {
        XCTAssertEqual(BrainEnergy.reference(breakEndedAt: t0 - 600, refilledAt: t0 - 60, now: t0), t0 - 60)
        XCTAssertEqual(BrainEnergy.reference(breakEndedAt: t0 - 60, refilledAt: t0 - 600, now: t0), t0 - 60)
    }

    func testAFutureReferenceIsIgnored() {
        XCTAssertNil(BrainEnergy.reference(breakEndedAt: t0 + 600, refilledAt: nil, now: t0))
    }

    func testDescriptions() {
        XCTAssertEqual(BrainEnergy.describe(.draining(level: 0.62, remaining: 28 * 60)), "62% · about 28m left")
        XCTAssertEqual(BrainEnergy.describe(.depleted(overdue: 12 * 60)), "Empty for 12m — break now")
        XCTAssertEqual(BrainEnergy.minutes(75 * 60), "1h 15m")
    }

    func testShowBrainBatteryIsOnByDefault() {
        let saved = UserDefaults.standard.object(forKey: BrainBatterySettings.enabledKey)
        defer { UserDefaults.standard.set(saved, forKey: BrainBatterySettings.enabledKey) }
        UserDefaults.standard.removeObject(forKey: BrainBatterySettings.enabledKey)
        XCTAssertTrue(BrainBatterySettings.isEnabled)
    }

    /// `BRAIN_BATTERY_RENDER=<dir> swift test --filter BrainEnergyTests` writes
    /// every state, dark and light, at 4× — to look at the drawing without a menu bar.
    func testRenderSamplesWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["BRAIN_BATTERY_RENDER"] else { return }
        let samples: [(String, BrainEnergy.State, Bool)] = [
            ("100", .draining(level: 1, remaining: 4500), true),
            ("62", .draining(level: 0.62, remaining: 1700), true),
            ("15", .draining(level: 0.15, remaining: 700), true),
            ("empty-on", .depleted(overdue: 120), true),
            ("empty-off", .depleted(overdue: 120), false),
            ("idle", .idle, true),
        ]
        let size = BrainBatteryIcon.size, scale: CGFloat = 4
        for (name, state, blink) in samples {
            for dark in [true, false] {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                           pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                    (dark ? NSColor(srgbRed: 0.24, green: 0.45, blue: 0.66, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    NSRect(origin: .zero, size: size).fill()
                    BrainBatteryIcon.draw(state: state, blinkOn: blink)
                }
                NSGraphicsContext.restoreGraphicsState()
                try rep.representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: "\(dir)/brain-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
