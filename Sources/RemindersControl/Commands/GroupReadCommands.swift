import ArgumentParser
import Foundation
import GRDB

struct Groups: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "groups", abstract: "List Reminders list groups.")
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false
    @Option(name: .long, help: "Output format") var format: OutputFormat?
    @Flag(name: .long, help: "Disable ANSI color") var noColor = false

    /// Port of `cmd_groups` (upstream e013fb9): each group with its child lists, in Reminders'
    /// child order, and their reminder counts.
    func run() throws {
        Dispatch.runRead(json: json) { store in
            let (groups, childRows, _) = splitListGroupRows(store.lists(includeGroups: true))
            let counts = store.listReminderCounts(listPks: childRows.values.flatMap { $0.compactMap { $0.int("Z_PK") } })
            let payloads = groups.map { group in
                groupPayloadFromRows(group, children: childRows[group.int("Z_PK") ?? 0] ?? [], counts: counts)
            }
            if json || format == .json {
                Dispatch.printJSON(.array(payloads.map { .object($0) }), ensureAscii: false)
                return
            }
            let ansi = Ansi.resolve(noColorFlag: noColor)
            if format == .table {
                print(fmtColumns(headers: ["ID", "Title", "Group", "Active", "Done", "Total"],
                                 rows: Self.tableRows(groups: groups, childRows: childRows, counts: counts),
                                 titleIndex: 1, ansi: ansi))
                return
            }
            guard !groups.isEmpty else { print("No Reminders list groups found."); return }
            Self.printGroups(groups: groups, childRows: childRows, counts: counts, ansi: ansi)
        }
    }

    private static func tableRows(groups: [Row], childRows: [Int: [Row]], counts: [Int: ListReminderCounts]) -> [[String]] {
        func countCells(_ c: ListReminderCounts) -> [String] { ["\(c.active)", "\(c.completed)", "\(c.total)"] }
        return groups.flatMap { group -> [[String]] in
            let groupName = group.string("ZNAME") ?? ""
            let children = childRows[group.int("Z_PK") ?? 0] ?? []
            let childCounts = children.map { counts[$0.int("Z_PK") ?? 0] ?? ListReminderCounts() }
            let total = childCounts.reduce(into: ListReminderCounts()) {
                $0.active += $1.active; $0.completed += $1.completed; $0.total += $1.total
            }
            let groupRow = ["\(group.int("Z_PK") ?? 0)", safeDisplay(groupName), ""] + countCells(total)
            let rows = zip(children, childCounts).map { child, c in
                ["\(child.int("Z_PK") ?? 0)", "  \(listTitle(child))", safeDisplay(groupName)] + countCells(c)
            }
            return [groupRow] + rows
        }
    }

    private static func printGroups(groups: [Row], childRows: [Int: [Row]], counts: [Int: ListReminderCounts], ansi: Ansi) {
        print(ansi.bold("Reminder List Groups:"))
        for group in groups {
            let children = childRows[group.int("Z_PK") ?? 0] ?? []
            let childCounts = children.map { counts[$0.int("Z_PK") ?? 0] ?? ListReminderCounts() }
            let active = childCounts.reduce(0) { $0 + $1.active }
            let completed = childCounts.reduce(0) { $0 + $1.completed }
            let info = ansi.dim(" [\(active) active, \(completed) completed, \(children.count) lists]")
            print("  \(colorListName(group.string("ZNAME"), ansi: ansi)) \(ansi.dim("(id: \(group.int("Z_PK") ?? 0))"))\(info)")
            for (child, c) in zip(children, childCounts) {
                let childInfo = ansi.dim(" [\(c.active) active, \(c.completed) completed]")
                print("    \(listTitle(child, ansi: ansi)) \(ansi.dim("(id: \(child.int("Z_PK") ?? 0))"))\(childInfo)")
            }
        }
        print("\n\(groups.count) group\(groups.count == 1 ? "" : "s")")
    }
}

