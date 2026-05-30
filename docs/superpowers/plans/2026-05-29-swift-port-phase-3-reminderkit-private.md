# Phase 3 — ReminderKit Private-Metadata Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold the private ReminderKit write surface in-process (the legacy out-of-process `remctl-private.m` ObjC helper), un-stubbing the 11 deferred commands (flag, unflag, list-edit, list-pin, list-unpin, smart-list-create/edit/delete, template-create/apply/delete) and every `phase3()`-gated private flag on add/edit/list-create — reaching full functional + JSON parity with the Python `remctl`.

**Architecture:** Mirror the Phase-2 EventKit seam one-for-one with a SEPARATE, parallel `PrivateWriter` protocol (NOT an extension of `RemindersWriter`). A production `ReminderKitWriter` wraps a fleshed-out in-process ObjC `ReminderKitPrivate` target exposing a single `RKPDispatch(NSDictionary*) -> NSDictionary*` entrypoint that preserves the exact `{status, action, ...}` / `{status:"error", message}` JSON-shaped envelope the Python subprocess produced. CI drives every command core against a `MockPrivateWriter`; `ReminderKitWriter` is CI-excluded (needs a real store + Reminders TCC grant) and verified only by a manual smoke checklist, exactly as Phase 2's `EventKitWriter`.

**Tech Stack:** Swift 6 / SwiftPM, Swift Argument Parser, GRDB (reads), the private `ReminderKit.framework` via the `ReminderKitPrivate` ObjC target (`-F /System/Library/PrivateFrameworks -framework ReminderKit`, already wired), Swift Testing.

**Sources of truth (read these per task):**
- Python CLI: `./remctl` (line refs throughout).
- Legacy ObjC helper to port verbatim: `./remctl-private.m` (1430 lines; the 22-action dispatcher + ~32 `REM*` forward-declared interfaces).
- Behavioral contract: `docs/superpowers/specs/2026-05-28-reminders-cli-contract.md` (§flag/§unflag/§list-edit/§list-pin/§list-unpin/§smart-list-*/§template-*).
- Recon findings (consolidated payloads + risks): `docs/superpowers/specs/2026-05-29-phase3-recon-findings.md`.

**LOCKED decisions (do not relitigate):**
1. **In-process** ReminderKit (no external subprocess). The JSON IPC envelope is preserved as the in-process ObjC contract.
2. **`--private` flag stays REMOVED** project-wide (Phase-2 direction). Private capability is **unconditional/default-on**: every private-only flag implies the private path. The two pinned gate strings (`private metadata writes require --private.` / `remctl-private is unavailable...`) become **unreachable** — do NOT emit them; any contract test asserting them must be rewritten. **Hybrid imply-rule** for the `add --flag/--url/--tags` public-vs-private split: with no private-only signal, `add --flag` → EventKit lossy proxy (Phase 2 behavior), `add --url` → notes-append (Phase 2), `add --tags` → inline `#hashtag` title-append (public); the private path is taken when the value's destination is the private layer (see P12). `edit --tags` is private-only in Python — route it to the private layer unconditionally (it no longer refuses).
3. **Verification = mock-in-CI + manual smoke checklist + ported live matrix.** `ReminderKitWriter` and the ObjC dispatcher are NOT CI-covered.
4. **Distribution = source-build Homebrew.** No notarization/hardened-runtime in the formula (private-framework linkage is fine for a local `swift build`).

**KNOWN RISK (the gating unknown):** an entitlement-free in-process `saveSynchronouslyWithError:` is verified only for *instantiation*, not *save*. The final task ships a manual smoke; the user must run it to confirm writes materialize. Until then, ReminderKitWriter is "built + mock-verified, live-unverified."

**Cross-cutting parity rules:**
- Reuse `WriteDispatch.resolveReminderForWrite(store:id:op:)` verbatim for reminder pk→ckid + the NULL-ckid "no stable identifier" refusal.
- `WriteFormatting.pyRepr` already exists for `{name!r}` repr-style quoting.
- Object-ID URL scheme: `x-apple-reminderkit://REMCD{Reminder|ListSection|List|SmartList|Template}/<ckIdentifier>`.
- The PrivateWriter returns a structured `PrivateResult` (status + echoed fields) even on logical failure where the caller branches on status; only true faults throw.
- `IDEMPOTENT_PRIVATE_ACTIONS = {assign_section, set_flagged, set_urgent, set_early_reminder}` → 3 retries on a transient classification in the writer.

---

## File Structure

**New (Sources):**
- `Sources/ReminderKitPrivate/ReminderKitPrivate.m` + `include/ReminderKitPrivate.h` — grow from `RKPProbe()` to the full 22-action dispatcher `RKPDispatch`.
- `Sources/RemindersControl/Writes/PrivateWriter.swift` — protocol + `PrivateResult` + value types (`SubtaskSpec`, `EarlyReminderWrite`, `PrivateLocation`, `ListAppearance`).
- `Sources/RemindersControl/Writes/ReminderKitWriter.swift` — production `PrivateWriter` over `RKPDispatch` (CI-excluded).
- `Sources/RemindersControl/Commands/Support/PrivateWriterFactory.swift`.
- `Sources/RemindersControl/Writes/PrivateAppearance.swift` — `list_private_appearance_payload` + color/grocery/symbol normalizers + validation.
- `Sources/RemindersControl/Store/Queries+ListResolve.swift` — 4-tier list/smart-list resolver + `normalizeListLookupName` (NFKC) + `q_list_ckid`/`q_smart_list_ckid` + custom-smart-list queries.
- `Sources/RemindersControl/Writes/PrivateParsing.swift` — `parseEarlyReminder`, `splitCSV`, `parseSubtaskSpecs`, `normalizeSectionId`, `normalizeImagePaths`, URL guard.
- `Sources/RemindersControl/Writes/PrivateChanges.swift` — the per-reminder fan-out (`apply_private_changes` analog).
- `Sources/RemindersControl/SmartLists/FilterEncode.swift` — the smart-list filter ENCODE pipeline.
- `Sources/RemindersControl/Serialization/JSONValue.swift` — add a space-free compact mode (modify).

