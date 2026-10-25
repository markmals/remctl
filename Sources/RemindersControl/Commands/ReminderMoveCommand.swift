import ArgumentParser
import Foundation

let reminderMoveCommands: [ParsableCommand.Type] = [ReminderMove.self]

struct ReminderMove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder-move",
        abstract: "Reorder a reminder in its list or in a custom smart list.",
        discussion: "Without --smart-list, both reminders must share a list. Use --smart-list for cross-list "
            + "ordering in an unsectioned, manually ordered custom smart list.")

    @Argument(help: "Reminder numeric ID") var id: Int
    @Option(name: .long, help: "Place immediately before reminder ID") var before: Int?
    @Option(name: .long, help: "Place immediately after reminder ID") var after: Int?
    @Flag(name: .long, help: "Place first in the current ordering") var first = false
    @Flag(name: .long, help: "Place last in the current ordering") var last = false
    @Option(name: .customLong("smart-list"), help: "Custom smart list containing the reminder") var smartList: String?
    @Option(name: .customLong("smart-list-id"), help: "Custom smart list numeric ID") var smartListId: Int?
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let request = ReminderMoveRequest(id: id, before: before, after: after, first: first, last: last,
                                          smartList: smartList, smartListId: smartListId)
        let json = json
        WriteDispatch.emit(await WriteDispatch.runShellPrivate(json: json) { store, priv in
            try await Self.perform(request, json: json, store: store, private: priv)
        })
    }

    /// Port of `cmd_reminder_move` (upstream 374c24d). Everything is validated before the write,
    /// and the move is reported only once the store shows the new order (`verified: true`).
    static func perform(_ request: ReminderMoveRequest, json: Bool, store: RemindersStore,
                        private priv: PrivateWriter, readback: Readback = .standard) async throws -> WriteOutcome {
        let position = try MovePosition(id: request.id, before: request.before, after: request.after,
                                        first: request.first, last: request.last)
        let reminder = try MovableReminder(store: store, id: request.id, role: "")
        let anchor = try position.anchorId.map { try MovableReminder(store: store, id: $0, role: "anchor ") }

        let smartList: SmartListTarget?
        let plan: OrderingPlan
        if request.smartList != nil || request.smartListId != nil {
            let target = try resolveSmartListTarget(store: store, name: request.smartList, smartListId: request.smartListId)
            plan = try ReminderOrdering.smartListPlan(store: store, smartList: target, reminder: reminder,
                                                      position: position, anchor: anchor)
            smartList = target
        } else {
            try refuseSubtasks(reminder: reminder, anchor: anchor)
            plan = try ReminderOrdering.listPlan(store: store, reminder: reminder, position: position, anchor: anchor)
            smartList = nil
        }
        let outcome = try await ReminderOrdering.apply(plan, store: store, private: priv, readback: readback)

        if json {
            var pairs: [(String, JSONValue)] = [
                ("status", .string("updated")), ("id", .int(reminder.id)), ("title", .string(reminder.title)),
                ("position", .string(position.relation)), ("verified", .bool(true)),
            ]
            if outcome.helperError { pairs.append(("verifiedAfterHelperError", .bool(true))) }
            if let anchor { pairs += [("anchorId", .int(anchor.id)), ("anchorTitle", .string(anchor.title))] }
            pairs.append(smartList.map { ("smartList", .string($0.title)) } ?? ("list", .string(reminder.listName)))
            return .ok(JSONValue.object(pairs).serialized(indent: nil, ensureAscii: false) + "\n")
        }
        let destination = smartList.map { "smart list \(WriteFormatting.pyRepr($0.title))" }
            ?? "list \(WriteFormatting.pyRepr(reminder.listName))"
        let anchorText = anchor.map { " #\($0.id)" } ?? ""
        return .ok("Moved #\(reminder.id) \(position.relation)\(anchorText) in \(safeDisplay(destination)).\n")
    }

    /// A list's own ordering record places top-level reminders; subtasks follow their parent.
    private static func refuseSubtasks(reminder: MovableReminder, anchor: MovableReminder?) throws {
        if reminder.parentPk != nil {
            throw CommandFailure("subtask_move_unsupported", "#\(reminder.id) is a subtask; reordering subtasks is not supported yet.")
        }
        if let anchor, anchor.parentPk != nil {
            throw CommandFailure("invalid_move", "anchor #\(anchor.id) is a subtask; position reminders relative to top-level reminders.")
        }
    }
}

/// What `reminder-move` was asked to do.
struct ReminderMoveRequest {
    var id: Int
    var before: Int?
    var after: Int?
    var first = false
    var last = false
    var smartList: String?
    var smartListId: Int?
}
