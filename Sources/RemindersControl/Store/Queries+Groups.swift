import GRDB
import Foundation

/// A resolved Reminders list group: its full list row and its child lists in Reminders' order.
public struct GroupTarget {
    public let row: Row
    public let children: [Row]
    public let requested: String
    public let method: String

    public var id: Int { row.int("Z_PK") ?? 0 }
    public var title: String { row.string("ZNAME") ?? "" }
    public var objectUUID: String? { row.string("ZCKIDENTIFIER").flatMap { $0.isEmpty ? nil : $0 } }
}

extension RemindersStore {
    /// Port of `q_list_exact_name_count`: live lists and groups named exactly `name`.
    public func listExactNameCount(_ name: String) -> Int {
        (try? queue.read { try Int.fetchOne($0, sql:
            "SELECT COUNT(*) FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME = ?",
            arguments: [name]) ?? 0 }) ?? 0
    }

    /// Whether the live list `listPk` sits in group `groupPk` (nil: at the top level).
    public func listIsLive(_ listPk: Int, inGroup groupPk: Int?) -> Bool {
        guard let row = listRowByPkFull(listPk) else { return false }
        return listParentPk(row) == groupPk
    }
}

/// Port of `resolve_required_group_target_or_die`: a group by `--group-id` (which must name a group,
/// not a list) or by name among the groups (exact → case-insensitive → normalized). Failures carry
/// the codes commands report under `--json`.
public func resolveRequiredGroupTarget(store: RemindersStore, name: String?, groupId: Int?) throws -> GroupTarget {
    if name != nil && groupId != nil {
        throw CLIError("pass either a group name or --group-id, not both.", code: "invalid_group_target")
    }
    guard name != nil || groupId != nil else {
        throw CLIError("pass a group name or --group-id.", code: "invalid_group_target")
    }
    let requested = groupId.map { "id \($0)" } ?? name!
    let pk: Int
    if let groupId {
        guard let row = store.listByPkForResolution(groupId) else {
            throw CLIError("group not found: \(requested)", code: "group_not_found")
        }
        guard isGroupListRow(row) else {
            throw CLIError("\(WriteFormatting.pyRepr(row.string("ZNAME") ?? requested)) is a list, not a Reminders list group.",
                           code: "not_a_group")
        }
        pk = groupId
    } else {
        switch store.resolution(from: store.listGroupsForResolution(), name: name!) {
        case .found(let id, _, _)?:
            pk = id
        case .ambiguous(let candidates)?:
            let options = candidates.map { "\($0.id) (\($0.title))" }.joined(separator: ", ")
            throw CLIError("multiple groups match \(WriteFormatting.pyRepr(name!)). Use --group-id with one of: \(options)",
                           code: "group_ambiguous")
        default:
            throw CLIError("group not found: \(requested)", code: "group_not_found")
        }
    }
    guard let row = store.listRowByPkFull(pk) else {
        throw CLIError("group not found: \(requested)", code: "group_not_found")
    }
    let method = WriteFormatting.resolveMethod(store: store, name: name, listId: groupId,
                                               resolvedTitle: row.string("ZNAME") ?? "")
    return GroupTarget(row: row, children: store.childLists(groupPk: pk), requested: requested, method: method)
}