**New (Tests):**
- `tests/RemindersControlTests/Support/MockPrivateWriter.swift`.
- Per-command/per-module test files mirroring Phase-2 naming.

**Modified (Commands):**
- `Sources/RemindersControl/Commands/WriteCommands.swift` — FlagCmd/Unflag; un-stub Add/Edit private flags.
- `Sources/RemindersControl/Commands/ListCommands.swift` — ListEdit/ListPin/ListUnpin; un-stub ListCreate appearance flags.
- `Sources/RemindersControl/Commands/SmartListCommands.swift` — SmartListCreate/Edit/Delete.
- `Sources/RemindersControl/Commands/TemplateCommands.swift` — TemplateCreate/Apply/Delete.
- `Package.swift` — link AppKit on ReminderKitPrivate if needed (it links Foundation/AppKit/ReminderKit in the Python build).

---

## FOUNDATION

### Task P1: ObjC `ReminderKitPrivate` dispatcher (`RKPDispatch`)

**Files:**
- Modify: `Sources/ReminderKitPrivate/ReminderKitPrivate.m`, `Sources/ReminderKitPrivate/include/ReminderKitPrivate.h`
- Reference (port verbatim): `./remctl-private.m` (the ~32 `REM*` forward `@interface` decls + the 22-action handlers + `output()`/`fail()` helpers)
- Modify if needed: `Package.swift` (add `-framework Foundation -framework AppKit` to the ReminderKitPrivate linker flags if the ported code uses AppKit; the Python build uses `-framework Foundation -framework AppKit -framework ReminderKit`)

**What:** Port `remctl-private.m`'s logic into the in-process target. Keep `RKPProbe()`. Add ONE Swift-callable entrypoint:
```objc
// include/ReminderKitPrivate.h
#import <Foundation/Foundation.h>
const char *RKPProbe(void);
/// Dispatch one private action. `request` mirrors the legacy stdin JSON dict
/// (must contain "action"). Returns the response dict: success {"status":...,"action":...,...}
/// or {"status":"error","message":...}. Never throws / never calls exit().
NSDictionary *RKPDispatch(NSDictionary *request);
```
- Port the `REM*` `@interface` forward declarations verbatim from `remctl-private.m` (no public headers exist; selector correctness is runtime-only).
- Port the per-action handlers for ALL 22 actions (the allow-list at `remctl-private.m:655-678`): `add_private_metadata, add_url_attachments, add_tags, add_subtasks, assign_section, add_section_and_assign, add_attachments, set_flagged, set_urgent, set_early_reminder, add_location_alarm, create_list, set_list_appearance, set_list_pinned, set_smart_list_pinned, categorize_grocery_items, create_smart_list, update_smart_list, delete_smart_list, create_template, apply_template, delete_template`.
- CRITICAL CHANGES vs the legacy `main()`: it read stdin/wrote stdout/called `exit(1)`. Instead, `RKPDispatch` takes the request dict and RETURNS the response dict. Replace `fail(msg)` (which did `output({status:error,message}); exit(1)`) with `return @{@"status":@"error", @"message":msg}`. Replace `output(dict)` with `return dict`. Unknown action → `{"status":"error","message":@"Unknown action"}`.
- Wrap the whole dispatch body in `@try/@catch (NSException *e) { return @{@"status":@"error",@"message":e.reason ?: @"private API fault"}; }` so a private-API fault (e.g. unrecognized selector) becomes a clean error dict, never a crash.
- Preserve the security guards from the helper: URL SSRF/public-address check (`looksLikeWebURL` + getaddrinfo) and the image-`files[]`-rejected rule. The 1MiB stdin / empty-stdin caps are IPC artifacts and can be dropped (in-process there is no stdin).
- Keep the `REMColor` cyan→`#5AC8FA` remap, hashtag type int `1`, proximity `1=enter/2=leave`, colorSpace `2`, smart-list type `com.apple.reminders.smartlist.custom`, and `minimumSupportedVersion/effectiveMinimumSupportedVersion = @(20220430)` exactly as in the legacy source.

**Steps:**
- [ ] Read `remctl-private.m` in full. Port the forward decls + helpers + 22 handlers into `ReminderKitPrivate.m`, refactoring `main()`'s stdin/stdout/exit into the `RKPDispatch(NSDictionary*)->NSDictionary*` shape with the `@try/@catch` wrapper.
- [ ] Add `RKPDispatch` to the header. Update `Package.swift` linker flags if AppKit is required.
- [ ] `swift build` (the target compiles; selector correctness is runtime-only and CANNOT be unit-tested in CI).
- [ ] Add a CI-safe test in `tests/RemindersControlTests/PrivateLinkTests.swift`: assert `RKPProbe()=="reminderkit-ok"` still passes, and that `RKPDispatch(@{})` (no action) returns a dict with `status=="error"` (exercises the entrypoint + error envelope WITHOUT performing a save). Do NOT call any action that saves.
- [ ] Commit.

**Note for the implementer:** This is the riskiest, least-verifiable task. Port faithfully; do not "improve" selectors. Any action that performs a `saveSynchronouslyWithError:` is live-unverifiable in CI — correctness is confirmed only by the P18 manual smoke. Report any selector you are unsure about.

---

### Task P2: `PrivateWriter` protocol + value types + `MockPrivateWriter`

**Files:**
- Create: `Sources/RemindersControl/Writes/PrivateWriter.swift`
- Create: `tests/RemindersControlTests/Support/MockPrivateWriter.swift`

**What:** The mockable boundary, mirroring `RemindersWriter`/`MockWriter`. (See the full recommended protocol in the recon findings, "Current Swift Phase-3 STUBS + the writer SEAM" §Schemas.)

