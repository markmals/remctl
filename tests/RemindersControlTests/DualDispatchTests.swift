import Testing
import Foundation
import GRDB
@testable import RemindersControl

@Suite(.serialized) struct DualDispatchTests {

    // MARK: - Fixture helpers

    /// Builds a minimal fixture store dir and sets REMCTL_STORE_DIR for the duration of `body`.
    private func withFixtureStore(seed: (Database) throws -> Void = { _ in },
                                  body: (URL) async throws -> Void) async throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try seed(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        // Point the no-arg RemindersStore.open() at our fixture.
        setenv("REMCTL_STORE_DIR", dir.path, 1)
        defer { unsetenv("REMCTL_STORE_DIR") }
        try await body(dir)
    }

    // MARK: - PrivateWriterFactory

    @Test func privateFactoryDefaultsToReminderKitWriter() {
        #expect(PrivateWriterFactory.make() is ReminderKitWriter)
    }

    @Test func privateFactoryIsOverridable() {
        let saved = PrivateWriterFactory.make
        defer { PrivateWriterFactory.make = saved }
        let mock = MockPrivateWriter()
        PrivateWriterFactory.make = { mock }
        #expect(PrivateWriterFactory.make() is MockPrivateWriter)
    }

    // MARK: - runShellPrivate: mock injection + outcome propagation

    @Test func runShellPrivateInjectsPrivateWriter() async throws {
        try await withFixtureStore(seed: { _ in }, body: { _ in
            let mockPrivate = MockPrivateWriter()
            let savedPrivate = PrivateWriterFactory.make
            defer { PrivateWriterFactory.make = savedPrivate }
            PrivateWriterFactory.make = { mockPrivate }

            let outcome = await WriteDispatch.runShellPrivate { _, priv in
                _ = try await priv.setFlagged(id: "CK-1", flagged: true)
                return .ok("flagged\n")
            }

            #expect(mockPrivate.calls == [.setFlagged(id: "CK-1", flagged: true)])
            #expect(outcome == .ok("flagged\n"))
        })
    }

    @Test func runShellPrivatePropagatesOutcome() async throws {
        try await withFixtureStore(seed: { _ in }, body: { _ in
            let saved = PrivateWriterFactory.make
            defer { PrivateWriterFactory.make = saved }
            PrivateWriterFactory.make = { MockPrivateWriter() }

            let outcome = await WriteDispatch.runShellPrivate { _, _ in .ok("x") }
            #expect(outcome == .ok("x"))
        })
    }

    @Test func runShellPrivateMapsWriteError() async throws {
        try await withFixtureStore(seed: { _ in }, body: { _ in
            let saved = PrivateWriterFactory.make
            defer { PrivateWriterFactory.make = saved }
            PrivateWriterFactory.make = { MockPrivateWriter() }

            let outcome = await WriteDispatch.runShellPrivate { _, _ in
                throw WriteError("private failed", exitCode: 2)
            }
            #expect(outcome == WriteOutcome.error("private failed", code: 2))
            #expect(outcome.exitCode == 2)
            #expect(outcome.stderr == "Error: private failed\n")
        })
    }

    // MARK: - runShellBoth: mock injection for both writers + outcome propagation

    @Test func runShellBothInjectsBothWriters() async throws {
        try await withFixtureStore(seed: { _ in }, body: { _ in
            let mockWriter = MockWriter()
            let mockPrivate = MockPrivateWriter()

            let savedWriter = WriterFactory.make
            let savedPrivate = PrivateWriterFactory.make
            defer {
                WriterFactory.make = savedWriter
                PrivateWriterFactory.make = savedPrivate
            }
            WriterFactory.make = { mockWriter }
            PrivateWriterFactory.make = { mockPrivate }

            let outcome = await WriteDispatch.runShellBoth { _, writer, priv in
                _ = try await writer.complete(id: "EK-99")
                _ = try await priv.setFlagged(id: "CK-99", flagged: false)
                return .ok("both\n")
            }

            #expect(mockWriter.calls == [.complete(id: "EK-99", completionDate: nil)])
            #expect(mockPrivate.calls == [.setFlagged(id: "CK-99", flagged: false)])
            #expect(outcome == .ok("both\n"))
        })
    }

    @Test func runShellBothPropagatesOutcome() async throws {
        try await withFixtureStore(seed: { _ in }, body: { _ in
            let savedWriter = WriterFactory.make
            let savedPrivate = PrivateWriterFactory.make
            defer {
                WriterFactory.make = savedWriter
                PrivateWriterFactory.make = savedPrivate
            }
            WriterFactory.make = { MockWriter() }
            PrivateWriterFactory.make = { MockPrivateWriter() }

            let outcome = await WriteDispatch.runShellBoth { _, _, _ in .ok("y") }
            #expect(outcome == .ok("y"))
        })
    }

    @Test func runShellBothMapsWriteError() async throws {
        try await withFixtureStore(seed: { _ in }, body: { _ in
            let savedWriter = WriterFactory.make
            let savedPrivate = PrivateWriterFactory.make
            defer {
                WriterFactory.make = savedWriter
                PrivateWriterFactory.make = savedPrivate
            }
            WriterFactory.make = { MockWriter() }
            PrivateWriterFactory.make = { MockPrivateWriter() }

            let outcome = await WriteDispatch.runShellBoth { _, _, _ in
                throw WriteError("both failed")
            }
            #expect(outcome == WriteOutcome.error("both failed"))
            #expect(outcome.exitCode == 1)
            #expect(outcome.stderr == "Error: both failed\n")
        })
    }
}
