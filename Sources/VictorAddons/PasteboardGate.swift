import AppKit

/// Serializes every `NSPasteboard.general` access in the app.
///
/// `NSPasteboard` is NOT thread-safe: it lazily rebuilds an internal type-cache
/// array whenever `changeCount` moves, and this app touches the general
/// pasteboard from several threads at once — the main thread (menu actions,
/// banners), the `EventTapRunLoop` thread (⌘V/⌃V interception), the clip-stack
/// poller queue (every 300ms), and global-queue workers (notes appender, wheel
/// re-paste). The 4 workshop crashes of 2026-07-22 (SIGSEGV/SIGABRT inside
/// `-[NSPasteboard _updateTypeCacheIfNeeded]`) were two of those threads
/// reading/rebuilding that cache concurrently — the crash reports literally
/// show the event-tap thread and the clip-stack queue inside
/// `-[NSPasteboard stringForType:]` at the same instant.
///
/// The lock is recursive so gated helpers can safely call each other
/// (e.g. `ClipboardManager.read()` from inside another gated block).
/// Keep critical sections short: only pasteboard calls belong inside —
/// do image decoding/encoding and disk I/O outside the gate.
enum PasteboardGate {
    private static let lock = NSRecursiveLock()

    @discardableResult
    static func sync<T>(_ body: (NSPasteboard) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(NSPasteboard.general)
    }
}
