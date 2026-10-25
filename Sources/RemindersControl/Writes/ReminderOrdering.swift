import Foundation
import GRDB

/// A live reminder `reminder-move` positions, or positions another one next to.
struct MovableReminder {
    let id: Int
    let title: String
    let ckid: String
    let listPk: Int
    let listName: String
    let parentPk: Int?

    /// `role` names the reminder in the refusal: "" for the one being moved, "anchor " for its anchor.
    init(store: RemindersStore, id: Int, role: String) throws {
        guard let row = store.reminder(pk: id), let ckid = row.string("ZCKIDENTIFIER"), !ckid.isEmpty else {
            throw CommandFailure("reminder_not_found", "\(role)#\(id) not found or has no stable identifier.")
        }
        self.id = id
        self.ckid = ckid
        title = row.string("ZTITLE") ?? ""
        listPk = row.int("ZLIST") ?? 0
        listName = row.string("list_name") ?? ""
        parentPk = row.int("ZPARENTREMINDER").flatMap { $0 == 0 ? nil : $0 }
    }
}

/// Where `reminder-move` puts a reminder: before/after an anchor, or first/last.
struct MovePosition {
    let relation: String
    let anchorId: Int?

    /// Port of `reminder_move_relation`: one placement, never relative to itself. Only a
    /// `--parent`/`--top-level` move may leave it out (nil), and then picks its own default.
    static func parse(id: Int, before: Int?, after: Int?, first: Bool, last: Bool,
                      hierarchyMove: Bool) throws -> MovePosition? {
        let choices: [(String, Int?)] = [before.map { ("before", $0) }, after.map { ("after", $0) },
                                         first ? ("first", nil) : nil, last ? ("last", nil) : nil].compactMap { $0 }
        if choices.isEmpty && hierarchyMove { return nil }
        guard choices.count == 1 else {
            throw CommandFailure("invalid_move", "pass exactly one of --before, --after, --first, or --last.")
        }
        if choices[0].1 == id {
            throw CommandFailure("invalid_move", "a reminder cannot be positioned relative to itself.")
        }
        return MovePosition(relation: choices[0].0, anchorId: choices[0].1)
    }
}

/// A move ready to write: the private call, and the order the store must show once it lands.
struct OrderingPlan {
    let write: (PrivateWriter) async throws -> PrivateResult
    let expected: [String]
    let readOrder: (RemindersStore) -> [String]
}

enum ReminderOrdering {
    /// Port of `cmd_reminder_move`'s list path (upstream 374c24d): both reminders share a list,
    /// and the move must produce `expected` in the list's persisted order.
    static func listPlan(store: RemindersStore, reminder: MovableReminder, position: MovePosition,
                         anchor: MovableReminder?) throws -> OrderingPlan {
        if let anchor, anchor.listPk != reminder.listPk {
            throw CommandFailure("invalid_move", "reminders in different lists require --smart-list or --smart-list-id.")
        }
        guard let listCkid = store.listCkid(pk: reminder.listPk) else {
            throw CommandFailure("list_missing_identifier", "target list has no stable identifier.")
        }
        let current = store.listReminderOrder(listPk: reminder.listPk)
        guard !current.isEmpty else {
            throw CommandFailure("order_unavailable", "this list has no readable ReminderKit ordering data.")
        }
        guard let expected = reorderIdentifiers(current, moving: reminder.ckid, position: position.relation,
                                                anchor: anchor?.ckid) else {
            throw CommandFailure("anchor_unpositioned", "the anchor has no persisted position in this list.")
        }
        return OrderingPlan(
            write: { try await $0.moveReminderInList(id: reminder.ckid, listId: listCkid, position: position.relation,
                                                     anchorId: anchor?.ckid) },
            expected: expected,
            readOrder: { $0.listReminderOrder(listPk: reminder.listPk) })
    }

    /// Port of `_smart_list_move_request` (upstream 374c24d): an unsectioned custom smart list
    /// whose manual order already records the reminder. Sectioned smart lists are refused here,
    /// before anything is written.
    static func smartListPlan(store: RemindersStore, smartList: SmartListTarget, reminder: MovableReminder,
                              position: MovePosition, anchor: MovableReminder?) throws -> OrderingPlan {
        guard smartList.isCustom, let smartListCkid = smartList.objectUUID else {
            throw CommandFailure("smart_list_not_custom", "reminder positioning currently supports custom smart lists only.")
        }
        let listType = RemindersStore.customSmartListManualOrderType
        guard let hint = store.manualSortHint(listType: listType, listId: smartListCkid) else {
            throw CommandFailure("order_unavailable",
                                 "this smart list has no manual-order hint yet. Reorder one reminder in Reminders.app once, then retry.")
        }
        guard store.smartListSections(smartListPk: smartList.id).isEmpty, hint.secondaryLevelElementIDs.isEmpty else {
            throw CommandFailure("sectioned_smart_list", "reminder positioning in sectioned custom smart lists is not supported yet.")
        }
        let folded = unicodeCasefold(reminder.ckid)
        guard hint.topLevelElementIDs.contains(where: { unicodeCasefold($0) == folded }) else {
            throw CommandFailure("reminder_unpositioned",
                                 "#\(reminder.id) has no persisted position in smart list \(WriteFormatting.pyRepr(smartList.title)).")
        }
        guard let expected = reorderIdentifiers(hint.topLevelElementIDs, moving: reminder.ckid,
                                                position: position.relation, anchor: anchor?.ckid) else {
            throw CommandFailure("anchor_unpositioned", "the anchor has no persisted manual position in this smart list. "
                                 + "Move the anchor once in Reminders.app or use --first/--last.")
        }
        let movingID = expected.first { unicodeCasefold($0) == folded } ?? reminder.ckid
        return OrderingPlan(
            write: { try await $0.setSmartListManualOrder(id: movingID, smartListId: smartListCkid,
                                                          manualOrderingId: hint.objectUUID, topLevelElementIds: expected) },
            expected: expected,
            readOrder: { $0.manualSortHint(listType: listType, listId: smartListCkid)?.topLevelElementIDs ?? [] })
    }

    /// Writes the move, then waits for the store to show the planned order. A helper error whose
    /// move landed anyway counts as done (`helperError`), as upstream reports it.
    static func apply(_ plan: OrderingPlan, store: RemindersStore, private priv: PrivateWriter,
                      readback: Readback) async throws -> (result: PrivateResult, helperError: Bool) {
        let result = try await plan.write(priv)
        let expected = plan.expected.map(unicodeCasefold)
        let verified = await readback.waitUntil { plan.readOrder(store).map(unicodeCasefold) == expected }
        guard verified else {
            if result.status != "updated" {
                throw CommandFailure("private_write_failed", result.message ?? "private helper failed")
            }
            throw CommandFailure("order_unverified", "ReminderKit reported success, but the new reminder order could not be verified.")
        }
        return (result, result.status != "updated")
    }
}
