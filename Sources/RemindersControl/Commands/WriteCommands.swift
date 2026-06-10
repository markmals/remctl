import ArgumentParser
import Foundation

let writeCommands: [ParsableCommand.Type] = [
    Add.self, Edit.self, Done.self, Undone.self, Delete.self,
    FlagCmd.self, Unflag.self, Link.self, Open.self,
]

/// Build the `private` JSON array from a list of `PrivateResult`s (in emission order). Each element
/// is `{status, <echoed fields sorted by key>}` — the same shape P8/P9 use for the single-result
/// `private` sub-object. Mirrors `payload["private"] = private_results` (cmd_add:5239/cmd_edit:5567).
func privateResultsJSON(_ results: [PrivateResult]) -> JSONValue {
    .array(results.map { r in
        var pairs: [(String, JSONValue)] = [("status", .string(r.status))]
        for key in r.fields.keys.sorted() { pairs.append((key, r.fields[key]!)) }
        return .object(pairs)
    })
}

/// The human-mode private summary line (cmd_add:5248 / cmd_edit:5574,5587):
/// `Private metadata: applied N update(s)` with `s` only when N != 1.
func privateMetadataLine(_ results: [PrivateResult]) -> String {
    let n = results.count
    return "Private metadata: applied \(n) update\(n != 1 ? "s" : "")\n"
}

struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a reminder.")

    @Argument(help: "Reminder title") var title: String
    @Option(name: [.short, .long], help: "Target list name") var list: String?
    @Option(name: .long, help: "Create in a list by stable numeric ID") var listId: Int?
    @Option(name: [.short, .long], help: "Notes / body") var notes: String?
    @Option(name: [.short, .long], help: "Due date; date-only forms (YYYY-MM-DD, today, +3d) create all-day reminders, explicit times (Friday at 15:00) create timed reminders") var due: String?
    @Option(name: [.short, .long], help: "Priority: high, medium, low, or none") var priority: String?
    @Option(name: .long, help: "Recurrence: daily, weekly, 'weekly mon,wed,fri', 'monthly 1,15', yearly") var recurrence: String?
    @Option(name: .long, help: "Alarm: 15m, 1h, 1d, or an absolute date") var alarm: String?
    @Option(name: .long, help: "URL; appended to notes") var url: String?

    // Declared but Phase-3 (private ReminderKit metadata) — stubbed.
    @Flag(name: [.short, .long], help: "Flag the reminder") var flag = false
    @Option(name: [.short, .long], help: "Comma-separated tags") var tags: String?
    @Flag(name: .long, help: "Categorize in a Groceries list") var grocery = false
    @Option(name: .long, help: "Assign to an existing section") var section: String?
    @Option(name: .long, help: "Assign to a section by stable ID") var sectionId: String?
    @Option(name: .long, help: "Create a section and assign this reminder") var newSection: String?
    @Option(name: .long, help: "Add a subtask title or JSON object (repeatable)") var subtask: [String] = []
    @Option(name: .long, help: "Add an image attachment path (repeatable)") var image: [String] = []
    @Flag(inversion: .prefixedNo, help: "Set urgent state") var urgent: Bool?
    @Option(name: .long, help: "Early Reminder before due date, e.g. 15m, 1h, 2d") var earlyReminder: String?

    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellBoth { store, writer, priv in
            try await Self.perform(
                title: args.title, list: args.list, listId: args.listId, notes: args.notes,
                due: args.due, priority: args.priority, recurrence: args.recurrence, alarm: args.alarm,
                url: args.url, flag: args.flag, tags: args.tags, grocery: args.grocery,
                section: args.section, sectionId: args.sectionId, newSection: args.newSection,
                subtask: args.subtask, image: args.image, urgent: args.urgent, earlyReminder: args.earlyReminder,
                json: args.json, store: store, writer: writer, private: priv)
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
        json: Bool, store: RemindersStore, writer: RemindersWriter, private priv: PrivateWriter,
        now: Date = Date(), calendar: Calendar = .current,
        groceryAttempts: Int = 24, groceryDelay: Double = 0.25
    ) async throws -> WriteOutcome {

        // wantsPrivate (hybrid imply-rule; `--private` removed): ANY private-ONLY flag present.
        // The private-only flags are section/section-id/new-section/urgent/early-reminder/grocery plus
        // P13's --subtask/--image (both imply-private — apply_private_changes runs them on the ckid).
        // When wantsPrivate, --flag/--tags/--url route through the private writer; otherwise they
        // keep their Phase-2 public behavior (EventKit flag-proxy / title #hashtags / notes-append).
        let wantsPrivate = section != nil || sectionId != nil || newSection != nil
            || urgent != nil || earlyReminder != nil || grocery
            || !subtask.isEmpty || !image.isEmpty

        // 1. Validate inputs BEFORE any write or list resolution (mirrors cmd_add order).
        var dueDate: Date? = nil
        if let due, !due.isEmpty {
            guard let parsed = WriteParsing.parseDue(due, now: now, calendar: calendar) else {
                return failInvalidDueDate(due, json: json)   // exit 2
            }
            dueDate = parsed
        }
        // Date-only due text ("today", "2026-06-01", "+3d", "next friday") creates an
        // all-day reminder (upstream 6755b8e `due_all_day`).
        let dueAllDay = dueDate != nil && WriteParsing.dueSpecIsAllDay(due ?? "")

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

        // 2. Parse the early-reminder spec up front (validates the format; a bad spec throws the
        //    CLIError from PrivateParsing.parseEarlyReminder). Mirrors parse_early_reminder being
        //    invoked from early_reminder_requires_due_date(a) (remctl:2505).
        var parsedEarly: EarlyReminderWrite? = nil
        if let earlyReminder {
            parsedEarly = try PrivateParsing.parseEarlyReminder(earlyReminder)
        }

        // 2a. Early-Reminder due-date guard (cmd_add:5156): a non-clear early-reminder requires a
        //     due date on the new reminder. Runs AFTER due/priority/alarm/recurrence validation.
        if case .set = parsedEarly, dueDate == nil {
            throw CLIError("Early Reminder requires a reminder due date.")
        }

        // 2b. Parse --subtask specs + normalize --image paths up front (validates format; a bad spec
        //     — e.g. subtask location address — throws a CLIError exit 1 before any write). Mirrors
        //     parse_subtask_specs / normalize_image_paths being invoked in apply_private_changes.
        let subtaskSpecs = try PrivateParsing.parseSubtaskSpecs(subtask)
        let imagePaths = PrivateParsing.normalizeImagePaths(image)

        // 2d. Empty-title check. Mirrors the bridge's raw `!title.isEmpty` guard
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

        // 4. Public-fallback --tags: when NOT wantsPrivate, inline `#hashtag` TITLE-append
        //    (cmd_add:5188-5193). Split on `,`, strip, prefix `#` if missing, skip if already in
        //    the title. When wantsPrivate, tags route to addPrivateMetadata instead (step 7).
        var finalTitle = title
        if let tags, !wantsPrivate {
            for raw in tags.split(separator: ",", omittingEmptySubsequences: false) {
                let t = raw.trimmingCharacters(in: .whitespaces)
                let h = t.hasPrefix("#") ? t : "#\(t)"
                if !finalTitle.contains(h) { finalTitle += " \(h)" }
            }
        }

        // 5. Build the ReminderWrite.
        var write = ReminderWrite()
        write.title = finalTitle
        if let resolvedListTitle { write.list = resolvedListTitle }
        if let notes, !notes.isEmpty { write.notes = notes }
        if let dueDate {
            write.due = .set(dueDate)
            if dueAllDay { write.allDay = true }
        }
        if let priorityValue { write.priority = priorityValue }
        // --url: PUBLIC path only appends to notes (cmd_add:5203 `if a.url and not wants_private`).
        // When wantsPrivate, the url routes to addPrivateMetadata (step 7) instead.
        if let url, !url.isEmpty, !wantsPrivate { write.url = url }
        // --flag: PUBLIC path only uses the EventKit priority-proxy (cmd_add:5202
        // `if a.flag and not wants_private`). When wantsPrivate it routes to setFlagged (step 7).
        if flag && !wantsPrivate { write.flagged = true }
        if let parsedRecurrence { write.recurrence = parsedRecurrence }
        if let parsedAlarm { write.alarm = parsedAlarm }

        // 6. Create.
        let result = try await writer.create(write)

        // 7. Private fan-out (only when wantsPrivate). Operates on the created reminder's ckid.
        //    Routes --flag→setFlagged, --url+--tags→addPrivateMetadata, plus section/urgent/
        //    early-reminder (cmd_add:5211-5220 apply_private_changes).
        var privateResults: [PrivateResult] = []
        if wantsPrivate {
            privateResults = try await PrivateChanges.apply(
                reminderCkid: result.id ?? "",
                url: url, tags: tags.map(PrivateParsing.splitCSV) ?? [],
                section: section, sectionId: sectionId, newSection: newSection,
                subtasks: subtaskSpecs, images: imagePaths,
                flagged: flag ? true : nil, urgent: urgent, earlyReminder: parsedEarly,
                grocery: grocery,
                store: store, listPk: resolution?.id,
                writer: writer, private: priv, now: now, calendar: calendar,
                groceryAttempts: groceryAttempts, groceryDelay: groceryDelay)
        }

        // 8. Re-read for the numeric Z_PK by the created ZCKIDENTIFIER.
        let numericId = result.id.flatMap { store.reminder(identifier: $0)?.int("Z_PK") }

        // 9. Output.
        if json {
            var pairs: [(String, JSONValue)] = [
                ("status", .string("created")),
                ("id", .string(result.id ?? "")),
                ("title", .string(finalTitle)),
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
            // "private" attaches AFTER numericId (cmd_add:5238-5239).
            if !privateResults.isEmpty { pairs.append(("private", privateResultsJSON(privateResults))) }
            return .ok(JSONValue.object(pairs).serialized(indent: nil, ensureAscii: true) + "\n")
        }
        var out = "Created: \(safeDisplay(finalTitle))\n"
        if let resolution, resolution.method != "exact" {
            out += "List: \(safeDisplay(resolution.title)) (resolved from \(safeDisplay(resolution.requested)))\n"
        }
        if let numericId { out += "ID: #\(numericId)\n" }
        if !privateResults.isEmpty { out += privateMetadataLine(privateResults) }
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
    @Option(name: [.short, .long], help: "Comma-separated synced tags") var tags: String?
    @Flag(name: .long, help: "Categorize in a Groceries list") var grocery = false
    @Option(name: .long, help: "Assign to an existing section") var section: String?
    @Option(name: .long, help: "Assign to a section by stable ID") var sectionId: String?
    @Option(name: .long, help: "Create a section and assign this reminder") var newSection: String?
    @Option(name: .long, help: "Add a subtask title or JSON object (repeatable)") var subtask: [String] = []
    @Option(name: .long, help: "Add an image attachment path (repeatable)") var image: [String] = []
    @Flag(inversion: .prefixedNo, help: "Set the real flagged state") var flagged: Bool?
    @Flag(inversion: .prefixedNo, help: "Set urgent state") var urgent: Bool?
    @Option(name: .long, help: "Early Reminder before due date") var earlyReminder: String?
    @Option(name: .long, help: "Location address (not supported for location alarms)") var address: String?

    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        let args = self
        WriteDispatch.emit(await WriteDispatch.runShellBoth { store, writer, priv in
            try await Self.perform(
                id: args.id, title: args.title, list: args.list, listId: args.listId,
                notes: args.notes, due: args.due, priority: args.priority, url: args.url,
                recurrence: args.recurrence, alarm: args.alarm,
                locationTitle: args.locationTitle, latitude: args.latitude, longitude: args.longitude,
                radius: args.radius, proximity: args.proximity,
                tags: args.tags, grocery: args.grocery, section: args.section, sectionId: args.sectionId,
                newSection: args.newSection, subtask: args.subtask, image: args.image,
                flagged: args.flagged, urgent: args.urgent, earlyReminder: args.earlyReminder, address: args.address,
                json: args.json, store: store, writer: writer, private: priv)
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
        json: Bool, store: RemindersStore, writer: RemindersWriter, private priv: PrivateWriter,
        now: Date = Date(), calendar: Calendar = .current,
        groceryAttempts: Int = 24, groceryDelay: Double = 0.25
    ) async throws -> WriteOutcome {

        // 1. Resolve pk -> (title, ckid) with the "edit it" refusal, and read the current row
        //    for ZDUEDATE / ZDISPLAYDATEDATE / ZLIST (needed for nudge / carry / clear).
        let (_, ckid) = try WriteDispatch.resolveReminderForWrite(store, id: id, op: "edit it")
        guard let row = store.reminder(pk: id) else { throw WriteError("#\(id) not found") }
        let currentDue = row.double("ZDUEDATE")
        let currentDisplay = row.double("ZDISPLAYDATEDATE")

        // 2. Parse --subtask specs + normalize --image paths up front (validates format; a bad spec
        //    — e.g. subtask location address — throws a CLIError exit 1 before any write). Mirrors
        //    parse_subtask_specs / normalize_image_paths being invoked in apply_private_changes.
        let subtaskSpecs = try PrivateParsing.parseSubtaskSpecs(subtask)
        let imagePaths = PrivateParsing.normalizeImagePaths(image)

        // wantsPrivate (hybrid imply-rule; `--private` removed): ANY private-ONLY flag present.
        // The private-only flags on edit are section/section-id/new-section/flagged/urgent/
        // early-reminder/grocery plus P13's --subtask/--image (both imply-private).
        // On edit, --tags has NO public fallback (cmd_edit:5417 errors without --private), so it
        // always routes through the private writer too — but tags ALONE is not "private-only" in
        // the source's gating set; it implies private because private_changes_from_args includes
        // it. So when --tags is the only private flag, we still want it private. Fold that in.
        let wantsPrivate = section != nil || sectionId != nil || newSection != nil
            || flagged != nil || urgent != nil || earlyReminder != nil || tags != nil || grocery
            || !subtask.isEmpty || !image.isEmpty

        // Parse the early-reminder spec up front (validates format; bad → CLIError).
        var parsedEarly: EarlyReminderWrite? = nil
        if let earlyReminder {
            parsedEarly = try PrivateParsing.parseEarlyReminder(earlyReminder)
        }

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

        // 4a. Early-Reminder due-date guard (cmd_edit:5466-5469): a non-clear early-reminder
        //     requires a due date. Clearing the due (-d clear) removes it → fail; otherwise fail
        //     only when no new due is given AND the reminder has no existing ZDUEDATE.
        if case .set = parsedEarly {
            if dueIsClear || (dueDate == nil && currentDue == nil) {
                throw CLIError("Early Reminder requires a reminder due date.")
            }
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

        // --address is only meaningful alongside a location alarm, and the location-alarm path is
        // EventKit-expressible (no private street-address support yet). Mirrors validate_private_args
        // (remctl:2483-2491): when --latitude/--longitude are present, an --address is rejected (exit 1).
        if (latitude != nil || longitude != nil), address != nil {
            throw WriteError("--address is not currently supported for location alarms.")
        }

        // 5. Build the ReminderWrite from validated fields.
        var write = ReminderWrite()
        var hasChanges = false
        if let title, !title.isEmpty { write.title = title; hasChanges = true }
        if let resolvedListTitle { write.list = resolvedListTitle; hasChanges = true }

        // url merges into notes (notes + "\n\n" + url, or url alone). notes gate is `!= nil`:
        // an empty notes string still sets notes (mirrors Python `notes_body is not None`).
        // PUBLIC path only (cmd_edit:5525 `if a.url and not wants_private`): when wantsPrivate the
        // url routes to addPrivateMetadata instead of merging into notes.
        var notesBody = notes
        if let url, !url.isEmpty, !wantsPrivate {
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

        // 8. has_changes / wants_private gate (cmd_edit:5546,5576):
        //    • has_changes        → EventKit update, then private fan-out (if wantsPrivate).
        //    • !has_changes && wantsPrivate → private-ONLY branch (no EventKit update; JSON indent=2).
        //    • neither            → "Nothing to update." (mirrors the 5630 fallthrough).
        if !hasChanges && !wantsPrivate {
            return .ok("Nothing to update.\n")
        }

        // Private-only branch: no editable field changed but private metadata was requested.
        // The source emits indent=2 JSON here (cmd_edit:5584) — a deliberate quirk vs the main path.
        if !hasChanges {
            let privateResults = try await applyPrivate(
                reminderCkid: ckid, url: url, tags: tags, section: section, sectionId: sectionId,
                newSection: newSection, subtasks: subtaskSpecs, images: imagePaths,
                flagged: flagged, urgent: urgent, earlyReminder: parsedEarly, grocery: grocery,
                store: store, listPk: resolution?.id ?? row.int("ZLIST"),
                writer: writer, private: priv, now: now, calendar: calendar,
                groceryAttempts: groceryAttempts, groceryDelay: groceryDelay)
            if json {
                let obj: JSONValue = .object([
                    ("status", .string("updated")),
                    ("id", .int(id)),
                    ("private", privateResultsJSON(privateResults)),
                ])
                return .ok(obj.serialized(indent: 2, ensureAscii: true) + "\n")
            }
            var out = "Updated #\(id)\n"
            out += privateMetadataLine(privateResults)
            return .ok(out)
        }

        // 9. Fire the nudge first (separate update), then the real update.
        if let nudgeDate {
            var nudge = ReminderWrite()
            nudge.due = .set(nudgeDate)
            _ = try await writer.update(id: ckid, nudge)
        }
        _ = try await writer.update(id: ckid, write)

        // 9a. Private fan-out (only when wantsPrivate) on the resolved ckid (cmd_edit:5549).
        var privateResults: [PrivateResult] = []
        if wantsPrivate {
            privateResults = try await applyPrivate(
                reminderCkid: ckid, url: url, tags: tags, section: section, sectionId: sectionId,
                newSection: newSection, subtasks: subtaskSpecs, images: imagePaths,
                flagged: flagged, urgent: urgent, earlyReminder: parsedEarly, grocery: grocery,
                store: store, listPk: resolution?.id ?? row.int("ZLIST"),
                writer: writer, private: priv, now: now, calendar: calendar,
                groceryAttempts: groceryAttempts, groceryDelay: groceryDelay)
        }

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
            // "private" attaches AFTER list/resolvedList (cmd_edit:5566-5567).
            if !privateResults.isEmpty { pairs.append(("private", privateResultsJSON(privateResults))) }
            return .ok(JSONValue.object(pairs).serialized(indent: nil, ensureAscii: true) + "\n")
        }
        var out = "Updated #\(id)\n"
        if let resolution { out += "List: \(safeDisplay(resolution.title))\n" }
        if !privateResults.isEmpty { out += privateMetadataLine(privateResults) }
        return .ok(out)
    }

    /// Adapter: parse tags (CSV) and forward to the shared `PrivateChanges.apply` fan-out. The
    /// `flagged` collapse for edit is just the boolean as-is (add collapses --flag→true upstream).
    private static func applyPrivate(
        reminderCkid: String, url: String?, tags: String?,
        section: String?, sectionId: String?, newSection: String?,
        subtasks: [SubtaskSpec], images: [String],
        flagged: Bool?, urgent: Bool?, earlyReminder: EarlyReminderWrite?, grocery: Bool,
        store: RemindersStore, listPk: Int?,
        writer: RemindersWriter, private priv: PrivateWriter,
        now: Date, calendar: Calendar,
        groceryAttempts: Int, groceryDelay: Double
    ) async throws -> [PrivateResult] {
        try await PrivateChanges.apply(
            reminderCkid: reminderCkid,
            url: url, tags: tags.map(PrivateParsing.splitCSV) ?? [],
            section: section, sectionId: sectionId, newSection: newSection,
            subtasks: subtasks, images: images,
            flagged: flagged, urgent: urgent, earlyReminder: earlyReminder, grocery: grocery,
            store: store, listPk: listPk,
            writer: writer, private: priv, now: now, calendar: calendar,
            groceryAttempts: groceryAttempts, groceryDelay: groceryDelay)
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

struct FlagCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "flag", abstract: "Flag a reminder.")
    @Argument(help: "Reminder ID") var id: Int
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false

    func run() async throws {
        let id = self.id, json = self.json
        WriteDispatch.emit(await WriteDispatch.runShellBoth { store, writer, priv in
            try await FlagCmd.performFlag(id: id, flagged: true, json: json,
                                         store: store, writer: writer, private: priv)
        })
    }
}

struct Unflag: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unflag", abstract: "Unflag a reminder.")
    @Argument(help: "Reminder ID") var id: Int
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false

    func run() async throws {
        let id = self.id, json = self.json
        WriteDispatch.emit(await WriteDispatch.runShellBoth { store, writer, priv in
            try await FlagCmd.performFlag(id: id, flagged: false, json: json,
                                         store: store, writer: writer, private: priv)
        })
    }
}

extension FlagCmd {
    /// Shared core for `flag` and `unflag`. Parameterised by `flagged`.
    ///
    /// Strategy (mirrors cmd_flag / cmd_unflag in the Python CLI):
    ///   1. PRIMARY: `PrivateWriter.setFlagged` — touches the real ZFLAGGED column.
    ///   2. FALLBACK: EventKit priority-proxy via `RemindersWriter.update(id:flagged:)`.
    ///   3. BOTH FAILED → throw the identifier-based-refusal WriteError (exit 1).
    static func performFlag(
        id: Int, flagged: Bool, json: Bool,
        store: RemindersStore, writer: RemindersWriter, private priv: PrivateWriter
    ) async throws -> WriteOutcome {
        // Step 1: resolve the reminder row → (title, ckid).
        // resolveReminderForWrite throws:
        //   • WriteError("#<id> not found")             — not found
        //   • WriteError("The reminder has no stable identifier. Refusing…")  — NULL ckid
        let (title, ckid) = try WriteDispatch.resolveReminderForWrite(
            store, id: id, op: flagged ? "flag it" : "unflag it")

        // Step 2: PRIMARY — private writer (real ZFLAGGED via ReminderKit).
        var privateSucceeded = false
        do {
            let r = try await priv.setFlagged(id: ckid, flagged: flagged)
            if r.status == "updated" { privateSucceeded = true }
        } catch {
            // Private call threw — fall through to EventKit fallback.
        }

        // Step 3: FALLBACK — EventKit priority-proxy (lossy: 0↔1).
        if !privateSucceeded {
            var didFallback = false
            do {
                var w = ReminderWrite()
                w.flagged = flagged
                _ = try await writer.update(id: ckid, w)
                didFallback = true
            } catch {
                // Fallback also failed — both paths failed.
            }
            if !didFallback {
                // Both failed → refuse with the same message as _refuse_unsafe_title_fallback.
                let shownTitle = safeDisplay(title.isEmpty ? "(untitled)" : title)
                throw WriteError(
                    "Identifier-based writes failed. Refusing unsafe title-based fallback for #\(id) " +
                    "('\(shownTitle)') while trying to \(flagged ? "flag it" : "unflag it").")
            }
        }

        // Step 4: success output.
        let verb = flagged ? "flagged" : "unflagged"
        let label = flagged ? "Flagged" : "Unflagged"
        if json {
            let obj: JSONValue = .object([
                ("status", .string(verb)),
                ("id",     .int(id)),
                ("title",  .string(title)),
            ])
            return .ok(obj.serialized(indent: nil, ensureAscii: true) + "\n")
        }
        return .ok("\(label): \(safeDisplay(title))\n")
    }
}

/// The reminder deep-link URL scheme, verbatim from `cmd_link`/`cmd_open` (remctl:5928/5945):
///   `x-apple-reminderkit://REMCDReminder/<ZCKIDENTIFIER>`
/// This is parity-critical — the format must match the Python source byte-for-byte.
func reminderDeepLink(_ ckid: String) -> String {
    "x-apple-reminderkit://REMCDReminder/\(ckid)"
}

/// `link` is a pure READ command (port of `cmd_link`, remctl:5905). It is NOT an EventKit write:
/// it never resolves an identifier for writing, never refuses on a NULL ckid, and never errors on
/// not-found (it warns and continues). It mirrors `cmd_link` exactly:
///   * accepts variadic IDs OR a list target (`-l/--list` / `--list-id`), not both;
///   * a list target expands to that list's top-level reminders (respecting `--completed`);
///   * for each id, a missing reminder warns to stderr (non-fatal) and a NULL ckid is silently skipped;
///   * `--json` emits a JSON *array* (indent=2, ensure_ascii=true, like `json.dumps(..., indent=2)`)
///     of `{id, title, link}`; human emits two lines per result (`#<id> <title>` + dim link).
struct Link: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "link", abstract: "Get deep link(s) for reminders.")
    @Argument(help: "Reminder IDs") var ids: [Int] = []
    @Option(name: [.short, .long], help: "Get links for all active reminders in a list") var list: String?
    @Option(name: .long, help: "Get links for all active reminders in a list by stable numeric ID") var listId: Int?
    @Flag(name: .long, help: "Include completed reminders") var completed = false
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false
    @Flag(name: .long, help: "Disable ANSI color") var noColor = false

    func run() async throws {
        let ids = self.ids, list = self.list, listId = self.listId
        let completed = self.completed, json = self.json
        let ansi = Ansi.resolve(noColorFlag: noColor)
        // link is READ-ONLY: no writer needed. WriteDispatch.perform maps thrown
        // CLIError / RemindersDBUnavailable to a WriteOutcome ("Error: <msg>", exit 1).
        let outcome = await WriteDispatch.perform {
            let store = try RemindersStore.open()
            return try Self.perform(ids: ids, list: list, listId: listId,
                                    completed: completed, json: json, store: store, ansi: ansi)
        }
        WriteDispatch.emit(outcome)
    }

    /// Testable core (no print/exit). Pure read + format — mirrors `cmd_link` (remctl:5905) step for step.
    static func perform(ids: [Int], list: String?, listId: Int?, completed: Bool,
                        json: Bool, store: RemindersStore, ansi: Ansi) throws -> WriteOutcome {
        var ids = ids
        // 1. IDs and a list target are mutually exclusive (remctl:5910).
        if !ids.isEmpty && (list != nil || listId != nil) {
            throw CLIError("pass reminder IDs or a list target, not both.")
        }
        // 2. A list target expands to that list's top-level reminders (remctl:5913-5916).
        //    resolveRequiredListTarget's own errors (not found / ambiguous) pass through.
        if list != nil || listId != nil {
            let target = try resolveRequiredListTarget(store: store, name: list, listId: listId)
            let items = store.reminders(listPk: target.id, completed: completed, topLevel: true)
            ids = items.compactMap { $0.int("Z_PK") }
        }
        // 3. Nothing to do (remctl:5917-5919). NOTE: cmd_link prints this line WITHOUT an "Error: "
        //    prefix (unlike the "not both" message), so return the bare stderr rather than a CLIError.
        if ids.isEmpty {
            return WriteOutcome(stderr: "No reminders specified.\n", exitCode: 1)
        }
        // 4. Resolve each id. Missing -> warn (non-fatal); NULL ckid -> silently skip (remctl:5921-5927).
        var results: [(id: Int, title: String, link: String, listName: String?)] = []
        var warnings = ""
        for rid in ids {
            guard let r = store.reminder(pk: rid) else {
                warnings += "Warning: #\(rid) not found\n"
                continue
            }
            guard let ckid = r.string("ZCKIDENTIFIER"), !ckid.isEmpty else { continue }
            let link = reminderDeepLink(ckid)   // x-apple-reminderkit://REMCDReminder/<ckid>
            results.append((id: rid, title: r.string("ZTITLE") ?? "", link: link, listName: r.string("list_name")))
        }
        // 5. Output.
        if json {
            // cmd_link JSON: a *list* of {id,title,link} with internal _list_name stripped,
            // emitted via json.dumps(..., indent=2) (ensure_ascii defaults to TRUE) (remctl:5931).
            let arr: JSONValue = .array(results.map { r in
                .object([
                    ("id", .int(r.id)),
                    ("title", .string(r.title)),
                    ("link", .string(r.link)),
                ])
            })
            return WriteOutcome(stdout: arr.serialized(indent: 2, ensureAscii: true) + "\n",
                                stderr: warnings, exitCode: 0)
        }
        // cmd_link human form (remctl:5933-5935): per result, line 1 `<colored #id> <title>`,
        // line 2 two-space-indented dim link. Id coloring is reminder_id_text == colorByList.
        var out = ""
        for r in results {
            out += "\(colorByList("#\(r.id)", listName: r.listName, ansi: ansi)) \(safeDisplay(r.title))\n"
            out += "  \(ansi.dim(r.link))\n"
        }
        return WriteOutcome(stdout: out, stderr: warnings, exitCode: 0)
    }
}

