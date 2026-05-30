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
        WriteDispatch.emit(await WriteDispatch.runShell { store, writer in
            try await Self.perform(id: id, json: json, store: store, writer: writer)
        })
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
        WriteDispatch.emit(await WriteDispatch.runShell { store, writer in
            try await Self.perform(id: id, json: json, store: store, writer: writer)
        })
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

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a reminder.")
    @Argument(help: "Reminder ID") var id: Int
    @Flag(name: .long, help: "Skip the confirmation prompt") var force = false
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false

    func run() async throws {
        let id = self.id, force = self.force, json = self.json
        WriteDispatch.emit(await WriteDispatch.runShell { store, writer in
            try await Self.perform(id: id, force: force, json: json, store: store, writer: writer, confirm: { prompt in
                FileHandle.standardOutput.write(Data(prompt.utf8))
                let line = readLine() ?? ""
                return line.lowercased().hasPrefix("y")
            })
        })
    }

    /// Testable core. `confirm` receives the full prompt string and returns the user's yes/no.
    static func perform(id: Int, force: Bool, json: Bool, store: RemindersStore, writer: RemindersWriter,
                        confirm: (_ prompt: String) -> Bool) async throws -> WriteOutcome {
        let (title, ckid) = try WriteDispatch.resolveReminderForWrite(store, id: id, op: "delete it")
        if !force {
            let list = store.reminder(pk: id)?.string("list_name") ?? ""
            let prompt = "Delete '\(safeDisplay(title))' from \(safeDisplay(list))? [y/N] "
            guard confirm(prompt) else { return .ok("Cancelled.\n") }   // exit 0, no JSON
        }
        _ = try await writer.delete(id: ckid)
        if json {
            let obj: JSONValue = .object([("status", .string("deleted")), ("id", .int(id)), ("title", .string(title))])
            return .ok(obj.serialized(indent: nil, ensureAscii: true) + "\n")
        }
        return .ok("Deleted: \(safeDisplay(title))\n")
    }
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
