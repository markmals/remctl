import GRDB
import Foundation

extension RemindersStore {
    /// All hashtag names in alphabetical order.
    public func allTagNames() -> [String] {
        (try? queue.read { try String.fetchAll($0, sql:
            "SELECT ZNAME FROM ZREMCDHASHTAGLABEL WHERE ZNAME IS NOT NULL ORDER BY ZNAME") }) ?? []
    }
}
