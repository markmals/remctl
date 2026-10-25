import Foundation

/// Where a reminder sits, as hierarchy moves verify it: whether it is live, its parent (nil at
/// the top level), and its level's order. A sibling missing from the order record adds a marker,
/// so a level Reminders has not fully recorded never verifies.
struct HierarchyState: Equatable {
    let exists: Bool
    let parentPk: Int?
    let order: [String]

    /// Port of `_hierarchy_state`. Membership is read fresh on every call.
    static func read(store: RemindersStore, reminderPk: Int, listPk: Int, parentPk: Int?) -> HierarchyState {
        let row = store.reminder(pk: reminderPk)
        let members = Set(store.siblingIdentifiers(listPk: listPk, parentPk: parentPk).keys.map(unicodeCasefold))
        var order = store.listReminderOrder(listPk: listPk).map(unicodeCasefold).filter(members.contains)
        if Set(order) != members { order.append("<unrecorded>") }
        return HierarchyState(exists: row != nil, parentPk: row?.int("ZPARENTREMINDER").flatMap { $0 == 0 ? nil : $0 },
                              order: order)
    }
}

/// A `reminder-move` within a list's subtask hierarchy, checked against the store and ready to write.
struct HierarchyMove {
    let reminder: MovableReminder
    let parent: MovableReminder?
    let relation: String
    let position: String
    let anchorCkid: String?
    let anchorPk: Int?
    let listCkid: String
    let expected: HierarchyState
    let hierarchy: String
}

/// Port of `_reminder_move_in_hierarchy` (upstream 3eb076b): nest a reminder under a parent,
/// reorder it among subtasks, or return it to the top level, keeping its identifier.
enum SubtaskHierarchy {
    /// Writes the move, then waits for the store to show the planned parent and level order. A
    /// helper error whose move landed anyway counts as done (`helperError`).
    static func apply(_ move: HierarchyMove, store: RemindersStore, private priv: PrivateWriter,
                      readback: Readback) async throws -> (result: PrivateResult, helperError: Bool) {
        let result = try await priv.moveReminderInHierarchy(
            id: move.reminder.ckid, listId: move.listCkid, parentId: move.parent?.ckid,
            position: move.position, anchorId: move.anchorCkid)
        let verified = await readback.waitUntil {
            HierarchyState.read(store: store, reminderPk: move.reminder.id, listPk: move.reminder.listPk,
                                parentPk: move.expected.parentPk) == move.expected
        }
        guard verified else {
            if result.status != "updated" {
                throw CommandFailure("private_write_failed", result.message ?? "private helper failed")
            }
            throw CommandFailure("hierarchy_unverified", "ReminderKit reported success, but the new subtask structure could not be verified.")
        }
        return (result, result.status != "updated")
    }

    /// Placed next to a top-level reminder, a reminder joins that reminder's section, as a drop
    /// does in Reminders. Returns the section it joined, or a warning when it did not; nil for both
    /// when there was nothing to join.
    static func joinAnchorSection(_ move: HierarchyMove, store: RemindersStore, private priv: PrivateWriter,
                                  readback: Readback) async throws -> (section: String?, warning: String?) {
        let listPk = move.reminder.listPk
        guard move.parent == nil, ["before", "after"].contains(move.relation), let anchorCkid = move.anchorCkid,
              let section = store.reminderSectionCkid(listPk: listPk, reminderCkid: anchorCkid),
              section != store.reminderSectionCkid(listPk: listPk, reminderCkid: move.reminder.ckid) else { return (nil, nil) }
        let result = try await priv.assignSection(id: move.reminder.ckid, sectionId: section)
        let name = store.liveSection(listPk: listPk, identifier: section)?.string("ZDISPLAYNAME") ?? section
        let joined = await readback.waitUntil {
            store.reminderSectionCkid(listPk: listPk, reminderCkid: move.reminder.ckid) == section
        }
        if joined { return (name, nil) }
        let detail = result.status == "error" ? (result.message.map { " (\($0))" } ?? "") : ""
        return (nil, "section_not_set: the move is verified, but #\(move.reminder.id) did not join section "
                + "\(WriteFormatting.pyRepr(name))\(detail)")
    }

