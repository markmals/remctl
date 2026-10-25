import ArgumentParser
import Foundation

let sectionCommands: [ParsableCommand.Type] = [SectionCreate.self, SectionRename.self, SectionDelete.self]

/// Every section write is read back from the store before it is reported (`verified: true`).
private func unverifiedSection(_ what: String) -> CommandFailure {
    CommandFailure("section_write_unverified", "ReminderKit reported success, but the \(what) could not be verified.")
}

private func sectionPayload(status: String, list: (id: Int, title: String), sectionId: String,
                            name: String?, result: PrivateResult) -> String {
    var pairs: [(String, JSONValue)] = [
        ("status", .string(status)), ("list", .string(list.title)), ("listId", .int(list.id)),
        ("sectionId", .string(sectionId)),
    ]
    if let name { pairs.append(("name", .string(name))) }
    pairs += [("verified", .bool(true)), ("private", result.jsonObject)]
    return JSONValue.object(pairs).serialized(indent: nil, ensureAscii: false) + "\n"
}

/// The list a section command works in. Sections need the list's stable identifier.
private func sectionList(store: RemindersStore, list: String?, listId: Int?) throws -> (id: Int, title: String, ckid: String) {
    let target = try resolveRequiredListTarget(store: store, name: list, listId: listId)
    guard let ckid = target.objectUUID, !ckid.isEmpty else {
        throw CommandFailure("list_missing_identifier", "target list has no stable CloudKit identifier.")
    }
    return (target.id, target.title, ckid)
}

/// The section a rename/delete targets, by name or `--section-id`.
private func targetSection(store: RemindersStore, listPk: Int, name: String?, sectionId: String?,
                           verb: String) throws -> (ckid: String, name: String) {
    guard let ckid = try store.resolveSectionCkid(listPk: listPk, section: name, sectionId: sectionId),
          let row = store.liveSection(listPk: listPk, identifier: ckid) else {
        throw CommandFailure("invalid_section_target", "pass the section to \(verb) by name or --section-id.")
    }
    return (ckid, row.string("ZDISPLAYNAME") ?? "")
}

struct SectionCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "section-create", abstract: "Create a section in a list.")

    @Argument(help: "New section name") var name: String
    @Option(name: [.short, .long], help: "Target list name") var list: String?
    @Option(name: .long, help: "Target list by stable numeric ID") var listId: Int?
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate(json: json) { store, priv in
            try await Self.perform(name: args.name, list: args.list, listId: args.listId, json: args.json,
                                   store: store, private: priv)
        })
    }

    /// Port of `cmd_section_create` (upstream c0db904). The new section is appended to the list's
    /// current section order, and reported only once the store shows it.
    static func perform(name: String, list: String?, listId: Int?, json: Bool,
                        store: RemindersStore, private priv: PrivateWriter,
                        readback: Readback = .standard) async throws -> WriteOutcome {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandFailure("invalid_section_name", "pass a section name.")
        }
        let target = try sectionList(store: store, list: list, listId: listId)
        if store.sectionNameExists(listPk: target.id, name: name) {
            throw CommandFailure("section_exists",
                                 "section already exists in \(WriteFormatting.pyRepr(target.title)): \(name)")
        }
        let result = try await priv.createSection(
            listId: target.ckid, name: name, existingSectionIds: store.sectionOrder(listPk: target.id)
        ).requireStatus("created")

        var created: String?
        let verified = await readback.waitUntil {
            created = createdSectionId(store: store, listPk: target.id, name: name, reported: result.string("sectionId"))
            return created != nil
        }
        guard verified, let sectionId = created else { throw unverifiedSection("new section") }

        if json {
            return .ok(sectionPayload(status: "created", list: (target.id, target.title), sectionId: sectionId,
                                      name: name, result: result))
        }
        return .ok("Created section: \(safeDisplay(name)) in \(safeDisplay(target.title))\n")
    }

    /// The new section's identifier once the store holds it: the one the helper reported, or (when
    /// it reported none) the only section with that name, which the duplicate check made unique.
    private static func createdSectionId(store: RemindersStore, listPk: Int, name: String, reported: String?) -> String? {
        if let reported {
            let row = store.liveSection(listPk: listPk, identifier: reported)
            return row?.string("ZDISPLAYNAME") == name ? row?.string("ZCKIDENTIFIER") : nil
        }
        return store.sections(listPk: listPk).first { $0.string("ZDISPLAYNAME") == name }?.string("ZCKIDENTIFIER")
    }
}

