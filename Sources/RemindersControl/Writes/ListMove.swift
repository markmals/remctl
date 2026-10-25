import Foundation
import GRDB

/// A verified clone-delete list move (upstream ed5e982, generalized by cd31b51).
public struct CloneDeleteMove: Equatable {
    public var newId: Int
    public var oldId: Int
    public var listTitle: String
    public var objectUUID: String
    public var subtasksMoved: Int
    public var originalDeleted: Bool
}

/// A clone-delete failure with a structured JSON error code.
public struct CloneMoveError: Error, Equatable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }

    public func outcome(json: Bool) -> WriteOutcome {
        if json {
            let payload: JSONValue = .object([
                ("status", .string("error")),
                ("code", .string(code)),
                ("message", .string(message)),
            ])
            return WriteOutcome(stderr: payload.serialized(indent: nil, ensureAscii: true) + "\n", exitCode: 1)
        }
        return .error(message)
    }
}

/// EventKit cannot move a reminder that owns subtasks, and it refuses some moves across
/// list/container boundaries outright. Both cases are handled by cloning the tree into the
/// destination through ReminderKit, verifying the clone, then deleting the original.
public enum ListMove {
    /// EventKit save failures that look like a list/container-boundary rejection rather than a
    /// malformed request. Only those are retried as a clone-delete move (upstream cd31b51).
    public static func failureAllowsCloneDelete(_ message: String) -> Bool {
        let text = message.lowercased()
        guard !isAccessFailure(text) else { return false }
        guard text.contains("update failed:") || text.contains("save failed:") else { return false }
        let exclusions = ["not found", "invalid", "required", "calendar item", "identifier"]
        guard !exclusions.contains(where: { text.contains($0) }) else { return false }
        let needles = [
            "calendar", "container", "account", "caldav", "different store", "different source",
            "not editable", "not writable", "immutable", "move",
        ]
        return needles.contains(where: { text.contains($0) })
    }

    /// A permission failure is never a boundary rejection; retrying it as a clone would just
    /// fail again with a worse message.
    private static func isAccessFailure(_ lowercasedMessage: String) -> Bool {
        let needles = [
            "eventkit access error", "reminders access not granted", "not authorized",
            "authorization", "not permitted", "mach error 4099",
        ]
        return needles.contains(where: { lowercasedMessage.contains($0) })
    }

    /// Clones `row` plus `childRows` into `target`, waits for the clone to appear in the store,
    /// then deletes the original. Throws `CloneMoveError` with the original left in place
    /// whenever the clone cannot be verified.
    public static func cloneDelete(
        store: RemindersStore, row: Row, childRows: [Row],
        target: (id: Int, title: String, objectUUID: String?),
        writer: RemindersWriter, private priv: PrivateWriter,
        attempts: Int = 24, delay: Double = 0.25
    ) async throws -> CloneDeleteMove {
        let pk = row.int("Z_PK") ?? 0
        guard let reminderCkid = row.string("ZCKIDENTIFIER"), !reminderCkid.isEmpty else {
            throw CloneMoveError(code: "clone_move_missing_reminder_identifier",
                                 message: "cannot clone-move reminder because it has no stable ReminderKit identifier.")
        }
        guard let targetCkid = target.objectUUID, !targetCkid.isEmpty else {
            throw CloneMoveError(code: "clone_move_missing_list_identifier",
                                 message: "cannot clone-move reminder because the target list has no stable ReminderKit identifier.")
        }
        var childIds: [String] = []
        var missing: [Int] = []
        for child in childRows {
            if let ckid = child.string("ZCKIDENTIFIER"), !ckid.isEmpty { childIds.append(ckid) }
            else { missing.append(child.int("Z_PK") ?? 0) }
        }
        guard missing.isEmpty else {
            throw CloneMoveError(
                code: "clone_move_missing_subtask_identifiers",
                message: "cannot move parent with subtasks because these subtasks have no stable ReminderKit identifier: "
                    + missing.map { "#\($0)" }.joined(separator: ", "))
        }

        let result = try await priv.cloneReminderTree(id: reminderCkid, listId: targetCkid, childIds: childIds)
        guard result.status == "cloned" else {
            throw CloneMoveError(code: "clone_move_failed",
                                 message: "failed to clone reminder into target list: \(result.message ?? "private helper failed")")
        }
        guard case let .string(newCkid)? = result.fields["newId"], !newCkid.isEmpty else {
            throw CloneMoveError(code: "clone_move_missing_new_identifier",
                                 message: "private helper cloned the reminder but did not return the new reminder identifier.")
        }
        guard let clone = await waitForClone(store: store, identifier: newCkid, listPk: target.id,
                                             expectedSubtasks: childRows.count, attempts: attempts, delay: delay) else {
            throw CloneMoveError(
                code: "clone_move_unverified",
                message: "cloned reminder tree was not visible in the target list with the expected subtask count. "
                    + "Original #\(pk) was not deleted.")
        }

        do {
            _ = try await writer.delete(id: reminderCkid)
        } catch {
            let title = row.string("ZTITLE") ?? "(untitled)"
            throw CloneMoveError(
                code: "clone_move_original_not_deleted",
                message: "cloned '\(safeDisplay(title))' into the target list, but failed to delete "
                    + "original #\(pk). Leaving both reminders in place to avoid data loss.")
        }
        return CloneDeleteMove(
            newId: clone.row.int("Z_PK") ?? 0, oldId: pk, listTitle: target.title,
            objectUUID: newCkid, subtasksMoved: clone.subtasks.count, originalDeleted: true)
    }

    private static func waitForClone(store: RemindersStore, identifier: String, listPk: Int,
                                     expectedSubtasks: Int, attempts: Int, delay: Double) async -> (row: Row, subtasks: [Row])? {
        for attempt in 0..<max(1, attempts) {
            if let found = store.clonedReminderTree(identifier: identifier, listPk: listPk,
                                                    expectedSubtasks: expectedSubtasks) {
                return found
            }
            if attempt + 1 < attempts, delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        return nil
    }

    /// Output shape of a clone-delete move (upstream `emit_clone_delete_move_result`). The new
    /// numeric id differs from the requested one, so agents get `oldId` alongside it.
    public static func outcome(_ move: CloneDeleteMove, json: Bool,
                               resolution: (requested: String, title: String, id: Int, method: String)?) -> WriteOutcome {
        if json {
            var pairs: [(String, JSONValue)] = [
                ("status", .string("updated")),
                ("id", .int(move.newId)),
                ("oldId", .int(move.oldId)),
                ("list", .string(move.listTitle)),
                ("objectUUID", .string(move.objectUUID)),
                ("subtasksMoved", .int(move.subtasksMoved)),
                ("method", .string("clone-delete")),
                ("originalDeleted", .bool(move.originalDeleted)),
            ]
            if let resolution, resolution.method != "exact" {
                pairs.append(("resolvedList", .object([
                    ("requested", .string(resolution.requested)),
                    ("title", .string(resolution.title)),
                    ("id", .int(resolution.id)),
                    ("method", .string(resolution.method)),
                ])))
            }
            return .ok(JSONValue.object(pairs).serialized(indent: nil, ensureAscii: true) + "\n")
        }
        var out = "Moved #\(move.oldId) -> #\(move.newId)\n"
        out += "List: \(safeDisplay(move.listTitle))\n"
        out += "Subtasks: \(move.subtasksMoved)\n"
        return .ok(out)
    }
}
