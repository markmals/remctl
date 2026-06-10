# Port Upstream 1.0.4–1.1.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port every fix/feature from upstream (viticci/remctl) commits `6755b8e`…`ee8a120` into our Swift rewrite: all-day creation/edit, `done --date`, content-scored DB selection, shared-list assignment (+ `sharees` command), limited EventKit read fallback (`--via-eventkit`), and the doctor improvements (zsh fpath check, Ghostty/bundle host-app context, remindd hint).

**Architecture:** Our fork is a single Swift binary — EventKit and private ReminderKit run in-process (no bridge/helper subprocesses), so upstream's "bridge required" error paths vanish and the bridge JSON protocol maps onto `ReminderWrite`/`PrivateWriter`. Each task is an independently shippable vertical slice (impl + tests + completions), committed separately on branch `port-upstream-1.1.0`.

**Tech Stack:** Swift 6 / swift-argument-parser / GRDB / EventKit / private ReminderKit (ObjC `RKPDispatch`). Tests: swift-testing via `swift test`.

**Upstream reference:** all Python line refs are against `upstream/main` (`git show upstream/main:remctl`).

---

### Task 1: All-day reminder creation (upstream `6755b8e`)

**Files:**
- Modify: `Sources/RemindersControl/Writes/WriteParsing.swift` (add `dueSpecIsAllDay`)
- Modify: `Sources/RemindersControl/Writes/RemindersWriter.swift` (`ReminderWrite.allDay`)
- Modify: `Sources/RemindersControl/Writes/EventKitWriter.swift:138-141` (date-only components)
- Modify: `Sources/RemindersControl/Commands/WriteCommands.swift` (`Add.perform`, `--due` help)
- Test: `Tests/RemindersControlTests/WriteParsingTests.swift`, `Tests/RemindersControlTests/AddTests.swift`

- [ ] **Step 1: Failing tests for `dueSpecIsAllDay`** — port the upstream truth table (remctl:4287 `due_spec_is_all_day`): all-day = `today`, `tomorrow`, `eow`, `2026-06-01`, `+3d`, `3d`, `+2w`, `+1m`, `in 2 days`, `in 2 weeks`, `in 1 month`, `friday`, `next friday`, `this fri`; NOT all-day = `eod`, `+2h`, `in 3 hours`, `today at 3pm`, `tomorrow 09:30`, `friday at 15:00`, `tonight at 11`, `2026-06-01 14:00`, `2026-06-01T14:00`, empty string.
- [ ] **Step 2: Implement `WriteParsing.dueSpecIsAllDay`**