/// A list's title as list views print it: colored when `ansi` is on, with the Groceries marker.
private func listTitle(_ row: Row, ansi: Ansi? = nil) -> String {
    let name = ansi.map { colorListName(row.string("ZNAME"), ansi: $0) } ?? safeDisplay(row.string("ZNAME"))
    return isGroceryListRow(row) ? "\(name) \(Constants.groceryListMarker)" : name
}

struct GroupInfo: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "group-info", abstract: "Show one Reminders list group.")
    @Argument(help: "Group name") var name: String?
    @Option(name: .long, help: "Read by numeric group ID from groups") var groupId: Int?
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false

    /// Port of `cmd_group_info` (upstream e013fb9): the group, its child lists with counts, and the
    /// commands that act on it.
    func run() throws {
        Dispatch.runRead(json: json) { store in
            let group = try resolveRequiredGroupTarget(store: store, name: name, groupId: groupId)
            let counts = store.listReminderCounts(listPks: group.children.compactMap { $0.int("Z_PK") })
            if json {
                Dispatch.printJSON(.object(Self.payload(group, counts: counts)), ensureAscii: false)
            } else {
                Self.printGroup(group, counts: counts)
            }
        }
    }

    static func payload(_ group: GroupTarget, counts: [Int: ListReminderCounts]) -> [(String, JSONValue)] {
        var total = ListReminderCounts()
        let children: [JSONValue] = group.children.map { child in
            let c = counts[child.int("Z_PK") ?? 0] ?? ListReminderCounts()
            total.active += c.active; total.completed += c.completed; total.total += c.total
            return .object(listRefPayload(child, requested: nil, method: "exact") + [("counts", c.payload)])
        }
        let commands = suggestedCommands(group.title).map { ($0.key, JSONValue.string($0.command)) }
        return listRefPayload(group.row, requested: group.requested, method: group.method)
            + [("counts", total.payload), ("children", .array(children)), ("suggestedCommands", .object(commands))]
    }

    /// Port of `group_suggested_commands`.
    static func suggestedCommands(_ title: String) -> [(key: String, command: String)] {
        let quoted = WriteFormatting.shellQuote(title)
        let cli = CLIName.current
        return [
            ("show", "\(cli) show \(quoted)"),
            ("showTable", "\(cli) show \(quoted) --format table"),
            ("addList", "\(cli) group-edit \(quoted) --add-list LIST"),
            ("moveList", "\(cli) group-edit \(quoted) --move-list LIST --before-list SIBLING"),
            ("createList", "\(cli) list-create LIST --group \(quoted)"),
            ("delete", "\(cli) group-delete \(quoted) --force"),
        ]
    }

    private static func printGroup(_ group: GroupTarget, counts: [Int: ListReminderCounts]) {
        let childCounts = group.children.map { counts[$0.int("Z_PK") ?? 0] ?? ListReminderCounts() }
        let total = childCounts.reduce(into: ListReminderCounts()) {
            $0.active += $1.active; $0.completed += $1.completed; $0.total += $1.total
        }
        print(Ansi.resolve(noColorFlag: false).bold("Group: \(safeDisplay(group.title))"))
        print("  ID: \(group.id)")
        if let uuid = group.objectUUID { print("  Object UUID: \(uuid)") }
        print("  Counts: \(total.active) active, \(total.completed) completed, \(total.total) total")
        if group.children.isEmpty {
            print("\nNo child lists.")
        } else {
            print("\nChild Lists:")
            for (child, c) in zip(group.children, childCounts) {
                print("  \(safeDisplay(child.string("ZNAME"))) (id: \(child.int("Z_PK") ?? 0)) - "
                      + "\(c.active) active, \(c.completed) completed, \(c.total) total")
            }
        }
        print("\nSuggested Commands:")
        for (_, command) in suggestedCommands(group.title) { print("  \(command)") }
    }
}