/// `open` is a READ + launcher command (port of `cmd_open`, remctl:5937). It has NO `--json` flag and
/// NO failure/return-code handling — `cmd_open` ignores `subprocess.run`'s return code. The launcher
/// is injected as `launch([String]) -> Void` so tests record the argv without spawning a process.
/// Three branches, mirroring `cmd_open`'s `if hasattr(a,'id') and a.id` (note: Python treats `id == 0`
/// as falsy, so `open 0` is the generic "open the app" branch):
///   * id given and != 0, found, has ckid  -> launch deep link, print `Opened #<id> in Reminders.app`
///   * id given and != 0, found, NULL ckid  -> launch `-a Reminders`, print `Opened Reminders.app (no deep link available)`
///   * id given and != 0, NOT found         -> `Error: #<id> not found`, exit 1 (launcher not called)
///   * no id (or id == 0)                    -> launch `-a Reminders`, print `Opened Reminders.app`
struct Open: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open reminder in Reminders.app (or just open the app).")
    @Argument(help: "Reminder ID (opens specific reminder via deep link)") var id: Int?

    func run() async throws {
        let id = self.id
        let outcome = await WriteDispatch.perform {
            // The store is only needed for the specific-reminder branch; open it lazily there.
            return try Self.perform(id: id, store: { try RemindersStore.open() }, launch: Self.launchWithOpen)
        }
        WriteDispatch.emit(outcome)
    }

    /// Default launcher: invoke `/usr/bin/open <args...>` (the macOS launcher — NOT osascript).
    /// Mirrors cmd_open's `subprocess.run(["open", ...])` (remctl:5946/5949/5953): the return code
    /// is ignored, so this returns Void.
    static func launchWithOpen(_ args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = args
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // cmd_open ignores subprocess failures; match that — nothing to report.
        }
    }

    /// Testable core (no print/exit). `store` is a deferred opener so the no-id branch never touches
    /// the DB; `launch` is injected so tests can record the argv. Mirrors `cmd_open` (remctl:5937).
    static func perform(id: Int?, store: () throws -> RemindersStore, launch: ([String]) -> Void) throws -> WriteOutcome {
        // Python: `if hasattr(a, 'id') and a.id:` — id of 0 is falsy, so it falls to the generic branch.
        if let id, id != 0 {
            let s = try store()
            guard let r = s.reminder(pk: id) else {
                // Specific-reminder not-found is FATAL here (unlike link's warn) — remctl:5941-5943.
                throw CLIError("#\(id) not found")
            }
            if let ckid = r.string("ZCKIDENTIFIER"), !ckid.isEmpty {
                launch([reminderDeepLink(ckid)])   // x-apple-reminderkit://REMCDReminder/<ckid>
                return .ok("Opened #\(id) in Reminders.app\n")
            }
            launch(["-a", "Reminders"])
            return .ok("Opened Reminders.app (no deep link available)\n")
        }
        // No id (or id == 0): just open the app (remctl:5955-5957).
        launch(["-a", "Reminders"])
        return .ok("Opened Reminders.app\n")
    }
}
