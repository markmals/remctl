import ArgumentParser
import Foundation

let groupCommands: [ParsableCommand.Type] = [
    Groups.self, GroupInfo.self, GroupCreate.self, GroupEdit.self, GroupDelete.self,
]

/// Lists and groups share one namespace in Reminders' sidebar, so a group name must be unused.
func refuseTakenGroupName(_ name: String, store: RemindersStore) throws {
    if store.listExactNameCount(name) > 0 {
        throw CommandFailure("group_exists", "list or group already exists: \(name). Choose a unique group name.")
    }
}

func groupPayload(status: String, group: GroupHandle, extra: [(String, JSONValue)]) -> String {
    let pairs: [(String, JSONValue)] = [
        ("status", .string(status)), ("id", .int(group.id)), ("name", .string(group.title)),
        ("objectUUID", .string(group.ckid)), ("verified", .bool(true)),
    ] + extra
    return JSONValue.object(pairs).serialized(indent: nil, ensureAscii: false) + "\n"
}

func movedListsText(_ heading: String, _ members: [GroupMember], suffix: (GroupMember) -> String = { _ in "" }) -> String {
    guard !members.isEmpty else { return "" }
    return "\(heading)\n" + members.map { "  \(safeDisplay($0.title)) (id: \($0.id))\(suffix($0))\n" }.joined()
}

struct GroupCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "group-create", abstract: "Create a Reminders list group.")

    @Argument(help: "Group name") var name: String
    @Option(name: .customLong("add-list"), help: "Move an existing list into the new group by name; repeatable") var addList: [String] = []
    @Option(name: .customLong("add-list-id"), help: "Move an existing list into the new group by numeric ID; repeatable") var addListId: [Int] = []
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate(json: json) { store, priv in
            try await Self.perform(name: args.name, addLists: args.addList, addListIds: args.addListId,
                                   json: args.json, store: store, private: priv)
        })
    }

    /// Port of `cmd_group_create` (upstream e013fb9). The group and every list moved into it are read
    /// back from the store before they are reported.
    static func perform(name: String, addLists: [String], addListIds: [Int], json: Bool,
                        store: RemindersStore, private priv: PrivateWriter,
                        readback: Readback = .standard) async throws -> WriteOutcome {
        try refuseTakenGroupName(name, store: store)
        let members = try store.groupMembers(names: addLists, ids: addListIds)
        let result = try await priv.createGroup(name: name).requireStatus("created")
        let group = try await waitForGroup(ckid: result.string("id"), name: name, store: store, readback: readback)

        var added: [JSONValue] = []
        for member in members {
            let moved = try await GroupMembership.move(member, to: group, store: store, private: priv, readback: readback)
            added.append(member.summary(moved.jsonObject))
        }
        if json {
            return .ok(groupPayload(status: "created", group: group,
                                    extra: [("private", result.jsonObject), ("addedLists", .array(added))]))
        }
        return .ok("Created group: \(safeDisplay(name))\n" + movedListsText("Added lists:", members))
    }

    private static func waitForGroup(ckid: String?, name: String, store: RemindersStore,
                                     readback: Readback) async throws -> GroupHandle {
        guard let ckid else {
            throw CommandFailure("group_write_unverified", "ReminderKit created the group but did not return its identifier.")
        }
        var pk: Int?
        let verified = await readback.waitUntil {
            pk = store.listRowByCkid(ckid).flatMap { isGroupListRow($0) ? $0.int("Z_PK") : nil }
            return pk != nil
        }
        guard verified, let pk else {
            throw CommandFailure("group_write_unverified", "ReminderKit reported success, but the new group could not be verified.")
        }
        return GroupHandle(id: pk, title: name, ckid: ckid)
    }
}

struct GroupDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "group-delete", abstract: "Delete a Reminders list group, keeping its lists.")

    @Argument(help: "Group name") var name: String?
    @Option(name: .long, help: "Delete by numeric group ID from groups") var groupId: Int?
    @Flag(name: .long, help: "Skip the confirmation prompt (required with --json or non-interactive stdin)") var force = false
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellPrivate(json: json) { store, priv in
            try await Self.perform(name: args.name, groupId: args.groupId, force: args.force, json: args.json,
                                   store: store, private: priv, confirm: .standard)
        })
    }

    /// Port of `cmd_group_delete` (upstream e013fb9). Every child list moves to the top level first,
    /// and the group is deleted only once the store shows it empty, so no list or reminder goes
    /// with it.
    static func perform(name: String?, groupId: Int?, force: Bool, json: Bool,
                        store: RemindersStore, private priv: PrivateWriter, confirm: ConfirmationPrompt,
                        readback: Readback = .standard) async throws -> WriteOutcome {
        let target = try resolveRequiredGroupTarget(store: store, name: name, groupId: groupId)
        let group = try GroupHandle(target)
        let children = try target.children.map(GroupMember.init)
        if let stop = confirmDestructiveAction(
            force: force, json: json,
            prompt: "Delete group '\(safeDisplay(group.title))'? Child lists and reminders will be kept at top level. [y/N] ",
            identifier: .int(group.id), cancelMessage: "Aborted.", using: confirm) {
            return stop
        }
        var detached: [JSONValue] = []
        for child in children {
            let moved = try await GroupMembership.move(child, to: nil, store: store, private: priv, readback: readback)
            detached.append(child.summary(moved.jsonObject))
        }
        let remaining = store.childLists(groupPk: group.id)
        guard remaining.isEmpty else {
            let titles = remaining.map { WriteFormatting.pyRepr($0.string("ZNAME") ?? "") }.joined(separator: ", ")
            throw CommandFailure("group_not_empty", "group \(WriteFormatting.pyRepr(group.title)) still holds \(titles); it was not deleted.")
        }
        let result = try await priv.deleteGroup(groupId: group.ckid).requireStatus("deleted")
        guard await readback.waitUntil({ store.listRowByPkFull(group.id) == nil }) else {
            throw CommandFailure("group_write_unverified", "ReminderKit reported success, but the group is still in the store.")
        }
        if json {
            return .ok(groupPayload(status: "deleted", group: group,
                                    extra: [("detachedLists", .array(detached)), ("private", result.jsonObject)]))
        }
        return .ok("Deleted group: \(safeDisplay(group.title))\n" + movedListsText("Kept child lists:", children))
    }
}
