import Foundation

/// A thread that keeps a live run loop and lets other code hand it work.
///
/// It exists for IOBluetooth, whose asynchronous callbacks — `sdpQueryComplete`,
/// `rfcommChannelOpenComplete` — are delivered on the **run loop of the thread
/// that started the operation**. A `DispatchQueue` has no run loop, so work
/// started from one is answered by nobody: the operation is really performed by
/// the Bluetooth daemon, but its result never comes back, and code waiting for a
/// verdict silently gets none. (That is how a failing channel open was reported
/// as a success for weeks — see `HotspotFallback`.)
///
/// The main thread would do, and is what AppKit apps usually reach for, but the
/// operations here run into tens of seconds and the main thread also serves the
/// menu bar and the `/test/*` HTTP hooks. A thread of our own costs nothing and
/// cannot beachball anything.
final class RunLoopThread {
    private let name: String
    private var thread: Thread?

    init(name: String) { self.name = name }

    func start() {
        guard thread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let t = Thread {
            let rl = RunLoop.current
            // A run loop with no input sources returns from `run()` immediately
            // and the thread would just exit; the port is what keeps it alive.
            rl.add(Port(), forMode: .default)
            ready.signal()
            while !Thread.current.isCancelled {
                rl.run(mode: .default, before: .distantFuture)
            }
        }
        t.name = name
        t.start()
        thread = t
        _ = ready.wait(timeout: .now() + 2)
    }

    /// Runs `block` on the thread's run loop. Falls back to running it inline if
    /// the thread was never started — better a callback that never arrives than
    /// work that is silently dropped.
    func async(_ block: @escaping () -> Void) {
        guard let thread, thread.isExecuting else { return block() }
        // `perform(on:)` retains the receiver until the selector has run, which
        // is what keeps the box (and the block it holds) alive in the meantime.
        let box = Box(block)
        box.perform(#selector(Box.run), on: thread, with: nil, waitUntilDone: false)
    }

    private final class Box: NSObject {
        private let block: () -> Void
        init(_ block: @escaping () -> Void) { self.block = block }
        @objc func run() { block() }
    }
}