```swift
// PrivateWriter.swift
public struct PrivateResult: Sendable, Equatable {
    public var status: String           // "updated" | "created" | "deleted" | "error"
    public var fields: [String: JSONValue]   // echoed action-specific keys (id, url, name, subtasks, ...)
    public var message: String?         // present on status=="error"
    public init(status: String, fields: [String: JSONValue] = [:], message: String? = nil) { ... }
}
public struct SubtaskSpec: Sendable, Equatable { /* title (req) + notes,due,priority,alarm,recurrence,earlyReminder,urls,tags,images,flagged,urgent,latitude,longitude,locationTitle,radius,proximity — match parse_subtask_specs */ }
public enum EarlyReminderWrite: Sendable, Equatable { case clear(existingIdentifiers: [String]); case set(unit: Int, count: Int, existingIdentifiers: [String]) }
public struct PrivateLocation: Sendable, Equatable { public var title: String; public var latitude: Double; public var longitude: Double; public var radius: Double; public var proximity: Int; public var address: String? }
public struct ListAppearance: Sendable, Equatable { public var name: String?; public var color: String?; public var symbol: String?; public var emoji: String?; public var shouldCategorizeGroceryItems: Bool?; public var groceryLocaleID: String?; public var isEmpty: Bool { ... } }

public protocol PrivateWriter {
    func setFlagged(id: String, flagged: Bool) async throws -> PrivateResult
    func addPrivateMetadata(id: String, urls: [String], tags: [String]) async throws -> PrivateResult
    func assignSection(id: String, sectionId: String) async throws -> PrivateResult
    func addSectionAndAssign(id: String, name: String) async throws -> PrivateResult
    func addSubtasks(id: String, subtasks: [SubtaskSpec]) async throws -> PrivateResult
    func addAttachments(id: String, images: [String]) async throws -> PrivateResult
    func setUrgent(id: String, urgent: Bool) async throws -> PrivateResult
    func setEarlyReminder(id: String, spec: EarlyReminderWrite) async throws -> PrivateResult
    func addLocationAlarm(id: String, location: PrivateLocation) async throws -> PrivateResult
    func categorizeGroceryItems(listId: String, reminderIds: [String]) async throws -> PrivateResult
    func setListAppearance(listId: String, appearance: ListAppearance) async throws -> PrivateResult
    func setListPinned(listId: String, pinned: Bool) async throws -> PrivateResult
    func setSmartListPinned(smartListId: String, pinned: Bool) async throws -> PrivateResult
    func createList(name: String, appearance: ListAppearance) async throws -> PrivateResult
    func createSmartList(name: String, filterData: Data, appearance: ListAppearance) async throws -> PrivateResult
    func updateSmartList(smartListId: String, filterData: Data?, appearance: ListAppearance) async throws -> PrivateResult
    func deleteSmartList(smartListId: String) async throws -> PrivateResult
    func createTemplate(name: String, sourceListId: String, includeCompleted: Bool) async throws -> PrivateResult
    func applyTemplate(templateId: String) async throws -> PrivateResult
    func deleteTemplate(templateId: String) async throws -> PrivateResult
}
```
- `MockPrivateWriter: PrivateWriter, @unchecked Sendable` with a `Call` enum (one case per method capturing args), a `calls: [Call]` recorder, settable canned `result`/per-action results, and `throwError`. Mirror `MockWriter` exactly.

**Steps:**
- [ ] Write the protocol + value types. `swift build`.
- [ ] Write `MockPrivateWriter` + a tiny test asserting it records a `Call` and returns a canned `PrivateResult`.
- [ ] Commit.

---

### Task P3: `ReminderKitWriter` (production, CI-excluded)

**Files:**
- Create: `Sources/RemindersControl/Writes/ReminderKitWriter.swift`

**What:** `public final class ReminderKitWriter: PrivateWriter`. Each method marshals its typed args into the request `[String: Any]` dict (the exact key set from the recon action table / `remctl-private.m`), calls `RKPDispatch`, and unmarshals the returned `NSDictionary` into a `PrivateResult`. Encapsulate:
- A `dispatch(_ request: [String:Any]) -> PrivateResult` helper that calls `RKPDispatch`, reads `status`/`message`, and packs the rest into `PrivateResult.fields` as `JSONValue`.
- **Transient-retry** for `IDEMPOTENT_PRIVATE_ACTIONS` (`assign_section/set_flagged/set_urgent/set_early_reminder`): up to 3 attempts when the result is `status=="error"` AND the message classifies as transient. Port `private_helper_error_is_transient` (`remctl:2104`) — message contains `communicate with a helper application` (curly apostrophe U+2019) — BUT normalize: also treat a small set of known ReminderKit save-retry errors as transient (decouple from the fragile English substring per the recon risk; document the predicate). Sleep ~0.5s between attempts (`Task.sleep`).
- Mark CI-excluded (a doc comment + no unit tests of the live path, exactly like `EventKitWriter`). No `@testable` save calls.

**Steps:**
- [ ] Implement all 20 methods + `dispatch` + the transient-retry wrapper. `swift build`.
- [ ] NO live test (CI cannot grant TCC). Add only a comment documenting manual-verification in P18. Optionally a pure unit test of the transient-classification predicate if it's factored out as a pure function.
- [ ] Commit.

---

### Task P4: `PrivateWriterFactory` + dual-writer dispatch

**Files:**
- Create: `Sources/RemindersControl/Commands/Support/PrivateWriterFactory.swift`
- Modify: `Sources/RemindersControl/Writes/WriteDispatch.swift`

**What:**
```swift
public enum PrivateWriterFactory { nonisolated(unsafe) public static var make: () -> PrivateWriter = { ReminderKitWriter() } }
```
- Add a dual-writer dispatch to `WriteDispatch` so commands that need BOTH writers (add/edit with subtasks + location) get them:
```swift
static func runShellPrivate(_ body: (RemindersStore, PrivateWriter) async throws -> WriteOutcome) async -> WriteOutcome  // opens store + PrivateWriterFactory.make()
static func runShellBoth(_ body: (RemindersStore, RemindersWriter, PrivateWriter) async throws -> WriteOutcome) async -> WriteOutcome
```
Both wrap `perform { }` like the existing `runShell`.

