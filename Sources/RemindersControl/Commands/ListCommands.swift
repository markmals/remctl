import ArgumentParser
import Foundation

let listCommands: [ParsableCommand.Type] = [
    Lists.self, ListCreate.self, ListEdit.self, ListPin.self, ListUnpin.self,
    ListRename.self, ListDelete.self, ListSymbols.self,
]

struct Lists: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lists", abstract: "List all lists.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("lists") }
}

struct ListCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-create", abstract: "Create a list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("list-create") }
}

struct ListEdit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-edit", abstract: "Edit a list's appearance.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("list-edit") }
}

struct ListPin: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-pin", abstract: "Pin a list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("list-pin") }
}

struct ListUnpin: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-unpin", abstract: "Unpin a list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("list-unpin") }
}

struct ListRename: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-rename", abstract: "Rename a list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("list-rename") }
}

struct ListDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-delete", abstract: "Delete a list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("list-delete") }
}

struct ListSymbols: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-symbols", abstract: "List badge symbols.")
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false
    @Option(name: .long, help: "Write a standalone HTML preview contact sheet") var html: String?
    @Flag(name: .long, help: "Generate and open the HTML preview contact sheet") var preview = false
    @Flag(name: .long, help: "Disable ANSI color") var noColor = false

    /// Left-justify to width using raw character count (matches Python f"{s:<w}").
    private func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }

    func run() throws {
        // --html / --preview are Phase 4 (RemindersUICore asset extraction). Preserve the
        // mutual-exclusion error, then defer.
        if html != nil || preview {
            if json {
                FileHandle.standardError.write(Data("Error: --json cannot be combined with --html or --preview.\n".utf8))
                Foundation.exit(1)
            }
            throw NotImplemented("list-symbols --preview/--html")
        }

        let rows = officialListSymbols
        if json {
            let symbols: [JSONValue] = rows.map {
                .object([("name", .string($0.name)), ("asset", .string($0.asset)), ("preview", .string($0.preview))])
            }
            let obj: JSONValue = .object([
                ("count", .int(rows.count)),
                ("note", .string(listSymbolsNote)),
                ("symbols", .array(symbols)),
            ])
            Dispatch.printJSON(obj, ensureAscii: false)
            return
        }

        let ansi = Ansi.resolve(noColorFlag: noColor)
        print(ansi.bold("Official Reminders list symbols (\(rows.count)):"))
        // NOTE: the Python hint reads "... --private --symbol ..."; `--private` is removed in
        // the Swift port, so the hint drops it (documented human-output deviation).
        print(ansi.dim("Use these with: remctl list-create \"Name\" --symbol <name>"))
        print(ansi.dim("The left column is an approximate text fallback, not native Reminders/SF Symbol rendering."))
        print(ansi.dim("Tip: run `remctl list-symbols --preview` to open the native badge preview in your browser."))
        let width = rows.map { $0.name.count }.max() ?? 0
        print("  \(pad(ansi.dim("approx"), 2))  \(pad(ansi.dim("name"), width))  \(ansi.dim("asset"))")
        for row in rows {
            print("  \(pad(row.preview, 2))  \(pad(row.name, width))  \(ansi.dim(row.asset))")
        }
    }
}
