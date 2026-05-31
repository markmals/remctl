import ArgumentParser
import Foundation
import AppKit

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
/// IS a valid/accepted color. Hex colors (#RRGGBB) are also accepted (private path).
private let publicListColors: Set<String> = [
    "red", "orange", "yellow", "green", "blue", "purple", "brown", "gray", "cyan", "teal",
]

/// `^#[0-9A-Fa-f]{6}$` check for routing (mirrors HEX_COLOR_RE, remctl:227).
private func isHexColor(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.count == 7, trimmed.hasPrefix("#") else { return false }
    return trimmed.dropFirst().allSatisfy { "0123456789ABCDEFabcdef".contains($0) }
}

struct ListCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-create", abstract: "Create a list.")

    @Argument(help: "List title") var name: String
    @Option(name: .long, help: "List color name: red, orange, yellow, green, blue, purple, brown, gray, cyan, or teal") var color: String?

    // Declared but Phase-3 (private ReminderKit metadata) — stubbed. `--private` is removed
    // project-wide in Phase 2, so these always refuse.
    @Option(name: .long, help: "Official Reminders list symbol name") var symbol: String?
    @Option(name: .long, help: "Emoji badge") var emoji: String?
    @Flag(name: .long, help: "Create as a Groceries list") var groceries = false
    @Option(name: .long, help: "Groceries locale identifier, e.g. en_US") var groceryLocale: String?

    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellBoth { _, writer, priv in
            try await Self.perform(
                name: args.name, color: args.color, symbol: args.symbol, emoji: args.emoji,
                groceries: args.groceries, groceryLocale: args.groceryLocale, json: args.json,
                writer: writer, priv: priv)
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_list_create` (remctl:6085).
    /// Routes to the private path (ReminderKit `create_list`) when hex color, symbol, emoji,
    /// or grocery metadata is present; otherwise stays on the public EventKit path.
    /// PHASE-2 DIVERGENCE: the Python `if not bridge_available()` guard is MOOT (writer always
    /// present). The duplicate-name preflight (private-only) is likewise dropped.
    static func perform(
        name: String, color: String? = nil, symbol: String? = nil, emoji: String? = nil,
        groceries: Bool = false, standard: Bool = false, groceryLocale: String? = nil,
        json: Bool, writer: RemindersWriter, priv: PrivateWriter
    ) async throws -> WriteOutcome {
        // 1. Validate appearance args using P5 hex-allowed validators.
        //    CLIErrors propagate out and are mapped to "Error: <msg>" exit 1 by WriteDispatch.perform.
        try validateListAppearanceArgs(
            color: color, symbol: symbol, emoji: emoji,
            groceries: groceries, standard: standard, groceryLocale: groceryLocale)

        // 2. Decide path: private when hex color, symbol, emoji, groceries, standard, or grocery-locale.
        let privateNeeded = symbol != nil || emoji != nil || groceries || standard
            || (groceryLocale != nil && !(groceryLocale!.isEmpty))
            || (color.map { isHexColor($0) } ?? false)

        if privateNeeded {
            // 3a. PRIVATE PATH: build appearance and call priv.createList.
            let appearance = buildListAppearance(
                newName: nil, color: color, symbol: symbol, emoji: emoji,
                groceries: groceries, standard: standard, groceryLocale: groceryLocale)

            let result: PrivateResult
            do {
                result = try await priv.createList(name: name, appearance: appearance)
            } catch let e as WriteError {
                let suffix = e.message.isEmpty ? "" : ": \(e.message)"
                throw WriteError("Failed to create list '\(name)'\(suffix)", exitCode: e.exitCode)
            }

            guard result.status == "created" else {
                let msg = result.message ?? ""
                let suffix = msg.isEmpty ? "" : ": \(msg)"
                throw WriteError("Failed to create list '\(name)'\(suffix)")
            }

            // 4a. Output — private path.
            if json {
                var privatePairs: [(String, JSONValue)] = [("status", .string(result.status))]
                for key in result.fields.keys.sorted() {
                    privatePairs.append((key, result.fields[key]!))
                }
                let obj: JSONValue = .object([
                    ("status", .string("created")),
                    ("name", .string(name)),
                    ("private", .object(privatePairs)),
                ])
                return .ok(obj.serialized(indent: nil, ensureAscii: false) + "\n")
            }

            // Human output: "Created list: <name>\n" + optional metadata line.
            // Details in order: color, symbol, emoji, groceries locale (cmd_list_create:6109-6116).
            var details: [String] = []
            if let color, !color.isEmpty {
                details.append("color=\(normalizeListColor(color) ?? color)")
            }
            if let symbol, !symbol.isEmpty { details.append("symbol=\(symbol)") }
            if let emoji, !emoji.isEmpty { details.append("emoji=\(emoji)") }
            if groceries {
                let loc = groceryLocale.flatMap { try? normalizeGroceryLocale($0) } ?? defaultGroceryLocaleID
                details.append("groceries locale=\(loc)")
            }

            var out = "Created list: \(safeDisplay(name))\n"
            if !details.isEmpty {
                out += "Applied private metadata: \(details.joined(separator: ", "))\n"
            }
            return .ok(out)
        }

        // 3b. PUBLIC PATH (EventKit): existing Phase-2 behavior, byte-for-byte.
        // Validate color (named only — hex already handled above via privateNeeded).
        var publicColor: String? = nil
        if let color, !color.isEmpty {
            // cmd_list_create:6122-6123 sends the RAW color value to the bridge.
            publicColor = color
        }

        do {
            _ = try await writer.createList(title: name, color: publicColor)
        } catch let e as WriteError {
            let suffix = e.message.isEmpty ? "" : ": \(e.message)"
            throw WriteError("Failed to create list '\(name)'\(suffix)", exitCode: e.exitCode)
        }

        // 4b. Output — public path.
        if json {
            let obj: JSONValue = .object([("status", .string("created")), ("name", .string(name))])
            return .ok(obj.serialized(indent: nil, ensureAscii: true) + "\n")
        }
        return .ok("Created list: \(safeDisplay(name))\n")
    }
}

struct ListEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-edit", abstract: "Edit a list's appearance.")

    @Argument(help: "List name to edit") var name: String?
    @Option(name: .long, help: "Edit a list by stable numeric ID") var listId: Int?
    @Option(name: .customLong("new-name"), help: "New list name") var newName: String?
    @Option(name: .long, help: "List color name or #RRGGBB hex") var color: String?
    @Option(name: .long, help: "Official Reminders list symbol name") var symbol: String?
    @Option(name: .long, help: "Emoji badge") var emoji: String?
    @Flag(name: .long, help: "Set list type to Groceries") var groceries = false
    @Flag(name: .long, help: "Set list type to Standard") var standard = false
    @Option(name: .customLong("grocery-locale"), help: "Groceries locale identifier, e.g. en_US") var groceryLocale: String?
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate { store, priv in
            try await Self.perform(
                name: args.name, listId: args.listId, newName: args.newName,
                color: args.color, symbol: args.symbol, emoji: args.emoji,
                groceries: args.groceries, standard: args.standard,
                groceryLocale: args.groceryLocale, json: args.json,
                store: store, private: priv)
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_list_edit` (remctl:6137).
    static func perform(
        name: String?, listId: Int?,
        newName: String?, color: String?, symbol: String?, emoji: String?,
        groceries: Bool, standard: Bool, groceryLocale: String?,
        json: Bool,
        store: RemindersStore, private priv: PrivateWriter
    ) async throws -> WriteOutcome {
        // 1. Structural validation (symbol XOR emoji, unknown symbol, bad color, groceries XOR standard, etc.)
        //    CLIErrors from these validators propagate out and are mapped by WriteDispatch.perform to
        //    "Error: <msg>" exit 1.
        try validateListAppearanceArgs(
            color: color, symbol: symbol, emoji: emoji,
            groceries: groceries, standard: standard, groceryLocale: groceryLocale)

        // 2. No-change guard: at least one edit flag must be supplied.
        let hasChange = newName != nil || color != nil || symbol != nil || emoji != nil
            || groceries || standard || (groceryLocale != nil && !(groceryLocale!.isEmpty))
        if !hasChange {
            return .error("pass at least one of --new-name, --color, --symbol, --emoji, --groceries, --standard, or --grocery-locale.")
        }

        // 3. Resolve the target list. CLIErrors (not-both / no-target / not-found / ambiguous) propagate.
        let target = try resolveRequiredListTarget(store: store, name: name, listId: listId)

        // 4. Require a stable CloudKit identifier.
        guard let ckid = store.listCkid(pk: target.id), !ckid.isEmpty else {
            return .error("target list has no stable CloudKit identifier.")
        }

        // 5. Build the appearance payload and invoke the private writer.
        let appearance = buildListAppearance(
            newName: newName, color: color, symbol: symbol, emoji: emoji,
            groceries: groceries, standard: standard, groceryLocale: groceryLocale)

        let result: PrivateResult
        do {
            result = try await priv.setListAppearance(listId: ckid, appearance: appearance)
        } catch let e as WriteError {
            return .error(e.message)
        } catch {
            return .error("\(error)")
        }

        guard result.status == "updated" else {
            return .error(result.message ?? "private helper failed")
        }

        // 6. output_name = --new-name if given, else the RESOLVED current title.
        let outputName = newName ?? target.title

        // 7. Output.
        if json {
            var privatePairs: [(String, JSONValue)] = [("status", .string(result.status))]
            for key in result.fields.keys.sorted() {
                privatePairs.append((key, result.fields[key]!))
            }
            let obj: JSONValue = .object([
                ("status", .string("updated")),
                ("id", .int(target.id)),
                ("name", .string(outputName)),
                ("private", .object(privatePairs)),
            ])
            return .ok(obj.serialized(indent: nil, ensureAscii: false) + "\n")
        }
        return .ok("Updated list: \(safeDisplay(outputName))\n")
    }
}

