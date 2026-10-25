import ArgumentParser
import Foundation

let recoveryCommands: [ParsableCommand.Type] = [Deleted.self, Restore.self]

struct Deleted: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deleted",
        abstract: "Show recoverable reminders and their subtasks.",
        discussion: "Read Apple's Recently Deleted list. Results are paged; subtasks stay with their parent.")

    @Option(name: .long, help: "Reminders per page, 1-\(RemindersStore.searchMaxLimit); \(RemindersStore.searchDefaultLimit) when omitted")
    var limit: Int?
    @Option(name: .long, help: "Reminders to skip before this page; 0 when omitted") var offset: Int?
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let (limit, offset, json) = (limit, offset, json)
        WriteDispatch.emit(await WriteDispatch.perform(json: json) {
            let page = try recoveryPageArgs(limit: limit, offset: offset)
            let store = try RemindersStore.open()
            let items = try await RecentlyDeleted.read(store: store, private: PrivateWriterFactory.make())
            return Self.render(items, limit: page.limit, offset: page.offset, json: json)
        })
    }

    /// Port of `cmd_deleted`'s output: a page of PARENTS (their subtasks ride along nested), the
    /// totals a client needs to follow `nextOffset`, and the command that fetches the next page.
    static func render(_ items: [RecoveredReminder], limit: Int, offset: Int, json: Bool) -> WriteOutcome {
        let page = items.count > offset ? Array(items[offset..<min(offset + limit, items.count)]) : []
        let nextOffset = offset + page.count < items.count ? offset + page.count : nil
        if json {
            let payload: JSONValue = .object([
                ("items", .array(page.map { .object($0.payload) })),
                ("count", .int(page.count)),
                ("total", .int(items.count)),
                ("offset", .int(offset)),
                ("limit", .int(limit)),
                ("hasMore", .bool(nextOffset != nil)),
                ("nextOffset", nextOffset.map { JSONValue.int($0) } ?? .null),
            ])
            return .ok(payload.serialized(indent: 2, ensureAscii: true) + "\n")
        }
        var out = page.isEmpty ? "No recently deleted reminders\n" : ""
        for item in page {
            let subtasks = item.subtasks.isEmpty ? "" : " (\(item.subtasks.count) subtasks)"
            out += "  #\(item.id) \(safeDisplay(item.title))\(subtasks)\n"
        }
        if let nextOffset { out += "More results: \(CLIName.current) deleted --offset \(nextOffset) --limit \(limit)\n" }
        return .ok(out)
    }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Recover a deleted reminder into a list.",
        discussion: "Restore a reminder and its subtasks, keeping their IDs. The destination list "
            + "must be in the same account as the deleted reminder.")

    @Argument(help: "Reminder numeric ID from deleted") var id: Int
    @Option(name: [.short, .long], help: "Destination list name") var list: String?
    @Option(name: .long, help: "Destination list by stable numeric ID") var listId: Int?
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let (id, list, listId, json) = (id, list, listId, json)
        WriteDispatch.emit(await WriteDispatch.runShellPrivate(json: json) { store, priv in
            try await Self.perform(id: id, list: list, listId: listId, json: json,
                                   store: store, private: priv)
        })
    }

    /// Port of `cmd_restore` (upstream a413c19, c831b05, 972487f). The destination is resolved and
    /// the reminder proven recoverable before anything is written, and the recovery is reported
    /// only once the store shows the original ids and hierarchy in that list.
    static func perform(id: Int, list: String?, listId: Int?, json: Bool, store: RemindersStore,
                        private priv: PrivateWriter, readback: Readback = .standard) async throws -> WriteOutcome {
        let target = try resolveRequiredListTarget(store: store, name: list, listId: listId)
        var status = "restored"
        var pairs: [(String, JSONValue)] = []
        if let active = store.reminder(pk: id) {
            guard active.int("ZLIST") == target.id else {
                throw CommandFailure("reminder_not_deleted",
                                     "Reminder is already active in another list; restore does not move active reminders.")
            }
            // A no-op never claims the former subtasks came back with it (upstream c831b05), so
            // this reports neither a title read from the recovery view nor `verified`.
            status = "already_restored"
            pairs = [("list", .string(target.title))]
        } else {
            let item = try await recoverable(id: id, store: store, private: priv)
            guard let targetCkid = target.objectUUID, !targetCkid.isEmpty else {
                throw CommandFailure("restore_missing_list_identifier",
                                     "cannot restore into the destination list because it has no stable ReminderKit identifier.")
            }
            let result = try await priv.restoreReminder(id: item.identifier, listId: targetCkid)
            // A helper error whose save landed anyway still counts: the store is the authority.
            let verified = await readback.waitUntil {
                RecentlyDeleted.restored(item, store: store, listPk: target.id)
            }
            guard verified else {
                throw CommandFailure("restore_unconfirmed",
                                     (result.message ?? "Could not verify recovery of the reminder and all its subtasks.")
                                     + " Check info and deleted before retrying.")
            }
            pairs = [("title", .string(item.title)), ("list", .string(target.title)), ("verified", .bool(true))]
        }
        if json {
            let payload: JSONValue = .object([("status", .string(status)), ("id", .int(id))] + pairs)
            return .ok(payload.serialized(indent: nil, ensureAscii: false) + "\n")
        }
        return .ok("\(status.replacingOccurrences(of: "_", with: " ").capitalizedFirst): "
                   + "#\(id) in \(safeDisplay(target.title))\n")
    }

    /// The recovery-view entry `restore` may act on: present, and the top-level item of its tree.
    private static func recoverable(id: Int, store: RemindersStore,
                                    private priv: PrivateWriter) async throws -> RecoveredReminder {
        let items = try await RecentlyDeleted.read(store: store, private: priv)
        guard let item = RecentlyDeleted.find(items, id: id) else {
            throw CommandFailure("reminder_not_recoverable", "#\(id) is not in Recently Deleted.")
        }
        guard item.restoreId == id else {
            throw CommandFailure("restore_parent_required",
                                 "Restore parent #\(item.restoreId) to recover this subtask with its hierarchy.")
        }
        return item
    }
}

/// Port of `search_page_args` for the recovery reads, which page parents the same way `search`
/// pages matches. Bounds are checked before the store or ReminderKit is touched.
func recoveryPageArgs(limit: Int?, offset: Int?) throws -> (limit: Int, offset: Int) {
    if let limit, !(1...RemindersStore.searchMaxLimit).contains(limit) {
        throw CommandFailure("invalid_limit", "--limit must be between 1 and \(RemindersStore.searchMaxLimit).")
    }
    if let offset, offset < 0 {
        throw CommandFailure("invalid_offset", "--offset must be 0 or more.")
    }
    return (limit ?? RemindersStore.searchDefaultLimit, offset ?? 0)
}

extension String {
    /// Python `str.capitalize()`: first character upper, the rest lower.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst().lowercased()
    }
}
