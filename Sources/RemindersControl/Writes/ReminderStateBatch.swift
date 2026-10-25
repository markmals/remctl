import Foundation

/// A reminder state write: complete, uncomplete, or delete one reminder. Port of upstream
/// `STATE_WRITES` (remctl:9753).
enum ReminderStateOperation: String {
    case done, undone, delete

    /// The JSON status a successful write reports; also the batch status when every id succeeded.
    var successStatus: String {
        switch self {
        case .done: return "completed"
        case .undone: return "uncompleted"
        case .delete: return "deleted"
        }
    }

    /// The verb human output uses: `Completed: #23880 Pay rent`.
    var verb: String {
        switch self {
        case .done: return "Completed"
        case .undone: return "Uncompleted"
        case .delete: return "Deleted"
        }
    }

    /// The phrase the no-stable-identifier refusal ends with ("… while trying to complete it").
    var refusalPhrase: String {
        switch self {
        case .done: return "complete it"
        case .undone: return "uncomplete it"
        case .delete: return "delete it"
        }
    }
}

/// Completes, uncompletes, or deletes several reminders by numeric id in one call. Port of
/// upstream `run_reminder_state_batch` (remctl:10082): every id is resolved before the first
/// write, repeats are written once, and one failure does not stop the rest.
///
/// Upstream also reports "uncertain" writes and stops the batch after one, plus a time budget,
/// because it writes through a bridge subprocess that can time out and then retries the write
/// through AppleScript. Here `EventKitWriter` saves in-process and synchronously, so a write
/// either returns after the store accepted it or throws without committing.
enum ReminderStateBatch {
    /// Upstream `REMINDER_BATCH_MAX` (remctl:9747).
    static let maxIDs = 50

    /// The `--help` discussion shared by `done`, `undone`, and `delete`.
    static let helpDiscussion = """
        Several ids make one batch of up to \(maxIDs); list every id before the options. Every id \
        is checked before the first write, repeated ids are written once, and --json reports each \
        id under results with succeeded and failed (not changed) lists. It exits 1 unless every id \
        succeeded. --batch gives one id the same result shape.
        """

    /// Testable core (no print/exit). `date` is the raw `--date` text, honored for `done` only.
    static func run(
        operation: ReminderStateOperation, ids: [Int], date: String? = nil, force: Bool = false,
        json: Bool, store: RemindersStore, writer: RemindersWriter, confirm: ConfirmationPrompt,
        calendar: Calendar = .current
    ) async -> WriteOutcome {
        guard ids.count <= maxIDs else { return tooLarge(count: ids.count, json: json) }

        var completionDate: Date?
        var completionISO: String?
        if operation == .done, let date, !date.isEmpty {
            guard let parsed = WriteParsing.parseCompletionDate(date, calendar: calendar) else {
                return Done.failInvalidCompletionDate(date, json: json)   // exit 2, nothing read
            }
            completionDate = parsed
            completionISO = Done.isoDateTime(parsed, calendar: calendar)
        }

        var unique: [Int] = []
        var duplicates: [Int] = []
        for id in ids { if unique.contains(id) { duplicates.append(id) } else { unique.append(id) } }

        let plan = resolve(unique, operation: operation, datedCompletion: completionISO != nil, store: store)
        if operation == .delete, let stop = confirmBatchDelete(plan, force: force, json: json, confirm: confirm) {
            return stop
        }

        var items: [StateResult] = []
        items.reserveCapacity(plan.steps.count)
        for step in plan.steps {
            switch step {
            case .decided(let result):
                items.append(result)
            case .target(let id, let ckid):
                items.append(await write(id: id, ckid: ckid, operation: operation, completionDate: completionDate,
                                         completionISO: completionISO, store: store, writer: writer))
            }
        }
        return render(operation: operation, requested: ids, items: items, rows: plan.rows,
                      duplicates: duplicates, json: json)
    }

