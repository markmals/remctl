import ArgumentParser
import Foundation
import GRDB

enum ExportFormat: String, ExpressibleByArgument, CaseIterable { case json, csv }

let opsCommands: [ParsableCommand.Type] = [
    Export.self, Import.self, CompletionCmd.self, Doctor.self, Onboard.self, Permissions.self, Setup.self,
]

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export reminders.")
    @Option(name: [.short, .long], help: "Export only this list (by name)") var list: String?
    @Option(name: .long, help: "Export only this list (by numeric ID)") var listId: Int?
    @Option(name: .long, help: "Output format") var format: ExportFormat = .json
    @Flag(name: .long, help: "Accepted for compatibility; output is governed by --format") var json = false

    func run() throws {
        Dispatch.runRead { store in
            let items: [Row]
            if list != nil || listId != nil {
                let pk = try resolveRequiredListTarget(store: store, name: list, listId: listId)
                items = store.reminders(listPk: pk, completed: true, topLevel: false, limit: 10000)
            } else {
                items = store.reminders(completed: true, topLevel: false, limit: 10000)
            }
            let objs = serializeReminders(items, store: store)

            switch format {
            case .json:
                Dispatch.printJSON(.array(objs.map { .object($0) }), ensureAscii: true)
            case .csv:
                var rows: [[String]] = [["id", "title", "list", "completed", "flagged", "urgent",
                                         "priority", "due_date", "notes", "url", "tags"]]
                for obj in objs {
                    let d = Dictionary(obj, uniquingKeysWith: { a, _ in a })
                    func str(_ k: String) -> String { if case let .string(v)? = d[k] { return v }; return "" }
                    func intStr(_ k: String) -> String { if case let .int(v)? = d[k] { return String(v) }; return "" }
                    func boolStr(_ k: String) -> String { if case let .bool(v)? = d[k] { return v ? "True" : "False" }; return "False" }
                    var tags = ""
                    if case let .array(arr)? = d["tags"] {
                        tags = arr.compactMap { if case let .string(t) = $0 { return t } else { return nil } }.joined(separator: ",")
                    }
                    rows.append([intStr("id"), str("title"), str("list"), boolStr("completed"),
                                 boolStr("flagged"), boolStr("urgent"), str("priority"),
                                 str("dueDate"), str("notes"), str("url"), tags])
                }
                print(CSV.writeRows(rows), terminator: "")
            }
        }
    }
}

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import", abstract: "Import reminders.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("import") }
}

// Named `CompletionCmd` (not `Completion`) to stay clear of ArgumentParser's
// completion-script machinery; `commandName` remains "completion".
struct CompletionCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "completion", abstract: "Print a shell completion script.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("completion") }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Diagnose setup and permissions.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("doctor") }
}

struct Onboard: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "onboard", abstract: "First-run onboarding.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("onboard") }
}

struct Permissions: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "permissions", abstract: "Guided Full Disk Access setup.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("permissions") }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup", abstract: "Install shell completions/config.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("setup") }
}
