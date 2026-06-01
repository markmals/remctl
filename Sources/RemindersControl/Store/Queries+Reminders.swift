import GRDB
import Foundation

extension RemindersStore {
    /// q_reminders: WHERE base + optional list/parent/topLevel + completed filter; ORDER BY r.Z_PK LIMIT n.
    public func reminders(listPk: Int? = nil, completed: Bool = false,
                          parentPk: Int? = nil, topLevel: Bool = false, limit: Int = 500) -> [Row] {
        var c = ["r.ZMARKEDFORDELETION = 0", "r.ZACCOUNT IS NOT NULL"]
        var args: [DatabaseValueConvertible] = []
        if !completed { c.append("r.ZCOMPLETED = 0") }
        if let listPk { c.append("r.ZLIST = ?"); args.append(listPk) }
        if let parentPk { c.append("r.ZPARENTREMINDER = ?"); args.append(parentPk) }
        else if topLevel { c.append("(r.ZPARENTREMINDER IS NULL OR r.ZPARENTREMINDER = 0)") }
        let cols = remCols()  // built OUTSIDE the read (reentrancy)
        args.append(limit)
        let sql = "SELECT \(cols) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE \(c.joined(separator: " AND ")) ORDER BY r.Z_PK LIMIT ?"
        return (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: StatementArguments(args)) }) ?? []
    }

    public func reminder(pk: Int) -> Row? {
        let cols = remCols()
        let sql = "SELECT \(cols) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE r.Z_PK = ? AND r.ZMARKEDFORDELETION = 0 AND r.ZACCOUNT IS NOT NULL"
        return try? queue.read { try Row.fetchOne($0, sql: sql, arguments: [pk]) }
    }

    public func reminder(identifier: String) -> Row? {
        guard !identifier.isEmpty else { return nil }
        let cols = remCols()
        let sql = "SELECT \(cols) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE lower(r.ZCKIDENTIFIER) = lower(?) AND r.ZMARKEDFORDELETION = 0 AND r.ZACCOUNT IS NOT NULL ORDER BY r.Z_PK DESC LIMIT 1"
        return try? queue.read { try Row.fetchOne($0, sql: sql, arguments: [identifier]) }
    }

    public func subtaskCount(pk: Int) -> Int {
        (try? queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ZREMCDREMINDER WHERE ZPARENTREMINDER = ? AND ZMARKEDFORDELETION = 0 AND ZCOMPLETED = 0", arguments: [pk]) }) ?? 0
    }

    /// Port of `early_reminder_identifiers_for_reminder` (remctl:2522).
    /// Looks up the reminder by ckid and returns the existing due-date delta-alert
    /// `identifier`s (so a `set_early_reminder` write can replace them). A missing
    /// reminder or absent/invalid blob yields `[]`.
    public func earlyReminderIdentifiers(reminderCkid: String) -> [String] {
        guard !reminderCkid.isEmpty, let row = reminder(identifier: reminderCkid) else { return [] }
        // ts is irrelevant for identifier extraction (creationDate is optional); pass a no-op.
        return dueDateDeltaAlertsFromRow(row, ts: { _ in nil }).compactMap { alert in
            for (k, v) in alert where k == "identifier" {
                if case let .string(s) = v, !s.isEmpty { return s }
            }
            return nil
        }
    }
}

extension RemindersStore {
    /// Shared list-view runner. `extra` is the full WHERE body; `order` is the ORDER BY (+ optional LIMIT) tail.
    private func reminderListView(where extra: String, args: [DatabaseValueConvertible], order: String) -> [Row] {
        let cols = remCols()  // OUTSIDE the read (reentrancy)
        let sql = "SELECT \(cols) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE \(extra) ORDER BY \(order)"
        return (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: StatementArguments(args)) }) ?? []
    }

    /// q_search — LIKE escape (backslash, then % and _), match ZTITLE OR ZNOTES, ORDER BY Z_PK DESC LIMIT 100.
    public func search(_ query: String, completed: Bool = false) -> [Row] {
        let safe = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pat = "%\(safe)%"
        var w = ["r.ZMARKEDFORDELETION = 0", "r.ZACCOUNT IS NOT NULL", "l.Z_PK IS NOT NULL",
                 "(r.ZTITLE LIKE ? ESCAPE '\\' OR r.ZNOTES LIKE ? ESCAPE '\\')"]
        if !completed { w.append("r.ZCOMPLETED = 0") }
        return reminderListView(where: w.joined(separator: " AND "), args: [pat, pat], order: "r.Z_PK DESC LIMIT 100")
    }

    public func dueToday(includeOverdue: Bool = true, now: Date = Date()) -> [Row] {
        let (sod, eod) = DateWindows.dueTodayWindow(now)
        let due = dueFilterExpr()  // display-date-aware for all-day items
        let w: String
        if includeOverdue { w = "\(due) < \(AppleEpoch.toTs(eod)) AND \(due) IS NOT NULL" }
        else { w = "\(due) >= \(AppleEpoch.toTs(sod)) AND \(due) < \(AppleEpoch.toTs(eod))" }
        return reminderListView(where: "r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND \(w)", args: [], order: due)
    }

    public func upcoming(days: Int = 7, now: Date = Date()) -> [Row] {
        let (sod, future) = DateWindows.upcomingWindow(days: days, now: now)
        let due = dueFilterExpr()  // display-date-aware for all-day items
        return reminderListView(where: "r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND \(due) IS NOT NULL AND \(due) >= \(AppleEpoch.toTs(sod)) AND \(due) < \(AppleEpoch.toTs(future))", args: [], order: due)
    }

    public func overdue(now: Date = Date()) -> [Row] {
        let sod = DateWindows.startOfDay(now)
        let due = dueFilterExpr()  // display-date-aware for all-day items
        return reminderListView(where: "r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND \(due) IS NOT NULL AND \(due) < \(AppleEpoch.toTs(sod))", args: [], order: due)
    }

    public func flagged() -> [Row] {
        reminderListView(where: "r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND r.ZFLAGGED = 1", args: [], order: "r.ZDUEDATE NULLS LAST")
    }

    public func urgent() -> [Row] {
        let w = urgentWhereClause()  // OUTSIDE the read
        return reminderListView(where: "r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND \(w)", args: [], order: "r.ZDUEDATE NULLS LAST")
    }
}