    // ── Plan ──────────────────────────────────────────────────────────────────

    /// What one requested id resolved to: a result it already has, or a reminder to write.
    private enum Step {
        case decided(StateResult)
        case target(id: Int, ckid: String)
    }

    /// One id's outcome. A success carries no message; a failure always has one.
    private enum StateResult {
        case succeeded(id: Int, completionDate: String?)
        case failed(id: Int, status: String, code: String, message: String)

        var id: Int {
            switch self {
            case .succeeded(let id, _): return id
            case .failed(let id, _, _, _): return id
            }
        }
    }

    /// The reminder fields a resolved id reports, read once before any write.
    private struct ResolvedRow {
        let title: String?
        let list: String?
        let recurring: Bool
    }

    private struct Plan {
        var steps: [Step] = []
        var rows: [Int: ResolvedRow] = [:]
        var targetIDs: [Int] {
            steps.compactMap { step in
                if case let .target(id, _) = step { return id }
                return nil
            }
        }
    }

    /// Resolve every id against the read store before the batch writes anything.
    private static func resolve(_ ids: [Int], operation: ReminderStateOperation, datedCompletion: Bool,
                                store: RemindersStore) -> Plan {
        var plan = Plan()
        for id in ids {
            guard let row = store.reminder(pk: id) else {
                plan.steps.append(.decided(.failed(id: id, status: "not_found", code: "reminder_not_found",
                                                   message: "#\(id) not found")))
                continue
            }
            let title = row.string("ZTITLE")
            let recurring = operation == .done && recurrenceFromRow(row, ts: { AppleEpoch.ts($0) }) != nil
            plan.rows[id] = ResolvedRow(title: title, list: row.string("list_name"), recurring: recurring)

            guard let ckid = row.string("ZCKIDENTIFIER"), !ckid.isEmpty else {
                plan.steps.append(.decided(.failed(
                    id: id, status: "error", code: "no_stable_identifier",
                    message: WriteDispatch.noStableIdentifierMessage(id: id, title: title, op: operation.refusalPhrase))))
                continue
            }
            if recurring && datedCompletion {
                plan.steps.append(.decided(.failed(
                    id: id, status: "error", code: "completion_date_unsupported_for_recurring",
                    message: "--date is not supported for recurring reminders; "
                        + "complete it without --date to advance the series.")))
                continue
            }
            plan.steps.append(.target(id: id, ckid: ckid))
        }
        return plan
    }

    // ── Writes ────────────────────────────────────────────────────────────────

    private static func write(id: Int, ckid: String, operation: ReminderStateOperation, completionDate: Date?,
                              completionISO: String?, store: RemindersStore, writer: RemindersWriter) async -> StateResult {
        do {
            switch operation {
            case .done: _ = try await writer.complete(id: ckid, completionDate: completionDate)
            case .undone: _ = try await writer.uncomplete(id: ckid)
            case .delete: _ = try await writer.delete(id: ckid)
            }
        } catch {
            // A delete can fail because the reminder is already gone — removed along with a parent
            // deleted earlier in this batch. It is deleted either way (upstream remctl:10151).
            if operation == .delete, store.reminder(pk: id) == nil {
                return .succeeded(id: id, completionDate: nil)
            }
            let reason = (error as? WriteError)?.message ?? "\(error)"
            return .failed(id: id, status: "error", code: "write_failed",
                           message: "\(reason); #\(id) was not changed.")
        }
        return .succeeded(id: id, completionDate: completionISO)
    }

    /// One prompt for the whole batch, listing every reminder it would delete (upstream remctl:10127).
    private static func confirmBatchDelete(_ plan: Plan, force: Bool, json: Bool,
                                           confirm: ConfirmationPrompt) -> WriteOutcome? {
        let targets = plan.targetIDs
        guard !targets.isEmpty else { return nil }
        return confirmDestructiveAction(
            force: force, json: json, prompt: deletePrompt(targets, rows: plan.rows),
            identifier: .array(targets.map { .int($0) }), using: confirm)
    }

