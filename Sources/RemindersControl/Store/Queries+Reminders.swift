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
}
