import ArgumentParser
import Foundation

/// Port of `cmd_list_info` (upstream b8b601c): one list plus what writes into it need —
/// section ids for `--section-id` and sharees for `--assign`.
struct ListInfo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-info",
        abstract: "Show one list with its section ids and sharees.")
    @OptionGroup var opts: JSONOnlyOptions
    @Argument(help: "List name") var name: String?
    @Option(name: .long, help: "List by stable numeric ID") var listId: Int?

    func run() throws {
        Dispatch.runRead { store in
            let report = try listInfoReport(store: store, name: name, listId: listId)
            if opts.json {
                Dispatch.printJSON(report.json, ensureAscii: false)
                return
            }
            for line in report.lines(ansi: opts.ansi()) { print(line) }
        }
    }
}

/// One list's `lists --json` object together with its sections and sharees, in print order.
struct ListInfoReport {
    struct Section {
        let id: String?
        let name: String?
    }

    struct Sharee {
        let id: Int?
        let name: String
        let isCurrentUser: Bool
        /// `shareeToDict` output, reused verbatim for `--json`.
        let fields: [(String, JSONValue)]
    }

    let id: Int
    let title: String
    let listType: String
    /// `listToDict` for the list row — the object `lists --json` emits for it.
    let list: [(String, JSONValue)]
    /// The name the user typed, when it only matched case-insensitively or normalized.
    let resolvedFrom: String?
    let sections: [Section]
    let sharees: [Sharee]

    var json: JSONValue {
        var pairs = list
        if let resolvedFrom { pairs.append(("resolvedFrom", .string(resolvedFrom))) }
        pairs.append(("sections", .array(sections.map {
            .object([("id", $0.id.map(JSONValue.string) ?? .null),
                     ("name", $0.name.map(JSONValue.string) ?? .null)])
        })))
        pairs.append(("sharees", .array(sharees.map { .object($0.fields) })))
        pairs.append(("shared", .bool(!sharees.isEmpty)))
        return .object(pairs)
    }

    func lines(ansi: Ansi) -> [String] {
        var out = [
            "\(ansi.bold(safeDisplay(title))) \(ansi.dim("(id: \(id))"))",
            "Type: \(listType)",
        ]
        if sections.isEmpty {
            out.append("Sections: none")
        } else {
            out.append("Sections:")
            out += sections.map { "  - \(safeDisplay($0.name)) \(ansi.dim("(\($0.id ?? "?"))"))" }
        }
        if sharees.isEmpty {
            out.append("Not shared")
        } else {
            out.append("Shared with:")
            out += sharees.map { sharee in
                let current = sharee.isCurrentUser ? ansi.dim(" (me)") : ""
                let idText = ansi.dim("(id: \(sharee.id.map(String.init) ?? "?"))")
                return "  - \(safeDisplay(sharee.name))\(current) \(idText)"
            }
        }
        return out
    }
}

/// Resolve the list and gather everything `list-info` prints. Throws the shared list-resolution
/// errors, so a list group is refused here exactly as it is for `sharees`.
func listInfoReport(store: RemindersStore, name: String?, listId: Int?) throws -> ListInfoReport {
    let target = try resolveRequiredListTarget(store: store, name: name, listId: listId)
    let row = store.listRowByPkFull(target.id)
    let list: [(String, JSONValue)] = row.map(listToDict)
        ?? [("id", .int(target.id)), ("title", .string(target.title))]
    let method = store.resolveListRefWithMethod(name: name, listId: listId).method
    let ownerCkid = store.listSharedOwnerCkid(listPk: target.id)
    return ListInfoReport(
        id: target.id,
        title: target.title,
        listType: listInfoListType(list),
        list: list,
        resolvedFrom: method == "exact" || method == "id" ? nil : name,
        sections: store.sections(listPk: target.id).map {
            ListInfoReport.Section(id: $0.string("ZCKIDENTIFIER"), name: $0.string("ZDISPLAYNAME"))
        },
        sharees: store.sharees(listPk: target.id).map { row in
            ListInfoReport.Sharee(
                id: row.int("Z_PK"),
                name: shareeDisplayName(row),
                isCurrentUser: ckidEq(row.string("ZCKIDENTIFIER"), ownerCkid),
                fields: shareeToDict(row, currentUserCkid: ownerCkid))
        })
}

/// `payload.get("listType", "standard")`: the fallback `{id, title}` object carries no type.
private func listInfoListType(_ list: [(String, JSONValue)]) -> String {
    guard case let .string(type)? = list.first(where: { $0.0 == "listType" })?.1 else { return "standard" }
    return type
}
