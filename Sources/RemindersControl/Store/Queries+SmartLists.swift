import GRDB
import Foundation

extension RemindersStore {
    /// q_smart_lists: smart lists (Z_ENT=4 or ZSMARTLISTTYPE set). Returns [] if ZSMARTLISTTYPE absent.
    public func smartLists() -> [Row] {
        let t = tableColumnNames("ZREMCDBASELIST")
        guard t.contains("ZSMARTLISTTYPE") else { return [] }
        var cols = ["Z_PK", "ZNAME", "ZCKIDENTIFIER", "ZSMARTLISTTYPE", "ZFILTERDATA",
                    "ZMINIMUMSUPPORTEDAPPVERSION", "ZEFFECTIVEMINIMUMSUPPORTEDAPPVERSION"]
        for c in ["ZBADGEEMBLEM", "ZCOLOR"] where t.contains(c) { cols.append(c) }
        for c in ["ZISPINNEDBYCURRENTUSER", "ZPINNEDDATE"] where t.contains(c) { cols.append(c) }
        let sql = "SELECT \(cols.joined(separator: ", ")) FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND (Z_ENT = 4 OR ZSMARTLISTTYPE IS NOT NULL) ORDER BY COALESCE(ZNAME, ''), Z_PK"
        return (try? queue.read { try Row.fetchAll($0, sql: sql) }) ?? []
    }
}
