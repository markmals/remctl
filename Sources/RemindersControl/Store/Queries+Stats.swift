import GRDB
import Foundation

extension RemindersStore {
    public func statTotal() -> Int {
        count("SELECT COUNT(*) FROM ZREMCDREMINDER WHERE ZMARKEDFORDELETION = 0 AND ZACCOUNT IS NOT NULL")
    }
    public func statActive() -> Int {
        count("SELECT COUNT(*) FROM ZREMCDREMINDER WHERE ZMARKEDFORDELETION = 0 AND ZCOMPLETED = 0 AND ZACCOUNT IS NOT NULL")
    }
    public func statFlagged() -> Int {
        count("SELECT COUNT(*) FROM ZREMCDREMINDER WHERE ZMARKEDFORDELETION = 0 AND ZCOMPLETED = 0 AND ZFLAGGED = 1 AND ZACCOUNT IS NOT NULL")
    }
    public func statUrgent() -> Int {
        let w = urgentWhereClause()
        return count("SELECT COUNT(*) FROM ZREMCDREMINDER r WHERE r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND \(w)")
    }
    public func statOverdue(now: Date = Date()) -> Int {
        count("SELECT COUNT(*) FROM ZREMCDREMINDER r WHERE r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND r.ZDUEDATE IS NOT NULL AND r.ZDUEDATE < \(AppleEpoch.toTs(DateWindows.startOfDay(now)))")
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
