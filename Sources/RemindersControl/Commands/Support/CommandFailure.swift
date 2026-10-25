import Foundation

/// A command failure with a stable machine-readable `code`. Under `--json` it renders as the
/// structured stderr object `{"status":"error","code":…,"message":…,…context}`; otherwise as the
/// plain `Error: <message>` line. Both exit 1.
public struct CommandFailure: Error {
    public let code: String
    public let message: String
    public let context: [(String, JSONValue)]

    public init(_ code: String, _ message: String, context: [(String, JSONValue)] = []) {
        self.code = code; self.message = message; self.context = context
    }

    public func outcome(json: Bool) -> WriteOutcome {
        guard json else { return .error(message) }
        let payload: JSONValue = .object(
            [("status", .string("error")), ("code", .string(code)), ("message", .string(message))] + context)
        return WriteOutcome(stderr: payload.serialized(indent: nil, ensureAscii: false) + "\n", exitCode: 1)
    }
}

extension WriteDispatch {
    /// `perform` for commands that follow the JSON error convention: every failure, including
    /// the shared target-resolution `CLIError`s, renders through `CommandFailure`.
    public static func perform(json: Bool, _ body: () async throws -> WriteOutcome) async -> WriteOutcome {
        do { return try await body() }
        catch let failure as CommandFailure { return failure.outcome(json: json) }
        catch let error as CLIError {
            return CommandFailure(error.code ?? "invalid_request", error.message).outcome(json: json)
        }
        catch let error as RemindersDBUnavailable {
            return CommandFailure("database_unavailable", error.message).outcome(json: json)
        }
        catch let error as WriteError { return CommandFailure("write_failed", error.message).outcome(json: json) }
        catch { return CommandFailure("command_failed", "\(error)").outcome(json: json) }
    }

    /// `runShellPrivate` with the JSON error convention.
    public static func runShellPrivate(json: Bool, _ body: @escaping (RemindersStore, PrivateWriter) async throws -> WriteOutcome) async -> WriteOutcome {
        await perform(json: json) {
            try await body(try RemindersStore.open(), PrivateWriterFactory.make())
        }
    }
}

extension PrivateResult {
    /// The helper's reply as reported under a command's `private` key: status first, then the
    /// echoed fields sorted by key.
    public var jsonObject: JSONValue {
        .object([("status", .string(status))] + fields.keys.sorted().map { ($0, fields[$0]!) })
    }

    /// This reply when the helper reported `expected`; otherwise the write failed and the command
    /// stops with the helper's message.
    public func requireStatus(_ expected: String) throws -> PrivateResult {
        guard status == expected else {
            throw CommandFailure("private_write_failed", message ?? "private helper failed")
        }
        return self
    }

    /// A string field the helper echoed, or nil when it is absent or empty.
    public func string(_ key: String) -> String? {
        guard case let .string(value)? = fields[key], !value.isEmpty else { return nil }
        return value
    }
}
