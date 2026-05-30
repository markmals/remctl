import Testing
import CoreGraphics
@testable import RemindersControl

/// Only the pure `colorForName` seam is covered here. The rest of EventKitWriter
/// touches a real Reminders store + TCC permission and is verified manually (W13).
/// Constructing an EKEventStore (via EventKitWriter.init) does NOT itself require
/// authorization — only store access does — so these tests run cleanly in CI.
@Suite struct EventKitWriterTests {
    @Test func colorForNameKnownColors() {
        let w = EventKitWriter()

        let red = w.colorForName("red")
        #expect(red != nil)
        #expect(red?.components == [1.0, 0.23, 0.19, 1.0])

        let blue = w.colorForName("blue")
        #expect(blue?.components == [0.0, 0.48, 1.0, 1.0])

        // Case-insensitive lookup (bridge lowercases the name).
        #expect(w.colorForName("GREEN")?.components == [0.3, 0.85, 0.39, 1.0])
    }

    @Test func colorForNameUnknownReturnsNil() {
        let w = EventKitWriter()
        #expect(w.colorForName("chartreuse") == nil)
        #expect(w.colorForName("") == nil)
    }
}
