import GRDB
import Foundation

/// What every reminder read requires, so RemCTL shows what Reminders shows: the reminder
/// isn't deleted, it belongs to an account, and its list still exists and isn't deleted
/// either. Deleting a list can leave its reminder rows behind without the deleted flag.
/// Assumes the `r` (reminder) / `l` (joined list) aliases every reminder query uses.
/// The unary `+` keeps the deleted-flag tests off their own index so SQLite can use the
/// keyed index for the lookup instead (upstream #54).
let liveReminderSQL =
    "+r.ZMARKEDFORDELETION = 0 AND r.ZACCOUNT IS NOT NULL "
    + "AND l.Z_PK IS NOT NULL AND +l.ZMARKEDFORDELETION = 0"

/// Port of `sort_reminder_rows_by_identifier_order`. Rows absent from the ordering payload keep
/// their query order and follow the positioned rows, so a reminder that has not finished merging
/// into the list's ordering record is still listed.
func sortReminderRows(_ rows: [Row], identifierOrder: [String]) -> [Row] {
    var positions: [String: Int] = [:]
    for (index, identifier) in identifierOrder.enumerated() where !identifier.isEmpty {
        let key = unicodeCasefold(identifier)
        if positions[key] == nil { positions[key] = index }
    }
    guard !positions.isEmpty else { return rows }
    func position(_ row: Row) -> Int? {
        row.string("ZCKIDENTIFIER").flatMap { positions[unicodeCasefold($0)] }
    }
    return rows.enumerated().sorted { a, b in
        switch (position(a.element), position(b.element)) {
        case let (x?, y?): return x == y ? a.offset < b.offset : x < y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.offset < b.offset
        }
    }.map { $0.element }
}

