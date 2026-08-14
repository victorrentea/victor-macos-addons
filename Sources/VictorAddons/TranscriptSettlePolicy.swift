import Foundation

/// "Has whisper caught up with what I had already said when I pressed the key?"
///
/// The picker's whole premise is that the last sentence out of Victor's mouth
/// is *in* the list, and at the moment ⌘⌃V is pressed it is not yet in the file:
/// `whisper_runner` buffers audio in 6 s chunks, queues each one, and only then
/// runs inference — so the words spoken in the second before the keypress land
/// somewhere between 6 and ~15 s later. Firing the LLM immediately produces a
/// tidy list of segments that all stop one sentence short, which is the one
/// failure mode the feature cannot survive: it looks like it worked.
///
/// So the hotkey waits, and the rule is deliberately made of two clauses:
///
/// * **A floor (`minWait`).** Long enough for the in-flight chunk to be closed
///   *and* transcribed. Without it, a run that starts during a natural pause
///   sees an already-quiet file and declares victory before the last chunk has
///   even been handed to the model.
/// * **A quiet period (`quietSeconds`).** Once the floor has passed, the file
///   not growing for a couple of seconds is what says the backlog has drained.
///   Whisper writes a line per transcribed chunk, so continuous growth means
///   there is still speech in the queue and the newest words are not in yet.
///
/// `maxWait` is the give-up: on a long backlog (a burst of speech, a slow
/// model) waiting for true quiet could take a minute, and a picker that opens
/// with slightly-stale text beats one that never opens.
enum TranscriptSettlePolicy {
    static let minWait: TimeInterval = 8
    static let quietSeconds: TimeInterval = 2.5
    static let maxWait: TimeInterval = 25
    /// How often the caller re-samples the file size.
    static let pollInterval: TimeInterval = 0.35

    enum Decision: Equatable {
        /// Keep waiting (and keep the spinner under the cursor).
        case wait
        /// Whisper has caught up — read the tail.
        case ready
        /// Gave up waiting; read whatever is there and say so.
        case timedOut
    }

    /// - Parameters:
    ///   - elapsed: seconds since the hotkey was pressed.
    ///   - sinceLastGrowth: seconds since the transcript file last got bigger.
    ///     Callers seed this with `elapsed` at t=0, so a file that never grows
    ///     at all (nothing was said, or whisper is down) still settles at the
    ///     floor instead of hanging until `maxWait`.
    static func decide(elapsed: TimeInterval, sinceLastGrowth: TimeInterval) -> Decision {
        if elapsed >= maxWait { return .timedOut }
        if elapsed < minWait { return .wait }
        return sinceLastGrowth >= quietSeconds ? .ready : .wait
    }
}
