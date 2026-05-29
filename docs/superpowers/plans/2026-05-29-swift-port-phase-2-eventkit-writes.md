# Swift Port — Phase 2 (EventKit Writes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the EventKit write surface in-process: add, edit, done, undone, delete, link, open, import, list-create, list-rename, list-delete — at JSON/exit parity with the Python `remctl`.

**Architecture:** Fold `remctl-bridge.swift`'s EventKit logic into the package behind a mockable `RemindersWriter` protocol (real `EventKitWriter` over `EKEventStore`; recording `MockWriter` for tests). Each write command is a thin `AsyncParsableCommand` shell over a **testable core** that takes an injected read-only `RemindersStore` (Phase 1, for pk→ZCKIDENTIFIER resolution) + a `RemindersWriter` and returns a `WriteOutcome` (stdout / stderr / exit code) — so command logic is unit-tested without EventKit. Writes are `async` (EventKit authorization is async).

**Tech Stack:** Swift 6, Swift Argument Parser, GRDB (read side, Phase 1), EventKit + CoreLocation, Swift Testing. macOS 14+.

---

## Locked decisions (this phase)

| Area | Decision | Why |
|---|---|---|
| osascript | **Removed entirely.** No AppleScript anywhere. | Owner direction. EventKit (in-process) covers all standard writes; the Python's "bridge-unavailable" AppleScript fallback is unreachable when EventKit is in-process. |
| flag / unflag | **Deferred to Phase 3** (real `ZFLAGGED` via ReminderKit `set_flagged`). | EventKit has no public flagged API (only a lossy priority-proxy); osascript is removed. Shipping a proxy that doesn't change the real flag would fail parity. Real flag = ReminderKit = Phase 3. |
| list-edit, list-pin, list-unpin | **Deferred to Phase 3.** | Entirely ReminderKit (appearance/pin) — no EventKit op. (list-rename is a separate EventKit command and IS in Phase 2.) |
| add / edit flags | **Declare the full flag surface now; private-only flags error with a Phase-3 message.** | Owner direction. EventKit-expressible flags work in Phase 2; ReminderKit flags (urgent/grocery/section/subtask/image/early-reminder/synced-tags/rich-url) wire in Phase 3. |
| Testing | **Mock-only in CI** (testable cores + `MockWriter` + fixture `RemindersStore`); real EventKit verified manually/locally. | EventKit needs a real store + TCC permission, unavailable in CI. Matches the Python "mock the bridge" tests. |
| Write boundary | `RemindersWriter` protocol; real `EventKitWriter` ports `remctl-bridge.swift`. | One in-process binary; mockable seam for tests. |
| Async | Write commands are `async throws`; reads stay sync. | EventKit `requestFullAccessToReminders` is async. Root is already `AsyncParsableCommand`. |

**Ground truth:** the committed contract doc `docs/superpowers/specs/2026-05-28-reminders-cli-contract.md` (Reminder-mutation §307–485, Link/IO §487–579, Lists §581–778) has every write command's exact flags, JSON, errors, exit codes. The Python source `./remctl` holds the helper bodies to port (line refs given per task). `./remctl-bridge.swift` is the EventKit logic to port (W2).

---

## File structure

```
Sources/RemindersControl/
├─ Writes/
│  ├─ RemindersWriter.swift     # protocol + ReminderWrite/Recurrence/Alarm/Location/WriteResult/AuthSummary/WriteError  [W1]
│  ├─ EventKitWriter.swift      # real EKEventStore impl (ports remctl-bridge.swift)                                    [W2]
│  ├─ WriteParsing.swift        # parseDue (NL grammar), parseAlarmSpec, parseRecurrenceSpec, parsePriority             [W3]
│  └─ WriteDispatch.swift       # runWrite (async), WriteOutcome, identifier-safety, output helpers                     [W4]
├─ Commands/                    # existing stubs -> async cores                                                         [W5–W12]
│  └─ Support/WriterFactory.swift  # makeWriter() (real EventKit; test-overridable)                                     [W5]
tests/RemindersControlTests/
├─ Support/MockWriter.swift     # recording RemindersWriter for unit tests                                             [W1]
├─ WriteParsingTests.swift, DoneUndoneTests.swift, DeleteTests.swift, AddTests.swift, EditTests.swift,
│  LinkOpenTests.swift, ListWriteTests.swift, ImportTests.swift …
```

---

