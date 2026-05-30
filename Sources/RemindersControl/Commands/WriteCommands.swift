import ArgumentParser
import Foundation

let writeCommands: [ParsableCommand.Type] = [
    Add.self, Edit.self, Done.self, Undone.self, Delete.self,
    FlagCmd.self, Unflag.self, Link.self, Open.self,
]

struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a reminder.")

    @Argument(help: "Reminder title") var title: String
    @Option(name: [.short, .long], help: "Target list name") var list: String?
    @Option(name: .long, help: "Create in a list by stable numeric ID") var listId: Int?
    @Option(name: [.short, .long], help: "Notes / body") var notes: String?
    @Option(name: [.short, .long], help: "Due date (YYYY-MM-DD, today, tomorrow, Friday at 15:00, +3d, eod, eow)") var due: String?
    @Option(name: [.short, .long], help: "Priority: high, medium, low, or none") var priority: String?
    @Option(name: .long, help: "Recurrence: daily, weekly, 'weekly mon,wed,fri', 'monthly 1,15', yearly") var recurrence: String?
    @Option(name: .long, help: "Alarm: 15m, 1h, 1d, or an absolute date") var alarm: String?
    @Option(name: .long, help: "URL; appended to notes") var url: String?

    // Declared but Phase-3 (private ReminderKit metadata) — stubbed.
    @Flag(name: [.short, .long], help: "Flag the reminder (Phase 3)") var flag = false
    @Option(name: [.short, .long], help: "Comma-separated tags (Phase 3)") var tags: String?
    @Flag(name: .long, help: "Categorize in a Groceries list (Phase 3)") var grocery = false
    @Option(name: .long, help: "Assign to an existing section (Phase 3)") var section: String?
    @Option(name: .long, help: "Assign to a section by stable ID (Phase 3)") var sectionId: String?
    @Option(name: .long, help: "Create a section and assign this reminder (Phase 3)") var newSection: String?
    @Option(name: .long, help: "Add a subtask title or JSON object (repeatable, Phase 3)") var subtask: [String] = []
    @Option(name: .long, help: "Add an image attachment path (repeatable, Phase 3)") var image: [String] = []
    @Flag(inversion: .prefixedNo, help: "Set urgent state (Phase 3)") var urgent: Bool?
    @Option(name: .long, help: "Early Reminder before due date, e.g. 15m, 1h, 2d (Phase 3)") var earlyReminder: String?

    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShell { store, writer in
            try await Self.perform(
                title: args.title, list: args.list, listId: args.listId, notes: args.notes,
                due: args.due, priority: args.priority, recurrence: args.recurrence, alarm: args.alarm,
                url: args.url, flag: args.flag, tags: args.tags, grocery: args.grocery,
                section: args.section, sectionId: args.sectionId, newSection: args.newSection,
                subtask: args.subtask, image: args.image, urgent: args.urgent, earlyReminder: args.earlyReminder,
                json: args.json, store: store, writer: writer)
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_add`'s EventKit path.
    /// `now`/`calendar` are injected for deterministic due-date parsing.
    static func perform(
        title: String, list: String? = nil, listId: Int? = nil, notes: String? = nil,
        due: String? = nil, priority: String? = nil, recurrence: String? = nil, alarm: String? = nil,
        url: String? = nil, flag: Bool = false, tags: String? = nil, grocery: Bool = false,
        section: String? = nil, sectionId: String? = nil, newSection: String? = nil,
        subtask: [String] = [], image: [String] = [], urgent: Bool? = nil, earlyReminder: String? = nil,
        json: Bool, store: RemindersStore, writer: RemindersWriter,
        now: Date = Date(), calendar: Calendar = .current
    ) async throws -> WriteOutcome {

        // Title must be non-empty (argparse requires the positional; reject an empty/blank value).
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WriteError("title must not be empty.")
        }

        // 1. Validate inputs BEFORE any write or list resolution (mirrors cmd_add order).
        var dueDate: Date? = nil
        if let due, !due.isEmpty {
            guard let parsed = WriteParsing.parseDue(due, now: now, calendar: calendar) else {
                return failInvalidDueDate(due, json: json)   // exit 2
            }
            dueDate = parsed
        }

        var parsedRecurrence: RecurrenceWrite? = nil
        if let recurrence, !recurrence.isEmpty {
            guard let r = WriteParsing.parseRecurrenceSpec(recurrence) else {
                throw WriteError("could not parse recurrence \(pyRepr(recurrence)). Use daily, weekly, 'weekly mon,wed,fri', 'monthly 1,15', monthly, or yearly.")
            }
            parsedRecurrence = r
        }

        var parsedAlarm: AlarmWrite? = nil
        if let alarm, !alarm.isEmpty {
            guard let al = WriteParsing.parseAlarmSpec(alarm, allowClear: false) else {
                throw WriteError("could not parse alarm \(pyRepr(alarm)). Use 15m, 1h, 1d, or an absolute date.")
            }
            parsedAlarm = al
        }

        var priorityValue: Int? = nil
        if let priority, !priority.isEmpty {
            guard let p = WriteParsing.parsePriority(priority, allowAliases: true) else {
                throw WriteError("priority must be high, medium, low, or none.")
            }
            priorityValue = p
        }

        // 2. Phase-3 stub guard. Checked AFTER due/priority/alarm/recurrence validation
        //    (so a bad due still surfaces as exit 2 first) but BEFORE any write/list resolution.
        if flag { throw phase3("--flag") }
        if tags != nil { throw phase3("--tags") }
        if grocery { throw phase3("--grocery") }
        if section != nil { throw phase3("--section") }
        if sectionId != nil { throw phase3("--section-id") }
        if newSection != nil { throw phase3("--new-section") }
        if !subtask.isEmpty { throw phase3("--subtask") }
        if !image.isEmpty { throw phase3("--image") }
        if urgent != nil { throw phase3("--urgent") }
        if earlyReminder != nil { throw phase3("--early-reminder") }

        // 3. List resolution (only when a list name / id was given). EventKit uses the
        //    default list otherwise. Capture the resolution method for the resolvedList output.
        var resolvedListTitle: String? = nil
        var resolution: (requested: String, title: String, id: Int, method: String)? = nil
        if list != nil || listId != nil {
            let target = try resolveRequiredListTarget(store: store, name: list, listId: listId)
            resolvedListTitle = target.title
            let requested = listId != nil ? String(listId!) : (list ?? "")
            let method = resolveMethod(store: store, name: list, listId: listId, resolvedTitle: target.title)
            resolution = (requested: requested, title: target.title, id: target.id, method: method)
        }

        // 4. Build the ReminderWrite.
        var write = ReminderWrite()
        write.title = title
        if let resolvedListTitle { write.list = resolvedListTitle }
        if let notes, !notes.isEmpty { write.notes = notes }
        if let dueDate { write.due = .set(dueDate) }
        if let priorityValue { write.priority = priorityValue }
        if let url, !url.isEmpty { write.url = url }   // EventKitWriter appends to notes (Phase 2)
        if let parsedRecurrence { write.recurrence = parsedRecurrence }
        if let parsedAlarm { write.alarm = parsedAlarm }

        // 5. Create.
        let result = try await writer.create(write)

        // 6. Re-read for the numeric Z_PK by the created ZCKIDENTIFIER.
        let numericId = result.id.flatMap { store.reminder(identifier: $0)?.int("Z_PK") }

        // 7. Output.
        if json {
            var pairs: [(String, JSONValue)] = [
                ("status", .string("created")),
                ("id", .string(result.id ?? "")),
                ("title", .string(title)),
            ]
            if let resolution, resolution.method != "exact" {
                pairs.append(("resolvedList", .object([
                    ("requested", .string(resolution.requested)),
                    ("title", .string(resolution.title)),
                    ("id", .int(resolution.id)),
                    ("method", .string(resolution.method)),
                ])))
            }
            if let numericId { pairs.append(("numericId", .int(numericId))) }
            return .ok(JSONValue.object(pairs).serialized(indent: nil, ensureAscii: true) + "\n")
        }
        var out = "Created: \(safeDisplay(title))\n"
        if let resolution, resolution.method != "exact" {
            out += "List: \(safeDisplay(resolution.title)) (resolved from \(safeDisplay(resolution.requested)))\n"
        }
        if let numericId { out += "ID: #\(numericId)\n" }
        return .ok(out)
    }

    /// Build the exit-2 invalid-due-date outcome (mirrors `fail_invalid_due_date`).
    /// JSON mode prints the structured payload to stderr; otherwise the multi-line human message.
    static func failInvalidDueDate(_ value: String, json: Bool, field: String = "due", now: Date = Date(), calendar: Calendar = .current) -> WriteOutcome {
        let examples = dueDateExamples(now: now, calendar: calendar)
        if json {
            let payload: JSONValue = .object([
                ("status", .string("error")),
                ("code", .string("invalid_due_date")),
                ("field", .string(field)),
                ("input", .string(value)),
                ("message", .string("Could not parse due date. No reminder was created or changed.")),
                ("examples", .array(examples.map { .string($0) })),
            ])
            return WriteOutcome(stderr: payload.serialized(indent: nil, ensureAscii: true) + "\n", exitCode: 2)
        }
        var s = "Error: could not parse due date \(pyRepr(value)).\n"
        s += "No reminder was created or changed.\n"
        s += "\n"
        s += "Use exact forms like:\n"
        for e in examples { s += "  \(e)\n" }
        return WriteOutcome(stderr: s, exitCode: 2)
    }

    /// Port of `due_date_examples` (remctl:3850).
    private static func dueDateExamples(now: Date, calendar: Calendar) -> [String] {
        let df = DateFormatter()
        df.calendar = calendar
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = calendar.timeZone
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: now)
        // Note: Python's due_date_examples computes a tomorrow string but the returned
        // list only interpolates `today`; the rest are fixed literals. We mirror that.
        return [
            "\(today) 15:00",
            "today at 3pm",
            "tomorrow 09:30",
            "tonight at 11",
            "Friday at 15:00",
            "+3d",
        ]
    }

    private static func phase3(_ flag: String) -> WriteError {
        WriteError("\(flag) requires the private metadata layer (Phase 3); not yet implemented.")
    }

    /// Determine which match tier `resolveListRef` used, to reproduce the `method` field that
    /// the Python `resolve_list_ref` returns (Swift's `ListResolution.found` does not carry it).
    /// `--list-id` always resolves by id. For a name, recompute the 4-tier comparison against the
    /// resolved title (exact → case_insensitive → normalized).
    private static func resolveMethod(store: RemindersStore, name: String?, listId: Int?, resolvedTitle: String) -> String {
        if listId != nil { return "id" }
        guard let name else { return "exact" }
        if resolvedTitle == name { return "exact" }
        if resolvedTitle.lowercased() == name.lowercased() { return "case_insensitive" }
        return "normalized"
    }

    /// Python `repr()` of a string for error messages: single-quoted, with `'` and `\` escaped.
    /// Mirrors the `{value!r}` formatting in `fail_invalid_due_date` / `fail_invalid_recurrence`.
    private static func pyRepr(_ s: String) -> String {
        if s.contains("'") && !s.contains("\"") {
            return "\"\(s)\""
        }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }
}

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Edit a reminder.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("edit") }
}

