import ArgumentParser
import Foundation

let listCommands: [ParsableCommand.Type] = [
    Lists.self, ListCreate.self, ListEdit.self, ListPin.self, ListUnpin.self,
    ListRename.self, ListDelete.self, ListSymbols.self,
]

struct Lists: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lists", abstract: "List all lists.")
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false
    @Option(name: .long, help: "Output format") var format: OutputFormat?
    @Flag(name: .long, help: "Disable ANSI color") var noColor = false

    func run() throws {
        let effJSON = json || format == .json
        Dispatch.runRead { store in
            let rows = store.lists()
            if effJSON {
                Dispatch.printJSON(.array(rows.map { .object(listToDict($0)) }), ensureAscii: false)
                return
            }
            let ansi = Ansi.resolve(noColorFlag: noColor)
            if format == .table {
                let trows = rows.map { r -> TableRow in
                    let name = safeDisplay(r.string("ZNAME"))
                    let title = isGroceryListRow(r) ? "\(name) \(Constants.groceryListMarker)" : name
                    return TableRow(id: "\(r.int("Z_PK") ?? 0)", title: title, list: "", due: "", repeatText: "", pri: "")
                }
                print(fmtTable(trows, ansi: ansi))
                return
            }
            print(ansi.bold("Reminder Lists:"))
            for r in rows {
                let pk = r.int("Z_PK") ?? 0
                var listName = colorListName(r.string("ZNAME"), ansi: ansi)
                if isGroceryListRow(r) { listName += " \(Constants.groceryListMarker)" }
                let idDim = ansi.dim("(id: \(pk))")
                let secCount = store.sectionCountForList(pk)
                let secInfo = secCount >= 1 ? ansi.dim(" [\(secCount) sections]") : ""
                let pinned = r.has("ZISPINNEDBYCURRENTUSER") && (r.int("ZISPINNEDBYCURRENTUSER") ?? 0) != 0
                let pinInfo = pinned ? ansi.dim(" [pinned]") : ""
                print("  \(listName) \(idDim)\(secInfo)\(pinInfo)")
            }
            let n = rows.count
            print("\n\(n) list\(n == 1 ? "" : "s")")
        }
    }
}

/// Public list colors accepted by `LIST_COLOR_MAP` (remctl:214). Validation lowercases/trims the
/// input (`normalize_list_color`) before membership, so e.g. `--color RED` is accepted. NOTE: `teal`
/// IS a valid/accepted color, but the error message deliberately omits it (Python quirk, see below).
private let publicListColors: Set<String> = [
    "red", "orange", "yellow", "green", "blue", "purple", "brown", "gray", "cyan", "teal",
]

/// `validate_list_color`'s example string for the PUBLIC path (remctl:329) — the literal 9-name list
/// WITHOUT "teal", even though teal is a member of LIST_COLOR_MAP. Replicated verbatim.
private let publicListColorExamples = "red, orange, yellow, green, blue, purple, brown, gray, or cyan"

/// Port of `normalize_list_color` (remctl:305) for the name path only: trim + lowercase. (The
/// `#RRGGBB` hex branch belongs to the private path, which is removed in Phase 2.)
private func normalizeListColorName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespaces).lowercased()
}

