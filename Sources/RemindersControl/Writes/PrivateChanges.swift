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
///   4. add_subtasks           (subtask)                     — P13  (placeholder)
///   5. add_attachments        (image)                       — P13  (placeholder)
///   6. set_flagged            (flag / flagged collapsed)    — P12
///   7. set_urgent             (urgent)                      — P12
///   8. set_early_reminder     (early-reminder)              — P12
///   9. add_location_alarm     (latitude/longitude)          — P13/P14 (placeholder)
///  10. categorize_grocery_items (grocery)                   — P14  (placeholder)
///
/// P12 implements steps 1–3, 6–8. Steps 4–5 and 9–10 are reserved for P13/P14; their guards still
/// fire in Add/Edit.perform, so those flags can never reach this fan-out yet.
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
        flagged: Bool?, urgent: Bool?, earlyReminder: EarlyReminderWrite?,
        store: RemindersStore, listPk: Int?,
        private p: PrivateWriter
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

        // 4–5. add_subtasks / add_attachments — reserved for P13 (guarded in Add/Edit.perform).

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

        // 9–10. add_location_alarm / categorize_grocery_items — reserved for P13/P14.

        return results
    }
}
