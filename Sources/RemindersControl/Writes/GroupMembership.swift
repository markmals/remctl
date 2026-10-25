import Foundation
import GRDB

/// A list that moves into, out of, or within a Reminders list group.
struct GroupMember: Equatable {
    let id: Int
    let title: String
    let ckid: String
    let parentId: Int?

    init(_ row: Row) throws {
        id = row.int("Z_PK") ?? 0
        title = row.string("ZNAME") ?? ""
        parentId = listParentPk(row)
        guard let ckid = row.string("ZCKIDENTIFIER"), !ckid.isEmpty else {
            throw CommandFailure("list_missing_identifier",
                                 "list \(WriteFormatting.pyRepr(title)) has no stable CloudKit identifier.")
        }
        self.ckid = ckid
    }

    /// Port of `group_change_summary`: how a command reports a list it moved (or skipped).
    func summary(_ result: JSONValue?, skipped: Bool = false) -> JSONValue {
        var pairs: [(String, JSONValue)] = [("id", .int(id)), ("title", .string(title)), ("objectUUID", .string(ckid))]
        if skipped { pairs.append(("skipped", .bool(true))) }
        if let result { pairs.append(("private", result)) }
        return .object(pairs)
    }
}

/// The group a membership write targets.
struct GroupHandle {
    let id: Int
    let title: String
    let ckid: String

    init(_ target: GroupTarget) throws {
        guard let ckid = target.objectUUID else {
            throw CommandFailure("group_missing_identifier", "target group has no stable CloudKit identifier.")
        }
        id = target.id; title = target.title; self.ckid = ckid
    }

    init(id: Int, title: String, ckid: String) { self.id = id; self.title = title; self.ckid = ckid }
}

extension RemindersStore {
    /// A list named by `--add-list`, `--move-list`, and friends: resolved like a reminder's list
    /// target, so a group name is refused.
    func groupMember(name: String?, listId: Int?) throws -> GroupMember {
        let target = try resolveRequiredListTarget(store: self, name: name, listId: listId)
        guard let row = listRowByPkFull(target.id) else {
            throw CLIError("list not found: \(name ?? "id \(target.id)")", code: "list_not_found")
        }
        return try GroupMember(row)
    }

    /// Port of `resolve_group_member_list_refs`: ids first, then names, each list once.
    func groupMembers(names: [String], ids: [Int]) throws -> [GroupMember] {
        var members: [GroupMember] = []
        for member in try ids.map({ try groupMember(name: nil, listId: $0) })
            + names.map({ try groupMember(name: $0, listId: nil) })
        where !members.contains(where: { $0.id == member.id }) {
            members.append(member)
        }
        return members
    }
}

/// Group membership writes. Each one is read back from the store before it counts as done.
enum GroupMembership {
    /// Moves `member` into `group` (to the top level when nil) and returns once the store shows the
    /// list there. Only the container changes: the list keeps its row, and with it its reminders.
    static func move(_ member: GroupMember, to group: GroupHandle?, store: RemindersStore,
                     private priv: PrivateWriter, readback: Readback) async throws -> PrivateResult {
        let result = try await priv.setListParentGroup(listId: member.ckid, groupId: group?.ckid).requireStatus("updated")
        guard await readback.waitUntil({ store.listIsLive(member.id, inGroup: group?.id) }) else {
            let place = group.map { "in group \(WriteFormatting.pyRepr($0.title))" } ?? "at the top level"
            throw CommandFailure("group_write_unverified",
                                 "ReminderKit reported success, but list \(WriteFormatting.pyRepr(member.title)) is not \(place).")
        }
        return result
    }

    /// Port of `apply_private_group_child_order`. Reminders puts a list it adds to a group at the
    /// top, so every child is detached and the lists are re-attached in reverse of `ordered`. The
    /// final order is read back before it is reported.
    static func reorder(_ group: GroupHandle, current: [GroupMember], ordered: [GroupMember], store: RemindersStore,
                        private priv: PrivateWriter, readback: Readback) async throws -> JSONValue {
        let finalOrder = JSONValue.array(ordered.map { .int($0.id) })
        if current.map(\.id) == ordered.map(\.id) {
            return .object([("status", .string("updated")), ("method", .string("unchanged")), ("finalOrder", finalOrder)])
        }
        var detached: [JSONValue] = []
        var attached: [JSONValue] = []
        var outside: [GroupMember] = []
        do {
            for child in current {
                detached.append(child.summary(try await move(child, to: nil, store: store, private: priv, readback: readback).jsonObject))
                outside.append(child)
            }
            for member in ordered.reversed() {
                attached.append(member.summary(try await move(member, to: group, store: store, private: priv, readback: readback).jsonObject))
                outside.removeAll { $0.id == member.id }
            }
        } catch let failure as CommandFailure {
            throw stranded(failure, outside: outside)
        }
        guard await readback.waitUntil({ store.childLists(groupPk: group.id).compactMap { $0.int("Z_PK") } == ordered.map(\.id) }) else {
            throw CommandFailure("group_order_unverified",
                                 "ReminderKit reported success, but group \(WriteFormatting.pyRepr(group.title)) does not show the requested order.")
        }
        return .object([
            ("status", .string("updated")), ("method", .string("detach_reattach")),
            ("detachedLists", .array(detached)), ("attachedLists", .array(attached)), ("finalOrder", finalOrder),
        ])
    }

    /// A reorder that stopped part-way leaves some children at the top level; say which, so they
    /// can be put back.
    private static func stranded(_ failure: CommandFailure, outside: [GroupMember]) -> CommandFailure {
        guard !outside.isEmpty else { return failure }
        let titles = outside.map { WriteFormatting.pyRepr($0.title) }.joined(separator: ", ")
        return CommandFailure(failure.code, failure.message + " These lists are now at the top level: \(titles).",
                              context: failure.context + [("listsAtTopLevel", .array(outside.map { $0.summary(nil) }))])
    }
}
