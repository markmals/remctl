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

/// Build the `private` JSON sub-object: `status` first, then echoed helper fields sorted by key
/// (same shape as smart-list/list-edit commands).
private func privateSubObject(_ result: PrivateResult) -> JSONValue {
    var pairs: [(String, JSONValue)] = [("status", .string(result.status))]
    for key in result.fields.keys.sorted() { pairs.append((key, result.fields[key]!)) }
    return .object(pairs)
}

/// Template ref payload (mirrors `template_ref_payload`, remctl:1048): id, name, objectUUID,
/// requested, method.
private func templateRefPayload(id: Int, name: String, objectUUID: String?, requested: String?, method: String) -> JSONValue {
    .object([
        ("id", .int(id)),
        ("name", .string(name)),
        ("objectUUID", objectUUID.map { .string($0) } ?? .null),
        ("requested", requested.map { .string($0) } ?? .null),
        ("method", .string(method)),
    ])
}

struct TemplateCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-create", abstract: "Create a template from a list.")

    @Argument(help: "Template name") var name: String
    @Option(name: .customLong("from-list"), help: "Source list name") var fromList: String?
    @Option(name: .customLong("from-list-id"), help: "Source list numeric ID") var fromListId: Int?
    @Flag(name: .customLong("include-completed"), help: "Include completed reminders in the saved template") var includeCompleted = false
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate { store, priv in
            try await Self.perform(
                name: args.name, fromList: args.fromList, fromListId: args.fromListId,
                includeCompleted: args.includeCompleted, json: args.json, store: store, private: priv)
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_template_create` (remctl:4266).
    /// PHASE-3 DIVERGENCE: the `template-create requires --private.` gate is DROPPED.
    /// Order (load-bearing): mutex → required → dup → resolve source → ckid → count → create → poll.
    /// `pollAttempts`/`pollDelay` are injectable (default 12 / 0.25s per source); the poll
    /// short-circuits when expectedItemCount is nil or 0.
    static func perform(
        name: String, fromList: String?, fromListId: Int?, includeCompleted: Bool, json: Bool,
        store: RemindersStore, private priv: PrivateWriter,
        pollAttempts: Int = 12, pollDelay: Double = 0.25
    ) async throws -> WriteOutcome {
        // 1. Mutually-exclusive source flags.
        if fromList != nil && fromListId != nil {
            return .error("pass either --from-list or --from-list-id, not both.")
        }
        // 2. Required source.
        if fromList == nil && fromListId == nil {
            return .error("pass --from-list or --from-list-id.")
        }
        // 3. Duplicate EXACT-name check.
        if store.templateExactNameCount(name: name) > 0 {
            return .error("template already exists: \(name). Use a unique template name.")
        }
        // 4. Resolve the source list (full 4-tier resolution; surfaces ambiguity/not-found).
        let (resolution, method) = store.resolveListRefWithMethod(name: fromList, listId: fromListId)
        let listId: Int, listTitle: String, listUUID: String?
        switch resolution {
        case .found(let id, let title, let uuid): (listId, listTitle, listUUID) = (id, title, uuid)
        case .ambiguous(let candidates):
            let requested = fromListId != nil ? "id \(fromListId!)" : (fromList ?? "")
            let options = candidates.map { "\($0.id) (\($0.title))" }.joined(separator: ", ")
            return .error("multiple lists match '\(requested)'. Use the exact list name or --list-id with one of: \(options)")
        case .notFound:
            let requested = fromListId != nil ? "id \(fromListId!)" : (fromList ?? "")
            return .error("list not found: \(requested)")
        }
        // 5. Source list must have a stable CloudKit identifier.
        guard let sourceUUID = listUUID, !sourceUUID.isEmpty else {
            return .error("source list has no stable CloudKit identifier.")
        }
        // Build the sourceList ref payload (list_ref_payload shape) from the full row.
        let requested = fromListId != nil ? "id \(fromListId!)" : (fromList ?? "")
        let sourceListRef: JSONValue
        if let fullRow = store.listRowByPkFull(listId) {
            sourceListRef = .object(listRefPayload(fullRow, requested: requested, method: method))
        } else {
            sourceListRef = .object([
                ("id", .int(listId)), ("title", .string(listTitle)),
                ("objectUUID", .string(sourceUUID)), ("requested", .string(requested)),
                ("method", .string(method)), ("isGroceries", .bool(false)),
            ])
        }
        // 6. Expected item count (gates the poll only). nil when query errors.
        let expectedItems = store.listReminderCountForTemplate(listPk: listId, includeCompleted: includeCompleted)

        // 7. Invoke the private writer.
        let result: PrivateResult
        do {
            result = try await priv.createTemplate(name: name, sourceListId: sourceUUID, includeCompleted: includeCompleted)
        } catch let e as WriteError {
            return .error("Failed to create template '\(name)': \(e.message.isEmpty ? "private helper failed" : e.message)")
        } catch {
            return .error("Failed to create template '\(name)': \(error)")
        }
        guard result.status == "created" else {
            return .error("Failed to create template '\(name)': \(result.message ?? "private helper failed")")
        }

        // 8. Post-write poll: re-read templateMatches(name:) until one exists with itemCount ≥
        //    expected. Short-circuits if expectedItems is nil or 0.
        var templateDict: [(String, JSONValue)]?
        let storeDir = store.path.deletingLastPathComponent()
        for _ in 0..<max(pollAttempts, 1) {
            // Re-open a fresh connection each iteration (mirrors Python's per-poll open_db()) so the
            // poll observes committed template state. Falls back to the existing store on failure.
            let fresh = (try? RemindersStore.open(storeDir: storeDir)) ?? store
            if let row = fresh.templateMatches(name: name).first {
                let dict = templateToDict(row, store: fresh, includeItems: true)
                templateDict = dict
                let itemCount: Int = {
                    if case let .int(v)? = dict.first(where: { $0.0 == "itemCount" })?.1 { return v }
                    return 0
                }()
                if expectedItems == nil || itemCount >= expectedItems! { break }
            }
            if expectedItems == nil || expectedItems == 0 { break }
            if pollDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(pollDelay * 1_000_000_000)) }
        }

        // 9. Output.
        if json {
            var pairs: [(String, JSONValue)] = [
                ("status", .string("created")),
                ("name", .string(name)),
                ("sourceList", sourceListRef),
                ("private", privateSubObject(result)),
            ]
            if let expectedItems { pairs.append(("expectedItemCount", .int(expectedItems))) }
            if let templateDict { pairs.append(("template", .object(templateDict))) }
            return .ok(JSONValue.object(pairs).serialized(indent: 2, ensureAscii: false) + "\n")
        }
        return .ok("Created template: \(safeDisplay(name))\nSource list: \(safeDisplay(listTitle))\n")
    }
}

struct TemplateApply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-apply", abstract: "Create a list from a template.")

    @Argument(help: "Template name") var name: String?
    @Option(name: .customLong("template-id"), help: "Apply by numeric template ID") var templateId: Int?
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate { store, priv in
            try await Self.perform(
                name: args.name, templateId: args.templateId, json: args.json, store: store, private: priv)
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_template_apply` (remctl:4335).
    /// PHASE-3 DIVERGENCE: the `template-apply requires --private.` gate is DROPPED.
    static func perform(
        name: String?, templateId: Int?, json: Bool,
        store: RemindersStore, private priv: PrivateWriter
    ) async throws -> WriteOutcome {
        // Resolve template (exact-name or Z_PK). Not-found/ambiguous/mutex propagate as CLIError.
        if name == nil && templateId == nil { throw CLIError("pass a template name or --template-id.") }
        if name != nil && templateId != nil { throw CLIError("pass either a template name or --template-id, not both.") }
        let requested = templateId != nil ? "id \(templateId!)" : (name ?? "")
        let tplId: Int, tplName: String, tplUUID: String?, tplMethod: String
        switch store.resolveTemplateRef(name: name, templateId: templateId) {
        case .found(let id, let nm, let uuid):
            (tplId, tplName, tplUUID, tplMethod) = (id, nm, uuid, templateId != nil ? "id" : "exact")
        case .ambiguous(let candidates):
            let options = candidates.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
            throw CLIError("multiple templates match '\(requested)'. Use --template-id with one of: \(options)")
        case .notFound:
            throw CLIError("template not found: \(requested)")
        }
        guard let templateUUID = tplUUID, !templateUUID.isEmpty else {
            // The Python helper would receive a null templateId; surface as a helper failure.
            return .error("Failed to create list from template '\(tplName)': private helper failed")
        }

        let result: PrivateResult
        do {
            result = try await priv.applyTemplate(templateId: templateUUID)
        } catch let e as WriteError {
            return .error("Failed to create list from template '\(tplName)': \(e.message.isEmpty ? "private helper failed" : e.message)")
        } catch {
            return .error("Failed to create list from template '\(tplName)': \(error)")
        }
        guard result.status == "created" else {
            return .error("Failed to create list from template '\(tplName)': \(result.message ?? "private helper failed")")
        }

        // Post-write re-read: if the helper returned the new list UUID, fetch the created list.
        var listDict: [(String, JSONValue)]?
        if case let .string(createdUUID)? = result.fields["id"], !createdUUID.isEmpty,
           let row = store.listRowByCkid(createdUUID) {
            listDict = listToDict(row)
        }

        let templateRef = templateRefPayload(id: tplId, name: tplName, objectUUID: tplUUID, requested: requested, method: tplMethod)

        if json {
            var pairs: [(String, JSONValue)] = [
                ("status", .string("created")),
                ("template", templateRef),
                ("private", privateSubObject(result)),
            ]
            if let listDict { pairs.append(("list", .object(listDict))) }
            return .ok(JSONValue.object(pairs).serialized(indent: 2, ensureAscii: false) + "\n")
        }
        // Human name: list.title → result.name → ref.name.
        let listTitle: String? = {
            guard let listDict, case let .string(t)? = listDict.first(where: { $0.0 == "title" })?.1 else { return nil }
            return t
        }()
        let resultName: String? = { if case let .string(n)? = result.fields["name"] { return n }; return nil }()
        let displayName = listTitle ?? resultName ?? tplName
        return .ok("Created list from template: \(safeDisplay(displayName))\n")
    }
}

