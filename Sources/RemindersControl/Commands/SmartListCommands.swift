import ArgumentParser
import Foundation

let smartListCommands: [ParsableCommand.Type] = [
    SmartLists.self, SmartListCreate.self, SmartListEdit.self, SmartListDelete.self,
]

struct SmartLists: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-lists", abstract: "List smart lists.")
    @OptionGroup var opts: JSONOnlyOptions

    func run() throws {
        Dispatch.runRead { store in
            let payloads = store.smartLists().map { smartListToDict($0) }
            if opts.json {
                Dispatch.printJSON(.array(payloads.map { .object($0) }), ensureAscii: false)
                return
            }
            let ansi = opts.ansi()
            if payloads.isEmpty { print("No smart lists"); return }
            print(ansi.bold("Smart Lists:"))
            for item in payloads {
                let d = Dictionary(item, uniquingKeysWith: { a, _ in a })
                func str(_ k: String) -> String? { if case let .string(v)? = d[k] { return v }; return nil }
                func intOf(_ k: String) -> Int { if case let .int(v)? = d[k] { return v }; return 0 }
                let kind = str("kind") ?? "built-in"
                let smartType = str("smartListType") ?? "(none)"
                let length = intOf("filterLength")
                let isPinned: Bool = { if case let .bool(v)? = d["pinned"] { return v }; return false }()
                // filter summary description
                var desc = "No filter data"
                var supported = true
                var keys: [String] = []
                if case let .object(summary)? = d["filter"] {
                    let sd = Dictionary(summary, uniquingKeysWith: { a, _ in a })
                    if case let .string(v)? = sd["description"], !v.isEmpty { desc = v }
                    if case let .bool(s)? = sd["supported"] { supported = s }
                    if case let .array(ks)? = sd["keys"] { keys = ks.compactMap { if case let .string(s) = $0 { return s } else { return nil } } }
                }
                var line = safeDisplay(desc)
                if d["filter"] != nil, !supported {
                    let keyStr = keys.isEmpty ? "unknown keys" : keys.joined(separator: ", ")
                    line = "\(line): \(safeDisplay(keyStr))"
                }
                let pinInfo = isPinned ? ansi.dim(" [pinned]") : ""
                print("  \(safeDisplay(str("name"))) \(ansi.dim("(id: \(intOf("id")), \(kind))"))\(pinInfo)")
                print("    \(smartType) · filter bytes: \(length) · \(line)")
            }
            let n = payloads.count
            print("\n\(n) smart list\(n == 1 ? "" : "s")")
        }
    }
}

struct SmartListCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-list-create", abstract: "Create a smart list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("smart-list-create") }
}

struct SmartListEdit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-list-edit", abstract: "Edit a smart list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("smart-list-edit") }
}

struct SmartListDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-list-delete", abstract: "Delete a smart list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("smart-list-delete") }
}