struct SectionRename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "section-rename", abstract: "Rename a section in a list.")

    @Argument(help: "Existing section name; omit when using --section-id") var name: String?
    @Option(name: .customLong("new-name"), help: "New section name") var newName: String
    @Option(name: [.short, .long], help: "The section's list name") var list: String?
    @Option(name: .long, help: "The section's list by stable numeric ID") var listId: Int?
    @Option(name: .long, help: "Target the section by stable ID when names collide") var sectionId: String?
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate(json: json) { store, priv in
            try await Self.perform(name: args.name, sectionId: args.sectionId, newName: args.newName,
                                   list: args.list, listId: args.listId, json: args.json, store: store, private: priv)
        })
    }

    /// Port of `cmd_section_rename` (upstream c0db904): refuses a name another section of the list
    /// already uses, then reports the rename once the store shows it.
    static func perform(name: String?, sectionId: String?, newName: String, list: String?, listId: Int?,
                        json: Bool, store: RemindersStore, private priv: PrivateWriter,
                        readback: Readback = .standard) async throws -> WriteOutcome {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandFailure("invalid_section_name", "pass a new section name.")
        }
        let target = try sectionList(store: store, list: list, listId: listId)
        let section = try targetSection(store: store, listPk: target.id, name: name, sectionId: sectionId,
                                        verb: "rename")
        if store.sectionNameExists(listPk: target.id, name: newName, excluding: section.ckid) {
            throw CommandFailure("section_exists",
                                 "another section in \(WriteFormatting.pyRepr(target.title)) is already named \(WriteFormatting.pyRepr(newName)).")
        }
        let result = try await priv.renameSection(sectionId: section.ckid, name: newName).requireStatus("updated")
        let verified = await readback.waitUntil {
            store.liveSection(listPk: target.id, identifier: section.ckid)?.string("ZDISPLAYNAME") == newName
        }
        guard verified else { throw unverifiedSection("section rename") }

        if json {
            return .ok(sectionPayload(status: "renamed", list: (target.id, target.title), sectionId: section.ckid,
                                      name: newName, result: result))
        }
        return .ok("Renamed section: \(safeDisplay(section.name)) -> \(safeDisplay(newName)) in \(safeDisplay(target.title))\n")
    }
}

struct SectionDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "section-delete", abstract: "Delete a section in a list.")

    @Argument(help: "Existing section name; omit when using --section-id") var name: String?
    @Option(name: [.short, .long], help: "The section's list name") var list: String?
    @Option(name: .long, help: "The section's list by stable numeric ID") var listId: Int?
    @Option(name: .long, help: "Target the section by stable ID when names collide") var sectionId: String?
    @Flag(name: .long, help: "Skip the confirmation prompt (required with --json or non-interactive stdin)") var force = false
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate(json: json) { store, priv in
            try await Self.perform(name: args.name, sectionId: args.sectionId, list: args.list, listId: args.listId,
                                   force: args.force, json: args.json, store: store, private: priv, confirm: .standard)
        })
    }

    /// Port of `cmd_section_delete` (upstream c0db904). The section's reminders stay in the list,
    /// unsectioned.
    static func perform(name: String?, sectionId: String?, list: String?, listId: Int?, force: Bool, json: Bool,
                        store: RemindersStore, private priv: PrivateWriter, confirm: ConfirmationPrompt,
                        readback: Readback = .standard) async throws -> WriteOutcome {
        let target = try sectionList(store: store, list: list, listId: listId)
        let section = try targetSection(store: store, listPk: target.id, name: name, sectionId: sectionId,
                                        verb: "delete")
        if let stop = confirmDestructiveAction(
            force: force, json: json,
            prompt: "Delete section '\(safeDisplay(section.name))' in '\(safeDisplay(target.title))'? "
                + "Its reminders move to the list's default area. [y/N] ",
            identifier: .string(section.ckid), using: confirm) {
            return stop
        }
        let result = try await priv.deleteSection(sectionId: section.ckid).requireStatus("deleted")
        let verified = await readback.waitUntil { store.liveSection(listPk: target.id, identifier: section.ckid) == nil }
        guard verified else { throw unverifiedSection("section delete") }

        if json {
            return .ok(sectionPayload(status: "deleted", list: (target.id, target.title), sectionId: section.ckid,
                                      name: section.name, result: result))
        }
        return .ok("Deleted section: \(safeDisplay(section.name)) in \(safeDisplay(target.title))\n")
    }
}
