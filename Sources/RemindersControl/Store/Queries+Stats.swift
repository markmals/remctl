import GRDB
import Foundation

/// The five reminder counters `stats` prints, from one scan over live reminders.
public struct ReminderStats {
    public var total: Int
    public var active: Int
    public var flagged: Int
    public var urgent: Int
    public var overdue: Int
}

extension RemindersStore {
    /// Port of `cmd_stats`' counting query: a single pass over live reminders, so a deleted
    /// list's leftover rows no longer inflate any counter.
    public func reminderStats(now: Date = Date()) -> ReminderStats {
        // Built OUTSIDE the read (reentrancy).
        let urgent = urgentWhereClause()
        let due = dueFilterExpr()
        let sod = AppleEpoch.toTs(DateWindows.startOfDay(now))
        let sql = "SELECT COUNT(*) AS total, "
            + "COUNT(CASE WHEN r.ZCOMPLETED = 0 THEN 1 END) AS active, "
            + "COUNT(CASE WHEN r.ZCOMPLETED = 0 AND r.ZFLAGGED = 1 THEN 1 END) AS flagged, "
            + "COUNT(CASE WHEN r.ZCOMPLETED = 0 AND \(urgent) THEN 1 END) AS urgent, "
            + "COUNT(CASE WHEN r.ZCOMPLETED = 0 AND \(due) < \(sod) THEN 1 END) AS overdue "
            + "FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK "
            + "WHERE \(liveReminderSQL)"
        guard let row = try? queue.read({ try Row.fetchOne($0, sql: sql) }) ?? nil else {
            return ReminderStats(total: 0, active: 0, flagged: 0, urgent: 0, overdue: 0)
        }
        return ReminderStats(total: row["total"] ?? 0, active: row["active"] ?? 0,
                             flagged: row["flagged"] ?? 0, urgent: row["urgent"] ?? 0,
                             overdue: row["overdue"] ?? 0)
    }

    public func statListCount() -> Int {
        count("SELECT COUNT(*) FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != ''")
    }
    public func statSectionCount() -> Int {
        count("SELECT COUNT(*) FROM ZREMCDBASESECTION WHERE ZMARKEDFORDELETION = 0")
    }
    private func count(_ sql: String) -> Int {
        (try? queue.read { try Int.fetchOne($0, sql: sql) ?? 0 }) ?? 0
    }
}
