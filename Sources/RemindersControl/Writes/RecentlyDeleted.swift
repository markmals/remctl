import GRDB
import Foundation

/// One entry of Apple's Recently Deleted view, decorated with the RemCTL numeric id of its
/// tombstone row. `payload` is what `deleted` and `info --include-deleted` print.
public struct RecoveredReminder {
    public let id: Int
    public let title: String
    /// `ZCKIDENTIFIER`, the identifier the recovery view and the restore write both use.
    public let identifier: String
    /// The numeric id to pass to `restore`: this reminder when it is a top-level recovery item,
    /// otherwise the top-level parent that recovers the whole tree.
    public let restoreId: Int
    public let payload: [(String, JSONValue)]
    public let subtasks: [RecoveredReminder]
}

/// Port of `deleted_reminders` / `restored_tree_matches` (upstream a413c19, c831b05): Apple's
/// recovery view joined to RemCTL numeric ids, and the read-back that confirms a recovery.
public enum RecentlyDeleted {
    /// How deep a recovery tree may nest before RemCTL treats the response as corrupt.
    static let maxDepth = 32

    /// The recoverable reminders with their numeric ids and nested deleted subtasks. Every
    /// malformed or stale response fails closed; nothing falls back to old deletion records.
    public static func read(store: RemindersStore, private priv: PrivateWriter) async throws -> [RecoveredReminder] {
        let result = try await priv.recentlyDeleted()
        guard result.status == "ok", case let .array(native)? = result.fields["reminders"] else {
            throw CommandFailure("recently_deleted_unavailable",
                                 result.message ?? "Recently Deleted query failed.")
        }
        let rows = store.deletedReminders(identifiers: try identifiers(native))
        return try native.map { try convert($0, rows: rows, restoreId: nil) }
    }

    /// The item with this numeric id anywhere in the recovery trees, parent or subtask.
    public static func find(_ items: [RecoveredReminder], id: Int) -> RecoveredReminder? {
        for item in items {
            if item.id == id { return item }
            if let found = find(item.subtasks, id: id) { return found }
        }
        return nil
    }

    /// Whether `node` and every subtask under it are live in `listPk`, keeping their original
    /// identifiers and parent relationships. `parentPk` is the parent the tree expects (nil at
    /// the top level), so a flattened or renamed recovery never verifies.
    public static func restored(_ node: RecoveredReminder, store: RemindersStore,
                                listPk: Int, parentPk: Int? = nil) -> Bool {
        guard let row = store.reminder(pk: node.id), row.int("ZLIST") == listPk,
              let identifier = row.string("ZCKIDENTIFIER"),
              identifier.lowercased() == node.identifier.lowercased(),
              row.int("ZPARENTREMINDER").flatMap({ $0 == 0 ? nil : $0 }) == parentPk
        else { return false }
        return node.subtasks.allSatisfy { restored($0, store: store, listPk: listPk, parentPk: node.id) }
    }

    // MARK: - Decoding the recovery view

    /// Every identifier in the trees, depth-first, so one batched SQLite lookup covers them all.
    private static func identifiers(_ items: [JSONValue], depth: Int = 0) throws -> [String] {
        guard depth <= maxDepth else { throw unexpectedHierarchy }
        var collected: [String] = []
        for item in items {
            collected.append(try identifier(of: item))
            collected += try identifiers(try children(of: item), depth: depth + 1)
        }
        return collected
    }

    private static func convert(_ item: JSONValue, rows: [String: Row], restoreId: Int?) throws -> RecoveredReminder {
        guard let row = rows[try identifier(of: item)] else {
            throw CommandFailure("recently_deleted_changed",
                                 "Recently Deleted changed while reading. Refresh the list before restoring.")
        }
        let pk = row.int("Z_PK") ?? 0
        let restore = restoreId ?? pk
        let subtasks = try children(of: item).map { try convert($0, rows: rows, restoreId: restore) }
        var payload = serializeReminder(row, ts: { AppleEpoch.ts($0) }, priorityNames: Constants.priorityName)
        // serialize_reminder counts LIVE subtasks, of which a tombstone has none; the recovery
        // tree is what `restore` brings back, so its child count replaces that in place.
        if let index = payload.firstIndex(where: { $0.0 == "subtaskCount" }) {
            payload[index].1 = .int(subtasks.count)
        }
        payload += [("deleted", .bool(true)), ("recoverable", .bool(true)), ("restoreId", .int(restore))]
        if !subtasks.isEmpty {
            payload.append(("subtasks", .array(subtasks.map { .object($0.payload) })))
        }
        return RecoveredReminder(id: pk, title: row.string("ZTITLE") ?? "",
                                 identifier: row.string("ZCKIDENTIFIER") ?? "", restoreId: restore,
                                 payload: payload, subtasks: subtasks)
    }

    /// The canonical lowercased UUID of one entry, or a refusal when Reminders' shape changed.
    private static func identifier(of item: JSONValue) throws -> String {
        guard case let .object(fields) = item,
              case let .object(objectID)? = fields.first(where: { $0.0 == "objectID" })?.1,
              case let .string(raw)? = objectID.first(where: { $0.0 == "uuid" })?.1,
              let uuid = UUID(uuidString: raw)
        else { throw CommandFailure("recently_deleted_unavailable", "Unexpected Recently Deleted identifier.") }
        return uuid.uuidString.lowercased()
    }

    /// The entry's deleted subtasks: absent means none, anything but an array means the response
    /// no longer matches what RemCTL knows how to read.
    private static func children(of item: JSONValue) throws -> [JSONValue] {
        guard case let .object(fields) = item,
              let subtasks = fields.first(where: { $0.0 == "subtasks" })?.1 else { return [] }
        guard case let .array(children) = subtasks else { throw unexpectedHierarchy }
        return children
    }

    private static var unexpectedHierarchy: CommandFailure {
        CommandFailure("recently_deleted_unavailable", "Unexpected Recently Deleted hierarchy.")
    }
}