struct ListPin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-pin", abstract: "Pin a list.")

    @Argument(help: "List or smart-list name") var name: String?
    @Option(name: .long, help: "Pin a regular list by stable numeric ID") var listId: Int?
    @Option(name: .long, help: "Pin a smart list by stable numeric ID") var smartListId: Int?
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate { store, priv in
            try await Self.performPin(
                name: args.name, listId: args.listId, smartListId: args.smartListId,
                pinned: true, json: args.json, store: store, private: priv)
        })
    }

    /// Shared core for `list-pin` and `list-unpin`, parameterised by `pinned`.
    /// Mirrors `_cmd_list_pin_state` (remctl:6162).
    static func performPin(
        name: String?, listId: Int?, smartListId: Int?,
        pinned: Bool, json: Bool,
        store: RemindersStore, private priv: PrivateWriter
    ) async throws -> WriteOutcome {
        // 1. Reject both --list-id AND --smart-list-id together.
        if listId != nil && smartListId != nil {
            return .error("pass either --list-id or --smart-list-id, not both.")
        }

        // 2. Require at least one of: name, --list-id, --smart-list-id.
        let hasName = name != nil && !(name!.isEmpty)
        if !hasName && listId == nil && smartListId == nil {
            return .error("pass a list/smart-list name, --list-id, or --smart-list-id.")
        }

        // 3. Branch by target type.
        let targetId: Int
        let targetTitle: String
        let targetKind: String   // "list" or "smart-list" (used in JSON kind + human label)
        let ckid: String

        if let smartListId {
            // --smart-list-id path: resolve smart list by id.
            switch store.resolveSmartListRef(name: nil, smartListId: smartListId) {
            case .found(let id, let title, _):
                targetId = id; targetTitle = title; targetKind = "smart-list"
                guard let c = store.smartListCkid(pk: id), !c.isEmpty else {
                    return .error("target smart list has no stable CloudKit identifier.")
                }
                ckid = c
            case .ambiguous, .notFound:
                return .error("smart list not found: id \(smartListId)")
            }
        } else if let listId {
            // --list-id path: resolve regular list by id.
            switch store.resolveListRef(name: nil, listId: listId) {
            case .found(let id, let title, _):
                targetId = id; targetTitle = title; targetKind = "list"
                guard let c = store.listCkid(pk: id), !c.isEmpty else {
                    return .error("target list has no stable CloudKit identifier.")
                }
                ckid = c
            case .ambiguous, .notFound:
                return .error("list not found: id \(listId)")
            }
        } else {
            // Name path: dual-resolve — call BOTH resolvers.
            let nameStr = name ?? ""
            let listRes  = store.resolveListRef(name: nameStr, listId: nil)
            let smartRes = store.resolveSmartListRef(name: nameStr, smartListId: nil)

            // Ambiguous in EITHER kind fires before the both-match check (match Python ordering).
            if case .ambiguous(let candidates) = listRes {
                let options = candidates.map { "\($0.id) (\($0.title))" }.joined(separator: ", ")
                return .error("multiple lists match \(WriteFormatting.pyRepr(nameStr)). Use the exact list name or --list-id with one of: \(options)")
            }
            if case .ambiguous(let candidates) = smartRes {
                let options = candidates.map { "\($0.id) (\($0.title))" }.joined(separator: ", ")
                return .error("multiple smart lists match \(WriteFormatting.pyRepr(nameStr)). Use the exact smart-list name or --smart-list-id with one of: \(options)")
            }

            let listFound  = if case .found = listRes { true } else { false }
            let smartFound = if case .found = smartRes { true } else { false }

            if listFound && smartFound {
                return .error("\(WriteFormatting.pyRepr(nameStr)) matches both a list and a smart list. Use --list-id or --smart-list-id.")
            }

            if case .found(let id, let title, _) = listRes, listFound {
                targetId = id; targetTitle = title; targetKind = "list"
                guard let c = store.listCkid(pk: id), !c.isEmpty else {
                    return .error("target list has no stable CloudKit identifier.")
                }
                ckid = c
            } else if case .found(let id, let title, _) = smartRes, smartFound {
                targetId = id; targetTitle = title; targetKind = "smart-list"
                guard let c = store.smartListCkid(pk: id), !c.isEmpty else {
                    return .error("target smart list has no stable CloudKit identifier.")
                }
                ckid = c
            } else {
                return .error("list or smart list not found: \(nameStr)")
            }
        }

        // 4. Call the private writer.
        let result: PrivateResult
        do {
            result = try await (targetKind == "smart-list"
                ? priv.setSmartListPinned(smartListId: ckid, pinned: pinned)
                : priv.setListPinned(listId: ckid, pinned: pinned))
        } catch let e as WriteError {
            return .error(e.message)
        } catch {
            return .error("\(error)")
        }

        guard result.status == "updated" else {
            return .error(result.message ?? "private helper failed")
        }

        // 5. Output.
        let status = pinned ? "pinned" : "unpinned"
        if json {
            // Build private sub-object: status first, then echoed fields (sorted by key for stability).
            var privatePairs: [(String, JSONValue)] = [("status", .string(result.status))]
            for key in result.fields.keys.sorted() {
                privatePairs.append((key, result.fields[key]!))
            }
            let obj: JSONValue = .object([
                ("status", .string(status)),
                ("kind", .string(targetKind)),
                ("id", .int(targetId)),
                ("name", .string(targetTitle)),
                ("private", .object(privatePairs)),
            ])
            return .ok(obj.serialized(indent: nil, ensureAscii: false) + "\n")
        }
        let label = targetKind == "smart-list" ? "smart list" : "list"   // SPACE in human output
        return .ok("\(pinned ? "Pinned" : "Unpinned") \(label): \(safeDisplay(targetTitle))\n")
    }
}

