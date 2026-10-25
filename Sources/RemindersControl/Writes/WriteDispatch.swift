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
        guard let row = store.reminder(pk: id) else {
            throw WriteError("#\(id) not found", code: "not_found", context: [("id", .int(id))])
        }
        let title = row.string("ZTITLE")
        guard let ckid = row.string("ZCKIDENTIFIER"), !ckid.isEmpty else {
            throw WriteError(noStableIdentifierMessage(id: id, title: title, op: op),
                             code: "no_stable_identifier", context: [("id", .int(id))])
        }
        return (title ?? "", ckid)
    }

    /// The refusal a reminder without a ZCKIDENTIFIER gets, shared by the single-write resolve
    /// above and the batch path, which resolves rows itself.
    public static func noStableIdentifierMessage(id: Int, title: String?, op: String) -> String {
        let shownTitle = safeDisplay((title?.isEmpty == false ? title : nil) ?? "(untitled)")
        return "The reminder has no stable identifier. Refusing unsafe title-based fallback for #\(id) ('\(shownTitle)') while trying to \(op)."
    }

    /// A write refused for lack of Reminders access names the same-context fix
    /// (upstream cd31b51 `fail_bridge_write`).
    static func withAccessHint(_ message: String) -> String {
        isEventKitAccessError(message) ? message + "\n" + eventKitAccessFixText() : message
    }

    /// Emit a WriteOutcome from the ArgumentParser shell (writes streams + exits). Never returns.
    public static func emit(_ outcome: WriteOutcome) -> Never {
        if !outcome.stdout.isEmpty { FileHandle.standardOutput.write(Data(outcome.stdout.utf8)) }
        if !outcome.stderr.isEmpty { FileHandle.standardError.write(Data(outcome.stderr.utf8)) }
        exit(outcome.exitCode)
    }
}
