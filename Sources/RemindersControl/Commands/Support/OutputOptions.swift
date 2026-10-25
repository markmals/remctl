import ArgumentParser
import Foundation

public enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case plain, table, json
}

/// Shared options for read commands that support all output modes (today/upcoming/overdue/flagged/urgent/search/show).
public struct ReadDisplayOptions: ParsableArguments {
    public init() {}
    @Flag(name: .long, help: "Output machine-readable JSON") public var json = false
    @Option(name: .long, help: "Output format") public var format: OutputFormat?
    @Flag(name: [.short, .long], help: "Verbose output") public var verbose = false
    @Flag(name: .long, help: "Disable ANSI color") public var noColor = false

    /// --format json forces json; otherwise honor --json.
    public var effectiveJSON: Bool { json || format == .json }
    /// table only when not effectively json.
    public var useTable: Bool { !effectiveJSON && format == .table }
    public func ansi() -> Ansi { Ansi.resolve(noColorFlag: noColor) }
}

/// Shared options for read commands that only support JSON vs human (tags/sections/stats/subtasks/smart-lists/templates/template-info/list-symbols).
public struct JSONOnlyOptions: ParsableArguments {
    public init() {}
    @Flag(name: .long, help: "Output machine-readable JSON") public var json = false
    @Flag(name: .long, help: "Disable ANSI color") public var noColor = false
    public func ansi() -> Ansi { Ansi.resolve(noColorFlag: noColor) }
}

/// A command-level validation error → printed as "Error: <message>" with exit code 1. `code` is
/// the stable identifier commands following the JSON error convention report under `--json`.
public struct CLIError: Error, CustomStringConvertible {
    public let message: String
    public let code: String?
    public let context: [(String, JSONValue)]
    public init(_ m: String, code: String? = nil, context: [(String, JSONValue)] = []) {
        self.message = m; self.code = code; self.context = context
    }
    public var description: String { message }
}

public enum Dispatch {
    /// Open the store and run `body`; render failures to the command's requested output mode.
    public static func runRead(json: Bool = false, _ body: (RemindersStore) throws -> Void) {
        do {
            let store = try RemindersStore.open()
            try body(store)
        } catch {
            let outcome = FailureRendering.outcome(error, json: json)
            FileHandle.standardError.write(Data(outcome.stderr.utf8))
            exit(outcome.exitCode)
        }
    }
    public static func printJSON(_ v: JSONValue, indent: Int? = 2, ensureAscii: Bool) {
        print(v.serialized(indent: indent, ensureAscii: ensureAscii))
    }
}