## Test strategy

EventKit cannot run in CI. So write commands separate **logic** from the **ArgumentParser shell**:

- Each command exposes a core like `func performDone(id: Int, json: Bool, store: RemindersStore, writer: RemindersWriter) async -> WriteOutcome`.
- The `AsyncParsableCommand.run()` builds the real `EventKitWriter` + opens the real `RemindersStore` and calls the core, then emits the `WriteOutcome`.
- **Unit tests** call the core directly with a Phase-1 `FixtureDB`-backed `RemindersStore` (read side, to supply pk→ZCKIDENTIFIER rows) + a `MockWriter` (records the write call + returns a canned result), and assert the recorded call params + the `WriteOutcome` (stdout/stderr/exit). This mirrors the Python tests (`mock.patch.object(remctl, "bridge_call", ...)`).
- The black-box `CLIRunner` is **not** used for writes (it would hit real EventKit). Reads keep using it.
- **Manual verification** (W13): the binary is run locally against the real Reminders store to confirm EventKit actually creates/edits/deletes — recorded in the task, not in CI.

`WriteOutcome`: `struct WriteOutcome { var stdout: String; var stderr: String; var exitCode: Int32 }` (success → stdout + exit 0; error → stderr + exit 1 or 2). Cores never call `print`/`exit` directly (only the shell does), making them assertable.

---

## Package.swift change (W5)

`EventKitWriter` needs CoreLocation (`EKStructuredLocation`/`CLLocation`) in addition to the already-linked EventKit. Add `.linkedFramework("CoreLocation")` to the `RemindersControl` target's `linkerSettings` (alongside EventKit, AppKit). No new SwiftPM dependency.

---

# FOUNDATION (W1–W5)

## Task W1: RemindersWriter protocol + value types + MockWriter

The mockable EventKit boundary. Value types mirror the bridge `Command` (EventKit-settable fields only).

**Files:** Create `Sources/RemindersControl/Writes/RemindersWriter.swift`; `tests/RemindersControlTests/Support/MockWriter.swift`. Test: `tests/RemindersControlTests/WriteBoundaryTests.swift`.

- [ ] **Step 1: Implement `RemindersWriter.swift`**

```swift
import Foundation

/// Due-date intent on a write: set to a date, explicitly clear, or leave unchanged.
public enum DueWrite: Equatable { case set(Date); case clear }

public enum AlarmWrite: Equatable {
    case relativeOffset(TimeInterval)   // negative = before due (e.g. -900 for 15m before)
    case absolute(Date)
    case clear                          // remove all alarms
}

public struct RecurrenceWrite: Equatable {
    public var frequency: String        // "daily"|"weekly"|"monthly"|"yearly"
    public var interval: Int?
    public var daysOfWeek: [Int]?       // 1=Sun..7=Sat
    public var daysOfMonth: [Int]?
    public var end: Date?
    public init(frequency: String, interval: Int? = nil, daysOfWeek: [Int]? = nil, daysOfMonth: [Int]? = nil, end: Date? = nil) {
        self.frequency = frequency; self.interval = interval; self.daysOfWeek = daysOfWeek; self.daysOfMonth = daysOfMonth; self.end = end
    }
}

public struct LocationAlarmWrite: Equatable {
    public var title: String?
    public var latitude: Double
    public var longitude: Double
    public var radius: Double            // meters
    public var proximity: String         // "arriving"/"enter" or "leaving"/"leave"
}

/// Mirrors the bridge `Command` (EventKit-settable fields). nil = leave unchanged.
public struct ReminderWrite: Equatable {
    public var title: String?
    public var list: String?             // target list NAME (EventKit findList by title)
    public var due: DueWrite?
    public var priority: Int?            // 0/1/5/9
    public var notes: String?
    public var url: String?              // appended to notes (rich URL is Phase 3)
    public var flagged: Bool?            // EventKit priority-proxy (real flag is Phase 3)
    public var recurrence: RecurrenceWrite?
    public var alarm: AlarmWrite?
    public var location: LocationAlarmWrite?
    public init() {}
}

public struct WriteResult: Equatable {
    public var status: String            // "created"/"updated"/"deleted"/"completed"/...
    public var id: String?               // EventKit calendarItemIdentifier (for create/createList)
    public var title: String?
    public init(status: String, id: String? = nil, title: String? = nil) { self.status = status; self.id = id; self.title = title }
}

public struct AuthSummary: Equatable {
    public var calendarCount: Int
    public var defaultList: String
}

/// A write that failed with a user-facing message + exit code (mirrors fail()/fail_invalid_due_date).
public struct WriteError: Error, Equatable {
    public let message: String           // WITHOUT "Error: " prefix; the shell adds it
    public let exitCode: Int32
    public init(_ message: String, exitCode: Int32 = 1) { self.message = message; self.exitCode = exitCode }
}

/// The EventKit boundary. `id` is the reminder's ZCKIDENTIFIER / EventKit calendarItemIdentifier.
public protocol RemindersWriter {
    func authorize() async throws -> AuthSummary
    func create(_ write: ReminderWrite) async throws -> WriteResult
    func update(id: String, _ write: ReminderWrite, clearDue: Bool) async throws -> WriteResult
    func delete(id: String) async throws -> WriteResult
    func complete(id: String) async throws -> WriteResult
    func uncomplete(id: String) async throws -> WriteResult
    func createList(title: String, color: String?) async throws -> WriteResult
    func renameList(currentTitle: String, newTitle: String) async throws -> WriteResult
    func deleteList(title: String) async throws -> WriteResult
}
```

