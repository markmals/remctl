import GRDB
import Foundation

// Reads the clone-delete list move needs: the subtasks that must travel with a parent,
// and the verification read that proves the clone landed before the original is deleted
// (ports of `q_subtasks_for_parent` / `wait_for_cloned_reminder_tree`, upstream ed5e982).

extension RemindersStore {
    /// Every subtask of `parentPk`, completed ones included — they all move with the parent.
    public func subtasksForMove(parentPk: Int, limit: Int = 500) -> [Row] {
        reminders(completed: true, parentPk: parentPk, limit: limit)
    }

    /// The cloned reminder once it is visible in `listPk` with `expectedSubtasks` children,
    /// or nil. ReminderKit writes land in the SQLite store asynchronously, so the caller
    /// polls this before deleting the original.
    public func clonedReminderTree(identifier: String, listPk: Int, expectedSubtasks: Int) -> (row: Row, subtasks: [Row])? {
        guard let row = reminder(identifier: identifier), row.int("ZLIST") == listPk,
              let pk = row.int("Z_PK") else { return nil }
        let subtasks = subtasksForMove(parentPk: pk, limit: max(500, expectedSubtasks + 5))
        guard subtasks.count == expectedSubtasks else { return nil }
        return (row, subtasks)
    }
}
