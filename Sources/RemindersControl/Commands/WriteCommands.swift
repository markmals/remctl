import ArgumentParser
import Foundation

let writeCommands: [ParsableCommand.Type] = [
    Add.self, Edit.self, Done.self, Undone.self, Delete.self,
    FlagCmd.self, Unflag.self, Link.self, Open.self,
]

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a reminder.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("add") }
}

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Edit a reminder.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("edit") }
}

struct Done: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "done", abstract: "Mark reminders complete.")
    @Argument(help: "Reminder ID") var id: Int
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false

    func run() async throws {
        let outcome = await WriteDispatch.perform {
            let store = try RemindersStore.open()
            let writer = WriterFactory.make()
            return try await Self.perform(id: id, json: json, store: store, writer: writer)
        }
        WriteDispatch.emit(outcome)
    }

    /// Testable core (no print/exit). Tests call this with a FixtureDB store + MockWriter.
    static func perform(id: Int, json: Bool, store: RemindersStore, writer: RemindersWriter) async throws -> WriteOutcome {
        let (title, ckid) = try WriteDispatch.resolveReminderForWrite(store, id: id, op: "complete it")
        _ = try await writer.complete(id: ckid)
        if json {
            let obj: JSONValue = .object([("status", .string("completed")), ("id", .int(id)), ("title", .string(title))])
            return .ok(obj.serialized(indent: nil, ensureAscii: true) + "\n")
        }
        return .ok("Completed: \(safeDisplay(title))\n")
    }
}

struct Undone: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "undone", abstract: "Mark reminders incomplete.")
    @Argument(help: "Reminder ID") var id: Int
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false

    func run() async throws {
        let outcome = await WriteDispatch.perform {
            let store = try RemindersStore.open()
            let writer = WriterFactory.make()
            return try await Self.perform(id: id, json: json, store: store, writer: writer)
        }
        WriteDispatch.emit(outcome)
    }

    /// Testable core (no print/exit). Tests call this with a FixtureDB store + MockWriter.
    static func perform(id: Int, json: Bool, store: RemindersStore, writer: RemindersWriter) async throws -> WriteOutcome {
        let (title, ckid) = try WriteDispatch.resolveReminderForWrite(store, id: id, op: "uncomplete it")
        _ = try await writer.uncomplete(id: ckid)
        if json {
            let obj: JSONValue = .object([("status", .string("uncompleted")), ("id", .int(id)), ("title", .string(title))])
            return .ok(obj.serialized(indent: nil, ensureAscii: true) + "\n")
        }
        return .ok("Uncompleted: \(safeDisplay(title))\n")
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete reminders.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("delete") }
}

struct FlagCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "flag", abstract: "Flag a reminder.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("flag") }
}

struct Unflag: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unflag", abstract: "Unflag a reminder.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("unflag") }
}

struct Link: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "link", abstract: "Print a reminder's deep link.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("link") }
}

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open a reminder in Reminders.app.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("open") }
}