- [ ] **Step 2: Implement `MockWriter.swift`** (test support — records calls, returns canned results, can be set to throw)

```swift
import Foundation
@testable import RemindersControl

final class MockWriter: RemindersWriter, @unchecked Sendable {
    enum Call: Equatable {
        case authorize
        case create(ReminderWrite)
        case update(id: String, ReminderWrite, clearDue: Bool)
        case delete(id: String)
        case complete(id: String)
        case uncomplete(id: String)
        case createList(title: String, color: String?)
        case renameList(currentTitle: String, newTitle: String)
        case deleteList(title: String)
    }
    private(set) var calls: [Call] = []
    var nextResult: WriteResult = WriteResult(status: "ok", id: "EK-NEW", title: "")
    var throwError: WriteError?

    private func resultOr(_ status: String) throws -> WriteResult {
        if let e = throwError { throw e }
        return WriteResult(status: status, id: nextResult.id, title: nextResult.title)
    }
    func authorize() async throws -> AuthSummary { calls.append(.authorize); return AuthSummary(calendarCount: 1, defaultList: "Reminders") }
    func create(_ w: ReminderWrite) async throws -> WriteResult { calls.append(.create(w)); return try resultOr("created") }
    func update(id: String, _ w: ReminderWrite, clearDue: Bool) async throws -> WriteResult { calls.append(.update(id: id, w, clearDue: clearDue)); return try resultOr("updated") }
    func delete(id: String) async throws -> WriteResult { calls.append(.delete(id: id)); return try resultOr("deleted") }
    func complete(id: String) async throws -> WriteResult { calls.append(.complete(id: id)); return try resultOr("completed") }
    func uncomplete(id: String) async throws -> WriteResult { calls.append(.uncomplete(id: id)); return try resultOr("uncompleted") }
    func createList(title: String, color: String?) async throws -> WriteResult { calls.append(.createList(title: title, color: color)); return try resultOr("created") }
    func renameList(currentTitle: String, newTitle: String) async throws -> WriteResult { calls.append(.renameList(currentTitle: currentTitle, newTitle: newTitle)); return try resultOr("renamed") }
    func deleteList(title: String) async throws -> WriteResult { calls.append(.deleteList(title: title)); return try resultOr("deleted") }
}
```

- [ ] **Step 3: Failing test** `WriteBoundaryTests` — construct a `ReminderWrite`, call MockWriter.create, assert the recorded call + result; assert `throwError` propagates.
- [ ] **Step 4: Run** `swift test --filter WriteBoundaryTests` → PASS. `swift build` → no warnings.
- [ ] **Step 5: Commit** `git commit -m "Phase 2 (W1): RemindersWriter boundary + value types + MockWriter"`.

---

## Task W2: EventKitWriter (real EKEventStore implementation)

Port `remctl-bridge.swift` logic into the package as the real writer. Source of truth: `./remctl-bridge.swift` (read it in full). Key pieces to port: `parseISO` (local-time tolerant), `parseAlarm`, `buildRecurrenceRule`, `colorForName`, `findReminder`, `findList`, `applyFields`, `requestAccess` (→ async), and the action handlers (create/update/delete/complete/uncomplete/create_list/rename_list/delete_list).