    static func plan(store: RemindersStore, reminder: MovableReminder, position: MovePosition?,
                     anchor: MovableReminder?, targetParentPk: Int?) throws -> HierarchyMove {
        let parent = try targetParent(store: store, reminder: reminder, targetParentPk: targetParentPk)
        if targetParentPk == nil && reminder.parentPk == nil && position == nil {
            throw CommandFailure("invalid_move", "#\(reminder.id) is already a top-level reminder. "
                                 + "Pass --before, --after, --first, or --last to reorder it.")
        }
        var relation = position?.relation ?? "last"
        var anchor = anchor
        if position == nil, targetParentPk == nil, let formerParent = reminder.parentPk {
            // Like outdenting in Reminders, a reminder leaving its parent lands right after it.
            relation = "after"
            anchor = try? MovableReminder(store: store, id: formerParent, role: "")
            if anchor == nil {
                throw CommandFailure("invalid_move", "former parent #\(formerParent) not found. Pass --before, --after, --first, or --last.")
            }
        }
        let siblings = store.siblingIdentifiers(listPk: reminder.listPk, parentPk: targetParentPk)
        if let anchor, anchor.listPk != reminder.listPk || siblings[anchor.ckid] == nil {
            let level = targetParentPk.map { "a subtask of #\($0)" }
                ?? "a top-level reminder in \(WriteFormatting.pyRepr(reminder.listName))"
            throw CommandFailure("invalid_move", "anchor #\(anchor.id) is not \(level).")
        }
        let current = try levelOrder(store: store, reminder: reminder, siblings: siblings)
        let placement = try place(reminder: reminder, relation: relation, anchor: anchor, current: current)
        guard let listCkid = store.listCkid(pk: reminder.listPk) else {
            throw CommandFailure("list_missing_identifier", "target list has no stable identifier.")
        }
        let hierarchy = targetParentPk == nil ? (reminder.parentPk != nil ? "unnested" : "reordered")
            : (reminder.parentPk == targetParentPk ? "reordered" : "nested")
        let anchorPk = placement.anchorCkid.flatMap { ckid in siblings.first { unicodeCasefold($0.key) == unicodeCasefold(ckid) }?.value }
        return HierarchyMove(
            reminder: reminder, parent: parent, relation: relation, position: placement.position,
            anchorCkid: placement.anchorCkid, anchorPk: anchorPk, listCkid: listCkid,
            expected: HierarchyState(exists: true, parentPk: targetParentPk, order: placement.expected), hierarchy: hierarchy)
    }

    /// The new parent, which must be a live top-level reminder in the same list; a reminder that
    /// has subtasks of its own cannot join another one (Reminders allows one level).
    private static func targetParent(store: RemindersStore, reminder: MovableReminder,
                                     targetParentPk: Int?) throws -> MovableReminder? {
        guard let targetParentPk else { return nil }
        if targetParentPk == reminder.id {
            throw CommandFailure("invalid_move", "a reminder cannot be its own parent.")
        }
        guard let parent = try? MovableReminder(store: store, id: targetParentPk, role: "") else {
            throw CommandFailure("invalid_move", "parent #\(targetParentPk) not found or has no stable identifier.")
        }
        if parent.parentPk != nil {
            throw CommandFailure("invalid_move", "#\(targetParentPk) is itself a subtask. Reminders allows one level of subtasks.")
        }
        if parent.listPk != reminder.listPk {
            throw CommandFailure("invalid_move", "#\(targetParentPk) is in list \(WriteFormatting.pyRepr(parent.listName)). "
                                 + "Move #\(reminder.id) there first: remctl edit \(reminder.id) -l \(WriteFormatting.shellQuote(parent.listName))")
        }
        if reminder.parentPk != targetParentPk && !store.siblingIdentifiers(listPk: reminder.listPk, parentPk: reminder.id).isEmpty {
            throw CommandFailure("invalid_move", "#\(reminder.id) has its own subtasks. Reminders allows one level of subtasks.")
        }
        return parent
    }

    /// The other reminders of the target level, in the list's recorded order. Positions only mean
    /// something when the record holds every one of them.
    private static func levelOrder(store: RemindersStore, reminder: MovableReminder,
                                   siblings: [String: Int]) throws -> [String] {
        let ordering = store.listReminderOrder(listPk: reminder.listPk)
        guard !ordering.isEmpty else {
            throw CommandFailure("order_unavailable", "this list has no readable ReminderKit ordering data.")
        }
        let moving = unicodeCasefold(reminder.ckid)
        let others = Set(siblings.keys.map(unicodeCasefold)).subtracting([moving])
        let recorded = Set(ordering.map(unicodeCasefold))
        let unrecorded = others.subtracting(recorded).count
        guard unrecorded == 0 else {
            throw CommandFailure("level_unrecorded", "Reminders has not recorded a position for \(unrecorded) reminder(s) "
                                 + "at this level yet. Open the list in Reminders.app, then retry.")
        }
        return ordering.filter { others.contains(unicodeCasefold($0)) }
    }

    /// ReminderKit's position and anchor for `relation`, and the level order it must produce.
    private static func place(reminder: MovableReminder, relation: String, anchor: MovableReminder?,
                              current: [String]) throws -> (position: String, anchorCkid: String?, expected: [String]) {
        let position: String
        let anchorCkid: String?
        switch relation {
        case "first", "last":
            guard let edge = relation == "first" ? current.first : current.last else {
                return ("append", nil, [unicodeCasefold(reminder.ckid)])
            }
            (position, anchorCkid) = (relation == "first" ? "before" : "after", edge)
        default:
            guard let anchor, let recorded = current.first(where: { unicodeCasefold($0) == unicodeCasefold(anchor.ckid) }) else {
                throw CommandFailure("anchor_unpositioned", "the anchor has no persisted position in this list.")
            }
            (position, anchorCkid) = (relation, recorded)
        }
        let expected = reorderIdentifiers(current, moving: reminder.ckid, position: position, anchor: anchorCkid) ?? []
        return (position, anchorCkid, expected.map(unicodeCasefold))
    }
}
