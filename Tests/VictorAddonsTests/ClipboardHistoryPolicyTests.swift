import XCTest
@testable import VictorAddons

/// The rules of the ⌘⇧V history. Every one of these is a decision that fails
/// *silently* in the real thing — a history that drops the clip you wanted, or
/// one that keeps writing PNGs until the disk is full, both look like a history
/// that is working right up until they don't.
final class ClipboardHistoryPolicyTests: XCTestCase {

    private func text(_ s: String, at date: Date = Date()) -> ClipboardEntry {
        ClipboardEntry(id: UUID().uuidString, kind: .text(s), copiedAt: date, fingerprint: "t:" + s)
    }

    private func image(_ name: String, bytes: Int, at date: Date = Date()) -> ClipboardEntry {
        ClipboardEntry(id: name,
                       kind: .image(pixelWidth: 100, pixelHeight: 50, bytes: bytes),
                       copiedAt: date,
                       fingerprint: "i:" + name)
    }

    // MARK: insert

    func testNewestGoesFirst() {
        let result = ClipboardHistoryPolicy.insert(text("b"), into: [text("a")])
        XCTAssertEqual(result.list.count, 2)
        XCTAssertEqual(result.list.first?.kind, .text("b"))
        XCTAssertTrue(result.evicted.isEmpty)
    }

    /// Copying the same thing twice must not fill the picker with one string —
    /// the old row is replaced, not added beside.
    func testDuplicateIsMovedToFrontAndTheOldRowIsEvicted() {
        let old = text("hello", at: Date(timeIntervalSinceNow: -600))
        let list = [text("other"), old]
        let fresh = text("hello")

        let result = ClipboardHistoryPolicy.insert(fresh, into: list)

        XCTAssertEqual(result.list.count, 2)
        XCTAssertEqual(result.list.first?.id, fresh.id)
        XCTAssertEqual(result.evicted.map(\.id), [old.id])
        // The date is the new copy's: "just now" is the truth, the old stamp is not.
        XCTAssertEqual(result.list.first?.copiedAt, fresh.copiedAt)
    }

    /// Two rows holding the same pixels under different ids mean two copies of
    /// the same PNG on disk, so the older one is handed back for deletion —
    /// otherwise the folder grows by a full screenshot every re-copy.
    func testADuplicateImageUnderANewIdEvictsTheOldFile() {
        var old = image("old-file", bytes: 3_000_000, at: Date(timeIntervalSinceNow: -60))
        old = ClipboardEntry(id: old.id, kind: old.kind, copiedAt: old.copiedAt, fingerprint: "i:same-pixels")
        let fresh = ClipboardEntry(id: "new-file",
                                   kind: .image(pixelWidth: 100, pixelHeight: 50, bytes: 3_000_000),
                                   copiedAt: Date(), fingerprint: "i:same-pixels")

        let result = ClipboardHistoryPolicy.insert(fresh, into: [old])

        XCTAssertEqual(result.list.map(\.id), ["new-file"])
        XCTAssertEqual(result.evicted.map(\.id), ["old-file"])
    }

    /// Re-inserting the very same entry — which is what the store does when the
    /// identical image is copied again, and when a clip is pasted back out of
    /// the history — must NOT report its own file as evicted. Deleting it would
    /// leave a row pointing at a PNG that is gone.
    func testReinsertingTheSameEntryNeverEvictsItsOwnFile() {
        let entry = image("shot", bytes: 3_000_000, at: Date(timeIntervalSinceNow: -600))
        var refreshed = entry
        refreshed.copiedAt = Date()

        let result = ClipboardHistoryPolicy.insert(refreshed, into: [entry])

        XCTAssertEqual(result.list.map(\.id), ["shot"])
        XCTAssertTrue(result.evicted.isEmpty)
    }

