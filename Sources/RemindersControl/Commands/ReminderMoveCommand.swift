import ArgumentParser
import Foundation

let reminderMoveCommands: [ParsableCommand.Type] = [ReminderMove.self]

struct ReminderMove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder-move",
        abstract: "Reorder a reminder, or nest it under another, in a list or custom smart list.",
        discussion: "Without --smart-list, both reminders must share a list. Use --smart-list for cross-list "
            + "ordering in an unsectioned, manually ordered custom smart list. --parent makes the reminder a "
            + "subtask of another top-level reminder in the same list, and --top-level makes a subtask a "
            + "reminder of its own; both keep the reminder's ID. A subtask moved with --before, --after, "
            + "--first, or --last stays with its parent.")

    @Argument(help: "Reminder numeric ID") var id: Int
    @Option(name: .long, help: "Place immediately before reminder ID") var before: Int?
    @Option(name: .long, help: "Place immediately after reminder ID") var after: Int?
    @Flag(name: .long, help: "Place first in the current ordering") var first = false
    @Flag(name: .long, help: "Place last in the current ordering") var last = false
    @Option(name: .long, help: "Make it a subtask of reminder ID; placed last unless a position is given") var parent: Int?
    @Flag(name: .customLong("top-level"), help: "Make a subtask a top-level reminder; placed after its parent unless a position is given") var topLevel = false
    @Option(name: .customLong("smart-list"), help: "Custom smart list containing the reminder") var smartList: String?
    @Option(name: .customLong("smart-list-id"), help: "Custom smart list numeric ID") var smartListId: Int?
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let request = ReminderMoveRequest(id: id, before: before, after: after, first: first, last: last,
                                          parent: parent, topLevel: topLevel, smartList: smartList, smartListId: smartListId)
        let json = json
        WriteDispatch.emit(await WriteDispatch.runShellPrivate(json: json) { store, priv in
            try await Self.perform(request, json: json, store: store, private: priv)
        })
    }

    /// Port of `cmd_reminder_move` (upstream 374c24d, 3eb076b). Everything is validated before the
    /// write, and the move is reported only once the store shows it (`verified: true`).
    static func perform(_ request: ReminderMoveRequest, json: Bool, store: RemindersStore,
                        private priv: PrivateWriter, readback: Readback = .standard) async throws -> WriteOutcome {
        let smartTargeted = request.smartList != nil || request.smartListId != nil
        let hierarchyFlags = request.parent != nil || request.topLevel
        if request.parent != nil && request.topLevel {
            throw CommandFailure("invalid_move", "pass either --parent or --top-level, not both.")
        }
        if smartTargeted && hierarchyFlags {
            throw CommandFailure("invalid_move", "--parent and --top-level work within a list, not a smart list.")
        }
        let position = try MovePosition.parse(id: request.id, before: request.before, after: request.after,
                                              first: request.first, last: request.last, hierarchyMove: hierarchyFlags)
        let reminder = try MovableReminder(store: store, id: request.id, role: "")
        let anchor = try position?.anchorId.map { try MovableReminder(store: store, id: $0, role: "anchor ") }

        if smartTargeted, let position {
            let target = try resolveSmartListTarget(store: store, name: request.smartList, smartListId: request.smartListId)
            let plan = try ReminderOrdering.smartListPlan(store: store, smartList: target, reminder: reminder,
                                                          position: position, anchor: anchor)
            return try await reorder(plan, reminder: reminder, position: position, anchor: anchor,
                                     destination: ("smartList", target.title), json: json, store: store, private: priv,
                                     readback: readback)
        }
        if hierarchyFlags || reminder.parentPk != nil {
            let targetParent = request.parent ?? (request.topLevel ? nil : reminder.parentPk)
            let move = try SubtaskHierarchy.plan(store: store, reminder: reminder, position: position, anchor: anchor,
                                                 targetParentPk: targetParent)
            return try await moveInHierarchy(move, json: json, store: store, private: priv, readback: readback)
        }
        if let anchor, let anchorParent = anchor.parentPk {
            throw CommandFailure("invalid_move", "anchor #\(anchor.id) is a subtask. Pass --parent \(anchorParent) "
                                 + "to place #\(reminder.id) among its subtasks.")
        }
        let listPosition = position!  // only a hierarchy move may omit the placement
        let plan = try ReminderOrdering.listPlan(store: store, reminder: reminder, position: listPosition, anchor: anchor)
        return try await reorder(plan, reminder: reminder, position: listPosition, anchor: anchor,
                                 destination: ("list", reminder.listName), json: json, store: store, private: priv,
                                 readback: readback)
    }

    private static func reorder(_ plan: OrderingPlan, reminder: MovableReminder, position: MovePosition,
                                anchor: MovableReminder?, destination: (key: String, title: String), json: Bool,
                                store: RemindersStore, private priv: PrivateWriter, readback: Readback) async throws -> WriteOutcome {
        let outcome = try await ReminderOrdering.apply(plan, store: store, private: priv, readback: readback)
        if json {
            var pairs: [(String, JSONValue)] = [
                ("status", .string("updated")), ("id", .int(reminder.id)), ("title", .string(reminder.title)),
                ("position", .string(position.relation)), ("verified", .bool(true)),
            ]
            if outcome.helperError { pairs.append(("verifiedAfterHelperError", .bool(true))) }
            if let anchor { pairs += [("anchorId", .int(anchor.id)), ("anchorTitle", .string(anchor.title))] }
            pairs.append((destination.key, .string(destination.title)))
            return .ok(JSONValue.object(pairs).serialized(indent: nil, ensureAscii: false) + "\n")
        }
        let place = destination.key == "smartList" ? "smart list" : "list"
        let anchorText = anchor.map { " #\($0.id)" } ?? ""
        return .ok("Moved #\(reminder.id) \(position.relation)\(anchorText) in \(place) "
                   + "\(WriteFormatting.pyRepr(safeDisplay(destination.title))).\n")
    }

    private static func moveInHierarchy(_ move: HierarchyMove, json: Bool, store: RemindersStore,
                                        private priv: PrivateWriter, readback: Readback) async throws -> WriteOutcome {
        let outcome = try await SubtaskHierarchy.apply(move, store: store, private: priv, readback: readback)
        let joined = try await SubtaskHierarchy.joinAnchorSection(move, store: store, private: priv, readback: readback)
        let reminder = move.reminder
        if json {
            var pairs: [(String, JSONValue)] = [
                ("status", .string("updated")), ("id", .int(reminder.id)), ("title", .string(reminder.title)),
                ("hierarchy", .string(move.hierarchy)), ("parentId", move.parent.map { .int($0.id) } ?? .null),
                ("position", .string(move.relation)), ("list", .string(reminder.listName)), ("verified", .bool(true)),
            ]
            if let parent = move.parent { pairs.append(("parentTitle", .string(parent.title))) }
            if let anchorPk = move.anchorPk { pairs.append(("anchorId", .int(anchorPk))) }
            if outcome.helperError { pairs.append(("verifiedAfterHelperError", .bool(true))) }
            if let section = joined.section { pairs.append(("section", .string(section))) }
            if let warning = joined.warning { pairs.append(("warnings", .array([.string(warning)]))) }
            return .ok(JSONValue.object(pairs).serialized(indent: nil, ensureAscii: false) + "\n")
        }
        let place = move.parent.map { "under #\($0.id) \(safeDisplay($0.title))" } ?? "to the top level"
        let anchorText = move.anchorPk.map { " (\(move.position) #\($0))" } ?? ""
        return WriteOutcome(
            stdout: "Moved #\(reminder.id) \(place)\(anchorText) in list \(WriteFormatting.pyRepr(safeDisplay(reminder.listName))).\n",
            stderr: joined.warning.map { "Warning: \($0)\n" } ?? "")
    }
}

/// What `reminder-move` was asked to do.
struct ReminderMoveRequest {
    var id: Int
    var before: Int?
    var after: Int?
    var first = false
    var last = false
    var parent: Int?
    var topLevel = false
    var smartList: String?
    var smartListId: Int?
}