struct Done: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "done", abstract: "Mark reminders complete.")
    @Argument(help: "Reminder ID") var id: Int
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false

    func run() async throws {
        WriteDispatch.emit(await WriteDispatch.runShell { store, writer in
            try await Self.perform(id: id, json: json, store: store, writer: writer)
        })
    }

    /// Testable core (no print/exit). Tests call this with a FixtureDB store + MockWriter.
    static func perform(id: Int, json: Bool, store: RemindersStore, writer: RemindersWriter) async throws -> WriteOutcome {
        let (title, ckid) = try WriteDispatch.resolveReminderForWrite(store, id: id, op: "complete it")
        _ = try await writer.complete(id: ckid)
        if json {
            let obj: JSONValue = .object([("status", .string("completed")), ("id", .int(id)), ("title", .string(title))])
            return .ok(obj.serialized(indent: nil, ensureAscii: true) + "\n")
        }
        return .ok("Completed: \(safeDisplay(title))\n")
    }
}

struct Undone: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "undone", abstract: "Mark reminders incomplete.")
    @Argument(help: "Reminder ID") var id: Int
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false

    func run() async throws {
        WriteDispatch.emit(await WriteDispatch.runShell { store, writer in
            try await Self.perform(id: id, json: json, store: store, writer: writer)
        })
    }

    /// Testable core (no print/exit). Tests call this with a FixtureDB store + MockWriter.
    static func perform(id: Int, json: Bool, store: RemindersStore, writer: RemindersWriter) async throws -> WriteOutcome {
        let (title, ckid) = try WriteDispatch.resolveReminderForWrite(store, id: id, op: "uncomplete it")
        _ = try await writer.uncomplete(id: ckid)
        if json {
            let obj: JSONValue = .object([("status", .string("uncompleted")), ("id", .int(id)), ("title", .string(title))])
            return .ok(obj.serialized(indent: nil, ensureAscii: true) + "\n")
        }
        return .ok("Uncompleted: \(safeDisplay(title))\n")
    }
}

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a reminder.")
    @Argument(help: "Reminder ID") var id: Int
    @Flag(name: .long, help: "Skip the confirmation prompt") var force = false
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false

    func run() async throws {
        let id = self.id, force = self.force, json = self.json
        WriteDispatch.emit(await WriteDispatch.runShell { store, writer in
            try await Self.perform(id: id, force: force, json: json, store: store, writer: writer, confirm: { prompt in
                FileHandle.standardOutput.write(Data(prompt.utf8))
                let line = readLine() ?? ""
                return line.lowercased().hasPrefix("y")
            })
        })
    }

    /// Testable core. `confirm` receives the full prompt string and returns the user's yes/no.
    static func perform(id: Int, force: Bool, json: Bool, store: RemindersStore, writer: RemindersWriter,
                        confirm: (_ prompt: String) -> Bool) async throws -> WriteOutcome {
        let (title, ckid) = try WriteDispatch.resolveReminderForWrite(store, id: id, op: "delete it")
        if !force {
            let list = store.reminder(pk: id)?.string("list_name") ?? ""
            let prompt = "Delete '\(safeDisplay(title))' from \(safeDisplay(list))? [y/N] "
            guard confirm(prompt) else { return .ok("Cancelled.\n") }   // exit 0, no JSON
        }
        _ = try await writer.delete(id: ckid)
        if json {
            let obj: JSONValue = .object([("status", .string("deleted")), ("id", .int(id)), ("title", .string(title))])
            return .ok(obj.serialized(indent: nil, ensureAscii: true) + "\n")
        }
        return .ok("Deleted: \(safeDisplay(title))\n")
    }
}

struct FlagCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "flag", abstract: "Flag a reminder.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("flag") }
}

struct Unflag: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unflag", abstract: "Unflag a reminder.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("unflag") }
}

struct Link: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "link", abstract: "Print a reminder's deep link.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("link") }
}

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open a reminder in Reminders.app.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("open") }
}