struct TemplateDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-delete", abstract: "Delete a template.")

    @Argument(help: "Template name") var name: String?
    @Option(name: .customLong("template-id"), help: "Delete by numeric template ID") var templateId: Int?
    @Flag(name: .long, help: "Skip the confirmation prompt") var force = false
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate { store, priv in
            try await Self.perform(
                name: args.name, templateId: args.templateId, force: args.force, json: args.json,
                store: store, private: priv, confirm: { prompt in
                    FileHandle.standardOutput.write(Data(prompt.utf8))
                    let line = readLine() ?? ""
                    return ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
                })
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_template_delete` (remctl:4377).
    /// PHASE-3 DIVERGENCE: the `template-delete requires --private.` gate is DROPPED.
    /// `confirm` receives the full prompt and returns yes/no (only "y"/"yes" accept).
    /// NOTE: the JSON output is COMPACT (no indent) — diverges from create/apply.
    static func perform(
        name: String?, templateId: Int?, force: Bool, json: Bool,
        store: RemindersStore, private priv: PrivateWriter, confirm: (_ prompt: String) -> Bool
    ) async throws -> WriteOutcome {
        // Resolve template (exact-name or Z_PK). Not-found/ambiguous/mutex propagate as CLIError.
        if name == nil && templateId == nil { throw CLIError("pass a template name or --template-id.") }
        if name != nil && templateId != nil { throw CLIError("pass either a template name or --template-id, not both.") }
        let requested = templateId != nil ? "id \(templateId!)" : (name ?? "")
        let tplId: Int, tplName: String, tplUUID: String?, tplMethod: String
        switch store.resolveTemplateRef(name: name, templateId: templateId) {
        case .found(let id, let nm, let uuid):
            (tplId, tplName, tplUUID, tplMethod) = (id, nm, uuid, templateId != nil ? "id" : "exact")
        case .ambiguous(let candidates):
            let options = candidates.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
            throw CLIError("multiple templates match '\(requested)'. Use --template-id with one of: \(options)")
        case .notFound:
            throw CLIError("template not found: \(requested)")
        }

        // Confirmation unless --force. A non-yes answer prints "Aborted." and returns exit 0
        // with NO JSON, even in --json mode.
        if !force {
            let prompt = "Delete template '\(safeDisplay(tplName))'? [y/N] "
            guard confirm(prompt) else { return .ok("Aborted.\n") }
        }

        guard let templateUUID = tplUUID, !templateUUID.isEmpty else {
            return .error("Failed to delete template '\(tplName)': private helper failed")
        }

        let result: PrivateResult
        do {
            result = try await priv.deleteTemplate(templateId: templateUUID)
        } catch let e as WriteError {
            return .error("Failed to delete template '\(tplName)': \(e.message.isEmpty ? "private helper failed" : e.message)")
        } catch {
            return .error("Failed to delete template '\(tplName)': \(error)")
        }
        guard result.status == "deleted" else {
            return .error("Failed to delete template '\(tplName)': \(result.message ?? "private helper failed")")
        }

        if json {
            let obj: JSONValue = .object([
                ("status", .string("deleted")),
                ("template", templateRefPayload(id: tplId, name: tplName, objectUUID: tplUUID, requested: requested, method: tplMethod)),
                ("private", privateSubObject(result)),
            ])
            // COMPACT (indent: nil) — diverges from create/apply which use indent=2.
            return .ok(obj.serialized(indent: nil, ensureAscii: false) + "\n")
        }
        return .ok("Deleted template: \(safeDisplay(tplName))\n")
    }
}
