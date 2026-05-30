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
                throw WriteError("could not parse recurrence \(WriteFormatting.pyRepr(recurrence)). Use daily, weekly, 'weekly mon,wed,fri', 'monthly 1,15', monthly, or yearly.")
            }
            parsedRecurrence = r
        }

        var parsedAlarm: AlarmWrite? = nil
        if let alarm, !alarm.isEmpty {
            guard let al = WriteParsing.parseAlarmSpec(alarm, allowClear: false) else {
                throw WriteError("could not parse alarm \(WriteFormatting.pyRepr(alarm)). Use 15m, 1h, 1d, or an absolute date.")
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

        // 2b. Empty-title check. Mirrors the bridge's raw `!title.isEmpty` guard
        //     (remctl-bridge.swift:359) that EventKitWriter.create reproduces — NO trimming,
        //     so a whitespace-only title is accepted. Runs AFTER due-validation (exit 2 wins)
        //     and the Phase-3 stub guard (private-refusal fires first), matching parity.
        if title.isEmpty { throw WriteError("title is required for create") }

        // 3. List resolution (only when a list name / id was given). EventKit uses the
        //    default list otherwise. Capture the resolution method for the resolvedList output.
        var resolvedListTitle: String? = nil
        var resolution: (requested: String, title: String, id: Int, method: String)? = nil
        if list != nil || listId != nil {
            let target = try resolveRequiredListTarget(store: store, name: list, listId: listId)
            resolvedListTitle = target.title
            let requested = listId != nil ? String(listId!) : (list ?? "")
            let method = WriteFormatting.resolveMethod(store: store, name: list, listId: listId, resolvedTitle: target.title)
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
        var s = "Error: could not parse due date \(WriteFormatting.pyRepr(value)).\n"
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
}

/// Location-alarm trigger direction. Mirrors Python argparse `choices=["arriving","leaving"]`
/// on `remctl edit --proximity` (remctl:7782): an invalid value is rejected at parse time (exit 2).
/// The raw value is the lowercase string the EventKit writer maps (arriving→.enter, leaving→.leave).
enum Proximity: String, ExpressibleByArgument, CaseIterable {
    case arriving, leaving
}

struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Edit a reminder.")

    @Argument(help: "Reminder ID") var id: Int
    @Option(name: .long, help: "New title") var title: String?
    @Option(name: [.short, .long], help: "Move to a list by name") var list: String?
    @Option(name: .long, help: "Move to a list by stable numeric ID") var listId: Int?
    @Option(name: [.short, .long], help: "Notes / body") var notes: String?
    @Option(name: [.short, .long], help: "Due date (YYYY-MM-DD, today, +3d, …) or 'clear'") var due: String?
    @Option(name: [.short, .long], help: "Priority: high, medium, low, or none") var priority: String?
    @Option(name: .long, help: "URL; appended to notes") var url: String?
    @Option(name: .long, help: "Recurrence: daily, weekly, 'weekly mon,wed,fri', 'monthly 1,15', yearly") var recurrence: String?
    @Option(name: .long, help: "Alarm: 15m, 1h, 1d, an absolute date, or clear") var alarm: String?

    // Location alarm (EventKit-expressible). Radius/proximity defaults live here.
    @Option(name: .long, help: "Location alarm title") var locationTitle: String?
    @Option(name: .long, help: "Location alarm latitude") var latitude: Double?
    @Option(name: .long, help: "Location alarm longitude") var longitude: Double?
    @Option(name: .long, help: "Location alarm radius in meters") var radius: Double = 100.0
    @Option(name: .long, help: "Location alarm trigger direction: arriving or leaving") var proximity: Proximity = .arriving

    // Declared but Phase-3 (private ReminderKit metadata) — stubbed.
    @Option(name: [.short, .long], help: "Comma-separated synced tags (Phase 3)") var tags: String?
    @Flag(name: .long, help: "Categorize in a Groceries list (Phase 3)") var grocery = false
    @Option(name: .long, help: "Assign to an existing section (Phase 3)") var section: String?
    @Option(name: .long, help: "Assign to a section by stable ID (Phase 3)") var sectionId: String?
    @Option(name: .long, help: "Create a section and assign this reminder (Phase 3)") var newSection: String?
    @Option(name: .long, help: "Add a subtask title or JSON object (repeatable, Phase 3)") var subtask: [String] = []
    @Option(name: .long, help: "Add an image attachment path (repeatable, Phase 3)") var image: [String] = []
    @Flag(inversion: .prefixedNo, help: "Set the real flagged state (Phase 3)") var flagged: Bool?
    @Flag(inversion: .prefixedNo, help: "Set urgent state (Phase 3)") var urgent: Bool?
    @Option(name: .long, help: "Early Reminder before due date (Phase 3)") var earlyReminder: String?
    @Option(name: .long, help: "Location address (Phase 3)") var address: String?

    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShell { store, writer in
            try await Self.perform(
                id: args.id, title: args.title, list: args.list, listId: args.listId,
                notes: args.notes, due: args.due, priority: args.priority, url: args.url,
                recurrence: args.recurrence, alarm: args.alarm,
                locationTitle: args.locationTitle, latitude: args.latitude, longitude: args.longitude,
                radius: args.radius, proximity: args.proximity,
                tags: args.tags, grocery: args.grocery, section: args.section, sectionId: args.sectionId,
                newSection: args.newSection, subtask: args.subtask, image: args.image,
                flagged: args.flagged, urgent: args.urgent, earlyReminder: args.earlyReminder, address: args.address,
                json: args.json, store: store, writer: writer)
        })
    }

    /// Testable core (no print/exit). Mirrors `cmd_edit`'s EventKit (bridge) path.
    /// `now`/`calendar` are injected for deterministic due-date parsing + nudge/carry comparisons.
    static func perform(
        id: Int, title: String? = nil, list: String? = nil, listId: Int? = nil,
        notes: String? = nil, due: String? = nil, priority: String? = nil, url: String? = nil,
        recurrence: String? = nil, alarm: String? = nil,
        locationTitle: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
        radius: Double = 100.0, proximity: Proximity = .arriving,
        tags: String? = nil, grocery: Bool = false, section: String? = nil, sectionId: String? = nil,
        newSection: String? = nil, subtask: [String] = [], image: [String] = [],
        flagged: Bool? = nil, urgent: Bool? = nil, earlyReminder: String? = nil, address: String? = nil,
        json: Bool, store: RemindersStore, writer: RemindersWriter,
        now: Date = Date(), calendar: Calendar = .current
    ) async throws -> WriteOutcome {

        // 1. Resolve pk -> (title, ckid) with the "edit it" refusal, and read the current row
        //    for ZDUEDATE / ZDISPLAYDATEDATE / ZLIST (needed for nudge / carry / clear).
        let (_, ckid) = try WriteDispatch.resolveReminderForWrite(store, id: id, op: "edit it")
        guard let row = store.reminder(pk: id) else { throw WriteError("#\(id) not found") }
        let currentDue = row.double("ZDUEDATE")
        let currentDisplay = row.double("ZDISPLAYDATEDATE")

        // 2. Phase-3 stub guard FIRST. This is the analog of Python's
        //    `refuse_private_args_without_opt_in(a)` which runs at the very top of `cmd_edit`
        //    (remctl:5416), before list resolution and field validation. (In Swift the row must be
        //    resolved first — steps above — because not-found / identifier refusal need the row.)
        if tags != nil { throw phase3("--tags") }
        if grocery { throw phase3("--grocery") }
        if section != nil { throw phase3("--section") }
        if sectionId != nil { throw phase3("--section-id") }
        if newSection != nil { throw phase3("--new-section") }
        if !subtask.isEmpty { throw phase3("--subtask") }
        if !image.isEmpty { throw phase3("--image") }
        if flagged != nil { throw phase3("--flagged") }
        if urgent != nil { throw phase3("--urgent") }
        if earlyReminder != nil { throw phase3("--early-reminder") }
        if address != nil { throw phase3("--address") }

        // 3. List move, resolved BEFORE field validation to match cmd_edit source order
        //    (remctl:5425-5436 resolve the list; priority/recurrence/due/alarm validation only
        //    follows at 5447-5478). So `edit ID --list A --list-id B -d notadate` exits 1 on the
        //    both-list check, and `edit ID --list nonexistent -d notadate` exits 1 on list-not-found,
        //    rather than exit 2 on the bad due. Both name+id -> exit 1 (CLIError "not both").
        var resolvedListTitle: String? = nil
        var resolution: (requested: String, title: String, id: Int, method: String)? = nil
        if list != nil || listId != nil {
            let target = try resolveRequiredListTarget(store: store, name: list, listId: listId)
            resolvedListTitle = target.title
            let requested = listId != nil ? String(listId!) : (list ?? "")
            let method = WriteFormatting.resolveMethod(store: store, name: list, listId: listId, resolvedTitle: target.title)
            resolution = (requested: requested, title: target.title, id: target.id, method: method)
        }

        // 4. Validate inputs (no writes). Order mirrors cmd_edit: priority (5447) -> recurrence
        //    (5454) -> due (5461) -> alarm (5470). `-d clear` is special-cased; a non-clear
        //    unparseable due is exit 2 (same fail_invalid_due_date as add). priority/alarm/
        //    recurrence -> exit 1. `now`/`calendar` are forwarded into the exit-2 example dates.
        var priorityValue: Int? = nil
        if let priority, !priority.isEmpty {
            // edit has NO short aliases (allowAliases: false).
            guard let p = WriteParsing.parsePriority(priority, allowAliases: false) else {
                throw WriteError("priority must be high, medium, low, or none.")
            }
            priorityValue = p
        }

        var parsedRecurrence: RecurrenceWrite? = nil
        if let recurrence, !recurrence.isEmpty {
            guard let r = WriteParsing.parseRecurrenceSpec(recurrence) else {
                throw WriteError("could not parse recurrence \(WriteFormatting.pyRepr(recurrence)). Use daily, weekly, 'weekly mon,wed,fri', 'monthly 1,15', monthly, or yearly.")
            }
            parsedRecurrence = r
        }

        let dueIsClear = (due == "clear")
        var dueDate: Date? = nil
        if let due, !due.isEmpty, !dueIsClear {
            guard let parsed = WriteParsing.parseDue(due, now: now, calendar: calendar) else {
                return Add.failInvalidDueDate(due, json: json, now: now, calendar: calendar)   // exit 2
            }
            dueDate = parsed
        }

        // Alarm: clear-keywords -> .clear; else parse; bad -> exit 1.
        let explicitAlarm = (alarm != nil && !(alarm!.isEmpty))
        var parsedAlarm: AlarmWrite? = nil
        var clearAlarm = false
        if explicitAlarm {
            if let al = WriteParsing.parseAlarmSpec(alarm!, allowClear: true, calendar: calendar) {
                if al == .clear { clearAlarm = true } else { parsedAlarm = al }
            } else {
                throw WriteError("could not parse alarm \(WriteFormatting.pyRepr(alarm!)). Use 15m, 1h, 1d, an absolute date, or clear.")
            }
        }

        // Location alarm pairing: lat+long must come as a pair.
        if (latitude != nil) != (longitude != nil) {
            throw WriteError("Location alarms require latitude and longitude")
        }

        // 5. Build the ReminderWrite from validated fields.
        var write = ReminderWrite()
        var hasChanges = false
        if let title, !title.isEmpty { write.title = title; hasChanges = true }
        if let resolvedListTitle { write.list = resolvedListTitle; hasChanges = true }

        // url merges into notes (notes + "\n\n" + url, or url alone). notes gate is `!= nil`:
        // an empty notes string still sets notes (mirrors Python `notes_body is not None`).
        var notesBody = notes
        if let url, !url.isEmpty {
            notesBody = (notesBody != nil && !notesBody!.isEmpty) ? (notesBody! + "\n\n" + url) : url
        }
        if notesBody != nil { write.notes = notesBody; hasChanges = true }

        if let priorityValue { write.priority = priorityValue; hasChanges = true }

        if dueIsClear {
            write.due = .clear; hasChanges = true
        } else if let dueDate {
            write.due = .set(dueDate); hasChanges = true
        }

        if let parsedRecurrence { write.recurrence = parsedRecurrence; hasChanges = true }

        // 6. Double-tap nudge: if the new due equals the current ZDUEDATE to the second, fire a
        //    separate intermediate update (+1h) FIRST so the CKRecord carries a real change.
        var nudgeDate: Date? = nil
        if let dueDate, let currentDue {
            let currentUnix = currentDue + AppleEpoch.offset
            if Int(dueDate.timeIntervalSince1970) == Int(currentUnix) {
                nudgeDate = dueDate.addingTimeInterval(3600)
            }
        }

        // 7. Absolute-alarm carry / clear (only when no explicit --alarm).
        if !explicitAlarm {
            if let dueDate, shouldCarryAbsoluteAlarm(store: store, pk: id, oldDue: currentDue, calendar: calendar) {
                // Move the matching absolute alarm to follow the new due.
                write.alarm = .absolute(dueDate); hasChanges = true
            } else if dueIsClear, shouldClearMatchingAbsoluteAlarm(store: store, pk: id, oldDue: currentDue, oldDisplay: currentDisplay, calendar: calendar) {
                write.alarm = .clear; hasChanges = true
            }
        } else if clearAlarm {
            write.alarm = .clear; hasChanges = true
        } else if let parsedAlarm {
            write.alarm = parsedAlarm; hasChanges = true
        }

        // Location alarm (lat+long both present, validated above). The writer expects the
        // lowercase proximity string ("arriving"/"leaving"); EventKitWriter maps leaving->.leave,
        // arriving->.enter (remctl Swift EventKitWriter ~199).
        if let latitude, let longitude {
            write.location = LocationAlarmWrite(title: locationTitle, latitude: latitude, longitude: longitude, radius: radius, proximity: proximity.rawValue)
            hasChanges = true
        }

        // 8. has_changes gate: nothing editable changed -> no-op (Phase 2 has no private-only branch).
        if !hasChanges {
            return .ok("Nothing to update.\n")
        }

        // 9. Fire the nudge first (separate update), then the real update.
        if let nudgeDate {
            var nudge = ReminderWrite()
            nudge.due = .set(nudgeDate)
            _ = try await writer.update(id: ckid, nudge)
        }
        _ = try await writer.update(id: ckid, write)

        // 10. Output.
        if json {
            var pairs: [(String, JSONValue)] = [
                ("status", .string("updated")),
                ("id", .int(id)),
            ]
            if let resolution {
                pairs.append(("list", .string(resolution.title)))
                if resolution.method != "exact" {
                    pairs.append(("resolvedList", .object([
                        ("requested", .string(resolution.requested)),
                        ("title", .string(resolution.title)),
                        ("id", .int(resolution.id)),
                        ("method", .string(resolution.method)),
                    ])))
                }
            }
            return .ok(JSONValue.object(pairs).serialized(indent: nil, ensureAscii: true) + "\n")
        }
        var out = "Updated #\(id)\n"
        if let resolution { out += "List: \(safeDisplay(resolution.title))\n" }
        return .ok(out)
    }

    /// Port of `should_carry_absolute_alarm_to_new_due` (remctl:1522). Returns true only when the
    /// reminder has exactly ONE alarm, it is absolute, and it equals the OLD due (to the second).
    private static func shouldCarryAbsoluteAlarm(store: RemindersStore, pk: Int, oldDue: Double?, calendar: Calendar) -> Bool {
        guard let oldDue else { return false }
        let alarms = alarmRowsToJSON(store.alarms(pk: pk))
        let absolutes = alarms.filter { alarmType($0) == "absolute" }
        guard alarms.count == 1, absolutes.count == 1 else { return false }
        guard let alarmDate = absoluteAlarmDate(absolutes[0], calendar: calendar) else { return false }
        return sameSecond(alarmDate, appleToDate(oldDue))
    }

    /// Port of `should_clear_matching_absolute_alarm` (remctl:1547). True when the reminder has
    /// exactly ONE absolute alarm matching the OLD due OR the OLD display date (to the second).
    private static func shouldClearMatchingAbsoluteAlarm(store: RemindersStore, pk: Int, oldDue: Double?, oldDisplay: Double?, calendar: Calendar) -> Bool {
        let alarms = alarmRowsToJSON(store.alarms(pk: pk))
        let absolutes = alarms.filter { alarmType($0) == "absolute" }
        guard alarms.count == 1, absolutes.count == 1 else { return false }
        guard let alarmDate = absoluteAlarmDate(absolutes[0], calendar: calendar) else { return false }
        for candidate in [oldDue, oldDisplay] {
            if let c = candidate, sameSecond(alarmDate, appleToDate(c)) { return true }
        }
        return false
    }

    /// Apple/CoreData seconds -> Date (mirrors Python `ts()` semantics for the comparison).
    private static func appleToDate(_ v: Double) -> Date { Date(timeIntervalSince1970: v + AppleEpoch.offset) }

    /// Whether two dates are equal to the second (mirrors `_same_datetime_second`).
    private static func sameSecond(_ a: Date, _ b: Date) -> Bool {
        Int(a.timeIntervalSince1970) == Int(b.timeIntervalSince1970)
    }

    /// Extract the `type` string from a serialized alarm JSON object.
    private static func alarmType(_ alarm: JSONValue) -> String? {
        guard case let .object(pairs) = alarm else { return nil }
        for (k, v) in pairs where k == "type" { if case let .string(s) = v { return s } }
        return nil
    }

    /// Parse the absolute alarm's naive-local `date` ISO string into a Date in the calendar's TZ.
    /// Mirrors `_parse_alarm_iso_datetime(alarm["date"])` (Python `datetime.fromisoformat`).
    private static func absoluteAlarmDate(_ alarm: JSONValue, calendar: Calendar) -> Date? {
        guard case let .object(pairs) = alarm else { return nil }
        var iso: String? = nil
        for (k, v) in pairs where k == "date" { if case let .string(s) = v { iso = s } }
        guard let iso else { return nil }
        let df = DateFormatter()
        df.calendar = calendar
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = calendar.timeZone
        df.isLenient = false
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            df.dateFormat = fmt
            if let d = df.date(from: iso) { return d }
        }
        return nil
    }

    private static func phase3(_ flag: String) -> WriteError {
        WriteError("\(flag) requires the private metadata layer (Phase 3); not yet implemented.")
    }
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
