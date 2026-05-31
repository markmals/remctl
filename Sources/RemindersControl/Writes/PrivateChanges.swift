import Foundation

/// The private-metadata fan-out. Port of `apply_private_changes` (remctl:3003).
///
/// Given a reminder's ZCKIDENTIFIER and the parsed/validated private fields, this emits one
/// `PrivateWriter` call per requested change — IN THE EXACT SOURCE ORDER — and collects each
/// `PrivateResult` into an array (in emission order). Absent fields are skipped.
///
/// Source emission order (apply_private_changes:3003-3141):
///   1. add_private_metadata   (url or tags)                 — P12
///   2. assign_section         (section / section-id)        — P12
///   3. add_section_and_assign (new-section)                 — P12
///   4. add_subtasks           (subtask)                     — P13
///   5. add_attachments        (image)                       — P13
///   6. set_flagged            (flag / flagged collapsed)    — P12
///   7. set_urgent             (urgent)                      — P12
///   8. set_early_reminder     (early-reminder)              — P12
///   9. add_location_alarm     (latitude/longitude)          — P14  (placeholder)
///  10. categorize_grocery_items (grocery)                   — P14  (placeholder)
///
/// P12 implements steps 1–3, 6–8. P13 implements steps 4–5 (subtasks + image attachments).
/// Steps 9–10 are reserved for P14; their guards still fire in Add/Edit.perform.
public enum PrivateChanges {

    /// Apply the simple (P12) private changes for one reminder. `flagged` is the COLLAPSED value:
    /// callers pass `true` for `add --flag`, or the `edit --flagged` boolean, or nil if unset
    /// (matching `apply_private_changes`'s `flagged_value` logic at :3083-3091).
    ///
    /// `earlyReminder` is the already-parsed spec WITHOUT identifiers; this fan-out injects the
    /// reminder's existing delta-alert identifiers (early_reminder_identifiers_for_reminder:2522).
    /// The due-date guard (early_reminder_requires_due_date) lives in Add/Edit.perform, where the
    /// new/existing due date is known — matching cmd_add:5156 / cmd_edit:5466-5469.
    public static func apply(
        reminderCkid: String,
        url: String?, tags: [String],
        section: String?, sectionId: String?, newSection: String?,
        subtasks: [SubtaskSpec] = [], images: [String] = [],
        flagged: Bool?, urgent: Bool?, earlyReminder: EarlyReminderWrite?,
        store: RemindersStore, listPk: Int?,
        writer: RemindersWriter, private p: PrivateWriter,
        now: Date = Date(), calendar: Calendar = .current
    ) async throws -> [PrivateResult] {
        var results: [PrivateResult] = []

        // 1. add_private_metadata — urls=[url] if present, tags as-is (already split by caller).
        let urls = url.map { [$0] } ?? []
        if !urls.isEmpty || !tags.isEmpty {
            results.append(try await p.addPrivateMetadata(id: reminderCkid, urls: urls, tags: tags))
        }

        // 2. assign_section — pre-resolve the section CKID via the store (resolve_section_ckid:2803).
        if section != nil || sectionId != nil {
            let resolved = try store.resolveSectionCkid(listPk: listPk ?? 0, section: section, sectionId: sectionId)
            if let resolved {
                results.append(try await p.assignSection(id: reminderCkid, sectionId: resolved))
            }
        }

        // 3. add_section_and_assign — create a section by name and assign this reminder to it.
        if let newSection {
            results.append(try await p.addSectionAndAssign(id: reminderCkid, name: newSection))
        }

        // 4. add_subtasks — create the children, then fan each created child out to its public
        //    (EventKit bridge_update_subtask) and private (apply_subtask_private_metadata) fields.
        //    The add_subtasks PrivateResult is appended FIRST (matching apply_private_changes:3047,
        //    which builds the parent result, then runs the per-child loop). The per-child writes
        //    follow in spec order; within each child, private metadata runs before the bridge update
        //    (apply_private_changes:3053-3061).
        if !subtasks.isEmpty {
            let subtaskResult = try await p.addSubtasks(id: reminderCkid, subtasks: subtasks)
            results.append(subtaskResult)
            // Pair each spec to its created child by index over the echoed `subtasks` array
            // (apply_private_changes uses `zip(subtasks, subtask_result["subtasks"])`).
            let children = childEntries(from: subtaskResult)
            for (spec, child) in zip(subtasks, children) {
                guard let childId = child.id, !childId.isEmpty else { continue }
                // 4a. Child PRIVATE metadata (apply_subtask_private_metadata:2398).
                results.append(contentsOf: try await applySubtaskPrivateMetadata(childId: childId, spec: spec, p: p))
                // 4b. Child PUBLIC fields via the EventKit bridge (bridge_update_subtask:2371).
                if let bridge = try await bridgeUpdateSubtask(childId: childId, spec: spec, writer: writer, now: now, calendar: calendar) {
                    results.append(bridge)
                }
            }
        }

        // 5. add_attachments — image attachments on the parent. files[] is always empty (the ObjC
        //    contract rejects generic file/PDF attachments; images only). apply_private_changes:3075.
        if !images.isEmpty {
            results.append(try await p.addAttachments(id: reminderCkid, images: images))
        }

        // 6. set_flagged — collapsed flag/flagged value.
        if let flagged {
            results.append(try await p.setFlagged(id: reminderCkid, flagged: flagged))
        }

        // 7. set_urgent.
        if let urgent {
            results.append(try await p.setUrgent(id: reminderCkid, urgent: urgent))
        }

        // 8. set_early_reminder — inject the reminder's existing delta-alert identifiers here, so a
        //    set/clear replaces the prior alerts (apply_private_changes:3107).
        if let earlyReminder {
            let existing = store.earlyReminderIdentifiers(reminderCkid: reminderCkid)
            let spec: EarlyReminderWrite
            switch earlyReminder {
            case .clear:
                spec = .clear(existingIdentifiers: existing)
            case let .set(unit, count, _):
                spec = .set(unit: unit, count: count, existingIdentifiers: existing)
            }
            results.append(try await p.setEarlyReminder(id: reminderCkid, spec: spec))
        }

        // 9–10. add_location_alarm / categorize_grocery_items — reserved for P14.

        return results
    }

