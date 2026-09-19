import XCTest
@testable import VictorAddons

/// Never two agents on ONE CONVERSATION.
///
/// A reply Victor sends while a run is still going used to become a second
/// Terminal agent on the same thread: two claudes, two replies, and whichever
/// finished last overwrote the thread's session record. It is now deferred to
/// the agent already running, which folds it into its own reply.
///
/// Two halves are tested here, and they have to agree: the poller's decision
/// (`splitByBusyThread` + `watermarkCeiling`) and the on-disk claim
/// `flux-agent.sh` writes (`threadClaimPath` / `threadClaimIsLive`).
final class FluxThreadDeferralTests: XCTestCase {

    private let goodAuth = """
        amazonses.com; spf=pass (spfCheck: domain of _spf.google.com designates \
        209.85.208.48 as permitted sender) client-ip=209.85.208.48; \
        envelope-from=victorrentea@gmail.com; helo=mail-ed1-f48.google.com; \
        dkim=pass header.i=@gmail.com; dmarc=pass header.from=gmail.com;
        """

    private func message(id: String, thread: String, at seconds: TimeInterval) -> FluxMessage {
        FluxMessage(messageId: id,
                    from: "Victor Rentea <victorrentea@gmail.com>",
                    subject: "hi",
                    timestamp: Date(timeIntervalSince1970: seconds),
                    authenticationResults: goodAuth,
                    threadId: thread,
                    labels: ["received", "unread"])
    }

    // MARK: Splitting a poll's fresh mail

    func testMailForABusyThreadIsDeferred() {
        let busy = message(id: "m1", thread: "busy", at: 100)
        let free = message(id: "m2", thread: "free", at: 200)
        let split = FluxMailPolicy.splitByBusyThread([busy, free]) { $0 == "busy" }
        XCTAssertEqual(split.launch.map(\.messageId), ["m2"])
        XCTAssertEqual(split.deferred.map(\.messageId), ["m1"])
    }

    func testNothingIsDeferredWhenNoAgentIsRunning() {
        let mail = [message(id: "m1", thread: "t1", at: 100),
                    message(id: "m2", thread: "t2", at: 200)]
        let split = FluxMailPolicy.splitByBusyThread(mail) { _ in false }
        XCTAssertEqual(split.launch.count, 2)
        XCTAssertTrue(split.deferred.isEmpty)
    }

    /// Two replies on the same busy thread are both steering for the same
    /// running agent — neither may sneak through.
    func testEveryMessageOfABusyThreadIsDeferred() {
        let mail = [message(id: "m1", thread: "t1", at: 100),
                    message(id: "m2", thread: "t1", at: 200)]
        let split = FluxMailPolicy.splitByBusyThread(mail) { _ in true }
        XCTAssertTrue(split.launch.isEmpty)
        XCTAssertEqual(split.deferred.count, 2)
    }

    // MARK: The watermark ceiling

    /// The deferred message is left unread AND unremembered; the only thing that
    /// brings it back is being newer than the watermark. So a *newer* message
    /// from another thread must not push the watermark past it — that would turn
    /// a deferral into a silent deletion.
    func testCeilingIsTheOldestDeferredMessage() {
        let deferred = [message(id: "m2", thread: "t1", at: 300),
                        message(id: "m1", thread: "t1", at: 100)]
        XCTAssertEqual(FluxMailPolicy.watermarkCeiling(deferred: deferred),
                       Date(timeIntervalSince1970: 100))
    }

    func testNoCeilingWhenNothingWasDeferred() {
        XCTAssertNil(FluxMailPolicy.watermarkCeiling(deferred: []))
    }

    // MARK: The claim file, shared with flux-agent.sh

    /// The path is a contract between two languages: the script writes
    /// `printf %s "$THREAD_ID" | shasum | cut -c1-16`. If Swift's idea of that
    /// name ever drifts, the claim becomes invisible and the second agent is
    /// back — so compute it with the real `shasum` and compare.
    func testClaimPathMatchesTheShellFormula() throws {
        let threadId = "f28ab4e4-d1e9-4d23-b7de-7b62eb3b6e3f"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "printf '%s' '\(threadId)' | shasum | cut -c1-16"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let sha = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(FluxAgentLauncher.threadClaimPath(threadId),
                       "/tmp/flux-agent-thread-\(sha).claim")
    }

    func testClaimIsLiveWhileItsProcessIs() throws {
        let threadId = "live-\(UUID().uuidString)"
        let path = FluxAgentLauncher.threadClaimPath(threadId)
        try "4242\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(FluxAgentLauncher.threadClaimIsLive(threadId) { $0 == 4242 })
    }

    /// A killed run, or a Mac that rebooted with the file left in /tmp, must not
    /// wedge the thread shut forever.
    func testClaimOfADeadProcessIsNotLive() throws {
        let threadId = "dead-\(UUID().uuidString)"
        let path = FluxAgentLauncher.threadClaimPath(threadId)
        try "4242\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(FluxAgentLauncher.threadClaimIsLive(threadId) { _ in false })
    }

    func testMissingOrGarbledClaimIsNotLive() throws {
        XCTAssertFalse(FluxAgentLauncher.threadClaimIsLive("never-claimed-\(UUID().uuidString)") { _ in true })

        let threadId = "garbled-\(UUID().uuidString)"
        let path = FluxAgentLauncher.threadClaimPath(threadId)
        try "not-a-pid\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(FluxAgentLauncher.threadClaimIsLive(threadId) { _ in true })
    }

    /// An empty thread id (the `parse` fallback when AgentMail omits it) must
    /// never read as busy, or one malformed payload would freeze all mail.
    func testEmptyThreadIdIsNeverBusy() {
        XCTAssertFalse(FluxAgentLauncher.isThreadBusy(""))
    }
}
