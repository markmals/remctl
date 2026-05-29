import ArgumentParser
import Foundation
import GRDB

let templateCommands: [ParsableCommand.Type] = [
    Templates.self, TemplateInfo.self, TemplateCreate.self, TemplateApply.self, TemplateDelete.self,
]

struct Templates: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "templates", abstract: "List templates.")
    @OptionGroup var opts: JSONOnlyOptions

    func run() throws {
        Dispatch.runRead { store in
            let payloads = store.templates().map { templateToDict($0) }
            if opts.json {
                Dispatch.printJSON(.array(payloads.map { .object($0) }), ensureAscii: false)
                return
            }
            let ansi = opts.ansi()
            if payloads.isEmpty { print("No templates"); return }
            print(ansi.bold("Templates:"))
            for item in payloads {
                let d = Dictionary(item, uniquingKeysWith: { a, _ in a })
                func intOf(_ k: String) -> Int { if case let .int(v)? = d[k] { return v }; return 0 }
                let name: String = { if case let .string(s)? = d["name"] { return s }; return "" }()
                let itemCount = intOf("itemCount")
                var bits = ["id: \(intOf("id"))", "\(itemCount) item\(itemCount == 1 ? "" : "s")"]
                let secCount = intOf("sectionCount")
                if secCount != 0 { bits.append("\(secCount) section\(secCount == 1 ? "" : "s")") }
                if d["publicLink"] != nil { bits.append("shared") }
                print("  \(safeDisplay(name)) \(ansi.dim("(" + bits.joined(separator: ", ") + ")"))")
            }
            let n = payloads.count
            print("\n\(n) template\(n == 1 ? "" : "s")")
        }
    }
}

struct TemplateInfo: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-info", abstract: "Show template details.")
    @OptionGroup var opts: JSONOnlyOptions
    @Argument(help: "Template name") var name: String?
    @Option(name: .long, help: "Read by numeric template ID") var templateId: Int?

    func run() throws {
        Dispatch.runRead { store in
            let id = try resolveRequiredTemplateTarget(store: store, name: name, templateId: templateId)
            guard let row = store.templateMatches(templateId: id).first else {
                throw CLIError("template not found: id \(id)")
            }
            let payload = templateToDict(row, store: store, includeItems: true)
            if opts.json {
                Dispatch.printJSON(.object(payload), ensureAscii: false)
                return
            }
            let ansi = opts.ansi()
            let d = Dictionary(payload, uniquingKeysWith: { a, _ in a })
            func str(_ k: String) -> String? { if case let .string(v)? = d[k] { return v }; return nil }
            func intOf(_ k: String) -> Int { if case let .int(v)? = d[k] { return v }; return 0 }
            print(ansi.bold(safeDisplay(str("name"))))
            print("ID: \(intOf("id"))")
            if let uuid = str("objectUUID") { print("Object UUID: \(uuid)") }
            if let link = str("deepLink") { print("Deep link: \(link)") }
            print("Items: \(intOf("itemCount"))")
            print("Sections: \(intOf("sectionCount"))")
            if case let .object(pub)? = d["publicLink"],
               let url = pub.first(where: { $0.0 == "url" }).flatMap({ if case let .string(s) = $0.1 { return s } else { return nil } }) {
                print("Existing public link: \(url)")
            }
            if case let .array(sections)? = d["sections"], !sections.isEmpty {
                print("\nSections:")
                for s in sections {
                    guard case let .object(sp) = s else { continue }
                    let sd = Dictionary(sp, uniquingKeysWith: { a, _ in a })
                    let sname: String = { if case let .string(v)? = sd["name"] { return v }; return "" }()
                    let sid: Int = { if case let .int(v)? = sd["id"] { return v }; return 0 }()
                    print("  \(safeDisplay(sname)) \(ansi.dim("(id: \(sid))"))")
                }
            }
            if case let .array(items)? = d["items"], !items.isEmpty {
                print("\nSaved Reminders:")
                let priMarker = ["high": "!!!", "medium": "!!", "low": "!"]
                for it in items {
                    guard case let .object(ip) = it else { continue }
                    let idd = Dictionary(ip, uniquingKeysWith: { a, _ in a })
                    let title: String = { if case let .string(v)? = idd["title"] { return v }; return "" }()
                    let pri: String = { if case let .string(v)? = idd["priority"] { return v }; return "none" }()
                    let priStr = priMarker[pri].map { " \($0)" } ?? ""
                    var tagStr = ""
                    if case let .array(tags)? = idd["tags"], !tags.isEmpty {
                        tagStr = " " + tags.compactMap { if case let .string(t) = $0 { return "#" + safeDisplay(t) } else { return nil } }.joined(separator: " ")
                    }
                    print("  - \(safeDisplay(title))\(priStr)\(tagStr)")
                }
            }
        }
    }
}

struct TemplateCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-create", abstract: "Create a template from a list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("template-create") }
}

struct TemplateApply: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-apply", abstract: "Create a list from a template.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("template-apply") }
}

struct TemplateDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-delete", abstract: "Delete a template.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("template-delete") }
}