**Steps:**
- [ ] Add the factory + the two runShell variants. `swift build`.
- [ ] Unit-test `runShellPrivate`/`runShellBoth` by overriding the factories with mocks (mirror the WriteBoundaryTests factory save/restore pattern) — assert the body receives a mock and the outcome propagates.
- [ ] Commit.

---

## SHARED HELPERS

### Task P5: list/smart-list resolution + ckid queries + appearance payload

**Files:**
- Create: `Sources/RemindersControl/Store/Queries+ListResolve.swift`
- Create: `Sources/RemindersControl/Writes/PrivateAppearance.swift`
- Test: `tests/RemindersControlTests/ListResolveTests.swift`, `PrivateAppearanceTests.swift`

**What (resolution + ckid):** Port the 4-tier resolver and ckid queries (recon §list-edit, `remctl:771/803/891/958/967`):
- `normalizeListLookupName(_:) -> String` — `unicodedata.normalize("NFKC")` + `casefold()`, keep `isalnum` chars, collapse all Unicode category M/P/S/Z + whitespace runs to single spaces, strip. Use Foundation/ICU (`precomposedStringWithCompatibilityMapping` for NFKC; `.lowercased()` is not casefold — use the appropriate case-folding). **This is parity-critical and non-trivial — unit-test against fixtures.**
- `store.resolveListRef(name:)` / `store.resolveSmartListRef(name:)` → 4-tier (exact ZNAME → casefold → NFKC-normalized), each uniqueness-checked; >1 → ambiguous-with-candidates. (`resolveRequiredListTarget` already does exact+lower for lists — extend or add the smart-list twin + the NFKC tier.)
- `store.listCkid(pk:) -> String?` (Z_ENT=3) / `store.smartListCkid(pk:) -> String?` (Z_ENT=4 OR ZSMARTLISTTYPE IS NOT NULL) — return nil on NULL/empty.
- `store.customSmartListExactNameCount(name:) -> Int` and `store.customSmartListMatches(name:) -> [(pk,name,ckid)]` (ZSMARTLISTTYPE='com.apple.reminders.smartlist.custom' AND ZNAME=? ORDER BY Z_PK) for smart-list edit/delete (exact-name-only).

**What (appearance):** Port `list_private_appearance_payload` (`remctl:2716`) → builds `ListAppearance`; + `normalizeListColor` (hex→UPPER, name→lower; `remctl:305`), `normalizeGroceryLocale` (regex `^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})?$`, `-`→`_`, lang.lower()+`_`+REGION.upper(), default `en_US`; `remctl:2682`), `validateListAppearanceArgs` (symbol XOR emoji; symbol in `OFFICIAL_LIST_SYMBOL_NAMES`; color validation; `remctl:2635`) and `validateListGroceryArgs` (groceries XOR standard; standard excludes locale; `remctl:2699`). Grocery key-presence rules: groceries→`shouldCategorizeGroceryItems:true`+`groceryLocaleID`; standard→`shouldCategorizeGroceryItems:false` (no locale); locale-only→`groceryLocaleID` only. Color included only when value present (no `--private` gate now — default-on). `OFFICIAL_LIST_SYMBOL_NAMES` already exists from Phase 1's list-symbols catalog — reuse it.

**Steps (TDD):**
- [ ] Write failing tests for `normalizeListLookupName` (NFKC + category-collapse fixtures, incl. accented/fullwidth/punctuation cases), the 4-tier resolver (exact/casefold/normalized/ambiguous), the ckid queries (Z_ENT discrimination, NULL→nil), and the appearance builder (color hex-upper/name-lower, grocery key-presence variants, symbol/emoji validation + error strings).
- [ ] Implement. Iterate to green. `swift build`.
- [ ] Commit.

---

### Task P6: space-free compact JSON serializer

**Files:**
- Modify: `Sources/RemindersControl/Serialization/JSONValue.swift`
- Test: `tests/RemindersControlTests/JSONValueCompactTests.swift`

**What:** Phase-1 compact mode hard-codes `", "` / `": "` (JSONValue.swift:42,61) — Python `separators=(",",":")` has NO spaces. Add a space-free mode used ONLY for smart-list filter bytes (not the existing data-read/write JSON which must keep its spacing for parity). Recommended: add a parameter, e.g. `func serialized(indent: Int? = nil, ensureAscii: Bool = ..., spaceSeparators: Bool = true)` where `spaceSeparators: false` emits `","`/`":"`. Default `true` so NO existing caller changes behavior. Keep insertion-order preservation (`.object` is ordered).

**Steps (TDD):**
- [ ] Failing test: `JSONValue.object([("a",.int(1)),("b",.string("x"))]).serialized(indent: nil, spaceSeparators: false) == "{\"a\":1,\"b\":\"x\"}"` and confirm `spaceSeparators: true` (default) is unchanged (`{"a": 1, "b": "x"}`). Round-trip test: a sample filter payload → space-free bytes → `decodeSmartListFilterBlob` → expected summary (proves byte-compatibility with the Phase-1 decoder).
- [ ] Implement. Verify NO regression in existing serializer tests. `swift build`.
- [ ] Commit.

---

## BAND A — flag/unflag + pin/unpin

### Task P7: flag / unflag

**Files:**
- Modify: `Sources/RemindersControl/Commands/WriteCommands.swift` (replace `FlagCmd`/`Unflag` NotImplemented stubs at ~:615/:621)
- Test: `tests/RemindersControlTests/FlagTests.swift`
- Reference: `cmd_flag` (`remctl:5957`), `cmd_unflag` (`remctl:5993`), contract §flag/§unflag, recon §flag/unflag.