struct ListUnpin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-unpin", abstract: "Unpin a list.")

    @Argument(help: "List or smart-list name") var name: String?
    @Option(name: .long, help: "Unpin a regular list by stable numeric ID") var listId: Int?
    @Option(name: .long, help: "Unpin a smart list by stable numeric ID") var smartListId: Int?
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate { store, priv in
            try await ListPin.performPin(
                name: args.name, listId: args.listId, smartListId: args.smartListId,
                pinned: false, json: args.json, store: store, private: priv)
        })
    }
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
    // Python `--html nargs='?' const=''` (remctl:7831) is a three-state flag: omitted → nil;
    // bare `--html` → write to the default path; `--html PATH` → write to PATH. ArgumentParser
    // can't bind an optional array, so a non-producible sentinel default distinguishes omission
    // (`htmlSentinel`) from a bare flag (`[]`) from `--html PATH` (`["PATH"]`). See `resolvedHTMLArg`.
    @Option(name: .long, parsing: .upToNextOption,
            help: "Write a standalone HTML preview contact sheet (optionally to PATH)") var html: [String] = Self.htmlSentinel
    static let htmlSentinel = ["\u{0}__remctl_html_absent__"]

    /// Collapse the three-state `--html` array to Python's nargs='?'/const='' value:
    /// sentinel (omitted) → nil; [] (bare --html) → ""; ["PATH", ...] → first element.
    var resolvedHTMLArg: String? {
        if html == Self.htmlSentinel { return nil }
        return html.first ?? ""
    }
    @Flag(name: .long, help: "Generate and open the HTML preview contact sheet") var preview = false
    @Flag(name: .long, help: "Disable ANSI color") var noColor = false

    /// Left-justify to width using raw character count (matches Python f"{s:<w}").
    private func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }

    func run() throws {
        // --html / --preview: write a standalone HTML badge contact-sheet. Preserve the
        // mutual-exclusion error, then run the testable core with the real seams.
        let htmlArg = resolvedHTMLArg
        if htmlArg != nil || preview {
            if json {
                FileHandle.standardError.write(Data("Error: --json cannot be combined with --html or --preview.\n".utf8))
                Foundation.exit(1)
            }
            let outcome = try Self.performHTML(
                htmlArg: htmlArg, preview: preview,
                exportAssets: Self.exportBadgeAssets,
                launch: Open.launchWithOpen)
            if !outcome.stdout.isEmpty { print(outcome.stdout, terminator: "") }
            if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
            return
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

    struct HTMLOutcome { let stdout: String; let exitCode: Int32 }

    /// Testable core for `--html`/`--preview` (ports write_list_symbols_html + the
    /// cmd_list_symbols html branch, remctl:5035/5044). Pure of GUI side effects when
    /// `exportAssets` and `launch` are injected.
    ///
    /// Path resolution mirrors Python's `--html` nargs='?' const='' → default mapping:
    ///   * `htmlArg == nil`  (no --html; e.g. bare --preview) → default CONFIG_DIR path
    ///   * `htmlArg == ""`   (bare --html)                    → default CONFIG_DIR path
    ///   * `htmlArg == PATH` (--html PATH)                    → PATH with `~` expanded
    ///
    /// GRACEFUL-DEGRADE deviation: unlike Python (which exit-1s when Swift or the
    /// RemindersUICore framework is absent), this ALWAYS writes a sheet and succeeds.
    /// A missing framework simply yields an empty `exportAssets` result → glyph-only sheet.
    static func performHTML(
        htmlArg: String?,
        preview: Bool,
        env: [String: String] = ProcessInfo.processInfo.environment,
        exportAssets: ([String]) -> [String: Data],
        launch: ([String]) -> Void
    ) throws -> HTMLOutcome {
        let rows = officialListSymbols
        let outputURL: URL
        if let htmlArg, !htmlArg.isEmpty {
            outputURL = URL(fileURLWithPath: (htmlArg as NSString).expandingTildeInPath)
        } else {
            outputURL = Paths.resolveConfigDir(env: env).appendingPathComponent("list-symbols.html")
        }

        // Build a name→PNG dict via the injected exporter (assets that miss are simply
        // absent → the matching card renders its fallback glyph).
        let exported = exportAssets(rows.map { $0.asset })
        let html = buildListSymbolsHTML(rows: rows, imageDataByAsset: exported)

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try html.data(using: .utf8)!.write(to: outputURL)

        if preview { launch([outputURL.path]) }
        return HTMLOutcome(stdout: "HTML preview: \(outputURL.path)\n", exitCode: 0)
    }

    /// In-process AppKit asset export (the impure half; NOT CI-tested — the
    /// RemindersUICore private framework is absent in CI). Loads the framework bundle,
    /// renders each `bundle.image(forResource:)` to PNG, and collects successes only.
    /// Per-asset misses are omitted; an entirely-missing framework returns `[:]` (the
    /// caller then writes a glyph-only sheet). Replaces Python's `swift -` subprocess.
    static func exportBadgeAssets(_ names: [String]) -> [String: Data] {
        let bundlePath = "/System/Library/PrivateFrameworks/RemindersUICore.framework"
        guard let bundle = Bundle(path: bundlePath) else {
            FileHandle.standardError.write(Data(
                "Note: RemindersUICore framework not found; the preview uses text glyphs only.\n".utf8))
            return [:]
        }
        var out: [String: Data] = [:]
        for asset in names {
            guard let image = bundle.image(forResource: asset),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { continue }
            out[asset] = png
        }
        return out
    }
}
