import Foundation

/// Where `group-edit --move-list` puts a list among its group's children.
enum GroupPlacement: Equatable {
    case before(GroupMember)
    case after(GroupMember)
    case first
    case last

    var position: String {
        switch self {
        case .before: "before"
        case .after: "after"
        case .first: "first"
        case .last: "last"
        }
    }
}

/// A `group-edit --move-list` request. The list may already be a child, or join the group here.
struct GroupMove {
    let list: GroupMember
    let placement: GroupPlacement

    /// The sibling the list lands next to and on which side: the named sibling, or for
    /// `--first`/`--last` the current first/last other child (`group_child_ref_by_position`).
    func relativeTo(children: [GroupMember]) -> (sibling: GroupMember, side: String)? {
        let others = children.filter { $0.id != list.id }
        switch placement {
        case .before(let sibling): return (sibling, "before")
        case .after(let sibling): return (sibling, "after")
        case .first: return others.first.map { ($0, "before") }
        case .last: return others.last.map { ($0, "after") }
        }
    }

    /// Port of `compute_group_child_order_after_move`: the group's children once the list is moved.
    func order(children: [GroupMember], groupTitle: String) throws -> [GroupMember] {
        let remaining = children.filter { $0.id != list.id }
        switch placement {
        case .first: return [list] + remaining
        case .last: return remaining + [list]
        case .before(let sibling), .after(let sibling):
            guard sibling.id != list.id else {
                throw CommandFailure("invalid_group_edit", "cannot place a list relative to itself.")
            }
            guard var index = remaining.firstIndex(where: { $0.id == sibling.id }) else {
                throw CommandFailure("list_not_in_group",
                                     "sibling list \(WriteFormatting.pyRepr(sibling.title)) is not currently in group \(WriteFormatting.pyRepr(groupTitle)).")
            }
            if case .after = placement { index += 1 }
            return Array(remaining[..<index]) + [list] + Array(remaining[index...])
        }
    }
}