**What:** CLI: `flag <id:Int> [--json]` / `unflag <id:Int> [--json]`. Testable cores `static func perform(id:json:store:writer:private:) async throws -> WriteOutcome` taking BOTH a `RemindersWriter` (for the lossy fallback) and a `PrivateWriter`.
- Resolve pk→ckid via `resolveReminderForWrite(store:id:op:"flag it"/"unflag it")` (handles not-found `#<id> not found` + NULL-ckid `The reminder has no stable identifier. Refusing unsafe title-based fallback for #<id> ('<safeDisplay(title or (untitled))>') while trying to flag it.`).
- PRIMARY: `private.setFlagged(id: ckid, flagged: true/false)`; success = `status=="updated"`.
- FALLBACK (lossy): if the private call fails, use the EventKit priority-1 proxy via the `RemindersWriter` (flag: priority 0→1; unflag: 1→0) — same as `EventKitWriter.swift:164-168`.
- If BOTH fail → `Error: Identifier-based writes failed. Refusing unsafe title-based fallback for #<id> ('<title>') while trying to flag it.` exit 1.
- Output: human `Flagged: <safeDisplay(title)>` / `Unflagged: <safeDisplay(title)>`; JSON COMPACT `{"status":"flagged","id":<numeric Z_PK>,"title":<raw ZTITLE>}` / `{"status":"unflagged",...}`. NO `--private` gate.
- Share ONE implementation parameterized by `flagged: Bool`.

**Steps (TDD):** failing tests (flag/unflag happy via MockPrivateWriter `.setFlagged(ckid,true/false)`; JSON compact + numeric id; human; not-found; NULL-ckid refusal; private-fails→EventKit-proxy-fallback via MockWriter; both-fail refusal) → implement → green → commit.

---

### Task P8: list-pin / list-unpin

**Files:**
- Modify: `Sources/RemindersControl/Commands/ListCommands.swift` (replace `ListPin`/`ListUnpin` at ~:148/:154)
- Test: `tests/RemindersControlTests/ListPinTests.swift`
- Reference: `_cmd_list_pin_state` (`remctl:6162`), contract §list-pin/§list-unpin, recon §list-edit-pin.

**What:** CLI: `list-pin [name] [--list-id Int] [--smart-list-id Int] [--json]` / `list-unpin ...`. Share ONE core with `pinned: Bool`.
- Reject both `--list-id`+`--smart-list-id` → `Error: pass either --list-id or --smart-list-id, not both.`. Require name|list-id|smart-list-id → else `Error: pass a list/smart-list name, --list-id, or --smart-list-id.`.
- `--smart-list-id` → resolve smart list → `private.setSmartListPinned(smartListId: ckid, pinned:)`. `--list-id` → list → `private.setListPinned(listId: ckid, pinned:)`. `name` → DUAL-resolve (both `resolveListRef` + `resolveSmartListRef`); if EITHER is ambiguous, print that kind's resolution error and exit FIRST; if both match → `Error: <name!r> matches both a list and a smart list. Use --list-id or --smart-list-id.`; neither → `Error: list or smart list not found: <name>`; exactly one → use it.
- No-ckid → `Error: target list has no stable CloudKit identifier.` / `...smart list...`. Success requires `status=="updated"` else `Error: <message>`.
- Output: human `{Pinned|Unpinned} {label}: <safeDisplay(title)>` (label `list` or `smart list` SPACE); JSON `{"status":<"pinned"|"unpinned">,"kind":<"list"|"smart-list">,"id":<Z_PK>,"name":<title>,"private":<result fields>}` (kind HYPHEN).

**Steps (TDD):** failing tests (pin list by name/id; pin smart-list by name/smart-list-id; both-ids error; no-target error; dual-match-both error; ambiguous-fires-first; no-ckid refusal; kind hyphen vs label space; pinned/unpinned status) via MockPrivateWriter → implement → green → commit.

---

## BAND C — list appearance

### Task P9: list-edit

**Files:**
- Modify: `Sources/RemindersControl/Commands/ListCommands.swift` (replace `ListEdit` at ~:142)
- Test: `tests/RemindersControlTests/ListEditTests.swift`
- Reference: `cmd_list_edit` (`remctl:6137`), contract §list-edit, recon §list-edit-pin.

**What:** CLI: `list-edit [name] [--list-id Int] [--new-name] [--color] [--symbol] [--emoji] [--groceries] [--standard] [--grocery-locale] [--json]`. (NO `--private`.)
- Order: validate appearance args (P5) → no-change guard (`Error: pass at least one of --new-name, --color, --symbol, --emoji, --groceries, --standard, or --grocery-locale.`) → resolve list target (`resolveRequiredListTarget`; both-target/no-target/not-found/ambiguous errors) → build `ListAppearance` (P5) → `private.setListAppearance(listId: ckid, appearance:)` (no-ckid → `Error: target list has no stable CloudKit identifier.`; success `status=="updated"` else `Error: <message>`).
- `output_name` = `--new-name` OR resolved current title (NOT the input name). Output: human `Updated list: <safeDisplay(output_name)>`; JSON `{"status":"updated","id":<Z_PK>,"name":<output_name>,"private":<result fields>}`.

**Steps (TDD):** failing tests (rename; color hex-upper/name-lower; symbol/emoji; groceries/standard/locale key-presence; no-change error; not-both/no-target; output_name = new-name-or-resolved; no-ckid refusal) via MockPrivateWriter → implement → green → commit.

---

### Task P10: list-create appearance flags (un-stub)

**Files:**
- Modify: `Sources/RemindersControl/Commands/ListCommands.swift` (`ListCreate.perform` — remove the `phase3()` guards at ~:100-105)
- Test: extend `tests/RemindersControlTests/ListWriteTests.swift`
- Reference: `cmd_list_create` private path (`remctl:6085-6116`), recon §private-flags.