    private static func deletePrompt(_ targets: [Int], rows: [Int: ResolvedRow]) -> String {
        let lines = targets
            .map { "  #\($0) '\(safeDisplay(rows[$0]?.title))' (\(safeDisplay(rows[$0]?.list)))" }
            .joined(separator: "\n")
        let noun = targets.count == 1 ? "reminder" : "reminders"
        return "Delete \(targets.count) \(noun)?\n\(lines)\n[y/N] "
    }

    // ── Output ────────────────────────────────────────────────────────────────

    private static func tooLarge(count: Int, json: Bool) -> WriteOutcome {
        let message = "Pass at most \(maxIDs) reminder ids per call; got \(count). Nothing was changed."
        guard json else { return .error(message) }
        let payload: JSONValue = .object([
            ("status", .string("error")), ("code", .string("batch_too_large")), ("message", .string(message)),
        ])
        return WriteOutcome(stderr: payload.serialized(indent: nil, ensureAscii: true) + "\n", exitCode: 1)
    }

    private static func render(operation: ReminderStateOperation, requested: [Int], items: [StateResult],
                               rows: [Int: ResolvedRow], duplicates: [Int], json: Bool) -> WriteOutcome {
        var succeeded: [Int] = []
        var failed: [Int] = []
        for item in items {
            if case .succeeded(let id, _) = item { succeeded.append(id) } else { failed.append(item.id) }
        }
        // "failed" promises that nothing changed, so a batch with any success is "partial".
        let status = failed.isEmpty ? operation.successStatus : (succeeded.isEmpty ? "failed" : "partial")
        let exitCode: Int32 = failed.isEmpty ? 0 : 1

        if json {
            var pairs: [(String, JSONValue)] = [
                ("status", .string(status)),
                ("operation", .string(operation.rawValue)),
                ("requested", .array(requested.map { .int($0) })),
                ("succeeded", .array(succeeded.map { .int($0) })),
                ("failed", .array(failed.map { .int($0) })),
                ("results", .array(items.map { itemJSON($0, successStatus: operation.successStatus, row: rows[$0.id]) })),
            ]
            if !duplicates.isEmpty { pairs.append(("duplicatesIgnored", .array(duplicates.map { .int($0) }))) }
            return WriteOutcome(stdout: JSONValue.object(pairs).serialized(indent: nil, ensureAscii: true) + "\n",
                                exitCode: exitCode)
        }

        var stdout = ""
        var stderr = ""
        for item in items {
            switch item {
            case .succeeded(let id, _): stdout += "\(operation.verb): #\(id) \(safeDisplay(rows[id]?.title))\n"
            case .failed(_, _, _, let message): stderr += "Error: \(message)\n"
            }
        }
        if !duplicates.isEmpty {
            stdout += "Ignored repeated ids: \(duplicates.map(String.init).joined(separator: ", "))\n"
        }
        stdout += "\(succeeded.count) of \(items.count) \(operation.verb.lowercased())\n"
        return WriteOutcome(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }

    private static func itemJSON(_ item: StateResult, successStatus: String, row: ResolvedRow?) -> JSONValue {
        var pairs: [(String, JSONValue)] = [("id", .int(item.id))]
        switch item {
        case .succeeded(_, let completionDate):
            pairs.append(("status", .string(successStatus)))
            if let completionDate { pairs.append(("completionDate", .string(completionDate))) }
        case .failed(_, let status, let code, let message):
            pairs.append(("status", .string(status)))
            pairs.append(("code", .string(code)))
            pairs.append(("message", .string(message)))
        }
        if let row {
            pairs.append(("title", row.title.map { .string($0) } ?? .null))
            pairs.append(("list", row.list.map { .string($0) } ?? .null))
            if row.recurring { pairs.append(("recurring", .bool(true))) }
        }
        return .object(pairs)
    }
}
