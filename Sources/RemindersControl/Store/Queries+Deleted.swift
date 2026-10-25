import GRDB
import Foundation

extension RemindersStore {
    /// How many identifiers one `IN (...)` lookup carries, so a long recovery list stays well
    /// inside SQLite's bound-parameter limit (upstream a413c19).
    static let deletedReminderBatch = 400

    /// The tombstone rows behind the identifiers Apple's Recently Deleted view named, keyed by
    /// lowercased `ZCKIDENTIFIER`. `ZMARKEDFORDELETION = 1` also matches rows Reminders has
    /// already purged, so this only DECORATES the recovery view with the numeric ids and fields
    /// every read reports — it NEVER decides what is recoverable. A deleted reminder's list is
    /// cleared, so `list_name` is normally null.
    public func deletedReminders(identifiers: [String]) -> [String: Row] {
        let cols = remCols()  // built OUTSIDE the read (reentrancy)
        var rows: [String: Row] = [:]
        for start in stride(from: 0, to: identifiers.count, by: RemindersStore.deletedReminderBatch) {
            let batch = Array(identifiers[start..<min(start + RemindersStore.deletedReminderBatch, identifiers.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let sql = "SELECT \(cols) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK "
                + "WHERE lower(r.ZCKIDENTIFIER) IN (\(placeholders)) "
                + "AND r.ZMARKEDFORDELETION = 1 AND r.ZACCOUNT IS NOT NULL"
            let fetched = (try? queue.read {
                try Row.fetchAll($0, sql: sql, arguments: StatementArguments(batch))
            }) ?? []
            for row in fetched {
                guard let identifier = row.string("ZCKIDENTIFIER"), !identifier.isEmpty else { continue }
                rows[identifier.lowercased()] = row
            }
        }
        return rows
    }
}