**Files:** Create `Sources/RemindersControl/Writes/EventKitWriter.swift`. Test: none in CI (EventKit) — covered by W13 manual verification; add a tiny non-EventKit unit test for `parseISO`/`colorForName` if they're pure.

- [ ] **Step 1: Implement `EventKitWriter.swift`.** Structure (port from the bridge — preserve every comment about CKRecord/dueDateComponents/timeZone behavior, the `flagged`→priority proxy, URL→notes append):

```swift
import Foundation
import EventKit
import CoreLocation

public final class EventKitWriter: RemindersWriter {
    let store = EKEventStore()

    public init() {}

    public func authorize() async throws -> AuthSummary {
        try await requestAccess()
        return AuthSummary(calendarCount: store.calendars(for: .reminder).count,
                           defaultList: store.defaultCalendarForNewReminders()?.title ?? "")
    }
    private func requestAccess() async throws {
        let granted: Bool
        do { granted = try await store.requestFullAccessToReminders() }
        catch { throw WriteError("EventKit access error: \(error.localizedDescription)") }
        if !granted { throw WriteError("Reminders access not granted") }
    }
    // ... port parseISO/parseAlarm/buildRecurrenceRule/colorForName/findReminder/findList/applyFields ...
    // findReminder -> store.calendarItem(withIdentifier: id) as? EKReminder, else throw WriteError("Reminder not found for id: \(id)")
    // create/update/delete/complete/uncomplete/createList/renameList/deleteList -> EKEventStore ops, returning WriteResult.
}
```