    func testPastTheLimitTheOldestFallOffAndAreReported() {
        let list = (0..<5).map { text("clip\($0)") }
        let result = ClipboardHistoryPolicy.insert(text("new"), into: list, limit: 3)
        XCTAssertEqual(result.list.count, 3)
        XCTAssertEqual(result.list.map(\.kind), [.text("new"), .text("clip0"), .text("clip1")])
        XCTAssertEqual(result.evicted.map(\.kind), [.text("clip2"), .text("clip3"), .text("clip4")])
    }

    // MARK: expired

    func testOldClipsExpire() {
        let now = Date()
        let list = [text("fresh", at: now),
                    text("yesterday", at: now.addingTimeInterval(-24 * 3600)),
                    text("last week", at: now.addingTimeInterval(-7 * 24 * 3600))]
        let doomed = ClipboardHistoryPolicy.expired(list, now: now, maxAge: 3 * 24 * 3600)
        XCTAssertEqual(doomed.map(\.kind), [.text("last week")])
    }

    func testTheByteCeilingDropsTheOldestImagesFirst() {
        let now = Date()
        let list = [image("a", bytes: 600, at: now),
                    image("b", bytes: 600, at: now.addingTimeInterval(-60)),
                    image("c", bytes: 600, at: now.addingTimeInterval(-120))]
        let doomed = ClipboardHistoryPolicy.expired(list, now: now, maxBytes: 1_500)
        XCTAssertEqual(doomed.map(\.id), ["c"])
    }

    /// Text rows cost nothing on disk, so the image ceiling must not evict them.
    func testTextIsNotChargedAgainstTheByteCeiling() {
        let now = Date()
        let list = [image("big", bytes: 10_000, at: now)] + (0..<20).map {
            text("note\($0)", at: now.addingTimeInterval(-Double($0)))
        }
        let doomed = ClipboardHistoryPolicy.expired(list, now: now, maxBytes: 1_000)
        XCTAssertTrue(doomed.isEmpty, "text rows were evicted by a ceiling that exists for the image folder")
    }

    /// The guard against a machine that wakes up with a wrong clock: whatever is
    /// newest survives, even when it alone breaks both ceilings. It is the clip
    /// that is about to be pasted.
    func testTheNewestSurvivesEveryCeiling() {
        let now = Date()
        let list = [image("just copied", bytes: 99_999_999, at: now.addingTimeInterval(-99 * 24 * 3600))]
        let doomed = ClipboardHistoryPolicy.expired(list, now: now, maxAge: 60, maxBytes: 10)
        XCTAssertTrue(doomed.isEmpty)
    }

    // MARK: captions

    func testAgeReadsAsAGlance() {
        XCTAssertEqual(ClipboardHistoryPolicy.age(3), "just now")
        XCTAssertEqual(ClipboardHistoryPolicy.age(70), "a minute ago")
        XCTAssertEqual(ClipboardHistoryPolicy.age(240), "4 minutes ago")
        XCTAssertEqual(ClipboardHistoryPolicy.age(3500), "58 minutes ago")
        XCTAssertEqual(ClipboardHistoryPolicy.age(5000), "an hour ago")
        XCTAssertEqual(ClipboardHistoryPolicy.age(4 * 3600), "4 hours ago")
        XCTAssertEqual(ClipboardHistoryPolicy.age(30 * 3600), "yesterday")
        XCTAssertEqual(ClipboardHistoryPolicy.age(3 * 86400), "3 days ago")
    }

    /// A copied paragraph or block of code has to read as ONE thing in the
    /// bezel, so every run of whitespace collapses to a single space.
    func testPreviewCollapsesWhitespaceAndTruncates() {
        XCTAssertEqual(ClipboardHistoryPolicy.preview("  one\n\ttwo   three \n"), "one two three")
        let long = String(repeating: "x", count: 500)
        let preview = ClipboardHistoryPolicy.preview(long, limit: 10)
        XCTAssertEqual(preview, String(repeating: "x", count: 10) + "…")
    }
}
