import GRDB
import Foundation

public final class RemindersStore {
    public let queue: DatabaseQueue
    public let path: URL
    private var columnCache: [String: Set<String>] = [:]

    private init(queue: DatabaseQueue, path: URL) { self.queue = queue; self.path = path }

    /// Open the best-scoring Data-*.sqlite under storeDir, read-only.
    public static func open(storeDir: URL = Paths.resolveStoreDir()) throws -> RemindersStore {
        let dbPath = try Paths.findMainDB(storeDir: storeDir)
        var config = Configuration()
        config.readonly = true   // SQLITE_OPEN_READONLY ~ ?mode=ro; no WAL change
        let q = try DatabaseQueue(path: dbPath.path, configuration: config)
        // Schema guard (port upstream aba7cf5): refuse a sqlite file that isn't a
        // Reminders store, instead of failing later with confusing query errors.
        let hasReminderTable = (try? q.read { try $0.tableExists("ZREMCDREMINDER") }) ?? false
        guard hasReminderTable else {
            throw RemindersDBUnavailable(
                "Reminders store is missing the expected ZREMCDREMINDER table; "
                + "this macOS Reminders schema may need a RemCTL update.")
        }
        return RemindersStore(queue: q, path: dbPath)
    }

    public func tableColumnNames(_ table: String) -> Set<String> {
        if let c = columnCache[table] { return c }
        let cols = (try? queue.read { db in try Set(db.columns(in: table).map(\.name)) }) ?? []
        columnCache[table] = cols
        return cols
    }
    public func reminderHasColumn(_ col: String) -> Bool {
        tableColumnNames("ZREMCDREMINDER").contains(col)
    }
}