struct ListCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-create", abstract: "Create a list.")

    @Argument(help: "List title") var name: String
    @Option(name: .long, help: "List color name: red, orange, yellow, green, blue, purple, brown, gray, cyan, or teal") var color: String?

    // Declared but Phase-3 (private ReminderKit metadata) — stubbed. `--private` is removed
    // project-wide in Phase 2, so these always refuse.
    @Option(name: .long, help: "Official Reminders list symbol name (Phase 3)") var symbol: String?
    @Option(name: .long, help: "Emoji badge (Phase 3)") var emoji: String?
    @Flag(name: .long, help: "Create as a Groceries list (Phase 3)") var groceries = false
    @Option(name: .long, help: "Groceries locale identifier, e.g. en_US (Phase 3)") var groceryLocale: String?

    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShell { _, writer in
            try await Self.perform(
                name: args.name, color: args.color, symbol: args.symbol, emoji: args.emoji,
                groceries: args.groceries, groceryLocale: args.groceryLocale, json: args.json, writer: writer)
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_list_create`'s PUBLIC path (remctl:6085).
    /// PHASE-2 DIVERGENCE: the Python `if not bridge_available(): Error: remctl-bridge required for
    /// list management` guard is MOOT here — EventKit is in-process, the writer is always present —
    /// so it is NOT emitted. The duplicate-name preflight (private-only) is likewise dropped.
    static func perform(
        name: String, color: String? = nil, symbol: String? = nil, emoji: String? = nil,
        groceries: Bool = false, groceryLocale: String? = nil, json: Bool, writer: RemindersWriter
    ) async throws -> WriteOutcome {
        // 1. Phase-3 stub guard. `--symbol`/`--emoji`/`--groceries`/`--grocery-locale` all required the
        //    private metadata layer (`--private`) in Python; that path is removed in Phase 2.
        if symbol != nil { throw phase3("--symbol") }
        if emoji != nil { throw phase3("--emoji") }
        if groceries { throw phase3("--groceries") }
        if groceryLocale != nil { throw phase3("--grocery-locale") }

        // 2. Validate --color (public path of validate_list_color, remctl:321-332). Empty/nil is a
        //    no-op (no color). Unsupported -> exit 1 with the 9-name example string (teal omitted).
        var publicColor: String? = nil
        if let color, !color.isEmpty {
            guard publicListColors.contains(normalizeListColorName(color)) else {
                return .error("unsupported list color \(WriteFormatting.pyRepr(color)). Use \(publicListColorExamples).")
            }
            // cmd_list_create:6122-6123 sends the RAW color value (not the normalized form) to the bridge.
            publicColor = color
        }

        // 3. Create. On a caught WriteError, re-wrap to match cmd_list_create:6134.
        do {
            _ = try await writer.createList(title: name, color: publicColor)
        } catch let e as WriteError {
            let suffix = e.message.isEmpty ? "" : ": \(e.message)"
            throw WriteError("Failed to create list '\(name)'\(suffix)", exitCode: e.exitCode)
        }

        // 4. Output.
        if json {
            let obj: JSONValue = .object([("status", .string("created")), ("name", .string(name))])
            return .ok(obj.serialized(indent: nil, ensureAscii: true) + "\n")
        }
        return .ok("Created list: \(safeDisplay(name))\n")
    }

    private static func phase3(_ flag: String) -> WriteError {
        WriteError("\(flag) requires the private metadata layer (Phase 3); not yet implemented.")
    }
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

struct ListRename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-rename", abstract: "Rename a list.")

    @Argument(help: "List name to rename") var name: String?
    @Argument(help: "New list name") var newName: String?
    @Option(name: .long, help: "Rename a list by stable numeric ID") var listId: Int?
    @Option(name: .customLong("new-name"), help: "New list name, useful with --list-id") var newNameOption: String?
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShell { store, writer in
            try await Self.perform(
                name: args.name, newNamePositional: args.newName, listId: args.listId,
                newNameOption: args.newNameOption, json: args.json, store: store, writer: writer)
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_list_rename` (remctl:6234).
    /// PHASE-2 DIVERGENCE: the `if not bridge_available(): Error: remctl-bridge required for list
    /// management` guard is MOOT (writer always present) and is NOT emitted.
    static func perform(
        name: String?, newNamePositional: String?, listId: Int?, newNameOption: String?,
        json: Bool, store: RemindersStore, writer: RemindersWriter
    ) async throws -> WriteOutcome {
        // 1. New-name precedence: `--new-name` OR positional `new_name` (remctl:6235). Both -> error.
        if newNameOption != nil && newNamePositional != nil {
            return .error("pass the new list name as an argument or --new-name, not both.")
        }
        guard let newName = newNameOption ?? newNamePositional, !newName.isEmpty else {
            return .error("pass a new list name.")
        }

        // 2. Resolve the target list. resolveRequiredListTarget's CLIErrors pass through (mapped to
        //    "Error: <msg>" exit 1). The RESOLVED title is sent to the writer, NOT the raw `name` arg.
        let target = try resolveRequiredListTarget(store: store, name: name, listId: listId)
        let targetName = target.title

        // 3. Rename. On a caught WriteError, re-wrap to match cmd_list_rename:6261.
        do {
            _ = try await writer.renameList(currentTitle: targetName, newTitle: newName)
        } catch let e as WriteError {
            let suffix = e.message.isEmpty ? "" : ": \(e.message)"
            throw WriteError("Failed to rename list '\(targetName)'\(suffix)", exitCode: e.exitCode)
        }

        // 4. Output.
        if json {
            let obj: JSONValue = .object([
                ("status", .string("renamed")),
                ("id", .int(target.id)),
                ("old_name", .string(targetName)),
                ("new_name", .string(newName)),
            ])
            return .ok(obj.serialized(indent: nil, ensureAscii: true) + "\n")
        }
        return .ok("Renamed: \(safeDisplay(targetName)) -> \(safeDisplay(newName))\n")
    }
}

struct ListDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-delete", abstract: "Delete a list.")

    @Argument(help: "List name to delete") var name: String?
    @Option(name: .long, help: "Delete a list by stable numeric ID") var listId: Int?
    @Flag(name: .long, help: "Skip the confirmation prompt") var force = false
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShell { store, writer in
            try await Self.perform(
                name: args.name, listId: args.listId, force: args.force, json: args.json,
                store: store, writer: writer, confirm: { prompt in
                    FileHandle.standardOutput.write(Data(prompt.utf8))
                    let line = readLine() ?? ""
                    return line.lowercased().hasPrefix("y")
                })
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_list_delete` (remctl:6264). `confirm` receives the
    /// full prompt string and returns the user's yes/no (default No: anything not starting with y/Y).
    /// PHASE-2 DIVERGENCE: the `if not bridge_available(): Error: remctl-bridge required for list
    /// management` guard is MOOT (writer always present) and is NOT emitted.
    static func perform(
        name: String?, listId: Int?, force: Bool, json: Bool,
        store: RemindersStore, writer: RemindersWriter, confirm: (_ prompt: String) -> Bool
    ) async throws -> WriteOutcome {
        // 1. Resolve the target list (CLIErrors pass through). RESOLVED title goes to the writer.
        let target = try resolveRequiredListTarget(store: store, name: name, listId: listId)
        let targetName = target.title

        // 2. Confirmation unless --force (remctl:6275-6279). The prompt fires even in --json mode;
        //    a non-"y" answer prints `Cancelled.` and returns exit 0 with NO JSON (plain text).
        if !force {
            let prompt = "Delete list '\(safeDisplay(targetName))'? This cannot be undone. [y/N] "
            guard confirm(prompt) else { return .ok("Cancelled.\n") }
        }

        // 3. Delete. On a caught WriteError, re-wrap to match cmd_list_delete:6291.
        do {
            _ = try await writer.deleteList(title: targetName)
        } catch let e as WriteError {
            let suffix = e.message.isEmpty ? "" : ": \(e.message)"
            throw WriteError("Failed to delete list '\(targetName)'\(suffix)", exitCode: e.exitCode)
        }

        // 4. Output.
        if json {
            let obj: JSONValue = .object([
                ("status", .string("deleted")),
                ("id", .int(target.id)),
                ("name", .string(targetName)),
            ])
            return .ok(obj.serialized(indent: nil, ensureAscii: true) + "\n")
        }
        return .ok("Deleted list: \(safeDisplay(targetName))\n")
    }
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