    // MARK: - Subtask child fan-out

    /// A created subtask child as echoed by the `add_subtasks` PrivateResult. The ObjC RKPDispatch
    /// returns `fields["subtasks"]` as `[{id,title,url}]` (ReminderKitPrivate.m:1240-1244); P3's
    /// ReminderKitWriter unmarshals it into `.array(.object(...))`.
    struct SubtaskChild { var id: String?; var title: String?; var url: String? }

    /// Parse the `subtasks` array out of the `add_subtasks` PrivateResult fields.
    static func childEntries(from result: PrivateResult) -> [SubtaskChild] {
        guard case let .array(items)? = result.fields["subtasks"] else { return [] }
        return items.map { item in
            guard case let .object(pairs) = item else { return SubtaskChild() }
            var child = SubtaskChild()
            for (k, v) in pairs {
                guard case let .string(s) = v else { continue }
                switch k {
                case "id": child.id = s
                case "title": child.title = s
                case "url": child.url = s
                default: break
                }
            }
            return child
        }
    }

    /// Port of `bridge_update_subtask` (remctl:2371): push the child's PUBLIC fields through the
    /// EventKit writer. Only notes/due/priority/alarm/recurrence go through the bridge; if none of
    /// those are set the source returns None (no bridge call), so we return nil. Due/alarm/recurrence
    /// reuse the same parsers as add/edit (the spec carries the RAW strings from parse_subtask_specs).
    private static func bridgeUpdateSubtask(
        childId: String, spec: SubtaskSpec,
        writer: RemindersWriter, now: Date, calendar: Calendar
    ) async throws -> PrivateResult? {
        var write = ReminderWrite()
        var hasBridgeField = false

        if let notes = spec.notes { write.notes = notes; hasBridgeField = true }

        if let due = spec.due, !due.isEmpty {
            guard let parsed = WriteParsing.parseDue(due, now: now, calendar: calendar) else {
                throw CLIError("could not parse subtask due date \(WriteFormatting.pyRepr(due)). Use ISO (YYYY-MM-DD [HH:MM]) or shortcuts like today/tomorrow/eod/+3d.")
            }
            write.due = .set(parsed); hasBridgeField = true
        }

        if let priority = spec.priority {
            // parse_subtask_specs already validated the value (high/h/medium/med/m/low/l/none).
            guard let p = WriteParsing.parsePriority(priority, allowAliases: true) else {
                throw CLIError("subtask priority must be high, medium, low, or none.")
            }
            write.priority = p; hasBridgeField = true
        }

        if let alarm = spec.alarm, !alarm.isEmpty {
            guard let al = WriteParsing.parseAlarmSpec(alarm, allowClear: false, calendar: calendar) else {
                throw CLIError("could not parse subtask alarm \(WriteFormatting.pyRepr(alarm)).")
            }
            write.alarm = al; hasBridgeField = true
        }

        if let recurrence = spec.recurrence, !recurrence.isEmpty {
            guard let r = WriteParsing.parseRecurrenceSpec(recurrence) else {
                throw CLIError("subtask recurrence must be daily, weekly, monthly, yearly, 'weekly mon,wed,fri', or 'monthly 1,15'.")
            }
            write.recurrence = r; hasBridgeField = true
        }

        guard hasBridgeField else { return nil }
        let result = try await writer.update(id: childId, write)
        // Surface the bridge update as a PrivateResult so it joins the parent's results array.
        return PrivateResult(status: result.status, fields: ["id": .string(childId), "action": .string("update")])
    }

    /// Port of `apply_subtask_private_metadata` (remctl:2398): emit the child's PRIVATE actions in
    /// source order — add_private_metadata (urls/tags), add_attachments (images), set_flagged,
    /// set_urgent, set_early_reminder, add_location_alarm. Children are newly created, so the
    /// early-reminder carries no existing identifiers (unlike the parent path).
    private static func applySubtaskPrivateMetadata(
        childId: String, spec: SubtaskSpec, p: PrivateWriter
    ) async throws -> [PrivateResult] {
        var out: [PrivateResult] = []

        if !spec.urls.isEmpty || !spec.tags.isEmpty {
            out.append(try await p.addPrivateMetadata(id: childId, urls: spec.urls, tags: spec.tags))
        }
        if !spec.images.isEmpty {
            out.append(try await p.addAttachments(id: childId, images: spec.images))
        }
        if let flagged = spec.flagged {
            out.append(try await p.setFlagged(id: childId, flagged: flagged))
        }
        if let urgent = spec.urgent {
            out.append(try await p.setUrgent(id: childId, urgent: urgent))
        }
        if let early = spec.earlyReminder {
            // parse_subtask_specs validated the format; re-parse to the unit/count or clear spec.
            // No existing identifiers — the child was just created.
            let parsed = try PrivateParsing.parseEarlyReminder(early)
            out.append(try await p.setEarlyReminder(id: childId, spec: parsed))
        }
        if let lat = spec.latitude, let lon = spec.longitude {
            let loc = PrivateLocation(
                title: spec.locationTitle ?? "Location",
                latitude: lat, longitude: lon,
                radius: spec.radius ?? 100, proximity: spec.proximity ?? 1)
            out.append(try await p.addLocationAlarm(id: childId, location: loc))
        }

        return out
    }
}