Important porting notes (from the bridge):
- `requestFullAccessToReminders()` has an async/throws form on macOS 14+ — use it (no semaphore).
- `applyFields` maps `ReminderWrite` → `EKReminder` (title/list/due/priority/notes/url-append/flagged-proxy/recurrence/alarm/location). Keep the `dueDateComponents` WITHOUT `.timeZone` in the set + explicit `reminder.timeZone = .current` (the CKRecord-acceptance fix, bridge lines 216–230).
- `update` takes `clearDue` → when true, `reminder.dueDateComponents = nil` (the Python `dueExplicitlyNull` path).
- `create`/`createList` return `WriteResult(status:, id: reminder.calendarItemIdentifier, title:)`.
- Map EventKit save errors → `throw WriteError("Save failed: \(error.localizedDescription)")` etc. (match the bridge's `fail("...")` strings).
- `findList` by title; not found → `WriteError("List not found: \(name)")`. `createList` source selection: first `.calDAV` else `.local` source; else `WriteError("No suitable calendar source found")`.

- [ ] **Step 2: Build** `swift build` → confirm CoreLocation links (after W5 adds the framework; if doing W2 before W5, temporarily add the framework or expect a link error and reorder). No CI test.
- [ ] **Step 3: Commit** `git commit -m "Phase 2 (W2): EventKitWriter (ports remctl-bridge EventKit logic)"`.

> **Sequencing note:** do W5's Package.swift CoreLocation addition before/with W2 so the build links. The plan lists W5 after, but the implementer should add the framework when W2 first needs it.

---

## Task W3: write input parsing (due / alarm / recurrence / priority)

Port the Python parsers used pre-write. These are pure (no EventKit), so fully unit-testable. Source: `parse_due` (`remctl:3886`), `parse_alarm` (`remctl:4041`), `parse_recurrence`/`recurrence_or_die` (`remctl:3991`/`4035`), the `add` priority map `pm` (incl. `h/med/m/l` aliases) vs `edit`'s map (no aliases). Contract: §add Parity notes (line 356) has the full `parse_due` grammar.

**Files:** Create `Sources/RemindersControl/Writes/WriteParsing.swift`. Test: `tests/RemindersControlTests/WriteParsingTests.swift`.

- [ ] **Step 1: Failing tests** — port `test_parse_due_accepts_today_and_tomorrow_with_times`, `test_parse_due_rejects_invalid_clock_time`, `test_parse_recurrence_rejects_invalid_specs`, `test_parse_alarm_normalizes_relative_and_absolute_values` from `tests/test_cli.py` (lines 24–72). Use an injected `now`/calendar for determinism (the Python uses local `datetime.now()`).
- [ ] **Step 2–4: Implement + pass.** Functions:
  - `parseDue(_ s: String, now: Date, calendar: Calendar) -> Date?` — the full grammar (today/tomorrow/eod/eow/tonight/+Nd/+Nw/+Nh/+Nm/next-this-weekday/in N units/ISO forms; `parse_clock_time` rejects minute>59, validates am/pm). Return nil on unparseable (caller maps to exit-2). **Port the grammar faithfully from `remctl:3886`-onward; it's ~80 lines.**
  - `parseAlarmSpec(_ s: String) -> AlarmWrite?` — `15m/1h/1d` → `.relativeOffset(-seconds)`; ISO → `.absolute`; clear-keywords (`clear/none/off/remove/delete`, edit only) → `.clear`. nil on bad.
  - `parseRecurrenceSpec(_ s: String) -> RecurrenceWrite?` — `daily/weekly/monthly/yearly` + optional `weekly mon,wed,fri` / `monthly 1,15`. nil on bad.
  - `parsePriority(_ s: String, allowAliases: Bool) -> Int?` — add: `{high/h:1, medium/med/m:5, low/l:9, none:0}`; edit: `{high:1, medium:5, low:9, none:0}` (no aliases). nil on bad.
- [ ] **Step 5: Commit** `git commit -m "Phase 2 (W3): write input parsing (due/alarm/recurrence/priority)"`.

---

## Task W4: write dispatch + WriteOutcome + identifier safety

The async dispatch wrapper + the shared helpers every write command uses: open store (read), get/refuse ZCKIDENTIFIER, emit `WriteOutcome`, map `WriteError`/`RemindersDBUnavailable` to stderr+exit.

**Files:** Create `Sources/RemindersControl/Writes/WriteDispatch.swift`. Test: `tests/RemindersControlTests/WriteDispatchTests.swift`.

- [ ] **Step 1–4: Implement + test.**

```swift
import Foundation

public struct WriteOutcome: Equatable {
    public var stdout: String = ""
    public var stderr: String = ""
    public var exitCode: Int32 = 0
    public static func ok(_ s: String) -> WriteOutcome { WriteOutcome(stdout: s, stderr: "", exitCode: 0) }
    public static func error(_ m: String, code: Int32 = 1) -> WriteOutcome { WriteOutcome(stdout: "", stderr: "Error: \(m)\n", exitCode: code) }
}

public enum WriteDispatch {
    /// Resolve a reminder by numeric Z_PK and return its (title, ZCKIDENTIFIER). Mirrors the
    /// not-found + no-stable-identifier refusals (NEVER falls back to title matching).
    /// `op` is the gerund phrase, e.g. "complete it".
    public static func resolveReminderForWrite(_ store: RemindersStore, id: Int, op: String) throws -> (title: String, ckid: String) {
        guard let row = store.reminder(pk: id) else { throw WriteError("#\(id) not found") }
        let title = row.string("ZTITLE")
        guard let ckid = row.string("ZCKIDENTIFIER"), !ckid.isEmpty else {
            throw WriteError("The reminder has no stable identifier. Refusing unsafe title-based fallback for #\(id) ('\(title ?? "(untitled)")') while trying to \(op).")
        }
        return (title ?? "", ckid)
    }
    /// Run an async write core, mapping thrown WriteError/RemindersDBUnavailable to a WriteOutcome.
    public static func perform(_ body: () async throws -> WriteOutcome) async -> WriteOutcome {
        do { return try await body() }
        catch let e as WriteError { return .error(e.message, code: e.exitCode) }
        catch let e as RemindersDBUnavailable { return .error(e.message) }
        catch { return .error("\(error)") }
    }
    /// Emit a WriteOutcome from the ArgumentParser shell (prints + exits).
    public static func emit(_ outcome: WriteOutcome) -> Never {
        if !outcome.stdout.isEmpty { FileHandle.standardOutput.write(Data(outcome.stdout.utf8)) }
        if !outcome.stderr.isEmpty { FileHandle.standardError.write(Data(outcome.stderr.utf8)) }
        exit(outcome.exitCode)
    }
}
```

Tests: `resolveReminderForWrite` returns (title,ckid) for a present reminder; throws `#<id> not found`; throws the no-identifier refusal (with the exact op phrase) when ZCKIDENTIFIER null. `perform` maps a thrown `WriteError(code:2)` to an outcome with exit 2 + `Error: ` prefix.

- [ ] **Step 5: Commit** `git commit -m "Phase 2 (W4): write dispatch + WriteOutcome + identifier safety"`.

---

## Task W5: writer factory + async command shells + Package.swift

Add CoreLocation; a `WriterFactory` the shells use (real EventKit) and tests override; convert the Phase-2 command stubs to `async`. Keep `CommandTreeTests` (45 commands) green.

**Files:** Modify `Package.swift`; Create `Sources/RemindersControl/Commands/Support/WriterFactory.swift`; (command stubs converted in W6–W12). Test: `CommandTreeTests` still green.

- [ ] **Step 1:** Add `.linkedFramework("CoreLocation")` to the `RemindersControl` target linkerSettings.
- [ ] **Step 2:** `WriterFactory`:

```swift
public enum WriterFactory {
    /// Overridable for tests; production returns a real EventKit writer.
    public static var make: () -> RemindersWriter = { EventKitWriter() }
}
```
(Command shells call `WriterFactory.make()`. Tests inject a `MockWriter` by setting `WriterFactory.make = { mock }` — or, preferred, call the command's core directly with the mock, bypassing the factory.)

- [ ] **Step 3:** Build + `swift test --filter CommandTreeTests` → 45 commands, green.
- [ ] **Step 4: Commit** `git commit -m "Phase 2 (W5): CoreLocation + writer factory"`.

---

# WRITE COMMANDS (W6–W12)

> Pattern for every command: a `static func perform...(... store:, writer:) async -> WriteOutcome` core (testable) + the `AsyncParsableCommand` `run() async` shell that opens the real store, builds the writer via `WriterFactory.make()`, calls the core, and `WriteDispatch.emit`s the outcome. Tests call the core with a `FixtureDB` `RemindersStore` + `MockWriter`. JSON uses `Dispatch.printJSON`-style compact `json.dumps(...)` (status payloads are **compact**, `ensure_ascii=True` — verify each at source). Contract refs are to the committed contract doc.

## Task W6: done / undone

Contract §done (362), §undone (377). `id` (int Z_PK), `--json`. Resolve pk→ckid (refuse if none); `writer.complete(id: ckid)` / `uncomplete`; human `Completed: {title}` / `Uncompleted: {title}` (safeDisplay); JSON `{"status":"completed","id":<id>,"title":<raw title>}` (compact). Errors: not-found exit 1; no-identifier refusal ("complete it"/"uncomplete it"); EventKit failure → exit 1.

**Files:** Modify `Commands/ReadCommands.swift`→ wait, writes live in `WriteCommands.swift`. Modify `Sources/RemindersControl/Commands/WriteCommands.swift` (`Done`, `Undone`). Test: `tests/RemindersControlTests/DoneUndoneTests.swift`.

- [ ] TDD: with a fixture reminder (pk 42, ckid 'ABC', title 'Pay rent'): core → MockWriter records `.complete(id: "ABC")`, outcome.stdout `Completed: Pay rent\n`, exit 0; `--json` → `{"status": "completed", "id": 42, "title": "Pay rent"}\n` (compact). not-found pk → outcome.stderr `Error: #99 not found\n` exit 1, MockWriter NOT called. no-ckid reminder → refusal message. Implement both cores + shells. Commit `git commit -m "Phase 2 (W6): done/undone commands"`.

## Task W7: delete

Contract §delete (389). `id`, `--force`, `--json`. Confirmation prompt (unless `--force`): `Delete '{title}' from {list}? [y/N] ` — read a line; accept only `y`/`Y`-prefixed. Cancel → prints `Cancelled.` exit 0 (no JSON even with --json). Confirmed → `writer.delete(id: ckid)`, `Deleted: {title}` / JSON `{"status":"deleted","id":<id>,"title":<title>}`.

**Note on testing the prompt:** the core takes a `confirm: () -> Bool` closure (the shell wires it to a real stdin read; tests pass a stub). Or a `force: Bool` + `promptResponse`. Use an injected `confirm` closure defaulting to a real reader in the shell.

**Files:** Modify `WriteCommands.swift` (`Delete`). Test: `DeleteTests.swift`.

- [ ] TDD: --force deletes (MockWriter `.delete`); confirm-yes deletes; confirm-no → `Cancelled.\n` exit 0, MockWriter NOT called; not-found/no-id refusals ("delete it"). Commit.

## Task W8: add

The big one. Contract §add (307). Declare the FULL flag surface (per owner decision). Phase 2 implements EventKit flags; private-only flags (`--urgent/--grocery/--section/--new-section/--section-id/--subtask/--image/--early-reminder`, synced `--tags`, rich `--url`) → error `WriteError("<flag> requires the private metadata layer (Phase 3); not yet implemented.")`. Pre-write validation order matters (see contract Exit/errors): bad due → exit **2** (`fail_invalid_due_date` JSON shape); bad alarm/priority → exit 1.

Flow: parse due/priority/recurrence/alarm (validation BEFORE any write); resolve `-l/--list-id` via `store.resolveListRef` (Phase 1) → list name; build `ReminderWrite`; `writer.create(write)`; re-read created row by ckid via `store.reminder(identifier:)` for `numericId`; emit. Human: `Created: {title}`, optional `List: {title} (resolved from {requested})`, optional `ID: #{Z_PK}`. JSON: `{"status":"created","id":<ekId>,"title":<title>}` + `resolvedList`/`numericId` when applicable.

**Files:** Modify `WriteCommands.swift` (`Add`). Test: `AddTests.swift`.

- [ ] TDD: basic add (title+notes) → MockWriter `.create` with the expected `ReminderWrite`; JSON `{"status":"created",...}`. `--due "tomorrow"` sets `due`. bad `--due "notadate"` → exit 2 + the structured JSON error (`code":"invalid_due_date"`). `--priority high` → priority 1. `--url` (Phase 2 → notes-append, NOT private) — confirm contract: without --private the url goes to bridge `url`/notes; with --private removed, default behavior... **decision: Phase 2 `--url` = notes-append (the EventKit path)**; the rich-attachment behavior is Phase 3. A private-only flag like `--urgent` → the Phase-3 error. Commit `git commit -m "Phase 2 (W8): add command (EventKit flags; private flags stubbed)"`.

> Port `parse_due`'s exact grammar via W3. The `fail_invalid_due_date` JSON (contract line 338) is exit 2 with `examples` array — reproduce verbatim.

## Task W9: edit

Contract §edit (401). Declare full flag surface; private flags → Phase-3 error. EventKit fields: title, list move (`-l/--list-id`, bridge-only), notes, due (or `clear`), priority (no aliases — W3 `allowAliases:false`), url→notes-merge, recurrence, alarm (or clear-keyword), location alarm. Implement the **double-tap nudge** (contract line 449: if new due == current ZDUEDATE to the second, fire a pre-update `due:dt+1h` then the real update) and **absolute-alarm carry/clear** (lines 450–452, reading `q_alarms`/`ZDUEDATE`/`ZDISPLAYDATEDATE`). `notes_body is not None` gates notes (empty string still sets). No-op → `Nothing to update.`. JSON `{"status":"updated","id":<id>}` + `list`/`resolvedList` when moved.

**Files:** Modify `WriteCommands.swift` (`Edit`). Test: `EditTests.swift`.

- [ ] TDD: edit title → MockWriter `.update(id:ckid, write with title, clearDue:false)`; `--due clear` → `clearDue:true`; double-tap nudge fires two `.update` calls when new due == current; list move → `.update` with list + JSON `list`; no fields → `Nothing to update.` (no writer call); `-t/--tags` → Phase-3 error. Commit.

## Task W10: link / open

Contract §link (495), §open (517). **link is read-only** (no EventKit) — prints `x-apple-reminderkit://REMCDReminder/<ckid>` for given ids or a list's top-level reminders (skips null-ckid); JSON array `[{id,title,link}]` (indent=2). **open** shells `open` (the launcher, not osascript): deep-link the reminder, else `open -a Reminders`. Use a `launch: ([String]) -> Void` injected closure (shell wires `Process`/`open`; tests stub).

**Files:** Modify `Commands/ReadCommands.swift` or `WriteCommands.swift` (`Link`, `Open`). (link is read-only — it can live with reads; place per existing stub location.) Test: `LinkOpenTests.swift`.

- [ ] TDD: link by id → both lines (id-colored `#id`, dim link); link `--list` → all top-level; null-ckid omitted; both ids+list → `Error: pass reminder IDs or a list target, not both.`. open id → launch `["open", "x-apple-reminderkit://REMCDReminder/<ckid>"]` (stub records args), prints `Opened #<id> in Reminders.app`; open no-id → `["open","-a","Reminders"]`. Commit.

## Task W11: list-create / list-rename / list-delete

Contract §list-create (643), §list-rename (737), §list-delete (759). **list-create**: `name`, `--color` (public name only in Phase 2; hex/symbol/emoji/grocery → Phase-3 error), `--json`. `writer.createList(title:, color:)`; `Created list: {name}` / `{"status":"created","name":<name>}`. **list-rename**: `name`/`--list-id` + `new_name`/`--new-name`; resolve current title (Phase 1 `resolveRequiredListTarget`); `writer.renameList(currentTitle:, newTitle:)`; `Renamed: {old} -> {new}` / `{"status":"renamed","id":<pk>,"old_name":<old>,"new_name":<new>}`. **list-delete**: `name`/`--list-id`, `--force`, confirm prompt; `writer.deleteList(title:)`; `Deleted list: {title}`.

**Files:** Modify `Commands/ListCommands.swift` (`ListCreate`, `ListRename`, `ListDelete`). Test: `ListWriteTests.swift`.

- [ ] TDD: list-create basic → MockWriter `.createList(title:"Work", color:nil)`; `--color red` → color "red"; `--symbol x` → Phase-3 error (before writer call); list-rename resolves current title then `.renameList`; both new-name forms → error; list-delete --force → `.deleteList`, confirm-no → `Cancelled.`. Commit `git commit -m "Phase 2 (W11): list-create/rename/delete (EventKit)"`.

## Task W12: import

Contract §import (553). `file` (JSON array path), `--json`. Per item, build an `Add`-args namespace and call the **add core** (W8) with the same store+writer; count created/errors/total; summary `\nImported <c>/<t> reminders (<e> errors)` / compact JSON `{"created","errors","total"}`. Title-less item → stderr warning + errors++. A core that returns a non-zero `WriteOutcome` → errors++ (don't abort). `due` key wins over `dueDate`; tags dropped; priority forwarded as name string.

**Files:** Modify `Commands/OpsCommands.swift` (`Import`). Test: `ImportTests.swift`.

- [ ] TDD: a 2-item file (one valid, one title-less) → created 1, errors 1, total 2; summary text + JSON. `due` precedence. Commit.

---

## Task W13: integration verification + final

- [ ] **Step 1: Manual EventKit smoke (local, not CI).** Build release; run against the real store: `remctl add "remctl-phase2-test" -l <a real list> --due tomorrow --json`, confirm it appears in Reminders.app with the right due; `remctl done <id>`, `remctl edit <id> --title ...`, `remctl delete <id> --force`, `remctl list-create "remctl-tmp" --color blue` then `list-rename` + `list-delete --force`. Record results in the task (paste outputs). Confirm ZCKIDENTIFIER ↔ EventKit `calendarItemIdentifier` round-trips (the one assumption to validate live).
- [ ] **Step 2:** Full `swift test` green; `swift build` 0 warnings; `remctl --help` still 45 commands.
- [ ] **Step 3: Commit** + note in the commit which commands were live-verified.

---

## Self-review checklist

1. **Coverage:** Phase-2 commands all have a task: add(W8), edit(W9), done/undone(W6), delete(W7), link/open(W10), list-create/rename/delete(W11), import(W12). Deferred (documented, NOT in this plan): flag, unflag, list-edit, list-pin, list-unpin → Phase 3.
2. **osascript:** zero references in new code (grep to confirm at W13). `open` uses the `open` launcher only.
3. **Async:** write shells are `async`; cores are `async` and return `WriteOutcome` (no direct print/exit) for testability.
4. **Identifier safety:** done/undone/delete/edit resolve pk→ckid and refuse (no title fallback) — W4 helper, reused.
5. **Exit codes:** invalid-due = **2** (add/edit); all other write errors = 1. `WriteError.exitCode` carries it.
6. **JSON profiles:** status/error payloads are **compact** (`ensure_ascii=True`); link is `indent=2`. Verify each command's `json.dumps(...)` at its source line.
7. **Phase-3 stubs:** add/edit/list-create private-only flags error with a clear Phase-3 message (declared, not silently ignored).
8. **Type consistency:** `ReminderWrite`/`WriteResult`/`WriteError`/`WriteOutcome`/`RemindersWriter` names used uniformly W1→W12.

## Execution handoff

After saving, choose execution mode (subagent-driven recommended). W1–W5 (boundary + parsing + dispatch) are the critical path — review tightly. W6–W12 are repetitive over the established core/shell/mock pattern. W13's EventKit smoke is mine to run locally (not CI).