**What:** Un-stub `--symbol/--emoji/--groceries/--grocery-locale`. Decide path by whether a private appearance payload is needed (`list_private_appearance_payload(include_public_color_names=False)` non-empty → private; i.e. symbol/emoji/hex-color/grocery present). 
- PRIVATE path: build `ListAppearance` (with `include_public_color_names=True` so named colors are sent) → `private.createList(name:appearance:)`; success `status=="created"`; on failure wrap `Failed to create list '<name>': <message>` (reuse the Phase-2 `WriteFormatting` wrapper). Human `Created list: <name>` then if any private metadata `Applied private metadata: <details>` (color=/symbol=/emoji=/groceries locale=...); JSON `{"status":"created","name":<name>,"private":<result>}` (ensure_ascii=False).
- PUBLIC path (no private appearance needed, only `--color` public name or nothing): KEEP the existing Phase-2 EventKit `createList` behavior unchanged.
- NOTE the public-create-with-only-`--color` stays EventKit; symbol/emoji/grocery/hex-color route private.

**Steps (TDD):** failing tests (symbol→private createList; groceries+locale→private; `--color red` alone stays EventKit public; `Applied private metadata:` line; JSON private envelope) → implement → green → commit.

---

## BAND B — reminder private metadata (add/edit)

### Task P11: private-metadata parsers + section resolution

**Files:**
- Create: `Sources/RemindersControl/Writes/PrivateParsing.swift`
- Test: `tests/RemindersControlTests/PrivateParsingTests.swift`
- Reference: `parse_early_reminder` (`remctl:4093`), `split_csv` (`remctl:2157`), `parse_subtask_specs` (`remctl:2217`), `resolve_section_ckid` (`remctl:2803`), `normalize_section_id`/`normalize_image_paths`, the URL guard.

**What (pure parsers + a store query):**
- `parseEarlyReminder(_:) -> EarlyReminderWrite?` — clear-set `{clear,none,off,never,0,0m,0min}` → `.clear`; else unit code 0-4 (`EARLY_REMINDER_UNIT_CODES`: m/min→0, h/hr→1, d/day→2, w/wk→3, mo/month→4) + `count: -amount` → `.set(unit:count:)`. (Note: requires a due date unless clearing — that guard lives in the add/edit core.)
- `splitCSV(_:) -> [String]` — split `,`, strip, `lstrip('#')`, drop empties.
- `parseSubtaskSpecs(_:) -> [SubtaskSpec]` — bare title OR JSON object with the documented key set (recon §private-flags); `address` UNSUPPORTED → throw.
- `normalizeSectionId(_:)`, `normalizeImagePaths(_:)` (expanduser→absolute), the URL web-guard (port `looksLikeWebURL`).
- `store.resolveSectionCkid(listPk:section:sectionId:) -> String` — DB lookup by `ZLIST + lower(ZCKIDENTIFIER)` for id, or `q_sections` by display name, with duplicate-name disambiguation via member counts.

