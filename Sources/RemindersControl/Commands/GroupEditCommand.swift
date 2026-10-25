import ArgumentParser
import Foundation

/// What `group-edit` was asked to change.
struct GroupEditRequest {
    var newName: String?
    var addLists: [String] = []
    var addListIds: [Int] = []
    var removeLists: [String] = []
    var removeListIds: [Int] = []
    var moveList: String?
    var moveListId: Int?
    var beforeList: String?
    var beforeListId: Int?
    var afterList: String?
    var afterListId: Int?
    var first = false
    var last = false
}

/// The edits `group-edit` will make, checked against the store before anything is written.
private struct GroupEditPlan {
    var newName: String?
    var adds: [GroupMember]
    var removes: [GroupMember]
    var move: GroupMove?
}

struct GroupEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "group-edit", abstract: "Rename a group, add or remove its lists, or reorder them.")

    @Argument(help: "Group name") var name: String?
    @Option(name: .long, help: "Edit by numeric group ID from groups") var groupId: Int?
    @Option(name: .customLong("new-name"), help: "Rename the group") var newName: String?
    @Option(name: .customLong("add-list"), help: "Move an existing list into the group by name; repeatable") var addList: [String] = []
    @Option(name: .customLong("add-list-id"), help: "Move an existing list into the group by numeric ID; repeatable") var addListId: [Int] = []
    @Option(name: .customLong("remove-list"), help: "Move a child list out of the group by name; repeatable") var removeList: [String] = []
    @Option(name: .customLong("remove-list-id"), help: "Move a child list out of the group by numeric ID; repeatable") var removeListId: [Int] = []
    @Option(name: .customLong("move-list"), help: "Move or reorder a list in this group by name") var moveList: String?
    @Option(name: .customLong("move-list-id"), help: "Move or reorder a list in this group by numeric ID") var moveListId: Int?
    @Option(name: .customLong("before-list"), help: "Place --move-list before this child list") var beforeList: String?
    @Option(name: .customLong("before-list-id"), help: "Place --move-list before this child list ID") var beforeListId: Int?
    @Option(name: .customLong("after-list"), help: "Place --move-list after this child list") var afterList: String?
    @Option(name: .customLong("after-list-id"), help: "Place --move-list after this child list ID") var afterListId: Int?
    @Flag(name: .long, help: "Place --move-list first in the group") var first = false
    @Flag(name: .long, help: "Place --move-list last in the group") var last = false
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let request = GroupEditRequest(
            newName: newName, addLists: addList, addListIds: addListId, removeLists: removeList,
            removeListIds: removeListId, moveList: moveList, moveListId: moveListId, beforeList: beforeList,
            beforeListId: beforeListId, afterList: afterList, afterListId: afterListId, first: first, last: last)
        let (name, groupId, json) = (name, groupId, json)
        WriteDispatch.emit(await WriteDispatch.runShellPrivate(json: json) { store, priv in
            try await Self.perform(name: name, groupId: groupId, request: request, json: json, store: store, private: priv)
        })
    }

    /// Port of `cmd_group_edit` (upstream e013fb9). Every edit is validated before the first write,
    /// and each write is read back from the store before the next one starts.
    static func perform(name: String?, groupId: Int?, request: GroupEditRequest, json: Bool,
                        store: RemindersStore, private priv: PrivateWriter,
                        readback: Readback = .standard) async throws -> WriteOutcome {
        let target = try resolveRequiredGroupTarget(store: store, name: name, groupId: groupId)
        var group = try GroupHandle(target)
        let children = try target.children.map(GroupMember.init)
        let plan = try makePlan(request, group: group, children: children, store: store)

        var renamed: JSONValue = .null
        if let newName = plan.newName {
            let result = try await priv.setListAppearance(listId: group.ckid, appearance: ListAppearance(name: newName))
                .requireStatus("updated")
            guard await readback.waitUntil({ store.listRowByPkFull(group.id)?.string("ZNAME") == newName }) else {
                throw CommandFailure("group_write_unverified", "ReminderKit reported success, but the group was not renamed.")
            }
            renamed = .object([("oldName", .string(group.title)), ("newName", .string(newName)), ("private", result.jsonObject)])
            group = GroupHandle(id: group.id, title: newName, ckid: group.ckid)
        }
        var added: [JSONValue] = []
        for member in plan.adds {
            guard member.parentId != group.id else { added.append(member.summary(nil, skipped: true)); continue }
            let result = try await GroupMembership.move(member, to: group, store: store, private: priv, readback: readback)
            added.append(member.summary(result.jsonObject))
        }
        var removed: [JSONValue] = []
        for member in plan.removes {
            let result = try await GroupMembership.move(member, to: nil, store: store, private: priv, readback: readback)
            removed.append(member.summary(result.jsonObject))
        }
        var moved: JSONValue = .null
        if let move = plan.move {
            let ordered = try move.order(children: children, groupTitle: group.title)
            let result = try await GroupMembership.reorder(group, current: children, ordered: ordered, store: store,
                                                           private: priv, readback: readback)
            moved = movedPayload(move, children: children, ordered: ordered, result: result)
        }

        if json {
            return .ok(groupPayload(status: "updated", group: group, extra: [
                ("renamed", renamed), ("addedLists", .array(added)), ("removedLists", .array(removed)), ("movedList", moved),
            ]))
        }
        return .ok(humanOutput(group: group, oldTitle: target.title, plan: plan, children: children))
    }

    private static func makePlan(_ request: GroupEditRequest, group: GroupHandle, children: [GroupMember],
                                 store: RemindersStore) throws -> GroupEditPlan {
        var adds = try store.groupMembers(names: request.addLists, ids: request.addListIds)
        let removes = try store.groupMembers(names: request.removeLists, ids: request.removeListIds)
        let move = try moveRequest(request, store: store)
        if let move {
            if removes.contains(where: { $0.id == move.list.id }) {
                throw CommandFailure("invalid_group_edit", "cannot move and remove the same list in one group edit.")
            }
            if let sibling = move.relativeTo(children: children)?.sibling, removes.contains(where: { $0.id == sibling.id }) {
                throw CommandFailure("invalid_group_edit", "cannot place a list relative to a sibling that is being removed.")
            }
            adds.removeAll { $0.id == move.list.id }
            if !adds.isEmpty || !removes.isEmpty {
                throw CommandFailure("invalid_group_edit", "perform group ordering separately from other add/remove edits.")
            }
            _ = try move.order(children: children, groupTitle: group.title)
        }
        let newName = request.newName.flatMap { $0.isEmpty ? nil : $0 }
        guard newName != nil || !adds.isEmpty || !removes.isEmpty || move != nil else {
            throw CommandFailure("invalid_group_edit",
                                 "pass --new-name, --add-list/--add-list-id, --remove-list/--remove-list-id, or --move-list with a position.")
        }
        if let newName, newName != group.title { try refuseTakenGroupName(newName, store: store) }
        if let stray = removes.first(where: { $0.parentId != group.id }) {
            throw CommandFailure("list_not_in_group",
                                 "list \(WriteFormatting.pyRepr(stray.title)) is not currently in group \(WriteFormatting.pyRepr(group.title)).")
        }
        return GroupEditPlan(newName: newName, adds: adds, removes: removes, move: move)
    }

    /// Port of `resolve_group_ordering_request`.
    private static func moveRequest(_ r: GroupEditRequest, store: RemindersStore) throws -> GroupMove? {
        func member(_ name: String?, _ id: Int?, _ option: String) throws -> GroupMember? {
            if name != nil && id != nil {
                throw CommandFailure("invalid_group_edit", "pass either \(option) or \(option)-id, not both.")
            }
            guard name != nil || id != nil else { return nil }
            return try store.groupMember(name: name, listId: id)
        }
        let list = try member(r.moveList, r.moveListId, "--move-list")
        let before = try member(r.beforeList, r.beforeListId, "--before-list")
        let after = try member(r.afterList, r.afterListId, "--after-list")
        let placements: [GroupPlacement] = [before.map(GroupPlacement.before), after.map(GroupPlacement.after),
                                            r.first ? .first : nil, r.last ? .last : nil].compactMap { $0 }
        guard let list else {
            guard placements.isEmpty else {
                throw CommandFailure("invalid_group_edit", "--before-list/--after-list/--first/--last require --move-list or --move-list-id.")
            }
            return nil
        }
        guard placements.count == 1 else {
            throw CommandFailure("invalid_group_edit",
                                 "pass exactly one of --before-list, --before-list-id, --after-list, --after-list-id, --first, or --last with --move-list.")
        }
        return GroupMove(list: list, placement: placements[0])
    }

    private static func movedPayload(_ move: GroupMove, children: [GroupMember], ordered: [GroupMember],
                                     result: JSONValue) -> JSONValue {
        guard case .object(var pairs) = move.list.summary(result) else { return .null }
        pairs.append(("position", .string(move.placement.position)))
        pairs.append(("finalOrder", .array(ordered.map { .object([("id", .int($0.id)), ("title", .string($0.title))]) })))
        if let relative = move.relativeTo(children: children) {
            pairs.append(("relativeTo", .object([
                ("id", .int(relative.sibling.id)), ("title", .string(relative.sibling.title)),
                ("placement", .string(relative.side)),
            ])))
        }
        return .object(pairs)
    }

    private static func humanOutput(group: GroupHandle, oldTitle: String, plan: GroupEditPlan,
                                    children: [GroupMember]) -> String {
        var out = "Updated group: \(safeDisplay(group.title))\n"
        if plan.newName != nil { out += "Renamed: \(safeDisplay(oldTitle)) -> \(safeDisplay(group.title))\n" }
        out += movedListsText("Added lists:", plan.adds) { $0.parentId == group.id ? " [already in group]" : "" }
        out += movedListsText("Removed lists:", plan.removes)
        if let move = plan.move {
            if let relative = move.relativeTo(children: children) {
                out += "Moved list: \(safeDisplay(move.list.title)) \(relative.side) \(safeDisplay(relative.sibling.title))\n"
            } else {
                out += "Moved list: \(safeDisplay(move.list.title)) (\(move.placement.position))\n"
            }
        }
        return out
    }
}
