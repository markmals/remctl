import Foundation

/// How long a write waits for the Reminders store to show it. ReminderKit saves reach the SQLite
/// store asynchronously, so writes are verified by polling fresh reads (upstream `_wait_for_order`).
public struct Readback: Sendable {
    public var attempts: Int
    public var delay: Double
    public init(attempts: Int, delay: Double) { self.attempts = attempts; self.delay = delay }

    public static let standard = Readback(attempts: 12, delay: 0.25)
    /// One read, no sleeping: for tests whose fixture store already holds the post-write state.
    public static let immediate = Readback(attempts: 1, delay: 0)

    /// Re-runs `check` until it passes; false when every attempt failed.
    public func waitUntil(_ check: () -> Bool) async -> Bool {
        for attempt in 0..<max(1, attempts) {
            if check() { return true }
            if attempt + 1 < attempts, delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        return false
    }
}
