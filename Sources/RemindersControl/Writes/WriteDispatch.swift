import Foundation

/// The result of a write command's core: what to print and the exit code. Cores return this
/// (never print/exit directly) so they're unit-testable; the ArgumentParser shell emits it.
public struct WriteOutcome: Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
    public static func ok(_ s: String) -> WriteOutcome { WriteOutcome(stdout: s, exitCode: 0) }
    /// Mirrors the Python "Error: <msg>" stderr line. Adds the "Error: " prefix + trailing newline.
    public static func error(_ message: String, code: Int32 = 1) -> WriteOutcome {
        WriteOutcome(stderr: "Error: \(message)\n", exitCode: code)
    }
}

public enum WriteDispatch {
    /// Resolve a reminder by numeric Z_PK → (title, ZCKIDENTIFIER). Mirrors the not-found +
    /// no-stable-identifier refusals (NEVER falls back to title matching). `op` is the gerund
    /// phrase used in the refusal, e.g. "complete it" / "edit it".
    public static func resolveReminderForWrite(_ store: RemindersStore, id: Int, op: String) throws -> (title: String, ckid: String) {
        guard let row = store.reminder(pk: id) else { throw WriteError("#\(id) not found") }
        let title = row.string("ZTITLE")
        guard let ckid = row.string("ZCKIDENTIFIER"), !ckid.isEmpty else {
            let shownTitle = safeDisplay((title?.isEmpty == false ? title : nil) ?? "(untitled)")
            throw WriteError("The reminder has no stable identifier. Refusing unsafe title-based fallback for #\(id) ('\(shownTitle)') while trying to \(op).")
        }
        return (title ?? "", ckid)
    }

    /// Run an async write core, mapping thrown WriteError / RemindersDBUnavailable / other to a WriteOutcome.
    public static func perform(_ body: () async throws -> WriteOutcome) async -> WriteOutcome {
        do { return try await body() }
        catch let e as WriteError { return .error(e.message, code: e.exitCode) }
        catch let e as RemindersDBUnavailable { return .error(e.message) }
        catch { return .error("\(error)") }
    }

    /// Opens the read store + the production writer and runs `body`, mapping any thrown error to a
    /// WriteOutcome. The standard shell for write commands that resolve a Z_PK against the read store.
    public static func runShell(_ body: @escaping (RemindersStore, RemindersWriter) async throws -> WriteOutcome) async -> WriteOutcome {
        await perform {
            let store = try RemindersStore.open()
            let writer = WriterFactory.make()
            return try await body(store, writer)
        }
    }

    /// Opens the read store + the private writer and runs `body`, mapping any thrown error to a
    /// WriteOutcome. The standard shell for write commands that use only the private writer.
    public static func runShellPrivate(_ body: @escaping (RemindersStore, PrivateWriter) async throws -> WriteOutcome) async -> WriteOutcome {
        await perform {
            let store = try RemindersStore.open()
            let privateWriter = PrivateWriterFactory.make()
            return try await body(store, privateWriter)
        }
    }

    /// Opens the read store + the production writer + the private writer and runs `body`, mapping
    /// any thrown error to a WriteOutcome. The standard shell for write commands that need both.
    public static func runShellBoth(_ body: @escaping (RemindersStore, RemindersWriter, PrivateWriter) async throws -> WriteOutcome) async -> WriteOutcome {
        await perform {
            let store = try RemindersStore.open()
            let writer = WriterFactory.make()
            let privateWriter = PrivateWriterFactory.make()
            return try await body(store, writer, privateWriter)
        }
    }

    /// Emit a WriteOutcome from the ArgumentParser shell (writes streams + exits). Never returns.
    public static func emit(_ outcome: WriteOutcome) -> Never {
        if !outcome.stdout.isEmpty { FileHandle.standardOutput.write(Data(outcome.stdout.utf8)) }
        if !outcome.stderr.isEmpty { FileHandle.standardError.write(Data(outcome.stderr.utf8)) }
        exit(outcome.exitCode)
    }
}
