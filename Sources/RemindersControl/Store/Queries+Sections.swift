import GRDB
import Foundation

extension RemindersStore {
    /// All sections ordered by list name then Z_PK, with list_name joined in.
    public func sectionsAll() -> [Row] {
        let sql = """
        SELECT s.Z_PK, s.ZDISPLAYNAME, s.ZLIST, s.ZCKIDENTIFIER, l.ZNAME as list_name
        FROM ZREMCDBASESECTION s
        LEFT JOIN ZREMCDBASELIST l ON s.ZLIST = l.Z_PK
        WHERE s.ZMARKEDFORDELETION = 0
        ORDER BY l.ZNAME, s.Z_PK
        """
        return (try? queue.read { try Row.fetchAll($0, sql: sql) }) ?? []
    }
}