extension RemindersStore {
    /// q_reminders: WHERE base + optional list/parent/topLevel + completed filter.
    /// `manualOrder` (and any subtask read, which always follows its parent list's record)
    /// returns rows in Reminders' persisted display order; otherwise ORDER BY r.Z_PK.
    public func reminders(listPk: Int? = nil, completed: Bool = false,
                          parentPk: Int? = nil, topLevel: Bool = false, limit: Int = 500,
                          manualOrder: Bool = false) -> [Row] {
        var identifierOrder: [String] = []
        if manualOrder, let listPk { identifierOrder = listReminderOrder(listPk: listPk) }
        if let parentPk, identifierOrder.isEmpty {
            // Subtasks share their parent's list, whose ordering record holds their display order.
            if let parentList = reminderListPk(parentPk) {
                identifierOrder = listReminderOrder(listPk: parentList)
            }
        }
        var c = [liveReminderSQL]
        var args: [DatabaseValueConvertible] = []
        if !completed { c.append("r.ZCOMPLETED = 0") }
        if let listPk { c.append("r.ZLIST = ?"); args.append(listPk) }
        if let parentPk { c.append("r.ZPARENTREMINDER = ?"); args.append(parentPk) }
        else if topLevel { c.append("(r.ZPARENTREMINDER IS NULL OR r.ZPARENTREMINDER = 0)") }
        let cols = remCols()  // built OUTSIDE the read (reentrancy)
        var sql = "SELECT \(cols) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE \(c.joined(separator: " AND ")) ORDER BY r.Z_PK"
        if identifierOrder.isEmpty {
            sql += " LIMIT ?"
            args.append(limit)
        }
        let rows = (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: StatementArguments(args)) }) ?? []
        guard !identifierOrder.isEmpty else { return rows }
        return Array(sortReminderRows(rows, identifierOrder: identifierOrder).prefix(limit))
    }

    /// Port of `q_reminders_for_lists`: the reminders of several lists at once, kept grouped in
    /// the order the list ids are passed in — what `show <group>` needs for a group's child
    /// lists. `manualOrder` sorts each list's rows by that list's own display-order record.
    public func reminders(listPks: [Int], completed: Bool = false, topLevel: Bool = false,
                          limit: Int = 500, manualOrder: Bool = false) -> [Row] {
        guard !listPks.isEmpty else { return [] }
        var identifierOrders: [Int: [String]] = [:]
        if manualOrder {
            for listPk in listPks { identifierOrders[listPk] = listReminderOrder(listPk: listPk) }
        }
        let hasIdentifierOrder = identifierOrders.values.contains { !$0.isEmpty }
        var c = [liveReminderSQL]
        let placeholders = Array(repeating: "?", count: listPks.count).joined(separator: ", ")
        c.append("r.ZLIST IN (\(placeholders))")
        if !completed { c.append("r.ZCOMPLETED = 0") }
        if topLevel { c.append("(r.ZPARENTREMINDER IS NULL OR r.ZPARENTREMINDER = 0)") }
        let orderCases = listPks.enumerated().map { "WHEN \($0.element) THEN \($0.offset)" }.joined(separator: " ")
        let cols = remCols()  // built OUTSIDE the read (reentrancy)
        var sql = "SELECT \(cols) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK "
            + "WHERE \(c.joined(separator: " AND ")) "
            + "ORDER BY CASE r.ZLIST \(orderCases) ELSE \(listPks.count) END, r.Z_PK"
        var args: [DatabaseValueConvertible] = listPks
        if !hasIdentifierOrder {
            sql += " LIMIT ?"
            args.append(limit)
        }
        let rows = (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: StatementArguments(args)) }) ?? []
        guard manualOrder else { return rows }
        var rowsByList: [Int: [Row]] = [:]
        for row in rows { rowsByList[row.int("ZLIST") ?? 0, default: []].append(row) }
        let ordered = listPks.flatMap { listPk in
            sortReminderRows(rowsByList[listPk] ?? [], identifierOrder: identifierOrders[listPk] ?? [])
        }
        return Array(ordered.prefix(limit))
    }

    /// Port of `q_list_reminder_order`: the list's persisted display order as stable identifiers.
    /// Missing column, unreadable blob, or a non-array payload all mean "no manual order".
    func listReminderOrder(listPk: Int) -> [String] {
        guard tableColumnNames("ZREMCDBASELIST").contains("ZREMINDERIDSMERGEABLEORDERING_V2_JSON") else { return [] }
        let row = (try? queue.read { try Row.fetchOne($0, sql:
            "SELECT ZREMINDERIDSMERGEABLEORDERING_V2_JSON FROM ZREMCDBASELIST WHERE Z_PK = ? AND ZMARKEDFORDELETION = 0",
            arguments: [listPk]) }) ?? nil
        guard let blob = row?.blobString("ZREMINDERIDSMERGEABLEORDERING_V2_JSON"),
              let data = blob.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return parsed.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    private func reminderListPk(_ pk: Int) -> Int? {
        (try? queue.read { try Int.fetchOne($0, sql: "SELECT ZLIST FROM ZREMCDREMINDER WHERE Z_PK = ?", arguments: [pk]) }) ?? nil
    }

    public func reminder(pk: Int) -> Row? {
        let cols = remCols()
        let sql = "SELECT \(cols) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE r.Z_PK = ? AND \(liveReminderSQL)"
        return try? queue.read { try Row.fetchOne($0, sql: sql, arguments: [pk]) }
    }

    public func reminder(identifier: String) -> Row? {
        guard !identifier.isEmpty else { return nil }
        let cols = remCols()
        let sql = "SELECT \(cols) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE lower(r.ZCKIDENTIFIER) = lower(?) AND \(liveReminderSQL) ORDER BY r.Z_PK DESC LIMIT 1"
        return try? queue.read { try Row.fetchOne($0, sql: sql, arguments: [identifier]) }
    }

    public func subtaskCount(pk: Int) -> Int {
        (try? queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ZREMCDREMINDER WHERE ZPARENTREMINDER = ? AND +ZMARKEDFORDELETION = 0 AND ZCOMPLETED = 0", arguments: [pk]) }) ?? 0
    }

    /// Port of `early_reminder_identifiers_for_reminder` (remctl:2522).
    /// Looks up the reminder by ckid and returns the existing due-date delta-alert
    /// `identifier`s (so a `set_early_reminder` write can replace them). Falls back to the
    /// `ZREMCDDUEDATEDELTAALERT` table when the envelope blob holds none (upstream 088fab4).
    /// A missing reminder, or an absent blob and table, yields `[]`.
    public func earlyReminderIdentifiers(reminderCkid: String) -> [String] {
        guard !reminderCkid.isEmpty, let row = reminder(identifier: reminderCkid) else { return [] }
        // ts is irrelevant for identifier extraction (creationDate is optional); pass a no-op.
        let fromBlob = alertIdentifiers(dueDateDeltaAlertsFromRow(row, ts: { _ in nil }))
        return fromBlob.isEmpty ? alertIdentifiers(earlyReminderAlerts(reminderCkid)) : fromBlob
    }

    private func alertIdentifiers(_ alerts: [[(String, JSONValue)]]) -> [String] {
        alerts.compactMap { alert in
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
        var w = [liveReminderSQL,
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
        return reminderListView(where: "\(liveReminderSQL) AND r.ZCOMPLETED = 0 AND \(w)", args: [], order: due)
    }

    public func upcoming(days: Int = 7, now: Date = Date()) -> [Row] {
        let (sod, future) = DateWindows.upcomingWindow(days: days, now: now)
        let due = dueFilterExpr()  // display-date-aware for all-day items
        return reminderListView(where: "\(liveReminderSQL) AND r.ZCOMPLETED = 0 AND \(due) IS NOT NULL AND \(due) >= \(AppleEpoch.toTs(sod)) AND \(due) < \(AppleEpoch.toTs(future))", args: [], order: due)
    }

    public func overdue(now: Date = Date()) -> [Row] {
        let sod = DateWindows.startOfDay(now)
        let due = dueFilterExpr()  // display-date-aware for all-day items
        return reminderListView(where: "\(liveReminderSQL) AND r.ZCOMPLETED = 0 AND \(due) IS NOT NULL AND \(due) < \(AppleEpoch.toTs(sod))", args: [], order: due)
    }

    public func flagged() -> [Row] {
        reminderListView(where: "\(liveReminderSQL) AND r.ZCOMPLETED = 0 AND r.ZFLAGGED = 1", args: [], order: "r.ZDUEDATE NULLS LAST")
    }

    public func urgent() -> [Row] {
        let w = urgentWhereClause()  // OUTSIDE the read
        return reminderListView(where: "\(liveReminderSQL) AND r.ZCOMPLETED = 0 AND \(w)", args: [], order: "r.ZDUEDATE NULLS LAST")
    }
}