```swift
/// Port of `due_spec_is_all_day` (remctl:4287): true when the due-date TEXT names a
/// day without a clock time. Mirrors the Python regexes exactly; weekday lookup
/// reuses `daysMap` (Python WEEKDAY_MAP).
public static func dueSpecIsAllDay(_ s: String) -> Bool {
    if s.isEmpty { return false }
    let sl = s.lowercased().trimmingCharacters(in: .whitespaces)
    if ["today", "tomorrow", "eow"].contains(sl) { return true }
    if sl == "eod" { return false }
    if firstMatch(in: s.trimmingCharacters(in: .whitespaces), pattern: #"^\d{4}-\d{2}-\d{2}$"#, groupCount: 0) != nil { return true }
    if let m = firstMatch(in: sl, pattern: #"^[+]?(\d+)([dwmh])$"#) {
        return ["d", "w", "m"].contains(m[2])
    }
    if let m = firstMatch(in: sl, pattern: #"^in\s+(\d+)\s+(day|days|week|weeks|hour|hours|month|months)$"#) {
        return !["hour", "hours"].contains(m[2])
    }
    if let m = firstMatch(in: sl, pattern: #"^(?:(next|this)\s+)?(\w+)(?:\s+(?:at\s+)?(.+))?$"#, groupCount: 3) {
        return daysMap[m[2]] != nil && m[3].isEmpty
    }
    return false
}
```
(Note: `firstMatch` is currently `private`; relax to `internal`/keep private and call within the enum — it's in the same type, so no change needed.)
- [ ] **Step 3: Add `allDay` to `ReminderWrite`** — `public var allDay: Bool?` after `due` (mirrors bridge `Command.allDay`).
- [ ] **Step 4: EventKitWriter date-only components** — in `applyFields`, mirror upstream bridge:

```swift
if case .set(let date) = write.due {
    if write.allDay == true {
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day], from: date)
    } else {
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
    }
    reminder.timeZone = TimeZone.current
} else if case .clear = write.due { ... }
```
- [ ] **Step 5: Wire `Add.perform`** — after due parse: `let dueAllDay = dueDate != nil && WriteParsing.dueSpecIsAllDay(due!)`; in step 5 (build write): `if dueAllDay { write.allDay = true }`. Update `--due` help to "Due date; date-only forms create all-day reminders, explicit times create timed reminders". Add `remctl add "Pay rent" -d 2026-06-01` style doc examples in Task 12. (No bridge-required error: EventKit is in-process, always available.)
- [ ] **Step 6: AddTests** — MockWriter records `ReminderWrite`; assert `add -d 2026-06-01` produces `allDay == true` and `add -d "2026-06-01 14:00"` produces `allDay == nil`.
- [ ] **Step 7: `swift test` green; commit** `feat: create all-day reminders for date-only due inputs (port upstream 6755b8e)`

### Task 2: Preserve all-day due dates on edit (upstream `ee8a120`)

**Files:**
- Modify: `Sources/RemindersControl/Commands/WriteCommands.swift` (`Edit.perform` steps 4–9)
- Test: `Tests/RemindersControlTests/EditTests.swift`

- [ ] **Step 1: Failing tests** — (a) `edit -d 2026-06-01` sets `allDay == true` on the real write; (b) double-tap nudge for an all-day due uses **+1 day** not +1h and the nudge write carries `allDay == true`; (c) timed dues keep the +1h nudge and no allDay.
- [ ] **Step 2: Implement** — after due parse: `let dueAllDay = dueDate != nil && WriteParsing.dueSpecIsAllDay(due!)`. Nudge block (`WriteCommands.swift:495-501`): `nudgeDate = dueDate.addingTimeInterval(dueAllDay ? 86_400 : 3_600)`. In step 5: `if dueAllDay { write.allDay = true }`. In step 9 nudge firing: `if dueAllDay { nudge.allDay = true }`.
- [ ] **Step 3: `swift test` green; commit** `fix: preserve all-day due dates on edit (port upstream ee8a120)`

### Task 3: `done --date` explicit completion dates (upstream `aba7cf5` part)

**Files:**
- Modify: `Sources/RemindersControl/Writes/WriteParsing.swift` (`parseCompletionDate`)
- Modify: `Sources/RemindersControl/Writes/RemindersWriter.swift` (protocol `complete(id:completionDate:)`)
- Modify: `Sources/RemindersControl/Writes/EventKitWriter.swift` (`complete`)
- Modify: `Sources/RemindersControl/Commands/WriteCommands.swift` (`Done`)
- Modify: `Sources/RemindersControl/Commands/Support/ShellSupport.swift` (zsh/bash/fish entries for `done`)
- Test: `Tests/RemindersControlTests/DoneUndoneTests.swift`, `WriteParsingTests.swift`, `CompletionTests.swift`; update `Tests/RemindersControlTests/Support/MockWriter.swift`

- [ ] **Step 1: Failing tests** — `parseCompletionDate`: accepts `2026-05-27`, `2026-05-27 09:30`, `2026-05-27T09:30`, `2026-05-27 09:30:15`; rejects `tomorrow`, `2026-5-7`, `notadate`. Done: `--date` bad value → exit 2 with `invalid_completion_date` JSON (`{"status":"error","code":"invalid_completion_date","field":"date","input":…,"message":"Could not parse completion date. No reminder was changed.","examples":["2026-05-27","2026-05-27 09:30"]}`); `--date` on recurring reminder → exit 1 `completion_date_unsupported_for_recurring` with message `--date is not supported for recurring reminders. Use 'remctl done <id>' without --date to advance the series.`; success JSON gains `completionDate`; human gains ` (<iso>)` suffix.
- [ ] **Step 2: `parseCompletionDate`**

```swift
/// Port of `parse_completion_date` (remctl:4641). Strict: COMPLETION_DATE_RE is
/// ^\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?$ — then parsed naive-local.
public static func parseCompletionDate(_ value: String, calendar: Calendar = .current) -> Date? {
    let text = value.trimmingCharacters(in: .whitespaces)
    guard firstMatch(in: text, pattern: #"^\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?$"#, groupCount: 0) != nil else { return nil }
    let normalized = text.replacingOccurrences(of: "T", with: " ")
    for fmt in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
        if let d = strptime(normalized, format: fmt, calendar: calendar) { return d }
    }
    return nil
}
```
- [ ] **Step 3: Protocol change** — `func complete(id: String, completionDate: Date?) async throws -> WriteResult`. Update EventKitWriter (`reminder.completionDate = date` after `isCompleted = true`; echo ISO in result via new `WriteResult` field? No — keep WriteResult; Done formats from its own parsed date). Update `MockWriter` + all call sites (`Done.perform`).
- [ ] **Step 4: Wire `Done`** — `@Option(name: .long, help: "Completion date (YYYY-MM-DD [HH:MM])") var date: String?`. In `perform`: parse → exit-2 outcome on failure (mirror `Add.failInvalidDueDate` shape, ISO suffix formatted with `yyyy-MM-dd'T'HH:mm:ss`); read `store.reminder(pk:)` row, if `recurrenceFromRow(row, ts:…) != nil` and date given → exit 1 (JSON: `{"status":"error","code":"completion_date_unsupported_for_recurring","message":…,"id":id}` on stderr). Pass `completionDate` through; JSON output appends `("completionDate", .string(iso))`, human appends ` (\(iso))`.
- [ ] **Step 5: Completions** — add `done` blocks: zsh `'--date[Set completion date]:date:' '--json[JSON output]'`; bash `--date --json`; fish `-l date -d "Set completion date" -r` + `-l json`.
- [ ] **Step 6: `swift test` green; commit** `feat: done --date sets explicit completion dates (port upstream aba7cf5)`

### Task 4: Content-scored DB selection + schema validation (upstream `aba7cf5` part)

**Files:**
- Modify: `Sources/RemindersControl/Runtime/Paths.swift` (`findMainDBPath` scoring)
- Modify: `Sources/RemindersControl/Store/RemindersStore.swift` (`open` schema guard)
- Test: `Tests/RemindersControlTests/RuntimeTests.swift`, `StoreTests.swift`

- [ ] **Step 1: Failing tests** — temp store dir with two `Data-*.sqlite`: (a) bigger file with NO `ZREMCDREMINDER` table vs smaller file with reminder tables + rows → smaller wins; (b) two valid DBs → more non-deleted reminders wins; (c) `RemindersStore.open` on a DB without `ZREMCDREMINDER` throws `RemindersDBUnavailable` containing "ZREMCDREMINDER".
- [ ] **Step 2: Implement scoring** (port `reminders_db_score`, remctl:202-266; lexicographic tuple compare):

```swift
/// Port of `reminders_db_score`: (hasReminderTable, reminderCount, activeCount,
/// listCount, objectCount, latestModified, sidecarSize, dbSize) — compared
/// lexicographically, all read-only. Unreadable DB scores all-zero except sizes.
struct DBScore: Comparable { let parts: [Double]; static func < (a: Self, b: Self) -> Bool { … } }
static func remindersDBScore(_ url: URL) -> DBScore { /* open GRDB read-only, table_exists + scalar counts per upstream SQL, swallow errors */ }
static func sqliteSidecarSize(_ url: URL) -> Int  // sums -wal/-shm st_size
```
`findMainDBPath` becomes: glob candidates → `candidates.max(by: { score($0) < score($1) })`. Upstream SQL, verbatim: reminder count `SELECT COUNT(*) FROM ZREMCDREMINDER WHERE COALESCE(ZMARKEDFORDELETION,0)=0`; active adds `AND COALESCE(ZCOMPLETED,0)=0`; lists `SELECT COUNT(*) FROM ZREMCDBASELIST WHERE COALESCE(ZMARKEDFORDELETION,0)=0 AND ZNAME IS NOT NULL AND ZNAME != ''`; objects `SELECT COUNT(*) FROM ZREMCDOBJECT WHERE COALESCE(ZMARKEDFORDELETION,0)=0`; latest `SELECT MAX(COALESCE(ZMODIFIEDDATE, ZLASTMODIFIEDDATE, ZCREATIONDATE, 0)) FROM ZREMCDOBJECT` (each gated on the table existing).
- [ ] **Step 3: Schema guard in `RemindersStore.open`** — after opening, `if !tableColumnNames("ZREMCDREMINDER").isEmpty == false { throw RemindersDBUnavailable("Reminders store is missing the expected ZREMCDREMINDER table; this macOS Reminders schema may need a RemCTL update.") }` (use a real `table_exists` query via `db.tableExists`).
- [ ] **Step 4: `swift test` green; commit** `fix: pick the Reminders store by content score, validate schema on open (port upstream aba7cf5)`

### Task 5: Sharee queries + `sharees` command (upstream `683c362` part 1)

**Files:**
- Create: `Sources/RemindersControl/Store/Queries+Sharees.swift`
- Modify: `Sources/RemindersControl/Store/Schema.swift` (`Zent.sharee = 36`, `Zent.assignment = 21`)
- Modify: `Sources/RemindersControl/Commands/ReadCommands.swift` (add `Sharees` command to `readCommands`)
- Modify: `Sources/RemindersControl/Commands/Support/ShellSupport.swift` (completions: `sharees`)
- Modify: `Tests/RemindersControlTests/Support/FixtureDB.swift` (sharee/assignment columns)
- Test: Create `Tests/RemindersControlTests/ShareesTests.swift`

- [ ] **Step 1: Fixture columns** — extend `ZREMCDOBJECT` create with `ZDISPLAYNAME TEXT, ZFIRSTNAME TEXT, ZLASTNAME TEXT, ZADDRESS1 TEXT, ZSTATUS INTEGER, ZACCESSLEVEL INTEGER, ZLIST INTEGER, ZASSIGNEE INTEGER, ZORIGINATOR INTEGER, ZREMINDER1 INTEGER, ZCKASSIGNEEIDENTIFIER TEXT, ZCKORIGINATORIDENTIFIER TEXT, ZASSIGNEDDATE REAL, ZCKIDENTIFIER TEXT`; extend `ZREMCDBASELIST` with `ZSHAREDOWNERIDENTIFIER BLOB`.
- [ ] **Step 2: Failing tests** — fixture list with 2 sharees (one is the owner, blob UUID matches): `sharees(listPk:)` returns ordered rows; `listSharedOwnerCkid` decodes the blob; `shareeToDict` marks `currentUser` case-INSENSITIVELY (`ckidEq`); command JSON shape `{"list":…,"currentUserSharee":…,"sharees":[…]}`; human output `Sharees for <list>:` + `- Name (me) addr (id: N)` + count line; empty list → `No sharees`.
- [ ] **Step 3: Implement queries** (port q_sharees/q_list_shared_owner_ckid/q_assignment, remctl:1113-1576):

```swift
extension RemindersStore {
    public func sharees(listPk: Int) -> [Row]           // Z_ENT=Zent.sharee, ZLIST=?, ORDER BY Z_PK
    public func listSharedOwnerCkid(listPk: Int) -> String?  // uuidFromBlob(ZSHAREDOWNERIDENTIFIER), Z_ENT=Zent.list
    public func assignment(reminderPk: Int) -> Row?      // the LEFT JOIN query, LIMIT 1, swallow missing-column errors
}
public func ckidEq(_ a: String?, _ b: String?) -> Bool   // casefold compare, false when either empty (port ckid_eq)
public func shareeDisplayName(_ row: Row) -> String      // ZDISPLAYNAME ?? "First Last" ?? ZADDRESS1 ?? ""
public func shareeToDict(_ row: Row, currentUserCkid: String?) -> [(String, JSONValue)]
public func assignmentToDict(_ row: Row?, ts: (Double) -> Date?) -> JSONValue?   // {id,objectUUID,status,assignee:{…},originator:{…},assignedDate}
```
- [ ] **Step 4: `Sharees` command** — `@Argument var list: String?`, `@Option(name: .long) var listId: Int?`, `@OptionGroup JSONOnlyOptions`; resolve via `resolveRequiredListTarget`; outputs per upstream `cmd_sharees` (remctl:6224). JSON `indent: 2, ensureAscii: false`.
- [ ] **Step 5: Completions** — zsh command list entry `'sharees:Show people available for assignment in a shared list'` + `sharees)` block (`--list-id`, `--json`); bash commands string + `sharees` branch; fish subcommand + per-flag completes.
- [ ] **Step 6: `swift test` green; commit** `feat: sharees command + sharee/assignment queries (port upstream 683c362)`

### Task 6: Assignment writes — `--assign` / `--unassign` (upstream `683c362` part 2 + `03a2920` guardrails + `ckid_eq` fix from `aba7cf5`)

**Files:**
- Modify: `Sources/ReminderKitPrivate/ReminderKitPrivate.m` (+ `include/ReminderKitPrivate.h` if action list documented there)
- Modify: `Sources/RemindersControl/Writes/PrivateWriter.swift` (protocol + `assign`/`unassign` on changes)
- Modify: `Sources/RemindersControl/Writes/ReminderKitWriter.swift` (two methods; idempotent set += `assign_sharee`, `clear_assignment`)
- Create: `Sources/RemindersControl/Store/ShareeResolve.swift`
- Modify: `Sources/RemindersControl/Writes/PrivateChanges.swift` (`apply` gains `assign: String?`, `unassign: Bool`)
- Modify: `Sources/RemindersControl/Commands/WriteCommands.swift` (Add + Edit flags, wantsPrivate, both-flags guard)
- Modify: `Sources/RemindersControl/Commands/Support/ShellSupport.swift` (`--assign`/`--unassign` in add/edit completions)
- Test: `Tests/RemindersControlTests/PrivateChangesTests.swift`, `AddTests.swift`, `EditTests.swift`, new `ShareeResolveTests.swift`; update `MockPrivateWriter`

- [ ] **Step 1: ObjC actions** (verbatim port of upstream `remctl-private.m` diff): declare `- (id)assignmentContext;` on the change-item interface, add `REMReminderAssignmentContextChangeItem` interface (`addAssignmentWithAssigneeID:originatorID:status:`, `removeAllAssignments`), `shareeURL()` (`x-apple-reminderkit://REMCDSharee/<ckid>`), register `assign_sharee`/`clear_assignment` in the known-actions array, and implement both action branches inside `RKPDispatch`'s reminder-change block exactly as upstream (status:1, `removeAllAssignments` first; `details[@"assigneeId"]/[@"originatorId"]` / `details[@"assignmentCleared"] = @YES`).
- [ ] **Step 2: PrivateWriter protocol** — `func assignSharee(id: String, assigneeId: String, originatorId: String) async throws -> PrivateResult`; `func clearAssignment(id: String) async throws -> PrivateResult`. ReminderKitWriter marshals `["action": "assign_sharee", "id": id, "assigneeId": …, "originatorId": …]` / `["action": "clear_assignment", "id": id]`. MockPrivateWriter records.
- [ ] **Step 3: Failing resolution tests** (port the `03a2920` guardrail matrix): no sharees → `CLIError("target list has no sharees; assignment requires a shared list.")`; empty value → `--assign requires a name, email, phone number, or sharee ID.`; `me`/`myself` resolves owner (case-insensitive ckid match — the `aba7cf5` fix); exact name/email/phone/pk match; contains-match fallback; multiple matches → `multiple sharees match '…'. Use one of: …`; no match → `no sharee matching '…' in this list. Available: …`; originator = owner sharee, errors when absent.
- [ ] **Step 4: Implement `ShareeResolve.swift`** — `resolveSharee(store:listPk:value:) throws -> Row` and `resolveAssignmentOriginator(store:listPk:) throws -> Row`, port of remctl:846-918 with `ckidEq` everywhere upstream compares CKIDs, `normalizeListLookupName` for term matching (reuse the existing helper from Queries+Lists), `_sharee_match_terms` incl. the `addr.split(":",1)[1]` tail, exact-before-contains, Z_PK dedup.
- [ ] **Step 5: Wire commands** — Add + Edit: `@Option(name: .long, help: "Assign to a shared-list user (name, email, phone, sharee ID, or 'me')") var assign: String?`; `@Flag(name: .long, help: "Clear the existing assignment") var unassign = false`. Both → `CLIError("pass either --assign or --unassign, not both.")` (validated up front, port `validate_private_args`). Both join `wantsPrivate`. `--assign` without a resolvable shared-list target (`listPk == nil` on add) → `CLIError("--assign requires a target shared list via -l/--list or --list-id.")`. PrivateChanges.apply: insert slot 9.5 (after location comment, before grocery), in upstream order: `assign_sharee` (resolve assignee + originator) then `clear_assignment`.
- [ ] **Step 6: `swift test` green; commit** `feat: shared-list assignment via --assign/--unassign (port upstream 683c362 + 03a2920 guardrails + aba7cf5 ckid fix)`

### Task 7: Assignment display — fmt/info/serializers (upstream `683c362` part 3)

**Files:**
- Modify: `Sources/RemindersControl/Output/ReminderFormat.swift` (`fmt` gains `assigneeName: String? = nil`)
- Modify: `Sources/RemindersControl/Serialization/ReminderSerializer.swift` + the `serializeReminders(rows, store:)` convenience (attach `assignment`)
- Modify: `Sources/RemindersControl/Commands/ReadCommands.swift` (`Info` human lines; pass assignee to `fmt` in list renders)
- Test: `Tests/RemindersControlTests/ReminderFormatTests.swift`, `InfoTests.swift`, `SerializerTests.swift`

- [ ] **Step 1: Failing tests** — `fmt` renders ` @Name` after recurrence, before tags (dimmed when completed); verbose adds `    Assigned: Name` (cyan) before Flagged; `info` human prints `  Assigned:  Name` + `  By:        Originator` after Urgent; JSON serialization gains an `assignment` object after the base fields when the store has an assignment row.
- [ ] **Step 2: Implement** — `fmt(…, assigneeName: String? = nil)`: `let assignStr = assigneeName.map { " @\(safeDisplay($0))" } ?? ""` placed `…\(recurStr)\(assignStr)\(tagStr)\(subStr)`, dim on completed. Store-backed call sites (`Today`/`Upcoming`/`Overdue`/`Search`/`Flagged`/`Urgent`/`Show`/`Subtasks`/`Info` subtask lines): preload via `store.assignment(reminderPk:)` per row (or a `preloadAssignments(pks)` map alongside `preloadExtras`). Serializer: in the store-convenience `serializeReminders`/`serializeReminder` paths append `("assignment", assignmentToDict(...))` when non-nil.
- [ ] **Step 3: `swift test` green; commit** `feat: render assignments in fmt/info/JSON (port upstream 683c362)`

### Task 8: Limited EventKit read fallback `--via-eventkit` (upstream `391b1c9`)

**Files:**
- Create: `Sources/RemindersControl/Reads/EventKitReader.swift`
- Modify: `Sources/RemindersControl/Commands/ReadCommands.swift` (Show/Search/Today/Upcoming flag + early dispatch)
- Modify: `Sources/RemindersControl/Commands/Support/ShellSupport.swift` (completions)
- Test: Create `Tests/RemindersControlTests/EventKitReadTests.swift`

- [ ] **Step 1: Failing tests (pure parts)** — validation: `--via-eventkit` + `--list-id` → exit 2 `eventkit_read_unsupported` ("--via-eventkit cannot use RemCTL numeric list ids. Pass a list name instead."); + `--format table` → exit 2 ("…does not support table output…"); `show --via-eventkit` without list name → exit 2 ("--via-eventkit show requires a list name."). Payload wrapper: `{"source":"eventkit","fidelity":"limited","mode":…,"idWarning":…,"limitations":[6 strings],"items":[…]}` with items sanitized to the 14 `EVENTKIT_ITEM_KEYS` and no `id` key. Human formatter `fmtEventKitItem`: `[ ]`/`[x]` + title + due/list/notes lines per upstream `fmt_eventkit_item` (remctl:2517 — read it verbatim during implementation).
- [ ] **Step 2: Implement `EventKitReader`** — port `runLimitedEventKitRead` (bridge diff in `391b1c9`) against an injected `EKEventStore`: modes show/search/today/upcoming; list match by exact title, 0 → "List not found: …", >1 → "Multiple reminder lists named …; EventKit fallback cannot disambiguate them"; `fetchReminders` semaphore + 30s timeout + cancel; query filter case/diacritic-insensitive over title+notes; today = `predicateForIncompleteReminders(withDueDateStarting: includeOverdue ? nil : startOfToday, ending: startOfTomorrow)`; upcoming days clamped 1…3650, end = start + days + 1; sort dueDate-then-title with nil-due last; limit `max(1, min(limit ?? 500, 1000))`. Payload builder `reminderPayload(_ reminder:)` exactly as the upstream bridge (priorityName buckets, dateFromComponents allDay = no h/m/s, alarms/recurrence sub-payloads). Split payload-shaping into pure functions taking plain value structs so tests don't need EventKit objects.
- [ ] **Step 3: Wire the four commands** — `@Flag(name: .long, help: "Limited read-only EventKit fallback; no numeric ids or private metadata") var viaEventkit = false`. When set: validate (step 1 rules), then run the EventKit path **without opening the SQLite store** (this is the point — works without Full Disk Access), print wrapper JSON (`indent: 2`) or human lines + `EventKit fallback note: <idWarning>` trailer per upstream `cmd_show_eventkit`/`cmd_today_eventkit` (remctl:2589-2660 — read during implementation). Errors: failed read → exit 1 `eventkit_read_failed`.
- [ ] **Step 4: Completions** — `--via-eventkit` in zsh/bash/fish for show/search/today/upcoming (and `--no-overdue` already exists on today).
- [ ] **Step 5: `swift test` green; commit** `feat: --via-eventkit limited read fallback (port upstream 391b1c9)`

### Task 9: Doctor — zsh completion fpath check (upstream `aba7cf5` part)

**Files:**
- Modify: `Sources/RemindersControl/Commands/Support/ShellSupport.swift` (`zshCompletionLoadable`, `zshCompletionHint`)
- Modify: `Sources/RemindersControl/Commands/DoctorSupport.swift` (probe fields + check)
- Test: `Tests/RemindersControlTests/DoctorTests.swift`, `SetupTests.swift`

- [ ] **Step 1: Failing tests** — probes with shell=zsh + completion exists + loadable → `completion_fpath` ok ("<dir> is on zsh fpath"); not loadable → warn with hint text ("Add to ~/.zshrc:\n    fpath=(<dir> $fpath)\n    autoload -Uz compinit && compinit"); bash/fish or missing completion → no `completion_fpath` check. `zshCompletionLoadable`: true when dir in `FPATH` env (resolved compare); true when `~/.zshrc`/`.zprofile`/`.zshenv` (honoring `ZDOTDIR`) contains the dir literal, `~/rel`, or `$HOME/rel`; false otherwise.
- [ ] **Step 2: Implement** — port `zsh_completion_loadable` (remctl:7696) + `zsh_completion_hint`; `DoctorProbes` gains `completionFpathLoadable: Bool?` (nil = not applicable; the REAL probe computes it only for zsh + exists). `gatherDoctorChecks` appends the check right after `completion`. Setup output (`remctl setup --shell zsh`) prints the fpath hint lines per upstream installation.md.
- [ ] **Step 3: `swift test` green; commit** `feat: doctor reports zsh completion fpath loadability (port upstream aba7cf5)`

### Task 10: Doctor — host-app bundle context + Ghostty FDA guidance (upstream `aba7cf5` part)

**Files:**
- Modify: `Sources/RemindersControl/Commands/DoctorSupport.swift`
- Test: `Tests/RemindersControlTests/DoctorTests.swift`

- [ ] **Step 1: Failing tests** (pure seams) — `appBundleFromPathHint("/Applications/Ghostty.app/Contents/Resources" )` → the `.app` URL when it exists (use a temp dir fixture `Foo.app`); `bundleContextFromEnvironment` prefers `__CFBundleIdentifier` (injected mdfind-resolver closure) then `GHOSTTY_RESOURCES_DIR`/`GHOSTTY_BIN_DIR` path hints; context dict gains `host_app_path`, `host_bundle_id`, `host_app_source` keys; ancestry Ghostty.app entry is SKIPPED when bundle context resolved a different app.
- [ ] **Step 2: Implement** — port `app_bundle_from_path_hint` (regex `(/.*?\.app)(?:/|\s|$)`, exists + `.app` check), `find_app_bundle_by_identifier` (`mdfind "kMDItemCFBundleIdentifier == '<id>'"`, 5s timeout, id sanity regex `^[A-Za-z0-9_.-]+$`; injectable closure for tests), `bundle_context_from_environment` (sources: `__CFBundleIdentifier` → mdfind; else GHOSTTY env path hints). Update `doctorExecutionContext`: seed host_app from bundle context; in the ancestry loop skip `Ghostty.app` when it contradicts the bundle context; fall back to `app_bundle_from_path_hint(proc.command)` (`source: "process_command"`); set `effective_context` from the bundle context app when it wins. Update `DoctorRuntime.buildResult` `contextOrder` += `host_app_path`, `host_bundle_id`, `host_app_source` (after `host_app`). Update `fullDiskAccessTargets`: prefer `host_app_path` over `findAppBundle(host_app)`; skip the terminal entry when terminal==Ghostty.app but the resolved host app differs.
- [ ] **Step 3: `swift test` green; commit** `feat: doctor resolves embedder bundle context, fixes Ghostty FDA guidance (port upstream aba7cf5)`

### Task 11: ReminderKit transient-error remindd hint (upstream `aba7cf5`, adapted)

**Files:**
- Modify: `Sources/RemindersControl/Writes/ReminderKitWriter.swift`
- Test: `Tests/RemindersControlTests/ReminderKitWriterTests.swift`

- [ ] **Step 1: Failing test** — `ReminderKitWriter.enrichTransientMessage("Couldn't communicate with a helper application.", remindd: false)` → appends " Reminders daemon (remindd) is not running; open Reminders.app, then retry."; `remindd: true` / non-transient → unchanged.
- [ ] **Step 2: Implement** — pure `static func enrichTransientMessage(_ message: String?, remindd: Bool?) -> String?` + a `remindd()` probe (`pgrep -x remindd`, 5s timeout, nil on failure — port `remindd_running`). Call it where ReminderKitWriter surfaces an error-status `PrivateResult` message. (Upstream's other private-helper error fixes — missing-helper / no-JSON payload — are N/A: RKPDispatch is in-process and always returns a dict.)
- [ ] **Step 3: `swift test` green; commit** `feat: hint at stopped remindd on transient ReminderKit errors (port upstream aba7cf5)`

### Task 12: Docs + version 0.2.0

**Files:**
- Modify: `README.md`, `SKILL.md`, `docs/commands.md`, `docs/architecture.md`, `docs/installation.md`, `docs/private-metadata.md`
- Modify: version constant (grep `remctlVersion`)

- [ ] **Step 1: Docs** — port the prose from upstream's doc diffs, adapted to our in-process architecture (no "requires remctl-bridge" caveats): all-day due-input semantics; `done --date`; `sharees` + `--assign`/`--unassign` (+ guardrails, "agents must target a shared list"); `--via-eventkit` section incl. the JSON wrapper example and the agents-must-not-default warning; zsh fpath snippet in installation.md; Ghostty embedder note.
- [ ] **Step 2: Bump version** to `0.2.0` (new features, no breaking CLI changes).
- [ ] **Step 3: Full `swift test` + `swift build -c release`; commit** `docs: document 0.2.0 ported features; bump version`

---

## Self-review notes

- **Spec coverage:** 6755b8e→T1, ee8a120→T2, aba7cf5→T3/T4/T9/T10/T11 (+ckid fix inside T6), 683c362→T5/T6/T7, 03a2920→T6 step 3, 391b1c9→T8, releases→T12 version bump. Upstream items intentionally NOT ported: AppleScript fallback paths (no AppleScript in fork), `private_call` subprocess error payloads (in-process), bridge-required errors (in-process), `as_date_assign` (AppleScript only).
- **Type consistency:** `ReminderWrite.allDay: Bool?` (T1) is what T2 and T8's writer read; `complete(id:completionDate:)` (T3) is the only protocol-breaking change — update MockWriter once.
- **Order:** T1→T2 dependency (dueSpecIsAllDay); T5→T6→T7 dependency (queries → writes → display). T3/T4/T8/T9/T10/T11 are independent.