**Steps (TDD):** failing tests for each parser (early-reminder unit map + clear set; csv strip-#; subtask bare-vs-JSON + address-rejected; section-id last-segment; image expanduser) + the section resolver against a fixture → implement → green → commit.

---

### Task P12: add/edit simple private metadata (flag/tags/url/urgent/early-reminder/section)

**Files:**
- Create: `Sources/RemindersControl/Writes/PrivateChanges.swift` (the `apply_private_changes` analog — the ordered fan-out)
- Modify: `Sources/RemindersControl/Commands/WriteCommands.swift` (Add/Edit cores — wire `private:` writer, replace the relevant `phase3()` guards)
- Test: `tests/RemindersControlTests/PrivateChangesTests.swift`, extend `AddTests`/`EditTests`
- Reference: `apply_private_changes` (`remctl:3003`), cmd_add public split (`remctl:5188-5203`), cmd_edit (`remctl:5417/5525`), recon §private-flags.

**What:** Build `PrivateChanges.apply(reminderCkid:fields:private:store:) -> [PrivateResult]` emitting, IN ORDER (subset for this task; subtasks/image/grocery/location in P13/P14): `add_private_metadata` (url+tags), `assign_section` (section/section_id, pre-resolved via P11), `add_section_and_assign` (new_section), `set_flagged`, `set_urgent`, `set_early_reminder`. Collect result dicts.
- Wire into Add/Edit cores via `runShellBoth` (both writers). The reminder ckid comes from the EventKit `create`/the resolved edit target.
- **Public/private split (LOCKED imply-rule):** `add --flag` with no other private signal → EventKit lossy proxy (keep Phase-2 path); `add --url` → notes-append (Phase 2); `add --tags` → inline `#hashtag` title-append (PUBLIC — port `remctl:5188-5193`). When ANY private-only flag is present (or the value belongs to the private layer), route `--flag`→`set_flagged`, `--url`+`--tags`→`add_private_metadata`. `edit --tags` → private `add_private_metadata` unconditionally (no longer refuses); `edit --flagged`→`set_flagged`.
- `--early-reminder` requires a due date unless clearing (`early_reminder_requires_due_date`, `remctl:2505`) → else exit 1 with the source message; pass `existingIdentifiers` from a store query (`early_reminder_identifiers_for_reminder`, `remctl:2522`).
- Output: add/edit attach `"private":[<result dicts>]` to JSON and print `applied N updates` (or the existing success line) in human mode — match `cmd_add`/`cmd_edit` output exactly.

**Steps (TDD):** failing tests (PrivateChanges order; add --flag public vs private; add --tags title-append vs private; edit --flagged set_flagged; --urgent; --early-reminder set/clear + due-required guard; section/new-section; JSON `private` array) via Mock writers → implement → green → commit.

---

### Task P13: add/edit subtasks + attachments (dual-writer fan-out)

**Files:**
- Modify: `Sources/RemindersControl/Writes/PrivateChanges.swift`, `WriteCommands.swift`
- Test: extend `PrivateChangesTests`, `AddTests`/`EditTests`
- Reference: `apply_subtask_private_metadata` (`remctl:2398`), `bridge_update_subtask` (`remctl:2371`), `add_subtasks` + `add_attachments`, recon §private-flags subtask pipeline.

**What:** `--subtask` (repeatable) → `private.addSubtasks(id:subtasks:)` (parsed via P11) → for EACH returned child id: `apply_subtask_private_metadata` (child `add_private_metadata`/`add_attachments`/`set_flagged`/`set_urgent`/`set_early_reminder`/`add_location_alarm` via PrivateWriter) AND `bridge_update_subtask` (child public notes/due/priority/alarm/recurrence via the RemindersWriter/EventKit). This is the dual-writer coupling — the child ckid from `addSubtasks` threads into BOTH writers. `--image` → `private.addAttachments(id:images:)` (files[] empty; normalize paths via P11).

**Steps (TDD):** failing tests (single subtask bare; subtask with notes/due→both writers invoked on the child id; subtask with private child fields; --image attachments; address-in-subtask rejected) via Mock writers asserting the call sequence on both mocks → implement → green → commit.

---

### Task P14: grocery categorization + private-changes orchestration finalize

**Files:**
- Modify: `Sources/RemindersControl/Writes/PrivateChanges.swift`, `WriteCommands.swift`
- Test: extend `PrivateChangesTests`
- Reference: `apply_private_grocery_categorization` + `categorize_grocery_items` + `wait_for_grocery_section` (`remctl:2952`+), recon risks.

**What:** `--grocery` → after the reminder is in a grocery list, `private.categorizeGroceryItems(listId:reminderIds:)`. Port the `wait_for_grocery_section` polling (up to 24×0.25s reading the section table) OR consciously simplify (the recon flags it as timing-sensitive/not-mockable — if simplified, `log`/document the divergence). The polling reads SQLite, so inject the store; the categorize call goes through the PrivateWriter. Finalize the Add/Edit `private:[...]` JSON array + `applied N updates` human output across ALL private actions (this task closes out the orchestration). Confirm the FULL `phase3()` guard blocks in Add (`:94-105`) and Edit (`:297-311`) are removed and every flag is wired.

**Steps (TDD):** failing tests (grocery categorize call; the orchestration emits actions in the documented order; all add/edit private flags no longer throw phase3) → implement → green → commit.

---

## BAND D — smart-lists + templates

### Task P15: smart-list filter ENCODE pipeline (pure, CI-covered)

**Files:**
- Create: `Sources/RemindersControl/SmartLists/FilterEncode.swift`
- Test: `tests/RemindersControlTests/FilterEncodeTests.swift`
- Reference: `remctl_smart_lists.py` (`build_supported_filter_payload`, `_build_*_filter`, `encode_supported_filter_payload`, normalizers), `smart_list_filter_payload_from_args` (`remctl:4479`), `validate_materializing_smart_list_args` (`remctl:4455`), recon §smart-lists.

**What:** Port the BUILD→NORMALIZE→ENCODE pipeline. CLI args → ordered `JSONValue` filter payload (exact key order: `operation`-first-if-present, then flagged, priorities, hashtags, date, time, lists, location; location sub-object order title,latitude,radius,longitude,proximity; relativeRange order direction,magnitude,[includePastDue],units) → `serialized(indent:nil, ensureAscii:false, spaceSeparators:false)` (P6) → UTF-8 → base64 → `Data`. Include: `normalizeMatchOperation`, `normalizePriorities`, `_build_tag_filter` (the DOUBLE-nested `hashtags:{hashtags:{operation,include,exclude}}`, plus `{any:""}`/`{untagged:""}`), `_build_date_filter` (ambiguous-format date normalization to `DD-MM-YYYY`, the try-order matters; `relativeRange` magnitude is a STRING), `_build_time_filter`, `_build_lists_filter` (names/ids→objectUUID via existing resolver; operation-emission rules), `_build_location_filter` (vehicle + location sub-object; proximity synonyms arriving→enter/leaving→leave). The `--filter-json [@path]` escape hatch parses VERBATIM via `OrderedJSON` and re-serializes space-free, but `encode_supported_filter_payload` still re-summarizes and REJECTS unsupported/`all`. Port `validate_materializing_smart_list_args` guards with exact `SmartListFilterError` strings.

**Steps (TDD):** failing tests — for each filter family, build → base64 → `decodeSmartListFilterBlob` round-trips to the expected summary; key-order byte-exactness; the materialization guards' error strings; `--filter-json` verbatim + still-rejected-if-unsupported; date format try-order. (This is the highest-leverage correctness task and is FULLY CI-coverable.) → implement → green → commit.

---

### Task P16: smart-list-create / smart-list-edit / smart-list-delete

**Files:**
- Modify: `Sources/RemindersControl/Commands/SmartListCommands.swift` (replace stubs at ~:58/:64/:70)
- Test: `tests/RemindersControlTests/SmartListWriteTests.swift`
- Reference: `cmd_smart_list_create/edit/delete` (`remctl:4559/4604/4668`), contract §smart-list-*, recon §smart-lists.

**What:** Full CLI surfaces (recon §smart-lists "CLI FLAGS"). (NO `--private`.)
- create: required `name`; dup check via `customSmartListExactNameCount` (`Error: smart list already exists: <name>. Choose a unique test name.`); build+encode filter (P15); appearance (P5); `private.createSmartList(name:filterData:appearance:)`; success `status=="created"` else `Error: Failed to create smart list '<name>': <message>`. Output human `Created smart list: <name>` (+`Filter: <desc>` via Phase-1 summarize); JSON `{"status":"created","name":<name>,"filter":<summary|null>,"private":<result>}`.
- edit: `name`|`--smart-list-id` (exact-name resolution via `customSmartListMatches`; not-found/ambiguous errors); change-detection (`Error: pass at least one smart-list filter or appearance option.`); `filterData` OMITTED when only appearance changed; `private.updateSmartList(...)`; `status=="updated"`. JSON `{"status":"updated","id":<Z_PK>,"objectUUID":<ckid>,"name":<display>,["filter":...],"private":<result>}`.
- delete: interactive `Delete custom smart list '<name>'? [y/N]` unless `--force` (decline → `Aborted.` exit 0, no JSON); `private.deleteSmartList(smartListId: ckid)`; `status=="deleted"`. JSON `{"status":"deleted","id":<Z_PK>,"objectUUID":<ckid>,"name":<display>,"private":<result>}`.
- `smartListId` sent to the writer is ZCKIDENTIFIER (not Z_PK).

**Steps (TDD):** failing tests (create with filter→createSmartList(filterData); dup error; edit appearance-only omits filterData; edit change-detection error; delete confirm/force/abort; exact-name ambiguity; JSON envelopes) via MockPrivateWriter (+ fixture store) → implement → green → commit.

---

### Task P17: template-create / template-apply / template-delete

**Files:**
- Modify: `Sources/RemindersControl/Commands/TemplateCommands.swift` (replace stubs at ~:104/:110/:116)
- Test: `tests/RemindersControlTests/TemplateWriteTests.swift`
- Reference: `cmd_template_create/apply/delete` (`remctl:4297/4346/4392`), contract §template-*, recon §templates.

**What:** (NO `--private`.)
- create: `name` + `--from-list`|`--from-list-id` (mutex `Error: pass either --from-list or --from-list-id, not both.` / required `Error: pass --from-list or --from-list-id.`) + `--include-completed` + `--json`. Order: mutex → required → dup (`templateExactNameCount` → `Error: template already exists: <name>. Use a unique template name.`) → resolve source list (full resolution; objectUUID presence → `Error: source list has no stable CloudKit identifier.`) → `private.createTemplate(name:sourceListId:includeCompleted:)`; `status=="created"` else `Error: Failed to create template '<name>': <message>`. POST-WRITE POLL: up to 12×0.25s `store.templateMatches(name:)` until match AND itemCount≥expected (skip if expected in (None,0)); attach `template_to_dict(include_items=True)`. JSON (indent=2) `{"status":"created","name":<name>,"sourceList":<ref>,"private":<result>[,"expectedItemCount":N][,"template":<dict>]}`.
- apply: `name`|`--template-id` + `--json`. Resolve template (exact-name; `resolveRequiredTemplateTarget` exists). `private.applyTemplate(templateId: ckid)`; `status=="created"`. POST re-read: if `result.id` (new list UUID) → `SELECT ... WHERE Z_ENT=3 AND ZCKIDENTIFIER=?` → attach `list_to_dict`. JSON (indent=2) `{"status":"created","template":<ref>,"private":<result>[,"list":<dict>]}`.
- delete: `name`|`--template-id` + `--force` + `--json`. Interactive `Delete template '<name>'? [y/N]` unless `--force` (decline → `Aborted.` exit 0, no JSON). `private.deleteTemplate(templateId: ckid)`; `status=="deleted"`. JSON COMPACT `{"status":"deleted","template":<ref>,"private":<result>}`.
- listId/templateId to the writer are the OBJECT UUID (ZCKIDENTIFIER), never Z_PK.

**Steps (TDD):** failing tests (create mutex/required/dup/no-ckid; create poll attaches template; apply re-read attaches list; delete confirm/force/abort; compact-vs-indent JSON) via MockPrivateWriter (+ fixture store; mock the poll by seeding the fixture) → implement → green → commit.

---

## FINAL

### Task P18: integration verification + manual smoke + holistic review

**Files:**
- Create: `docs/superpowers/phase-3-manual-reminderkit-smoke.md`
- Possibly modify: contract-test files asserting the now-unreachable `--private` strings (rewrite per LOCKED decision 2)

**What:**
- Full `swift test` green; `swift build -c release`; `remctl --help` still lists 45 commands; CommandTreeTests intact; zero warnings.
- Audit: every `phase3()` guard and `NotImplemented` Phase-3 stub is gone (grep); the ops/list-symbols `NotImplemented` uses (OTHER phases) remain.
- Rewrite/remove any test asserting `private metadata writes require --private.` / `remctl-private is unavailable.` (unreachable now) and document the gating change.
- Write `phase-3-manual-reminderkit-smoke.md`: the per-action live checklist on the user's Mac (the ONLY way to verify selector correctness + that an entitlement-free save materializes). Cover: a throwaway list/smart-list/template create+apply+delete, flag/unflag, list-edit appearance, add-with-private-metadata (tags/section/subtask/urgent/early-reminder/grocery), and the smart-list filter round-trip (create a smart list, confirm Reminders.app renders the filter — the byte-parity proof). Lead with the gating unknown (save-without-entitlements) and the `set_early_reminder` unit-code + `delete_template`-via-`updateTemplate` "verify against live ReminderKit" items.
- Optionally port `scripts/live_private_matrix.py` as the macOS-version-drift regression matrix (manual, dev-machine only).
- Dispatch a holistic Phase-3 code review (cross-cutting: writer-seam consistency, the public/private split correctness, idempotent-retry, filter byte-parity, the dual-writer subtask coupling, no lingering stubs).

**Steps:**
- [ ] Verify build/test/help/grep-clean. Rewrite the unreachable-gate tests. Write the smoke checklist. Run the holistic review; fix findings. Commit. Then `superpowers:finishing-a-development-branch`.

---

## Self-Review (planner checklist)

- **Spec coverage:** all 11 deferred commands (P7/P8/P9/P16/P17 + list-pin/unpin in P8) + every `phase3()` flag on add (P12/P13/P14) / edit (P12/P13/P14) / list-create (P10) are covered; the shared private layer (P1–P6) precedes the commands that use it. ✓
- **Type consistency:** `PrivateResult`/`ListAppearance`/`SubtaskSpec`/`EarlyReminderWrite`/`PrivateLocation` defined once in P2 and used by P3/P5/P7–P17. `RKPDispatch` defined in P1, consumed by P3. The space-free serializer (P6) is consumed by P15. ✓
- **Dependency order:** P1→P2→P3→P4 (seam) → P5/P6 (shared) → P7/P8 (band A) → P9/P10 (band C) → P11→P12→P13→P14 (band B) → P15→P16→P17 (band D) → P18. ✓
- **Risk front-loading note:** P1+P3 carry the unverifiable-in-CI save risk; P15 (filter bytes) is the highest-leverage CI-coverable correctness task. The live save assumption is resolved only by the P18 manual smoke — flagged throughout.
