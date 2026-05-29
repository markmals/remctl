# Swift Port — Phase 1 (Reads) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the four read-side infrastructure layers (Runtime, Store via GRDB, Serialization, Output) and wire all 18 read/inspect commands to byte-for-byte JSON parity and human-output parity with the Python `remctl`.

**Architecture:** Bottom-up. A custom ordered `JSONValue` type underpins all `--json` output (Swift's `JSONEncoder` cannot reproduce Python's insertion-ordered, conditionally-omitted keys). A GRDB read-only `Store` reproduces every `q_*` query verbatim (exact SQL, `Z_ENT` discriminators, dynamic column probing). A `Serialization` layer mirrors `serialize_reminder` key-for-key. An `Output` layer mirrors `fmt`/`fmt_table`/color/`safe_display`. Commands are thin handlers over these.

**Tech Stack:** Swift 6, Swift Argument Parser 1.8, GRDB.swift 7.10 (read-only `DatabaseQueue`), Swift Testing. macOS 14+.

**Scope note (large phase):** This plan has ~40 tasks across 5 layers. It is one phase but may be executed in segments — Foundation (T1–T16) is a natural checkpoint that produces a buildable binary with the simplest commands working; Inspect/Lists/Smart/Templates/Export (T17–T40) layer on top. Each task is independently committable.

**Ground-truth sources (in repo):**
- `remctl` — the Python CLI (no extension, ~8,219 lines). Command handlers, inline SQL, output formatting.
- `remctl_serialization.py` (275), `remctl_smart_lists.py` (631), `remctl_runtime.py` (152).
- `tests/test_cli.py` (3,966) — the parity oracle (the serializer region 3609–3962 is the densest).
- `tests/test_runtime.py`, `tests/test_smart_lists.py` — unit oracles.
- `docs/superpowers/specs/2026-05-28-reminders-cli-contract.md` — committed parity contract (per-command + schema + queries with `remctl:line` refs).

**Parity rule:** Source code is ground truth. When the contract doc and source disagree, trust source. Where this plan inlines SQL/key-order/format strings, they were extracted verbatim; still cross-check the cited source line when implementing.

**Deliberate deviations (from design spec §5, already approved):**
- `--private` is removed. `urgent`, list appearance, etc. are first-class reads (they already are — these are read columns). The only human-string touch: the `list-symbols` human hint line drops `--private` (see T37).
- Human-output polish permitted; **JSON shape is strict parity** (byte-identical where feasible).

---

## File structure (created across the plan)

```
Sources/RemindersControl/
├─ Runtime/
│   ├─ AppleEpoch.swift        # appleEpoch, ts(), toTs(), isoLocalNoTZ()        [T2]
│   ├─ DateWindows.swift       # startOfDay, dueTodayWindow, upcomingWindow       [T3]
│   └─ Paths.swift             # resolveStoreDir/ConfigDir, findMainDB, errors     [T4]
├─ Output/
│   ├─ Constants.swift         # PRI, PRI_NAME, freq/unit/day maps, LIST_COLOR_MAP,
│   │                          #   GROCERY_LIST_MARKER, SMART_LIST_TYPE_NAMES …    [T5]
│   ├─ Color.swift             # Ansi gate + helpers, safeDisplay                  [T6]
│   ├─ ReminderFormat.swift    # fmt, fmtDue, recurrenceSummary/Badge, colorByList [T14]
│   ├─ Table.swift             # fmtTable, remindersToTableData                    [T15]
│   ├─ Grocery.swift           # GROCERY_CATEGORY_EMOJI, format/add section meta   [T27]
│   ├─ ListSymbols.swift       # OFFICIAL_LIST_SYMBOLS (71) + rows                 [T36]
│   └─ CSV.swift               # excel/CRLF writer                                 [T38]
├─ Serialization/
│   ├─ JSONValue.swift         # ordered JSON value + serializer                   [T1]
│   ├─ Row.swift               # ReminderRow protocol over GRDB Row / dict         [T7]
│   ├─ ReminderSerializer.swift# serializeReminder(s), recurrence, earlyReminders  [T9,T10]
│   ├─ ListSerializer.swift    # listToDict, parseListColor, parseBadgeEmblem      [T24]
│   ├─ SmartListSerializer.swift # smartListToDict, smartListDisplayName           [T32]
│   ├─ TemplateSerializer.swift# templateToDict, savedReminderToDict, uuidFromBlob [T34]
│   └─ AlarmAttachment.swift   # alarm/attachment serializers, hydrateDetail       [T29]
├─ SmartLists/
│   └─ FilterDecode.swift      # decode + summarize filter (read side)             [T31]
├─ Store/
│   ├─ RemindersStore.swift    # GRDB open RO, RemindersDBUnavailable              [T7]
│   ├─ Schema.swift            # Z_ENT, column probe, rem_cols                      [T8]
│   ├─ Queries+Reminders.swift # q_reminders/q_reminder/q_search/windows …         [T11,T12]
│   ├─ Queries+Extras.swift    # q_hashtags/q_rich_link/q_attachments/q_alarms, preload [T13]
│   ├─ Queries+Lists.swift     # q_lists, resolve_list_ref, q_sections, memberships [T24,T26]
│   ├─ Queries+SmartLists.swift# q_smart_lists                                     [T32]
│   └─ Queries+Templates.swift # q_templates/matches/sections/saved, resolve       [T34]
├─ Commands/                   # existing 45 stubs; fill read run()s               [T16–T39]
│   └─ Support/OutputOptions.swift  # option groups, format resolution, runHandler [T16]
tests/RemindersControlTests/
├─ Support/FixtureDB.swift     # builds CoreData-shaped SQLite fixtures            [T7]
├─ Support/CLIRunner.swift     # runs the built binary, captures stdout/stderr/exit [T16]
├─ JSONValueTests.swift, RuntimeTests.swift, StoreTests.swift,
│   SerializerTests.swift, OutputTests.swift, <Command>Tests.swift …
```

---

## Test strategy

Two levels, both Swift Testing (`import Testing`):

1. **Unit tests** drive layers directly against an **in-memory GRDB DB** built by `FixtureDB` (CREATE TABLE + INSERT mirroring the Python tests' inline fixtures). Fast, precise; the primary oracle for serializers/queries.
2. **Black-box CLI tests** build a temp on-disk `Data-test.sqlite`, set `REMCTL_STORE_DIR` to its dir, run the **built `remctl` binary** as a subprocess with `NO_COLOR=1`, and assert stdout/stderr/exit. This validates arg-parsing + dispatch + output end-to-end, mirroring `tests/test_cli.py`.

`NO_COLOR=1` (and non-tty, which subprocess pipes already guarantee) means CLI tests assert **uncolored** output — matching how the Python oracle captures stdout. Color-on byte parity is not required (human-polish allowance); color suppression logic is still unit-tested.

The Python suite is fully ported in Phase 5; in Phase 1 we write *new* Swift tests per task (TDD), reusing the Python oracle's exact expected values.

---

## Conventions used in tasks

- "Commit" steps: `git add <files> && git commit -m "<msg>"`. Stacked on branch `swift-port`.
- Run tests with `swift test --filter <SuiteOrTest>`; build with `swift build`.
- Every `run()` for read commands stays **synchronous** (`func run() throws`) — reads don't await. The `RemCTL` root remains `AsyncParsableCommand`; sync subcommands run fine under it. (Phase 2 writes convert their own commands to `async`.)

---

# FOUNDATION (T1–T16)

## Task 1: Ordered JSONValue + serializer

The cornerstone. Python `json.dumps` preserves dict insertion order, omits keys conditionally, and is called with varying `indent`/`ensure_ascii`. We need an ordered value type and a serializer matching Python's exact whitespace and escaping, including **not** escaping `/` (Swift's encoder escapes it by default).

**Files:**
- Create: `Sources/RemindersControl/Serialization/JSONValue.swift`
- Test: `tests/RemindersControlTests/JSONValueTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
@testable import RemindersControl

@Suite struct JSONValueTests {
    @Test func prettyArrayOfOneObjectMatchesPythonIndent2() {
        let v: JSONValue = .array([.object([
            ("id", .int(42)), ("title", .string("Buy milk")), ("completed", .bool(false)),
        ])])
        // json.dumps([{...}], indent=2, ensure_ascii=False) — no trailing newline
        let expected = """
        [
          {
            "id": 42,
            "title": "Buy milk",
            "completed": false
          }
        ]
        """
        #expect(v.serialized(indent: 2, ensureAscii: false) == expected)
    }

    @Test func emptyContainers() {
        #expect(JSONValue.array([]).serialized(indent: 2, ensureAscii: false) == "[]")
        #expect(JSONValue.object([]).serialized(indent: 2, ensureAscii: false) == "{}")
    }

    @Test func compactSeparatorsMatchPythonDefault() {
        // json.dumps({"a":1,"b":[2,3]}) -> '{"a": 1, "b": [2, 3]}'  (', ' and ': ')
        let v: JSONValue = .object([("a", .int(1)), ("b", .array([.int(2), .int(3)]))])
        #expect(v.serialized(indent: nil, ensureAscii: true) == #"{"a": 1, "b": [2, 3]}"#)
    }

    @Test func ensureAsciiEscapesNonAsciiWhenTrue() {
        // json.dumps({"name":"café 🥕"}) -> '{"name": "café 🥕"}'  (surrogate pair!)
        let v: JSONValue = .object([("name", .string("café 🥕"))])
        #expect(v.serialized(indent: nil, ensureAscii: true)
            == #"{"name": "café 🥕"}"#)
    }

    @Test func ensureAsciiFalseEmitsLiteralUnicode() {
        let v: JSONValue = .object([("name", .string("café 🥕"))])
        #expect(v.serialized(indent: nil, ensureAscii: false) == #"{"name": "café 🥕"}"#)
    }

    @Test func doesNotEscapeForwardSlash() {
        // Python never escapes '/': json.dumps("a/b") -> '"a/b"'
        #expect(JSONValue.string("a/b").serialized(indent: nil, ensureAscii: true) == #""a/b""#)
    }

    @Test func escapesControlAndQuoteAndBackslash() {
        #expect(JSONValue.string("a\"b\\c\n\t").serialized(indent: nil, ensureAscii: true)
            == #""a\"b\\c\n\t""#)
    }
}
```

- [ ] **Step 2: Run — expect compile failure (JSONValue undefined)**
Run: `swift test --filter JSONValueTests` → FAIL.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Insertion-ordered JSON value mirroring Python `json.dumps` output exactly.
public indirect enum JSONValue {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    /// Ordered key/value pairs — order is the output order (no sorting).
    case object([(String, JSONValue)])

    /// Serialize matching Python `json.dumps(value, indent: indent, ensure_ascii: ensureAscii)`.
    /// - indent: nil = compact with ", "/": " separators; non-nil = pretty with that many spaces.
    /// - ensureAscii: true escapes non-ASCII as \uXXXX (surrogate pairs for astral); false emits literal UTF-8.
    /// Forward slashes are NEVER escaped (matches Python). No trailing newline (callers add print()'s \n).
    public func serialized(indent: Int?, ensureAscii: Bool) -> String {
        var out = ""
        write(into: &out, indent: indent, ensureAscii: ensureAscii, level: 0)
        return out
    }

    private func write(into out: inout String, indent: Int?, ensureAscii: Bool, level: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += JSONValue.formatDouble(d)
        case .string(let s): out += JSONValue.encodeString(s, ensureAscii: ensureAscii)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            writeContainer(into: &out, open: "[", close: "]", count: items.count,
                           indent: indent, level: level) { i, o, childLevel in
                items[i].write(into: &o, indent: indent, ensureAscii: ensureAscii, level: childLevel)
            }
        case .object(let pairs):
            if pairs.isEmpty { out += "{}"; return }
            writeContainer(into: &out, open: "{", close: "}", count: pairs.count,
                           indent: indent, level: level) { i, o, childLevel in
                o += JSONValue.encodeString(pairs[i].0, ensureAscii: ensureAscii)
                o += ": "
                pairs[i].1.write(into: &o, indent: indent, ensureAscii: ensureAscii, level: childLevel)
            }
        }
    }

    private func writeContainer(into out: inout String, open: String, close: String, count: Int,
                                indent: Int?, level: Int,
                                element: (Int, inout String, Int) -> Void) {
        out += open
        let childLevel = level + 1
        let pad = indent.map { String(repeating: " ", count: $0 * childLevel) }
        let closePad = indent.map { String(repeating: " ", count: $0 * level) }
        for i in 0..<count {
            if i == 0 { if let pad { out += "\n" + pad } }
            else { out += indent == nil ? ", " : ",\n" + (pad ?? "") }
            element(i, &out, childLevel)
        }
        if let closePad { out += "\n" + closePad }
        out += close
    }

    /// Mirror Python json string encoding: \", \\, \n, \r, \t, \b, \f, \uXXXX for other C0;
    /// non-ASCII -> \uXXXX (UTF-16 incl. surrogate pairs) when ensureAscii, else literal. '/' never escaped.
    static func encodeString(_ s: String, ensureAscii: Bool) -> String {
        var r = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            case "\u{08}": r += "\\b"
            case "\u{0C}": r += "\\f"
            default:
                if scalar.value < 0x20 {
                    r += String(format: "\\u%04x", scalar.value)
                } else if scalar.value < 0x80 || !ensureAscii {
                    r.unicodeScalars.append(scalar)
                } else {
                    // ensureAscii && non-ASCII: emit UTF-16 units (surrogate pair if astral), lowercase hex
                    for unit in String(scalar).utf16 { r += String(format: "\\u%04x", unit) }
                }
            }
        }
        r += "\""
        return r
    }

    /// Match Python repr of floats in json (e.g. 1.0 -> "1.0", 123.0 -> "123.0", 456.5 -> "456.5").
    static func formatDouble(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e16 {
            return String(format: "%.1f", d) // 123.0 style
        }
        return String(d)
    }
}
```

> Note on `formatDouble`: Phase 1 only emits doubles for `pinnedDate`/`pinnedDate`-style raw Apple timestamps (e.g. `123.0`, `456.0`) — whole-number doubles → `"123.0"`. The `%.1f` branch covers the tested cases. If a future fractional value needs exact Python `repr`, revisit; flagged, not blocking.

- [ ] **Step 4: Run — expect PASS**
Run: `swift test --filter JSONValueTests` → all pass.

- [ ] **Step 5: Commit**
`git commit -m "Phase 1: ordered JSONValue + Python-parity serializer"`

---

## Task 2: Runtime — Apple epoch + local-naive ISO

Mirror `APPLE_EPOCH=978307200`, `ts(v)`, `to_ts(dt)`, and the `.isoformat()` rendering (local time, **no** timezone suffix, fractional seconds only when nonzero).

**Files:**
- Create: `Sources/RemindersControl/Runtime/AppleEpoch.swift`
- Test: `tests/RemindersControlTests/RuntimeTests.swift` (new suite `AppleEpochTests`)

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import RemindersControl

@Suite struct AppleEpochTests {
    // Oracle (test_cli.py): ZDUEDATE=801216000 -> "2026-05-23T10:00:00",
    //                       ZDISPLAYDATEDATE=801215100 -> "2026-05-23T09:45:00".
    // These assume the test host local timezone == Europe/Rome (CEST, +02:00) per the oracle.
    // To keep the assertion deterministic regardless of CI TZ, set TZ explicitly in the test.
    @Test func tsConvertsAppleEpochToLocalNaiveISO() {
        let prevTZ = TimeZone.default
        defer { TimeZone.default = prevTZ }
        TimeZone.default = TimeZone(identifier: "Europe/Rome")!
        #expect(AppleEpoch.ts(801216000) == "2026-05-23T10:00:00")
        #expect(AppleEpoch.ts(801215100) == "2026-05-23T09:45:00")
    }

    @Test func tsReturnsNilForFalsey() {
        #expect(AppleEpoch.ts(0) == nil)
        #expect(AppleEpoch.ts(nil) == nil)
    }

    @Test func toTsIsInverseOffset() {
        // to_ts(datetime) = unixSeconds - 978307200
        let unix = 801216000.0 + 978307200.0
        #expect(AppleEpoch.toTs(Date(timeIntervalSince1970: unix)) == 801216000)
    }

    @Test func fractionalSecondsRenderedOnlyWhenNonzero() {
        let prevTZ = TimeZone.default
        defer { TimeZone.default = prevTZ }
        TimeZone.default = TimeZone(identifier: "UTC")!
        // 0 apple-seconds -> 2001-01-01T00:00:00 (UTC), no fraction
        #expect(AppleEpoch.tsForce(0) == "2001-01-01T00:00:00")
    }
}
```

> If `TimeZone.default` setter proves unreliable in the test runtime, the implementation should accept an injectable `TimeZone`/`Calendar` (default `.current`) and the test passes `Europe/Rome`. Prefer injection — see Step 3 signature note.

- [ ] **Step 2: Run → FAIL**

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum AppleEpoch {
    /// Seconds between Unix epoch (1970-01-01) and Apple/CoreData reference date (2001-01-01 UTC).
    public static let offset: Double = 978_307_200

    /// `ts(v)` — None for falsey (0/nil); else Apple seconds -> local-naive ISO string.
    public static func ts(_ v: Double?, calendar: Calendar = .current) -> String? {
        guard let v, v != 0 else { return nil }
        return tsForce(v, calendar: calendar)
    }

    /// Like ts but does not short-circuit 0 (used where 0 is a valid instant).
    public static func tsForce(_ v: Double, calendar: Calendar = .current) -> String {
        isoLocalNoTZ(Date(timeIntervalSince1970: v + offset), calendar: calendar)
    }

    /// `to_ts(dt)` — Date -> Apple seconds.
    public static func toTs(_ d: Date) -> Double { d.timeIntervalSince1970 - offset }

    /// Mirror Python datetime.isoformat() for a naive LOCAL datetime:
    /// "YYYY-MM-DDTHH:MM:SS" with ".ffffff" appended only when microseconds != 0.
    public static func isoLocalNoTZ(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        var s = String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                       c.year ?? 0, c.month ?? 0, c.day ?? 0,
                       c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let micros = Int(((c.nanosecond ?? 0)) / 1000)
        if micros != 0 { s += String(format: ".%06d", micros) }
        return s
    }
}
```

> Implementer: `calendar.dateComponents` uses the calendar's timezone. For the TZ-injection test variant, build `var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Rome")!` and pass it; adjust the test to pass the calendar rather than mutating `TimeZone.default`. Pick whichever the runtime supports and make the test deterministic.

- [ ] **Step 4: Run → PASS**
- [ ] **Step 5: Commit** — `git commit -m "Phase 1: Runtime AppleEpoch ts/toTs/isoLocalNoTZ"`

---

## Task 3: Runtime — date windows

Mirror `start_of_day`, `due_today_window`, `upcoming_window` (note the `days+1` upper bound), local midnight.

**Files:**
- Create: `Sources/RemindersControl/Runtime/DateWindows.swift`
- Test: `RuntimeTests.swift` (suite `DateWindowTests`)

- [ ] **Step 1: Failing tests** (mirror `tests/test_runtime.py`)

```swift
@Suite struct DateWindowTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    private func d(_ y:Int,_ mo:Int,_ da:Int,_ h:Int=0,_ mi:Int=0) -> Date {
        cal.date(from: DateComponents(year:y,month:mo,day:da,hour:h,minute:mi))!
    }
    @Test func startOfDayTruncates() {
        #expect(DateWindows.startOfDay(d(2026,4,18,14,30), calendar: cal) == d(2026,4,18,0,0))
    }
    @Test func dueTodayWindowIsSodToSodPlusOne() {
        let (a,b) = DateWindows.dueTodayWindow(d(2026,4,18,14,30), calendar: cal)
        #expect(a == d(2026,4,18)); #expect(b == d(2026,4,19))
    }
    @Test func upcomingWindowAddsDaysPlusOne() {
        let (a,b) = DateWindows.upcomingWindow(days: 7, now: d(2026,4,18,14,30), calendar: cal)
        #expect(a == d(2026,4,18)); #expect(b == d(2026,4,26)) // sod + 8 days
    }
}
```

- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement**

```swift
import Foundation

public enum DateWindows {
    public static func startOfDay(_ now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }
    public static func dueTodayWindow(_ now: Date = Date(), calendar: Calendar = .current) -> (Date, Date) {
        let sod = startOfDay(now, calendar: calendar)
        return (sod, calendar.date(byAdding: .day, value: 1, to: sod)!)
    }
    public static func upcomingWindow(days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> (Date, Date) {
        let sod = startOfDay(now, calendar: calendar)
        return (sod, calendar.date(byAdding: .day, value: days + 1, to: sod)!)
    }
}
```

- [ ] **Step 4: Run → PASS**
- [ ] **Step 5: Commit** — `git commit -m "Phase 1: Runtime date windows"`

---

## Task 4: Runtime — paths & DB discovery

Mirror `resolve_store_dir` (env `REMCTL_STORE_DIR`, `~` expansion, empty=unset), `resolve_config_dir` (`REMCTL_CONFIG_DIR` as-is > `XDG_CONFIG_HOME`/app > `~/.config`/app), `find_main_db_path` (glob `Data-*.sqlite`, **largest by size**), `reminders_store_access_error`, and `RemindersDBUnavailable`. Source: `remctl_runtime.py:13-30`, `remctl:169-207`.

**Files:**
- Create: `Sources/RemindersControl/Runtime/Paths.swift`
- Test: `RuntimeTests.swift` (suite `PathsTests`)

- [ ] **Step 1: Failing tests**

```swift
@Suite struct PathsTests {
    @Test func storeDirHonorsEnvOverride() {
        let env = ["REMCTL_STORE_DIR": "/tmp/custom-store"]
        #expect(Paths.resolveStoreDir(env: env).path == "/tmp/custom-store")
    }
    @Test func storeDirDefaultsToGroupContainer() {
        let dir = Paths.resolveStoreDir(env: [:])
        #expect(dir.path.hasSuffix(
          "Library/Group Containers/group.com.apple.reminders/Container_v1/Stores"))
    }
    @Test func configDirPrecedence() {
        #expect(Paths.resolveConfigDir(env: ["REMCTL_CONFIG_DIR":"/c"]).path == "/c") // as-is, no /remctl
        #expect(Paths.resolveConfigDir(env: ["XDG_CONFIG_HOME":"/x"]).path == "/x/remctl")
        #expect(Paths.resolveConfigDir(env: [:]).path.hasSuffix(".config/remctl"))
    }
    @Test func findMainDBPicksLargest() throws {
        let tmp = try makeTempDir()
        try Data(count: 10).write(to: tmp.appendingPathComponent("Data-A.sqlite"))
        try Data(count: 9999).write(to: tmp.appendingPathComponent("Data-B.sqlite"))
        #expect(Paths.findMainDBPath(storeDir: tmp)?.lastPathComponent == "Data-B.sqlite")
    }
    @Test func findMainDBThrowsWhenNone() {
        let tmp = (try? makeTempDir())!
        #expect(throws: RemindersDBUnavailable.self) {
            _ = try Paths.findMainDB(storeDir: tmp)
        }
    }
}
```
(Provide `makeTempDir()` in `Support/`.)

- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement**

```swift
import Foundation

public struct RemindersDBUnavailable: Error, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

public enum Paths {
    static let defaultStoreSubpath =
        "Library/Group Containers/group.com.apple.reminders/Container_v1/Stores"

    static func env() -> [String: String] { ProcessInfo.processInfo.environment }

    public static func resolveStoreDir(env e: [String: String] = env()) -> URL {
        if let v = e["REMCTL_STORE_DIR"], !v.isEmpty {
            return URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(defaultStoreSubpath)
    }

    public static func resolveConfigDir(appName: String = "remctl", env e: [String: String] = env()) -> URL {
        if let v = e["REMCTL_CONFIG_DIR"], !v.isEmpty {
            return URL(fileURLWithPath: (v as NSString).expandingTildeInPath) // as-is, no appName
        }
        if let x = e["XDG_CONFIG_HOME"], !x.isEmpty {
            return URL(fileURLWithPath: (x as NSString).expandingTildeInPath).appendingPathComponent(appName)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config").appendingPathComponent(appName)
    }

    /// Glob `Data-*.sqlite`, return the LARGEST by file size (descending), or nil.
    public static func findMainDBPath(storeDir: URL = resolveStoreDir()) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        let candidates = items.filter {
            $0.lastPathComponent.hasPrefix("Data-") && $0.pathExtension == "sqlite"
        }
        return candidates.max {
            (size($0)) < (size($1))
        }
    }
    private static func size(_ u: URL) -> Int {
        (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// If store dir exists but is unreadable, returns the FDA-blocked message; else nil.
    public static func storeAccessError(storeDir: URL = resolveStoreDir()) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeDir.path) else { return nil }
        if fm.isReadableFile(atPath: storeDir.path) { return nil }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "remctl"
        return """
        Direct CLI reads are blocked because the Reminders store at \(storeDir.path) is not \
        readable from this process context (\(exe)). This usually means Full Disk Access is \
        missing for the app or interpreter that is running remctl here.
        """
    }

    public static func findMainDB(storeDir: URL = resolveStoreDir()) throws -> URL {
        if let err = storeAccessError(storeDir: storeDir) { throw RemindersDBUnavailable(err) }
        guard let p = findMainDBPath(storeDir: storeDir) else {
            throw RemindersDBUnavailable("No Reminders database found. Is iCloud Reminders enabled?")
        }
        return p
    }
}
```

- [ ] **Step 4: Run → PASS**
- [ ] **Step 5: Commit** — `git commit -m "Phase 1: Runtime paths + DB discovery"`

---

## Task 5: Output constants

Copy the module-level constant tables verbatim from source. Source lines: `PRI`/`PRI_NAME` (`remctl:210`-ish, also Output recon), `RECURRENCE_FREQUENCIES`/`DUE_DATE_DELTA_UNITS` (`remctl_serialization.py:8-21`), `RECURRENCE_DAY_NAMES`/`LIST_COLOR_MAP` (`remctl` Output region), `GROCERY_LIST_MARKER`, `CUSTOM_SMART_LIST_TYPE` (`remctl_smart_lists.py:10`), `SMART_LIST_TYPE_NAMES` (`remctl:4118-4126`).

**Files:**
- Create: `Sources/RemindersControl/Output/Constants.swift`
- Test: `tests/RemindersControlTests/OutputTests.swift` (suite `ConstantsTests`)

- [ ] **Step 1: Failing tests**

```swift
@Suite struct ConstantsTests {
    @Test func priorityMaps() {
        #expect(Constants.priorityName[0] == "none"); #expect(Constants.priorityName[1] == "high")
        #expect(Constants.priorityName[5] == "medium"); #expect(Constants.priorityName[9] == "low")
        #expect(Constants.priorityMarker[1] == "!!!"); #expect(Constants.priorityMarker[5] == "!!")
        #expect(Constants.priorityMarker[9] == "!"); #expect(Constants.priorityMarker[0] == "")
    }
    @Test func recurrenceMaps() {
        #expect(Constants.recurrenceFrequencies[0] == "daily")
        #expect(Constants.recurrenceFrequencies[3] == "yearly")
        #expect(Constants.recurrenceDayNames[2] == "Mon"); #expect(Constants.recurrenceDayNames[4] == "Wed")
    }
    @Test func listColorMapAndGroceryMarker() {
        #expect(Constants.listColorMap["blue"]! == (0,136,255))
        #expect(Constants.groceryListMarker == "🥕")
        #expect(Constants.customSmartListType == "com.apple.reminders.smartlist.custom")
        #expect(Constants.smartListTypeNames["com.apple.reminders.smartlist.flagged"] == "Flagged")
    }
}
```

- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement** (verbatim values from recon/source)

```swift
public enum Constants {
    public static let priorityName: [Int: String] = [0: "none", 1: "high", 5: "medium", 9: "low"]
    public static let priorityMarker: [Int: String] = [0: "", 1: "!!!", 5: "!!", 9: "!"]

    public static let recurrenceFrequencies: [Int: String] = [0: "daily", 1: "weekly", 2: "monthly", 3: "yearly"]
    /// (singular, plural)
    public static let dueDateDeltaUnits: [Int: (String, String)] =
        [0: ("minute","minutes"), 1: ("hour","hours"), 2: ("day","days"), 3: ("week","weeks"), 4: ("month","months")]
    public static let recurrenceDayNames: [Int: String] =
        [1:"Sun",2:"Mon",3:"Tue",4:"Wed",5:"Thu",6:"Fri",7:"Sat"]

    public static let listColorMap: [String: (Int,Int,Int)] = [
        "red":(255,41,104),"orange":(255,141,40),"yellow":(255,204,0),"green":(99,218,56),
        "blue":(0,136,255),"purple":(204,115,225),"brown":(162,132,94),"gray":(91,98,106),
        "cyan":(90,200,250),"teal":(48,176,199),
    ]
    public static let defaultListColorRGB = (0,122,255)
    public static let defaultListColorJSON = (name: "blue", hex: "#007AFF")

    public static let groceryListMarker = "🥕"
    public static let customSmartListType = "com.apple.reminders.smartlist.custom"
    public static let smartListTypeNames: [String: String] = [
        "com.apple.reminders.smartlist.all":"All",
        "com.apple.reminders.smartlist.today":"Today",
        "com.apple.reminders.smartlist.scheduled":"Scheduled",
        "com.apple.reminders.smartlist.flagged":"Flagged",
        "com.apple.reminders.smartlist.completed":"Completed",
        "com.apple.reminders.smartlist.assigned":"Assigned",
        "com.apple.reminders.smartlist.urgent":"Urgent",
    ]
    public static let deepLinkReminderPrefix = "x-apple-reminderkit://REMCDReminder/"
    public static let deepLinkTemplatePrefix = "x-apple-reminderkit://REMCDTemplate/"
}
```

> Implementer: cross-check each map against source before committing (esp. `SMART_LIST_TYPE_NAMES` keys at `remctl:4118-4126` and `LIST_COLOR_MAP`). The contract doc §"priority name maps" (line ~1255) corroborates.

- [ ] **Step 4: Run → PASS**
- [ ] **Step 5: Commit** — `git commit -m "Phase 1: Output constant tables"`

---

## Task 6: Output — color gate + safeDisplay

Mirror class `C` (ANSI codes, `enabled` gate: `--no-color` || `NO_COLOR` env present (any value) || not a tty), and `safe_display` (`TERMINAL_CONTROL_RE` = `[\x00-\x1f\x7f-\x9f  ]` → single space; nil → "").

**Files:**
- Create: `Sources/RemindersControl/Output/Color.swift`
- Test: `OutputTests.swift` (suite `ColorTests`)

- [ ] **Step 1: Failing tests**

```swift
@Suite struct ColorTests {
    @Test func disabledReturnsPlain() {
        var a = Ansi(enabled: false)
        #expect(a.red("x") == "x"); #expect(a.bold("x") == "x")
        #expect(a.rgb(1,2,3,"x") == "x")
    }
    @Test func enabledWrapsSGR() {
        var a = Ansi(enabled: true)
        #expect(a.red("x") == "\u{1B}[31mx\u{1B}[0m")
        #expect(a.dim(a.strikethrough("t")) == "\u{1B}[2m\u{1B}[9mt\u{1B}[0m\u{1B}[0m")
        #expect(a.rgb(0,136,255,"L") == "\u{1B}[38;2;0;136;255mL\u{1B}[0m")
    }
    @Test func safeDisplayReplacesControls() {
        #expect(safeDisplay("a\u{0}b\tc\u{2028}d") == "a b c d")
        #expect(safeDisplay(nil) == "")
        #expect(safeDisplay("\u{1B}]52;c;x\u{07}Clipboard").contains("Clipboard"))
    }
}
```

- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement**

```swift
import Foundation

public struct Ansi {
    public var enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }

    /// Resolve color suppression like main(): --no-color || NO_COLOR present || stdout not a tty.
    public static func resolve(noColorFlag: Bool, env: [String:String] = ProcessInfo.processInfo.environment,
                               isTTY: Bool = isatty(STDOUT_FILENO) != 0) -> Ansi {
        Ansi(enabled: !(noColorFlag || env["NO_COLOR"] != nil || !isTTY))
    }

    private func code(_ c: String, _ t: String) -> String { enabled ? "\u{1B}[\(c)m\(t)\u{1B}[0m" : t }
    public func red(_ t: String) -> String { code("31", t) }
    public func green(_ t: String) -> String { code("32", t) }
    public func yellow(_ t: String) -> String { code("33", t) }
    public func blue(_ t: String) -> String { code("34", t) }
    public func magenta(_ t: String) -> String { code("35", t) }
    public func cyan(_ t: String) -> String { code("36", t) }
    public func dim(_ t: String) -> String { code("2", t) }
    public func bold(_ t: String) -> String { code("1", t) }
    public func strikethrough(_ t: String) -> String { code("9", t) }
    public func rgb(_ r: Int, _ g: Int, _ b: Int, _ t: String) -> String {
        enabled ? "\u{1B}[38;2;\(r);\(g);\(b)m\(t)\u{1B}[0m" : t
    }
}

/// Replace terminal-control scalars with single space; nil -> "".
public func safeDisplay(_ value: String?) -> String {
    guard let value else { return "" }
    var out = String.UnicodeScalarView()
    for s in value.unicodeScalars {
        if s.value < 0x20 || (0x7F...0x9F).contains(s.value) || s.value == 0x2028 || s.value == 0x2029 {
            out.append(" ")
        } else { out.append(s) }
    }
    return String(out)
}
```

- [ ] **Step 4: Run → PASS**
- [ ] **Step 5: Commit** — `git commit -m "Phase 1: Output color gate + safeDisplay"`

---

## Task 7: Store — GRDB read-only open + FixtureDB + column probing

Open the DB read-only via GRDB `DatabaseQueue` (`Configuration.readonly = true` — equivalent to `?mode=ro`, no WAL change). Provide `RemindersStore` wrapping a connection, a `tableColumnNames`/`reminderHasColumn` probe using GRDB `db.columns(in:)`, and a `ReminderRow` abstraction. Provide the `FixtureDB` test helper.

**Files:**
- Create: `Sources/RemindersControl/Store/RemindersStore.swift`
- Create: `Sources/RemindersControl/Serialization/Row.swift`
- Create: `tests/RemindersControlTests/Support/FixtureDB.swift`
- Test: `tests/RemindersControlTests/StoreTests.swift` (suite `StoreOpenTests`)

- [ ] **Step 1: FixtureDB helper** (no test yet; support code)

```swift
import GRDB
import Foundation
@testable import RemindersControl

/// Builds an in-memory or temp-file CoreData-shaped SQLite DB for tests.
enum FixtureDB {
    /// In-memory writable queue for unit tests that call queries/serializers directly.
    static func inMemory(_ build: (Database) throws -> Void) throws -> DatabaseQueue {
        let q = try DatabaseQueue() // in-memory
        try q.write { try build($0) }
        return q
    }

    /// Create a temp dir containing a populated `Data-test.sqlite`; returns the dir.
    /// Use for black-box CLI tests via REMCTL_STORE_DIR.
    static func tempStore(_ build: (Database) throws -> Void) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remctl-fixt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("Data-test.sqlite").path
        let q = try DatabaseQueue(path: path)
        try q.write { try build($0) }
        return dir
    }

    /// Minimal ZREMCDREMINDER + ZREMCDBASELIST schema used by most reminder tests.
    /// (Add columns as tasks need them; keep names exact.)
    static func createRemindersSchema(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE ZREMCDBASELIST (
          Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZNAME TEXT, ZCKIDENTIFIER TEXT,
          ZMARKEDFORDELETION INTEGER DEFAULT 0, ZSMARTLISTTYPE TEXT, ZFILTERDATA BLOB,
          ZCOLOR BLOB, ZBADGEEMBLEM TEXT, ZISPINNEDBYCURRENTUSER INTEGER, ZPINNEDDATE REAL,
          ZSHOULDCATEGORIZEGROCERYITEMS INTEGER, ZSHOULDAUTOCATEGORIZEITEMS INTEGER,
          ZSHOULDSUGGESTCONVERSIONTOGROCERYLIST INTEGER, ZGROCERYLOCALEID TEXT,
          ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA TEXT,
          ZMINIMUMSUPPORTEDAPPVERSION INTEGER, ZEFFECTIVEMINIMUMSUPPORTEDAPPVERSION INTEGER
        );
        CREATE TABLE ZREMCDREMINDER (
          Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZNOTES TEXT, ZCOMPLETED INTEGER DEFAULT 0,
          ZFLAGGED INTEGER DEFAULT 0, ZPRIORITY INTEGER DEFAULT 0,
          ZISURGENTSTATEENABLEDFORCURRENTUSER INTEGER, ZDUEDATEDELTAALERTSDATA TEXT,
          ZDUEDATE REAL, ZDISPLAYDATEDATE REAL, ZALLDAY INTEGER, ZCOMPLETIONDATE REAL,
          ZCREATIONDATE REAL, ZPARENTREMINDER INTEGER, ZLIST INTEGER, ZICSURL TEXT,
          ZCKIDENTIFIER TEXT, ZMARKEDFORDELETION INTEGER DEFAULT 0, ZACCOUNT INTEGER
        );
        CREATE TABLE ZREMCDOBJECT (
          Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZMARKEDFORDELETION INTEGER DEFAULT 0,
          ZREMINDER INTEGER, ZREMINDER2 INTEGER, ZREMINDER3 INTEGER, ZREMINDER4 INTEGER,
          ZHASHTAGLABEL INTEGER, ZURL TEXT, ZFILENAME TEXT, ZUTI TEXT, ZWIDTH REAL, ZHEIGHT REAL,
          ZTRIGGER INTEGER, ZTIMEINTERVAL REAL, ZDATECOMPONENTSDATA BLOB, ZTITLE TEXT,
          ZLATITUDE REAL, ZLONGITUDE REAL, ZRADIUS REAL, ZADDRESS TEXT, ZPROXIMITY INTEGER,
          ZFREQUENCY INTEGER, ZINTERVAL INTEGER, ZOCCURRENCECOUNT INTEGER, ZENDDATE REAL,
          ZDAYSOFTHEWEEK TEXT, ZDAYSOFTHEMONTH TEXT, ZMONTHSOFTHEYEAR TEXT, ZDAYSOFTHEYEAR TEXT,
          ZWEEKSOFTHEYEAR TEXT, ZSETPOSITIONS TEXT
        );
        CREATE TABLE ZREMCDHASHTAGLABEL (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT);
        CREATE TABLE ZREMCDBASESECTION (
          Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZDISPLAYNAME TEXT, ZLIST INTEGER,
          ZCKIDENTIFIER TEXT, ZMARKEDFORDELETION INTEGER DEFAULT 0, ZTEMPLATE INTEGER,
          ZCANONICALNAME TEXT, ZCREATIONDATE REAL
        );
        CREATE TABLE ZREMCDSAVEDATTACHMENT (
          Z_PK INTEGER PRIMARY KEY, ZREMINDER INTEGER, ZFILENAME TEXT, ZUTI TEXT,
          ZATTACHMENTTYPERAWVALUE TEXT, ZMARKEDFORDELETION INTEGER DEFAULT 0
        );
        """)
    }
    // Template-specific tables added in T34's fixture extension.
}
```

- [ ] **Step 2: Failing tests**

```swift
@Suite struct StoreOpenTests {
    @Test func opensReadOnlyAndProbesColumns() throws {
        let dir = try FixtureDB.tempStore { try FixtureDB.createRemindersSchema($0) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        #expect(store.reminderHasColumn("ZISURGENTSTATEENABLEDFORCURRENTUSER"))
        #expect(!store.reminderHasColumn("ZNOPE"))
        #expect(store.tableColumnNames("ZREMCDBASELIST").contains("ZSMARTLISTTYPE"))
    }
    @Test func writeIsRejected() throws {
        let dir = try FixtureDB.tempStore { try FixtureDB.createRemindersSchema($0) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        #expect(throws: (any Error).self) {
            try store.queue.write { try $0.execute(sql: "INSERT INTO ZREMCDHASHTAGLABEL(ZNAME) VALUES('x')") }
        }
    }
}
```

- [ ] **Step 3: Implement Row.swift + RemindersStore.swift**

```swift
// Row.swift
import GRDB
import Foundation

/// Tolerant column access mirroring Python `_row_get` (optional) vs subscript (required).
/// GRDB's Row already supports `row["COL"]` with DatabaseValueConvertible; we wrap for clarity.
public protocol ReminderRow {
    func has(_ key: String) -> Bool
    func string(_ key: String) -> String?
    func int(_ key: String) -> Int?
    func double(_ key: String) -> Double?
    func data(_ key: String) -> Data?
}

extension GRDB.Row: ReminderRow {
    public func has(_ key: String) -> Bool { index(forColumn: key) != nil }
    public func string(_ key: String) -> String? { has(key) ? self[key] : nil }
    public func int(_ key: String) -> Int? { has(key) ? self[key] : nil }
    public func double(_ key: String) -> Double? { has(key) ? self[key] : nil }
    public func data(_ key: String) -> Data? { has(key) ? self[key] : nil }
}
```

```swift
// RemindersStore.swift
import GRDB
import Foundation

public final class RemindersStore {
    public let queue: DatabaseQueue
    public let path: URL
    private var columnCache: [String: Set<String>] = [:]

    private init(queue: DatabaseQueue, path: URL) { self.queue = queue; self.path = path }

    public static func open(storeDir: URL = Paths.resolveStoreDir()) throws -> RemindersStore {
        let dbPath = try Paths.findMainDB(storeDir: storeDir)
        var config = Configuration()
        config.readonly = true   // SQLITE_OPEN_READONLY, equivalent to ?mode=ro; no WAL change
        let q = try DatabaseQueue(path: dbPath.path, configuration: config)
        return RemindersStore(queue: q, path: dbPath)
    }

    public func tableColumnNames(_ table: String) -> Set<String> {
        if let c = columnCache[table] { return c }
        let cols = (try? queue.read { db in try Set(db.columns(in: table).map(\.name)) }) ?? []
        columnCache[table] = cols
        return cols
    }
    public func reminderHasColumn(_ col: String) -> Bool {
        tableColumnNames("ZREMCDREMINDER").contains(col)
    }
}
```

> Note: GRDB `DatabaseQueue` does not force WAL; with `readonly` it cannot alter journal mode, matching Python's `?mode=ro` (no WAL/immutable). Each command opens one `RemindersStore` (one connection) — matches `open_db()` per-invocation.

- [ ] **Step 4: Run → PASS**
- [ ] **Step 5: Commit** — `git commit -m "Phase 1: GRDB read-only Store + FixtureDB + column probing"`

---

## Task 8: Store — Z_ENT constants + rem_cols builder

Build the exact aliased reminder SELECT column string (incl. the 11 recurrence correlated subqueries), with dynamic fallbacks for optional columns. Source: `remctl rem_cols` (~1260-1267), `_RECURRENCE_COLS`, `urgent_column_expr`, `due_date_delta_alerts_expr`, `display_due_expr`, `due_expr`.

**Files:**
- Create: `Sources/RemindersControl/Store/Schema.swift`
- Test: `StoreTests.swift` (suite `RemColsTests`)

- [ ] **Step 1: Failing test** — assert the produced SQL contains the exact aliases.

```swift
@Suite struct RemColsTests {
    @Test func remColsHasExactAliases() throws {
        let dir = try FixtureDB.tempStore { try FixtureDB.createRemindersSchema($0) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        let cols = store.remCols()
        #expect(cols.contains("r.ZDUEDATE AS ZDUEDATE"))
        #expect(cols.contains("l.ZNAME as list_name"))
        #expect(cols.contains("AS recurrence_frequency"))
        #expect(cols.contains("AS recurrence_set_positions"))
        #expect(cols.contains("AS ZISURGENTSTATEENABLEDFORCURRENTUSER"))
    }
    @Test func urgentFallsBackToZeroWhenColumnMissing() throws {
        // schema without the urgent column -> expr is literal '0'
        let dir = try FixtureDB.tempStore { db in
            try db.execute(sql: "CREATE TABLE ZREMCDREMINDER (Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZNOTES TEXT, ZCOMPLETED INTEGER, ZFLAGGED INTEGER, ZPRIORITY INTEGER, ZDUEDATE REAL, ZALLDAY INTEGER, ZCOMPLETIONDATE REAL, ZCREATIONDATE REAL, ZPARENTREMINDER INTEGER, ZLIST INTEGER, ZICSURL TEXT, ZCKIDENTIFIER TEXT, ZMARKEDFORDELETION INTEGER, ZACCOUNT INTEGER); CREATE TABLE ZREMCDBASELIST (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT); CREATE TABLE ZREMCDOBJECT (Z_PK INTEGER PRIMARY KEY);")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try RemindersStore.open(storeDir: dir)
        #expect(store.remCols().contains("0 AS ZISURGENTSTATEENABLEDFORCURRENTUSER"))
    }
}
```

- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement**

```swift
import Foundation

public enum Zent {
    public static let list = 3, smartList = 4, alarm = 15, recurrence = 34
}

extension RemindersStore {
    func urgentColumnExpr(_ alias: String = "r") -> String {
        reminderHasColumn("ZISURGENTSTATEENABLEDFORCURRENTUSER")
            ? "\(alias).ZISURGENTSTATEENABLEDFORCURRENTUSER" : "0"
    }
    func urgentWhereClause(_ alias: String = "r") -> String {
        reminderHasColumn("ZISURGENTSTATEENABLEDFORCURRENTUSER")
            ? "\(alias).ZISURGENTSTATEENABLEDFORCURRENTUSER = 1" : "0 = 1"
    }
    func dueDateDeltaAlertsExpr(_ alias: String = "r") -> String {
        reminderHasColumn("ZDUEDATEDELTAALERTSDATA") ? "\(alias).ZDUEDATEDELTAALERTSDATA" : "NULL"
    }
    func displayDueExpr(_ alias: String = "r") -> String {
        reminderHasColumn("ZDISPLAYDATEDATE") ? "\(alias).ZDISPLAYDATEDATE" : "NULL"
    }

    /// 11 correlated subqueries on ZREMCDOBJECT (Z_ENT=34, FK ZREMINDER4).
    var recurrenceCols: String {
        let pairs: [(String,String)] = [
            ("ZFREQUENCY","recurrence_frequency"), ("ZINTERVAL","recurrence_interval"),
            ("ZOCCURRENCECOUNT","recurrence_count"), ("ZENDDATE","recurrence_end_date"),
            ("ZDAYSOFTHEWEEK","recurrence_days_of_week"), ("ZDAYSOFTHEMONTH","recurrence_days_of_month"),
            ("ZMONTHSOFTHEYEAR","recurrence_months_of_year"), ("ZDAYSOFTHEYEAR","recurrence_days_of_year"),
            ("ZWEEKSOFTHEYEAR","recurrence_weeks_of_year"), ("ZSETPOSITIONS","recurrence_set_positions"),
        ]
        return pairs.map { col, alias in
            "(SELECT rr.\(col) FROM ZREMCDOBJECT rr WHERE rr.ZREMINDER4 = r.Z_PK AND rr.ZMARKEDFORDELETION = 0 AND rr.Z_ENT = \(Zent.recurrence) ORDER BY rr.Z_PK LIMIT 1) AS \(alias)"
        }.joined(separator: ", ")
    }

    public func remCols() -> String {
        """
        r.Z_PK, r.ZTITLE, r.ZNOTES, r.ZCOMPLETED, r.ZFLAGGED, r.ZPRIORITY, \
        \(urgentColumnExpr()) AS ZISURGENTSTATEENABLEDFORCURRENTUSER, \
        \(dueDateDeltaAlertsExpr()) AS ZDUEDATEDELTAALERTSDATA, \
        r.ZDUEDATE AS ZDUEDATE, \(displayDueExpr()) AS ZDISPLAYDATEDATE, \
        r.ZALLDAY, r.ZCOMPLETIONDATE, r.ZCREATIONDATE, r.ZPARENTREMINDER, r.ZLIST, \
        r.ZICSURL, r.ZCKIDENTIFIER, l.ZNAME as list_name, \(recurrenceCols)
        """
    }
}
```

> The interval count subquery alias is `recurrence_interval` (Python aliases `ZINTERVAL`→`recurrence_interval`). Note `ZOCCURRENCECOUNT`→`recurrence_count` and `ZENDDATE`→`recurrence_end_date`. Cross-check `_RECURRENCE_COLS` in source.

- [ ] **Step 4: Run → PASS**
- [ ] **Step 5: Commit** — `git commit -m "Phase 1: Store Z_ENT + rem_cols builder"`

---

## Task 9: Serialization — recurrence + early-reminder helpers

Port `recurrence_from_row` and `due_date_delta_alerts_from_row` (`remctl_serialization.py`), producing ordered `JSONValue.object` fragments. Source key orders are in the Serialization recon and contract §"40 / Shared modules".

**Files:**
- Create: `Sources/RemindersControl/Serialization/ReminderSerializer.swift` (start)
- Test: `tests/RemindersControlTests/SerializerTests.swift` (suite `RecurrenceTests`)

- [ ] **Step 1: Failing tests** (from oracle: weekly Mon/Wed; early reminder count -15 unit 0)

```swift
@Suite struct RecurrenceTests {
    @Test func weeklyMonWed() {
        // daysOfWeek detailed list -> daysOfWeekDetailed (raw) + daysOfWeek [2,4]
        let row = DictRow([
            "recurrence_frequency": 1, "recurrence_interval": 1,
            "recurrence_days_of_week": #"[{"weekNumber":0,"dayOfTheWeek":2},{"weekNumber":0,"dayOfTheWeek":4}]"#,
        ])
        let rec = recurrenceFromRow(row, ts: { AppleEpoch.ts($0) })!
        // serialize to compact to assert order+content
        let s = JSONValue.object(rec).serialized(indent: nil, ensureAscii: true)
        #expect(s == #"{"frequency": "weekly", "interval": 1, "daysOfWeekDetailed": [{"weekNumber": 0, "dayOfTheWeek": 2}, {"weekNumber": 0, "dayOfTheWeek": 4}], "daysOfWeek": [2, 4]}"#)
    }
    @Test func earlyReminderBeforeLabel() {
        let row = DictRow(["ZDUEDATEDELTAALERTSDATA":
            #"{"dueDateDeltaAlerts":[{"dueDateDeltaUnit":0,"dueDateDeltaCount":-15,"identifier":"DELTA-1"}]}"#])
        let alerts = dueDateDeltaAlertsFromRow(row, ts: { AppleEpoch.ts($0) })
        #expect(alerts.count == 1)
        let s = JSONValue.object(alerts[0]).serialized(indent: nil, ensureAscii: true)
        #expect(s == #"{"unit": "minutes", "unitCode": 0, "count": -15, "value": 15, "direction": "before", "label": "15 minutes before", "identifier": "DELTA-1"}"#)
    }
    @Test func noRecurrenceWhenFrequencyMissing() {
        #expect(recurrenceFromRow(DictRow([:]), ts: { AppleEpoch.ts($0) }) == nil)
    }
}
```
(Provide `DictRow: ReminderRow` in `Support/` — a dictionary-backed row for unit tests; JSON blob columns stored as the raw string.)

- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement** (exact key order per Serialization recon)

```swift
import Foundation

/// Lenient JSON blob parse mirroring `_json_blob`: nil/"" -> nil; bytes utf8-replace; invalid -> nil.
func jsonBlob(_ value: Any?) -> Any? {
    let data: Data
    if let s = value as? String {
        if s.isEmpty { return nil }
        data = Data(s.utf8)
    } else if let d = value as? Data {
        if d.isEmpty { return nil }
        data = d
    } else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

public func recurrenceFromRow(_ row: ReminderRow, ts: (Double) -> String?) -> [(String, JSONValue)]? {
    guard let freqRaw = row.int("recurrence_frequency"),
          let freqName = Constants.recurrenceFrequencies[freqRaw] else { return nil }
    let interval = (row.int("recurrence_interval") ?? 0) == 0 ? 1 : row.int("recurrence_interval")!
    var out: [(String, JSONValue)] = [("frequency", .string(freqName)), ("interval", .int(interval))]

    if let daysRaw = jsonBlob(row.string("recurrence_days_of_week")) as? [Any], !daysRaw.isEmpty {
        out.append(("daysOfWeekDetailed", JSONValue.fromAny(daysRaw)))
        let nums = daysRaw.compactMap { ($0 as? [String: Any])?["dayOfTheWeek"] as? Int }
            .filter { $0 != 0 }
        out.append(("daysOfWeek", .array(nums.map { .int($0) })))
    }
    for (alias, key) in [("recurrence_days_of_month","daysOfMonth"),
                         ("recurrence_months_of_year","monthsOfYear"),
                         ("recurrence_days_of_year","daysOfYear"),
                         ("recurrence_weeks_of_year","weeksOfYear"),
                         ("recurrence_set_positions","setPositions")] {
        if let v = jsonBlob(row.string(alias)), !(isEmptyJSON(v)) {
            out.append((key, JSONValue.fromAny(v)))
        }
    }
    if let count = row.int("recurrence_count"), count != 0 { out.append(("count", .int(count))) }
    if let end = row.double("recurrence_end_date"), end != 0, let iso = ts(end) {
        out.append(("endDate", .string(iso)))
    }
    return out
}

public func dueDateDeltaAlertsFromRow(_ row: ReminderRow, ts: (Double) -> String?) -> [[(String, JSONValue)]] {
    guard let payload = jsonBlob(row.string("ZDUEDATEDELTAALERTSDATA")) as? [String: Any],
          let alerts = payload["dueDateDeltaAlerts"] as? [Any] else { return [] }
    var result: [[(String, JSONValue)]] = []
    for case let alert as [String: Any] in alerts {
        guard let unitRaw = (alert["dueDateDeltaUnit"] as? NSNumber)?.intValue,
              let count = (alert["dueDateDeltaCount"] as? NSNumber)?.intValue else { continue }
        let (singular, plural) = Constants.dueDateDeltaUnits[unitRaw] ?? ("unknown","unknown")
        let value = abs(count)
        let unitName = value == 1 ? singular : plural
        let direction = count < 0 ? "before" : "after"
        var item: [(String, JSONValue)] = [
            ("unit", .string(unitName)), ("unitCode", .int(unitRaw)), ("count", .int(count)),
            ("value", .int(value)), ("direction", .string(direction)),
            ("label", .string("\(value) \(unitName) \(direction)")),
        ]
        if let id = alert["identifier"] as? String, !id.isEmpty { item.append(("identifier", .string(id))) }
        if let cd = alert["creationDate"] as? NSNumber, let iso = ts(cd.doubleValue) {
            item.append(("creationDate", .string(iso)))
        }
        if let mv = alert["minimumSupportedAppVersion"] as? NSNumber {
            item.append(("minimumSupportedAppVersion", .int(mv.intValue)))
        }
        result.append(item)
    }
    return result
}
```

Add helpers `JSONValue.fromAny(_:)` (converts a `JSONSerialization` object preserving array/object structure; for objects, **preserve insertion order via JSONSerialization? No** — `JSONSerialization` loses dict order. For `daysOfWeekDetailed` the inner objects are tiny; reproduce their key order from the source blob. Since the raw blob is the source, parse it with an order-preserving parser OR, for the tested shape `{weekNumber, dayOfTheWeek}`, reconstruct in that fixed order.). Implementer: add a tiny order-preserving JSON parse for blob passthrough, or special-case the known keys. Document the choice. And `isEmptyJSON(_:)` (true for empty array/dict/`""`).

> Subtlety: `daysOfWeekDetailed`/`daysOfMonth`/etc. pass through the *raw parsed JSON* and must preserve element/key order. `JSONSerialization` does not preserve object key order. Use an order-preserving parser for blob passthrough (small helper) so nested objects serialize in source order. Add `OrderedJSON.parse(Data) -> JSONValue` and use it for blob passthrough fields; the test above pins `{"weekNumber":0,"dayOfTheWeek":2}` order.

- [ ] **Step 4: Run → PASS** (add `OrderedJSON` parser as needed)
- [ ] **Step 5: Commit** — `git commit -m "Phase 1: recurrence + early-reminder serialization"`

---

## Task 10: Serialization — serializeReminder / serializeReminders / preloadExtras

The heart of JSON parity. Port `serialize_reminder` with the exact 9 always-present keys + conditional keys in order. Port `serialize_reminders` + `preload_extras` (batch). Source: `remctl_serialization.py:167-260`, oracle `test_cli.py:3609-3962`.

**Files:**
- Modify: `Sources/RemindersControl/Serialization/ReminderSerializer.swift`
- Create: `Sources/RemindersControl/Store/Queries+Extras.swift` (preloadExtras stub here or T13; place `preloadExtras` here)
- Test: `SerializerTests.swift` (suite `ReminderSerializerTests`)

- [ ] **Step 1: Failing tests** (port the oracle's serializer assertions)

```swift
@Suite struct ReminderSerializerTests {
    // Mirrors test_flagged_and_urgent_reminders_show_distinct_symbols_and_serialize
    @Test func baseKeysAndOrder() {
        let row = DictRow([
            "Z_PK": 42, "ZTITLE": "Urgent flagged", "list_name": "Work",
            "ZCOMPLETED": 0, "ZFLAGGED": 1, "ZISURGENTSTATEENABLEDFORCURRENTUSER": 1,
            "ZPRIORITY": 0, "ZPARENTREMINDER": 0, "ZCKIDENTIFIER": "ABC", "ZALLDAY": nil,
        ])
        let obj = serializeReminder(row, ts: { AppleEpoch.ts($0) },
            priorityNames: Constants.priorityName, subtaskCounts: [42:0], hashtags: [:])
        let s = JSONValue.object(obj).serialized(indent: 2, ensureAscii: true)
        #expect(s == """
        {
          "id": 42,
          "title": "Urgent flagged",
          "list": "Work",
          "completed": false,
          "flagged": true,
          "urgent": true,
          "priority": "none",
          "subtaskCount": 0,
          "isSubtask": false,
          "deepLink": "x-apple-reminderkit://REMCDReminder/ABC"
        }
        """)
    }

    // Mirrors test_info_json_keeps_due_date_separate_from_display_alarm_date
    @Test func dueAndDisplayDateAndAllDay() {
        let cal = romeCalendar()
        let row = DictRow([
            "Z_PK": 1, "ZTITLE": "x", "list_name": "L", "ZCOMPLETED": 0, "ZFLAGGED": 0,
            "ZPRIORITY": 0, "ZPARENTREMINDER": 0, "ZDUEDATE": 801216000.0,
            "ZDISPLAYDATEDATE": 801215100.0, "ZALLDAY": 0,
        ])
        let obj = serializeReminder(row, ts: { AppleEpoch.ts($0, calendar: cal) },
            priorityNames: Constants.priorityName, subtaskCounts: [:], hashtags: [:])
        let d = Dictionary(uniqueKeysWithValues: obj.map { ($0.0, $0.1) })
        #expect(d["dueDate"]?.asString == "2026-05-23T10:00:00")
        #expect(d["displayDate"]?.asString == "2026-05-23T09:45:00")
        #expect(d["allDay"]?.asBool == false)
    }
}
```
(Add `JSONValue.asString/asBool` test helpers and `romeCalendar()`.)

- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement** (exact conditional order: section, notes, url, dueDate, displayDate, allDay, createdDate, completionDate, parentID, tags, recurrence, earlyReminder, earlyReminders, deepLink)

```swift
public func serializeReminder(
    _ row: ReminderRow,
    ts: (Double) -> String?,
    priorityNames: [Int: String],
    section: String? = nil,
    subtaskCounts: [Int: Int] = [:],
    hashtags: [Int: [String]] = [:],
    richLink: (() -> String?)? = nil,
    fallbackSubtaskCount: (() -> Int)? = nil,
    fallbackHashtags: (() -> [String])? = nil
) -> [(String, JSONValue)] {
    let pk = row.int("Z_PK") ?? 0
    let subtaskCount = subtaskCounts[pk] ?? fallbackSubtaskCount?() ?? 0
    let tags = hashtags[pk] ?? fallbackHashtags?() ?? []

    var o: [(String, JSONValue)] = [
        ("id", .int(pk)),
        ("title", row.string("ZTITLE").map { .string($0) } ?? .null),
        ("list", row.string("list_name").map { .string($0) } ?? .null),
        ("completed", .bool((row.int("ZCOMPLETED") ?? 0) != 0)),
        ("flagged", .bool((row.int("ZFLAGGED") ?? 0) != 0)),
        ("urgent", .bool((row.int("ZISURGENTSTATEENABLEDFORCURRENTUSER") ?? 0) != 0)),
        ("priority", .string(priorityNames[row.int("ZPRIORITY") ?? 0] ?? "none")),
        ("subtaskCount", .int(subtaskCount)),
        ("isSubtask", .bool((row.int("ZPARENTREMINDER") ?? 0) != 0)),
    ]
    if let section { o.append(("section", .string(section))) }
    if let notes = row.string("ZNOTES"), !notes.isEmpty { o.append(("notes", .string(notes))) }
    var url = row.string("ZICSURL")
    if (url == nil || url!.isEmpty), let r = richLink?() { url = r }
    if let url, !url.isEmpty { o.append(("url", .string(url))) }
    if let due = row.double("ZDUEDATE"), due != 0, let iso = ts(due) { o.append(("dueDate", .string(iso))) }
    if let disp = row.double("ZDISPLAYDATEDATE"), disp != 0, disp != row.double("ZDUEDATE"), let iso = ts(disp) {
        o.append(("displayDate", .string(iso)))
    }
    if row.has("ZALLDAY"), let ad = row.int("ZALLDAY") { o.append(("allDay", .bool(ad != 0))) }
    if let c = row.double("ZCREATIONDATE"), c != 0, let iso = ts(c) { o.append(("createdDate", .string(iso))) }
    if let cd = row.double("ZCOMPLETIONDATE"), cd != 0, let iso = ts(cd) { o.append(("completionDate", .string(iso))) }
    if let parent = row.int("ZPARENTREMINDER"), parent != 0 { o.append(("parentID", .int(parent))) }
    if !tags.isEmpty { o.append(("tags", .array(tags.map { .string($0) }))) }
    if let rec = recurrenceFromRow(row, ts: ts) { o.append(("recurrence", .object(rec))) }
    let early = dueDateDeltaAlertsFromRow(row, ts: ts)
    if !early.isEmpty {
        o.append(("earlyReminder", .object(early[0])))
        o.append(("earlyReminders", .array(early.map { .object($0) })))
    }
    if let ck = row.string("ZCKIDENTIFIER"), !ck.isEmpty {
        o.append(("deepLink", .string(Constants.deepLinkReminderPrefix + ck)))
    }
    return o
}
```

`serializeReminders(rows, store, memberships:)`: call `preloadExtras` over `rows` PKs; map each row through `serializeReminder` with `section = memberships[row.string("ZCKIDENTIFIER")]`, preloaded counts/tags, and resolvers bound to the store. Implement `preloadExtras(store, pks) -> (subtaskCounts:[Int:Int], hashtags:[Int:[String]])` with the two batch queries (exact SQL from recon: subtask `GROUP BY ZPARENTREMINDER` filtered `ZMARKEDFORDELETION=0 AND ZCOMPLETED=0`; hashtag join `o.ZREMINDER3 IN (...)`, preserving row order, no dedup).

- [ ] **Step 4: Run → PASS**
- [ ] **Step 5: Commit** — `git commit -m "Phase 1: serializeReminder(s) + preloadExtras"`

---

## Task 11: Store — core reminder queries

`q_reminders`, `q_reminder`, `q_reminder_by_identifier`, `q_subtask_count`. Exact SQL from Store recon. Returns GRDB `Row`s.

**Files:** Create `Sources/RemindersControl/Store/Queries+Reminders.swift`; Test `StoreTests.swift` (suite `ReminderQueryTests`).

- [ ] **Step 1: Failing tests** — insert 2 reminders (one completed, one with parent), assert `q_reminders(topLevel:true)` excludes completed + children; `q_reminder(pk:)` filters deletion/account; `q_subtask_count` counts active children.
- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement** (verbatim WHERE/ORDER/LIMIT)

```swift
extension RemindersStore {
    public func reminders(listPk: Int? = nil, completed: Bool = false,
                          parentPk: Int? = nil, topLevel: Bool = false, limit: Int = 500) -> [Row] {
        var c = ["r.ZMARKEDFORDELETION = 0", "r.ZACCOUNT IS NOT NULL"]
        var args: [DatabaseValueConvertible] = []
        if !completed { c.append("r.ZCOMPLETED = 0") }
        if let listPk { c.append("r.ZLIST = ?"); args.append(listPk) }
        if let parentPk { c.append("r.ZPARENTREMINDER = ?"); args.append(parentPk) }
        else if topLevel { c.append("(r.ZPARENTREMINDER IS NULL OR r.ZPARENTREMINDER = 0)") }
        let sql = "SELECT \(remCols()) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE \(c.joined(separator: " AND ")) ORDER BY r.Z_PK LIMIT ?"
        args.append(limit)
        return (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: StatementArguments(args)) }) ?? []
    }
    public func reminder(pk: Int) -> Row? {
        let sql = "SELECT \(remCols()) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE r.Z_PK = ? AND r.ZMARKEDFORDELETION = 0 AND r.ZACCOUNT IS NOT NULL"
        return try? queue.read { try Row.fetchOne($0, sql: sql, arguments: [pk]) }
    }
    public func reminder(identifier: String) -> Row? {
        guard !identifier.isEmpty else { return nil }
        let sql = "SELECT \(remCols()) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE lower(r.ZCKIDENTIFIER) = lower(?) AND r.ZMARKEDFORDELETION = 0 AND r.ZACCOUNT IS NOT NULL ORDER BY r.Z_PK DESC LIMIT 1"
        return try? queue.read { try Row.fetchOne($0, sql: sql, arguments: [identifier]) }
    }
    public func subtaskCount(pk: Int) -> Int {
        (try? queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ZREMCDREMINDER WHERE ZPARENTREMINDER = ? AND ZMARKEDFORDELETION = 0 AND ZCOMPLETED = 0", arguments: [pk]) }) ?? 0
    }
}
```

- [ ] **Step 4: Run → PASS**  **Step 5: Commit** — `git commit -m "Phase 1: Store core reminder queries"`

---

## Task 12: Store — date-window / search / flagged / urgent queries

`q_search`, `q_due_today`, `q_flagged`, `q_urgent`, `q_upcoming`, `q_overdue`. Bind date thresholds (numerically identical to Python's inlined `to_ts`). Exact LIKE escaping for search. Exact ORDER BY (incl. `NULLS LAST`).

**Files:** Modify `Queries+Reminders.swift`; Test suite `ReadQueryTests`.

- [ ] **Step 1: Failing tests** — search `%` escaping (a literal `%` must not match-all), flagged orders due NULLS LAST, today includes overdue when `includeOverdue`.
- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement**

```swift
extension RemindersStore {
    private func reminderListView(where extra: String, args: [DatabaseValueConvertible], order: String) -> [Row] {
        let sql = "SELECT \(remCols()) FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE \(extra) ORDER BY \(order)"
        return (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: StatementArguments(args)) }) ?? []
    }
    public func search(_ query: String, completed: Bool = false) -> [Row] {
        let safe = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let pat = "%\(safe)%"
        var w = ["r.ZMARKEDFORDELETION = 0", "r.ZACCOUNT IS NOT NULL", "l.Z_PK IS NOT NULL",
                 "(r.ZTITLE LIKE ? ESCAPE '\\' OR r.ZNOTES LIKE ? ESCAPE '\\')"]
        if !completed { w.append("r.ZCOMPLETED = 0") }
        return reminderListView(where: w.joined(separator: " AND "), args: [pat, pat],
                                order: "r.Z_PK DESC LIMIT 100")
    }
    public func dueToday(includeOverdue: Bool = true, now: Date = Date()) -> [Row] {
        let (sod, eod) = DateWindows.dueTodayWindow(now)
        let w: String
        if includeOverdue { w = "r.ZDUEDATE < \(AppleEpoch.toTs(eod)) AND r.ZDUEDATE IS NOT NULL" }
        else { w = "r.ZDUEDATE >= \(AppleEpoch.toTs(sod)) AND r.ZDUEDATE < \(AppleEpoch.toTs(eod))" }
        return reminderListView(where: "r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND \(w)", args: [], order: "r.ZDUEDATE")
    }
    public func upcoming(days: Int = 7, now: Date = Date()) -> [Row] {
        let (sod, future) = DateWindows.upcomingWindow(days: days, now: now)
        return reminderListView(where: "r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND r.ZDUEDATE IS NOT NULL AND r.ZDUEDATE >= \(AppleEpoch.toTs(sod)) AND r.ZDUEDATE < \(AppleEpoch.toTs(future))", args: [], order: "r.ZDUEDATE")
    }
    public func overdue(now: Date = Date()) -> [Row] {
        let sod = DateWindows.startOfDay(now)
        return reminderListView(where: "r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND r.ZDUEDATE IS NOT NULL AND r.ZDUEDATE < \(AppleEpoch.toTs(sod))", args: [], order: "r.ZDUEDATE")
    }
    public func flagged() -> [Row] {
        reminderListView(where: "r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND r.ZFLAGGED = 1", args: [], order: "r.ZDUEDATE NULLS LAST")
    }
    public func urgent() -> [Row] {
        reminderListView(where: "r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND \(urgentWhereClause())", args: [], order: "r.ZDUEDATE NULLS LAST")
    }
}
```

> Inlining `AppleEpoch.toTs(...)` as a numeric literal in the SQL string matches Python's f-string inlining. `Double` interpolation in Swift produces a decimal literal SQLite parses identically; results are numeric comparisons so format differences are immaterial.

- [ ] **Step 4: Run → PASS**  **Step 5: Commit** — `git commit -m "Phase 1: Store read-command queries"`

---

## Task 13: Store — extras queries (hashtags, rich link, attachments, alarms)

`q_hashtags`, `q_rich_link(s)`, `q_attachments` (UNION ALL), `q_alarms` (self-join Z_ENT=15). Exact SQL from Store/show recon.

**Files:** Modify `Queries+Extras.swift`; Test suite `ExtrasQueryTests`.

- [ ] **Step 1–5:** TDD each: insert ZREMCDOBJECT/ZREMCDHASHTAGLABEL/ZREMCDSAVEDATTACHMENT rows, assert returned values + order. Implement verbatim:

```swift
extension RemindersStore {
    public func hashtags(pk: Int) -> [String] {
        (try? queue.read { try String.fetchAll($0, sql: "SELECT h.ZNAME FROM ZREMCDOBJECT o JOIN ZREMCDHASHTAGLABEL h ON o.ZHASHTAGLABEL = h.Z_PK WHERE o.ZREMINDER3 = ?", arguments: [pk]) }) ?? []
    }
    public func richLink(pk: Int) -> String? {
        try? queue.read { try String.fetchOne($0, sql: "SELECT ZURL FROM ZREMCDOBJECT WHERE ZREMINDER2 = ? AND ZURL IS NOT NULL AND ZURL != '' AND ZMARKEDFORDELETION = 0 ORDER BY Z_PK", arguments: [pk]) }
    }
    public func attachments(pk: Int) -> [Row] {
        let sql = "SELECT ZFILENAME, ZUTI, ZATTACHMENTTYPERAWVALUE FROM ZREMCDSAVEDATTACHMENT WHERE ZREMINDER = ? AND ZMARKEDFORDELETION = 0 UNION ALL SELECT ZFILENAME, ZUTI, CASE WHEN ZWIDTH IS NOT NULL OR ZHEIGHT IS NOT NULL THEN 'image' ELSE 'file' END AS ZATTACHMENTTYPERAWVALUE FROM ZREMCDOBJECT WHERE ZREMINDER2 = ? AND ZFILENAME IS NOT NULL AND ZFILENAME != '' AND ZMARKEDFORDELETION = 0 ORDER BY ZFILENAME"
        return (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: [pk, pk]) }) ?? []
    }
    public func alarms(pk: Int) -> [Row] {
        let sql = "SELECT a.Z_PK AS alarm_id, a.ZTRIGGER AS trigger_id, t.Z_ENT AS trigger_entity, t.ZTIMEINTERVAL AS time_interval, t.ZDATECOMPONENTSDATA AS date_components, t.ZTITLE AS location_title, t.ZLATITUDE AS latitude, t.ZLONGITUDE AS longitude, t.ZRADIUS AS radius, t.ZADDRESS AS address, t.ZPROXIMITY AS proximity FROM ZREMCDOBJECT a LEFT JOIN ZREMCDOBJECT t ON a.ZTRIGGER = t.Z_PK WHERE a.ZREMINDER = ? AND a.Z_ENT = \(Zent.alarm) AND a.ZMARKEDFORDELETION = 0 AND (t.Z_PK IS NULL OR t.ZMARKEDFORDELETION = 0) ORDER BY a.Z_PK"
        return (try? queue.read { try Row.fetchAll($0, sql: sql, arguments: [pk]) }) ?? []
    }
}
```

- **Commit** — `git commit -m "Phase 1: Store extras queries"`

---

## Task 14: Output — fmt / fmtDue / recurrenceSummary / list coloring

Port `fmt` (single reminder line + verbose lines), `fmt_due`, `recurrence_summary`/`recurrence_badge`, `color_list_name`/`color_by_list`, `reminder_id_text`, and the priority/state-marker helpers. These render BOTH from serialized dicts (camelCase) and raw rows — for Phase 1, render from the **serialized `[(String,JSONValue)]`** (commands already serialize), simplifying. Source: Output recon.

**Files:** Create `Sources/RemindersControl/Output/ReminderFormat.swift`; Test suite `ReminderFormatTests`.

- [ ] **Step 1: Failing tests** (uncolored; oracle: weekly Mon, Wed badge; urgent⏰ before flagged⚑; fmt_due strings)

```swift
@Suite struct ReminderFormatTests {
    let a = Ansi(enabled: false)
    @Test func lineWithMarkersAndPriority() {
        let r = SerializedReminder(id: 42, title: "Urgent flagged", listName: "Work",
            completed: false, flagged: true, urgent: true, priority: "none")
        #expect(fmt(r, ansi: a, indent: "  ") == "  [ ] #42 ⏰ ⚑ Urgent flagged")
    }
    @Test func recurrenceSummaryWeeklyDays() {
        #expect(recurrenceSummary(frequency: "weekly", interval: 1, daysOfWeek: [2,4], daysOfMonth: nil, count: nil, endDate: nil) == "weekly Mon, Wed")
    }
}
```
(Define a `SerializedReminder` view-struct, or read fields from the `[(String,JSONValue)]`. Implementer picks; keep it test-friendly.)

- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement** per Output recon §`fmt`, §`fmt_due`, §`recurrence_summary`. Key rules:
  - status `[x]`(green)/`[ ]`(dim); id `#<id>` via colorByList; priority marker (1→red`!!!`,5→yellow`!!`,9→green`!`); markers urgent`⏰`(red) before flagged`⚑`(yellow); title `safeDisplay(title || "(untitled)")` (completed → dim+strikethrough); due suffix; recurrence badge `↻ {summary}`(magenta); tags ` #tag`; subtasks ` [N subtask(s)]`.
  - `fmtDue`: `(today HH:MM)`/`(today)`/`(tomorrow)`/red`(overdue Nd)`/`(YYYY-MM-DD)`.
  - `recurrenceSummary`: interval==1→bare word; else `every N plural`; weekly+days→` `+`, `-joined day names; monthly+daysOfMonth→` on `+csv; count→` x{count}` elif endDate→` until {endDate[:10]}`.
  - `colorListName`/`colorByList`: RGB from `Constants.listColorMap` (resolved via list-color cache, see T24) else cyan; disabled→plain `safeDisplay`.
- [ ] **Step 4: Run → PASS**  **Step 5: Commit** — `git commit -m "Phase 1: Output reminder line formatter"`

---

## Task 15: Output — fmtTable / remindersToTableData

Port the Unicode box table (`fmt_table`) and `reminders_to_table_data` (table-specific due strings, marker-prefixed title). Width math: columns ID|Title|List|Due|[Repeat]|Pri; visible-length via ANSI strip; title cap `max(10, width - fixed)`; truncate `…`. Source: Output recon §`fmt_table`/§`reminders_to_table_data`.

**Files:** Create `Sources/RemindersControl/Output/Table.swift`; Test suite `TableTests`.

- [ ] **Step 1: Failing test** — fixed width (pass `maxWidth: 80`), assert the box-drawing characters and a known row layout for a single reminder (uncolored). Assert empty rows → `""`.
- [ ] **Step 2–4:** Implement; tie width to a passed-in `maxWidth` (default: `COLUMNS` env / ioctl / 80) so tests are deterministic.
- [ ] **Step 5: Commit** — `git commit -m "Phase 1: Output box table"`

---

## Task 16: Commands — output option groups, format resolution, dispatch helpers

Replace the Phase-0 single `JSONOptions` with proper per-command groups and shared helpers: `runRead` (acquires store, maps `RemindersDBUnavailable`/other errors → stderr `Error: <msg>` + `exit(1)`), `printJSON`, and `Ansi` resolution. Add the CLI black-box test runner.

**Files:**
- Create: `Sources/RemindersControl/Commands/Support/OutputOptions.swift`
- Modify: `Sources/RemindersControl/GlobalOptions.swift`
- Create: `tests/RemindersControlTests/Support/CLIRunner.swift`
- Test: existing `CommandTreeTests` still green; new `DispatchTests`.

- [ ] **Step 1: Implement option groups & helpers**

```swift
import ArgumentParser
import Foundation

enum OutputFormat: String, ExpressibleByArgument, CaseIterable { case plain, table, json }

/// Commands with --json + --format + --verbose + --no-color (today/upcoming/overdue/flagged/urgent/search/show).
struct ReadDisplayOptions: ParsableArguments {
    @Flag(name: .long) var json = false
    @Option(name: .long) var format: OutputFormat?
    @Flag(name: [.short, .long]) var verbose = false
    @Flag(name: .long) var noColor = false

    /// Resolution: --format json forces json; --json beats --format table.
    var effectiveJSON: Bool { json || format == .json }
    var useTable: Bool { !effectiveJSON && format == .table }
    func ansi() -> Ansi { Ansi.resolve(noColorFlag: noColor) }
}

/// Commands with only --json (+ --no-color where they color): tags/sections/stats/subtasks/smart-lists/templates/list-symbols.
struct JSONOnlyOptions: ParsableArguments {
    @Flag(name: .long) var json = false
    @Flag(name: .long) var noColor = false
    func ansi() -> Ansi { Ansi.resolve(noColorFlag: noColor) }
}

enum Dispatch {
    /// Acquire store; on RemindersDBUnavailable or other errors -> stderr "Error: <msg>", exit 1.
    static func runRead(_ body: (RemindersStore) throws -> Void) {
        do {
            let store = try RemindersStore.open()
            try body(store)
        } catch let e as RemindersDBUnavailable {
            FileHandle.standardError.write(Data("Error: \(e.message)\n".utf8)); exit(1)
        } catch let e as CLIError {
            FileHandle.standardError.write(Data("Error: \(e.message)\n".utf8)); exit(1)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8)); exit(1)
        }
    }
    static func printJSON(_ v: JSONValue, indent: Int? = 2, ensureAscii: Bool) {
        print(v.serialized(indent: indent, ensureAscii: ensureAscii))
    }
}

/// Command-level validation error -> "Error: <message>" exit 1.
struct CLIError: Error { let message: String; init(_ m: String) { message = m } }
```

> `runRead` opens the store once. Commands that don't need the DB (list-symbols) won't call it. The `exit(1)` here reproduces `run_handler_with_fallback`. For ArgumentParser `--version`/`--help`/bad-choice, ArgumentParser already exits 2 — leave that to the framework (matches Python argparse exit 2).

- [ ] **Step 2: CLIRunner** (black-box helper)

```swift
import Foundation

enum CLIRunner {
    /// Path to the built remctl binary in the test bundle's build dir.
    static func binaryURL() -> URL {
        // .build/debug/remctl relative to package; resolve via env or known path.
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent() // -> package root
        return base.appendingPathComponent(".build/debug/remctl")
    }
    struct Result { let stdout: String; let stderr: String; let exit: Int32 }
    static func run(_ args: [String], storeDir: URL, extraEnv: [String:String] = [:]) throws -> Result {
        let p = Process()
        p.executableURL = binaryURL()
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["REMCTL_STORE_DIR"] = storeDir.path
        env["NO_COLOR"] = "1"
        extraEnv.forEach { env[$0] = $1 }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run(); p.waitUntilExit()
        return Result(
            stdout: String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            exit: p.terminationStatus)
    }
}
```

> CLI tests must run after `swift build`. Add a note in the suite: these require the debug binary built (the test process triggers `swift build` of the executable as a dependency in SwiftPM, so `.build/debug/remctl` exists when tests run). If resolution proves fragile, fall back to invoking via `swift run remctl` — but prefer the built path for speed.

- [ ] **Step 3:** Update Phase-0 stubs that used `@OptionGroup var output: JSONOptions` — leave them; T17+ replaces per command. Keep `CommandTreeTests` green (45 commands still register). Remove `JSONOptions` only once all readers migrated (or keep it for the not-yet-Phase-1 write/ops stubs). **Decision:** keep `JSONOptions` for write/ops stubs; read commands switch to the new groups in their tasks.
- [ ] **Step 4: Run** `swift test --filter CommandTreeTests` → PASS (still 45).
- [ ] **Step 5: Commit** — `git commit -m "Phase 1: command output options + dispatch helpers + CLI runner"`

---

# READ COMMANDS — set 1 (T17–T23)

> Each command task: (1) write a black-box CLI test (build a fixture, run binary, assert stdout/exit) + a unit test if the human format is intricate; (2) implement the command `run()`; (3) verify. Empty-result, JSON, and (where applicable) human + table paths each get an assertion.

## Task 17: Command — today / upcoming / overdue

Wire all three. Shared serialize→JSON; per-command human grouping; `--format table`; `upcoming` days validation (1–3650, **before** DB open); empty strings exact. JSON uses `indent=2` (verify ensure_ascii at the call site — these print `json.dumps([...], indent=2)`; confirm whether ensure_ascii is default-True; today recon shows `json.dumps(list, indent=2)` → ensure_ascii **True**. Implementer: verify against `remctl` source line for each; use that value).

**Files:** Modify `Sources/RemindersControl/Commands/ReadCommands.swift`; Test `tests/RemindersControlTests/DateCommandTests.swift`.

- [ ] **Step 1: Failing CLI tests**

```swift
@Suite struct DateCommandTests {
    @Test func todayJSONEmptyIsBracket() throws {
        let dir = try FixtureDB.tempStore { try FixtureDB.createRemindersSchema($0) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["today","--json"], storeDir: dir)
        #expect(r.stdout == "[]\n"); #expect(r.exit == 0)
    }
    @Test func upcomingRejectsNonPositiveDaysBeforeDBRead() throws {
        let dir = try FixtureDB.tempStore { _ in } // empty dir, no tables
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["upcoming","0"], storeDir: dir)
        #expect(r.exit == 1); #expect(r.stderr.contains("between 1 and 3650"))
    }
    @Test func overdueEmptyHuman() throws {
        let dir = try FixtureDB.tempStore { try FixtureDB.createRemindersSchema($0) }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["overdue"], storeDir: dir)
        #expect(r.stdout == "No overdue reminders\n")
    }
}
```

- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement** the three `run()`s. Structure (today shown; upcoming/overdue analogous per recon):

```swift
struct Today: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "today", abstract: "List reminders due today.")
    @OptionGroup var opts: ReadDisplayOptions
    @Flag(name: .long) var noOverdue = false
    func run() throws {
        Dispatch.runRead { store in
            let items = store.dueToday(includeOverdue: !noOverdue)
            let serialized = serializeReminders(items, store: store)
            if opts.effectiveJSON {
                Dispatch.printJSON(.array(serialized.map { .object($0) }), ensureAscii: true); return
            }
            if opts.useTable { print(fmtTable(remindersToTableData(items, store: store, ansi: opts.ansi()))); return }
            // human grouping: split overdue (due < startOfDay) vs due today; headers + "N total"
            renderToday(items, ansi: opts.ansi())
        }
    }
}
```

Implement `renderToday`/`renderUpcoming`/`renderOverdue` per recon's exact strings:
  - today empty → `Nothing due today (YYYY-MM-DD)` (date = now). Else: `Overdue (n):`(red) items indent `  `, blank line, `Due Today (n):`(bold) items, then `\n{total} total`.
  - upcoming empty → `Nothing due in the next {days} days`. Else `Upcoming ({days} days):`(bold), grouped by day (`Today`/`Tomorrow`/`%A, %b %d`), `\n{n} upcoming`.
  - overdue empty → `No overdue reminders`. Else `Overdue (n):`(red+bold), items (verbose if `-v`), `\n{n} overdue`.
Add `Upcoming` days validation in `run()` **before** `Dispatch.runRead`.

- [ ] **Step 4: Run → PASS**  **Step 5: Commit** — `git commit -m "Phase 1: today/upcoming/overdue commands"`

---

## Task 18: Command — flagged / urgent

JSON array (ensure_ascii per source — recon shows `json.dumps([...], indent=2)`; verify). Human: empty → `No flagged reminders`/`No urgent reminders`; else `Flagged:`/`Urgent:`(bold), items indent `  `, `\n{n} flagged`/`\n{n} urgent`. Table path. `-v` affects human only.

**Files:** Modify `ReadCommands.swift`; Test `FlaggedUrgentTests.swift`.

- [ ] TDD: empty human + JSON `[]` + a flagged+urgent row's JSON booleans. Implement both `run()`s (share a helper parameterized by query + labels). Commit `git commit -m "Phase 1: flagged/urgent commands"`.

---

## Task 19: Command — search

Positional `query` (required). Flags `--completed`, `-v`, `--json`, `--format`. JSON array. Human: empty → `No reminders matching '<q>'` (safeDisplay'd); else `Search: <bold q>` + items + `\n{n} result(s)`. LIKE-escape handled in Store (T12).

**Files:** Modify `ReadCommands.swift`; Test `SearchTests.swift`.

- [ ] TDD: literal `%` query does not match-all (insert a reminder, search `%`, assert no match unless title contains `%`); footer pluralization. Commit `git commit -m "Phase 1: search command"`.

---

## Task 20: Command — subtasks

Positional `id` (int Z_PK). `-v` (no-op), `--json`. Not-found → `Error: #<id> not found` exit 1. JSON: parent dict + `subtasks` array (children incl. completed; non-recursive); `json.dumps(d, indent=2)` ensure_ascii **True**. Human: `Parent: <title>`; `  No subtasks` or child lines + `\n{n} subtask(s)`.

**Files:** Modify `ReadCommands.swift`; Test `SubtasksTests.swift`.

- [ ] TDD: not-found error; parent+child JSON (`parentID` on child, parent `subtaskCount` may be < children count). Implement using `store.reminder(pk:)` + `store.reminders(parentPk:completed:true)`. Commit.

---

## Task 21: Command — stats

`--json` only. Five COUNT queries + `completed = total - active` + `len(lists)`/`len(sections)`. JSON key order `total,active,completed,overdue,flagged,urgent,lists,sections` (`indent=2`, ensure_ascii moot). Human: `Reminders Stats`(bold) + the exact label-padded lines (recon §stats has verbatim spacing) with conditional coloring.

**Files:** Modify `Sources/RemindersControl/Commands/ReadCommands.swift`; Test `StatsTests.swift`. (Add `store.countQueries`/`lists()`/`sections()` as needed — `lists()`/`sections()` land in T24/T26; for stats, add minimal count helpers now or depend on T24/T26 ordering. **Sequencing:** implement the 5 COUNTs here; use `store.lists().count`/`store.sections().count` — so schedule T24/T26 lists/sections queries before this, OR add thin count-only helpers. Decision: add `listCount()`/`sectionCount()` thin helpers in this task to avoid coupling.)

- [ ] TDD: JSON key order + values for a small fixture; human spacing for the zero-coloring case (uncolored → `  Overdue:    0`). Commit.

---

## Task 22: Command — tags

`--json` only. SQL `SELECT ZNAME FROM ZREMCDHASHTAGLABEL WHERE ZNAME IS NOT NULL ORDER BY ZNAME`. JSON array of `{"name": ...}` (`indent=2`, ensure_ascii **True**). JSON branch before empty check (empty store → `[]`). Human: empty → `No tags found`; else `Tags:`(bold) + `  #name`(magenta) + `\n{n} tag(s)`.

**Files:** Modify `ReadCommands.swift`; add `store.allTagNames()`; Test `TagsTests.swift`.

- [ ] TDD: empty `[]` (json) vs `No tags found` (human); ordering; footer singular `1 tag`. Commit.

---

## Task 23: Command — sections

`--json` only. SQL `q_sections(list_pk=nil)` (join lists, ORDER BY l.ZNAME, s.Z_PK). JSON **object** keyed by list name (`r.list_name or "?"`), values = arrays of `ZDISPLAYNAME` (raw); `indent=2`, ensure_ascii **True**; empty → `{}`. Human: empty → `No sections found`; grouped headers `{bold colorListName}:` + `  - name` + `\n{n} section(s)`.

**Files:** Modify `ReadCommands.swift`; add `store.sections(listPk:)`; Test `SectionsTests.swift`.

- [ ] TDD: grouped JSON object + empty `{}`; human grouping. Commit.

---

# LISTS (T24–T25)

## Task 24: Serialization+Store — list_to_dict, color/badge parse, q_lists

Port `list_to_dict` (conditional appearance keys), `parse_list_color` (NSKeyedArchiver plist → symbolic name + hex), `parse_badge_emblem`, `grocery_list_payload`, `list_select_columns`, `q_lists`, and the list-color cache (`load_list_colors`). `parse_list_color` uses `PropertyListSerialization` to read the binary plist and walk `$objects` for `ckSymbolicColorName`. Source: `remctl:350-405,458-484,739-...`.

**Files:** Create `Sources/RemindersControl/Serialization/ListSerializer.swift`, `Sources/RemindersControl/Store/Queries+Lists.swift`; Test `ListSerializerTests.swift` + `ListQueryTests.swift`.

- [ ] **Step 1: Failing tests** (from oracle `test_lists_json_reports_grocery_metadata`, `test_list_to_dict_includes_private_appearance_fields`):
  - badge `{"Emoji":"📌"}` → `badge.emoji == "📌"`; bad ZCOLOR blob → `color.hex == "#007AFF"` (default).
  - Groceries list → `listType=="groceries"`, `isGroceries`, `grocery.locale=="en_US"`; Work → `listType=="standard"`, no `grocery` key.
  - `q_lists` order ZNAME (binary), Z_ENT=3 filter, excludes smart lists.
- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement.** `list_to_dict` key order: `id,title,listType,isGroceries,[objectUUID],[color],[badge,badgeEmblem],[grocery],[pinned],[pinnedDate]`. Conditional rules per `lists` recon (column-presence vs truthiness). `parse_list_color`:

```swift
import Foundation

func parseListColor(_ blob: Data?) -> (name: String, hex: String) {
    guard let blob, !blob.isEmpty,
          let plist = try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil),
          let dict = plist as? [String: Any],
          let objects = dict["$objects"] as? [Any] else { return Constants.defaultListColorJSON }
    // find object dict containing "ckSymbolicColorName"; resolve UID -> name; "daHexString" -> hex
    // (walk $objects; CFKeyedArchiverUID resolution — see remctl:350-366)
    // On any failure: return Constants.defaultListColorJSON
    ...
}
```
> NSKeyedArchiver UID resolution: `PropertyListSerialization` represents `$objects` UIDs as `__NSCFType`/`NSKeyedArchiverUID`-like values. Implementer: resolve via the `CFKeyedArchiverUID` integer (use `(value as? NSObject)` introspection or `unarchiveObject`). If robust UID resolution is hard, an acceptable parity fallback: locate the dict with `ckSymbolicColorName`, read its referenced string from `$objects` by integer index. Test pins the **default** path (bad blob → `#007AFF`); add a real-color fixture if a sample blob is available. Flag if a real ZCOLOR sample is needed.

- [ ] **Step 4: Run → PASS**  **Step 5: Commit** — `git commit -m "Phase 1: list serialization + color/badge parse + q_lists"`

---

## Task 25: Command — lists

`--json` + `--format`. JSON array of `list_to_dict` (`indent=2`, ensure_ascii **False**). Human: `Reminder Lists:`(bold); per row `  {coloredName}{ 🥕 if grocery} (id: N){ [k sections]}{ [pinned]}`; `\n{n} list(s)`. Table path (title only). Section counts via `store.sections(listPk:)` (human only). Source: `lists` recon.

**Files:** Modify `Sources/RemindersControl/Commands/ListCommands.swift` (`Lists` struct); Test `ListsCommandTests.swift`.

- [ ] TDD: grocery carrot in human; JSON grocery metadata + absence on standard; `[1 sections]` (always plural word). Commit `git commit -m "Phase 1: lists command"`.

---

# SHOW / INFO (T26–T30)

## Task 26: Store — list resolution + sections + memberships

Port `resolve_list_ref` (4-tier: exact → casefold → normalized `normalize_list_lookup_name` → ambiguity/none), `--list-id` resolution (Z_PK, Z_ENT=3), `q_sections(list_pk)`, `q_section_memberships` (parse `ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA` JSON → memberID→section name), `q_section_member_counts`. Source: Store recon §resolve_list_ref/§q_section_memberships.

**Files:** Modify `Queries+Lists.swift`; Test `ListResolutionTests.swift`.

- [ ] TDD (oracle `test_list_resolution_*`): single normalized match; ambiguous → error payload; by-id includes objectUUID. Implement the cascade + `normalizeListLookupName` (NFKC + casefold + alnum/single-space collapse). Commit.

---

## Task 27: Output — grocery helpers

Port `GROCERY_CATEGORY_EMOJI` (the ~22-entry map — copy verbatim from source), `format_grocery_section_name` (HTML-unescape `&amp;` etc. + strip + emoji prefix), `add_grocery_section_metadata` (adds `sectionEmoji`), `is_grocery_list_row`, `grocery_category_emoji`. Source: `remctl` grocery region (the show recon cites `🥛 Dairy`, `🧻 Household`).

**Files:** Create `Sources/RemindersControl/Output/Grocery.swift`; Test `GroceryTests.swift`.

- [ ] TDD (oracle `test_show_*_grocery_*`): `Dairy, Eggs &amp; Cheese` → heading `[🥛 Dairy, Eggs & Cheese]`; JSON `sectionEmoji=="🥛"`. Copy the emoji map verbatim (cite source line range in a comment). HTML unescape: implement a small entity decoder for at least `&amp; &lt; &gt; &#39; &quot;` (match Python `html.unescape`; if more entities appear, extend). Commit.

---

## Task 28: Command — show

Positional `list` (optional) | `--list-id`; `--completed`, `-v`, `--json`, `--format`. List target resolution (errors: both/neither/not-found/ambiguous, exit 1). Items = top-level for list. JSON **array** of serialized reminders (`indent=2`, ensure_ascii **False**); grocery lists add `sectionEmoji`. Human: heading `{bold colorListName}{ 🥕}`; unsectioned items first, then per-section `  [heading]`(bold, grocery emoji) groups; `\n{n} reminder(s)`; empty → `No [active ]reminders in '<list>'`. Table path. Section membership via T26. Source: show recon.

**Files:** Modify `Sources/RemindersControl/Commands/ReadCommands.swift` (`Show`); Test `ShowCommandTests.swift`.

- [ ] TDD (oracle grocery section tests + empty + resolution errors). Commit `git commit -m "Phase 1: show command"`.

---

## Task 29: Serialization — alarms / attachments / hydrateDetail

Port `alarm_rows_to_json` (relative/absolute/location/unknown), `attachment_rows_to_json`, `_relative_alarm_label`, `_date_components_iso`, and `hydrate_reminder_detail` (adds `attachments`/`alarms`, recursing into subtasks). Source: show recon §info + oracle `test_alarm_rows_serialize_*`.

**Files:** Create `Sources/RemindersControl/Serialization/AlarmAttachment.swift`; Test `AlarmAttachmentTests.swift`.

- [ ] TDD (oracle: relative `relativeOffset=-900, relativeOffsetMinutes=-15, label "15 minutes before due date"`; absolute `date`, `timeZone`; location `proximity "arriving"` proximityCode 1). Implement exact key orders/labels. Commit.

---

## Task 30: Command — info

Positional `id` (int). `--json` only (NO `-v`, NO `--format`). Not-found → `Error: #<id> not found` exit 1. JSON: single hydrated dict (`indent=2`, ensure_ascii **True** — note differs from show) with `attachments`/`alarms`/`subtasks` (subtasks hydrated). Human: full detail block — `Reminder #id` header + label-aligned lines (recon §_print_info_payload has exact spacing). Source: show recon §info.

**Files:** Modify `ReadCommands.swift` (`Info`); Test `InfoCommandTests.swift`.

- [ ] TDD (oracle `test_cmd_info_json_*`): url rich-link fallback + section via memberships; subtask hydration; due/displayDate/allDay. Commit `git commit -m "Phase 1: info command"`.

---

# SMART LISTS (T31–T33)

## Task 31: SmartLists — filter decode + summarize (read side)

Port the read half of `remctl_smart_lists.py`: `decode_smart_list_filter_blob`, `summarize_smart_list_filter`, `_summarize_filter_family`, `_summarize_date_filter`, `_extract_keyed_archive_json`, `CUSTOM_SMART_LIST_TYPE`. Returns ordered summary objects. Source: `remctl_smart_lists.py:77-343`; oracle `tests/test_smart_lists.py`.

**Files:** Create `Sources/RemindersControl/SmartLists/FilterDecode.swift`; Test `FilterDecodeTests.swift` (port `test_smart_lists.py`).

- [ ] **Step 1: Failing tests** — port the unit oracle: null blob → all nil; `{}` (keyed archive) → summary kind `all`; `{"flagged":true}` → kind `flagged` supported; priorities; the 13 official samples all `supported:true`; legacy short selected-tag → unsupported/non-materializing. (These are in `tests/test_smart_lists.py` — translate each.)
- [ ] **Step 2: Run → FAIL**
- [ ] **Step 3: Implement** per recon parityNotes (decode branches: raw `{`-prefixed JSON `encoding:"json"` vs NSKeyedArchiver `encoding:"keyed_archive_json"`; summary families flagged/priority/hashtags/date/time/location/lists; date sub-summaries; ordered summary keys). Use `OrderedJSON.parse` for `filterJSON` passthrough.
- [ ] **Step 4: Run → PASS**  **Step 5: Commit** — `git commit -m "Phase 1: smart-list filter decode/summarize"`

---

## Task 32: Serialization+Store — smart_list_to_dict + q_smart_lists

Port `smart_list_to_dict` (ordered keys + conditional appearance/version/pinned + filter), `smart_list_display_name` (ZNAME or `SMART_LIST_TYPE_NAMES` or last dotted segment or `(unnamed)`), `q_smart_lists` (Z_ENT=4 OR ZSMARTLISTTYPE not null; ORDER BY COALESCE(ZNAME,''), Z_PK; dynamic columns). Source: `remctl:486-505,4118-4183`.

**Files:** Create `Sources/RemindersControl/Serialization/SmartListSerializer.swift`, `Sources/RemindersControl/Store/Queries+SmartLists.swift`; Test `SmartListSerializerTests.swift`.

- [ ] TDD (oracle `test_smart_lists_json_decodes_builtin_and_custom_rows`): ordering (Flagged before High Priority via COALESCE), Z_ENT=3 exclusion, pinned-from-pinnedDate fallback, `filter.kind=="priority"`, `filterJSON`. Commit.

---

## Task 33: Command — smart-lists

`--json` only. JSON array of `smart_list_to_dict` (`indent=2`, ensure_ascii **False**); empty → `[]`. Human: empty → `No smart lists`; else `Smart Lists:`(bold) + two lines per item (`  name (id: N, kind)[ [pinned]]` and `    {type|(none)} · filter bytes: {len} · {desc}`) + `\n{n} smart list(s)`. Source: smart-lists recon.

**Files:** Modify `Sources/RemindersControl/Commands/SmartListCommands.swift` (`SmartLists`); Test `SmartListsCommandTests.swift`.

- [ ] TDD: two-row fixture human + JSON. Commit `git commit -m "Phase 1: smart-lists command"`.

---

# TEMPLATES (T34–T35)

## Task 34: Serialization+Store — template serializers + queries + resolve

Port `template_to_dict` (+`include_items`), `saved_reminder_to_dict`, `template_section_to_dict`, `uuid_from_blob`, `decode_template_metadata`, `template_deep_link`, `template_public_link` (icloud URL fragment), `_metadata_tags`, `_template_time`; `q_templates`, `q_template_matches`, `q_template_sections`, `q_template_saved_reminders`, `template_select_columns`, `saved_reminder_select_columns`, `resolve_template_ref`. Source: templates recon (full SQL + key orders).

**Files:** Create `Sources/RemindersControl/Serialization/TemplateSerializer.swift`, `Sources/RemindersControl/Store/Queries+Templates.swift`; extend `FixtureDB` with template tables; Test `TemplateSerializerTests.swift`.

- [ ] TDD (oracle `test_templates_json_*`, `test_template_info_json_*`): counts, publicLink uuid/url (`Rome:_Things_To_See` fragment), items[0] title/flagged/priority/tags, sections[0] name. Implement exact key orders. Commit.

---

## Task 35: Command — templates + template-info

`templates`: `--json` only; JSON array (ensure_ascii **False**); human `Templates:` + `  name (id: N, k item(s)[, k section(s)][, shared])` + `\n{n} template(s)`; empty → `No templates`. `template-info`: positional `name` (nargs?) | `--template-id`; errors both/neither/not-found/ambiguous exit 1; JSON single object (ensure_ascii **False**); human detail block per recon. Source: templates recon.

**Files:** Modify `Sources/RemindersControl/Commands/TemplateCommands.swift` (`Templates`, `TemplateInfo`); Test `TemplateCommandTests.swift`.

- [ ] TDD: array vs object; resolution errors; human blocks. Commit `git commit -m "Phase 1: templates + template-info commands"`.

---

# LIST-SYMBOLS / EXPORT (T36–T39)

## Task 36: Output — OFFICIAL_LIST_SYMBOLS catalog (71)

Copy the 71-entry `(name, asset, preview)` catalog verbatim (full list is in the list-symbols recon and `remctl:230-300`). Provide `listSymbolRows()`.

**Files:** Create `Sources/RemindersControl/Output/ListSymbols.swift`; Test `ListSymbolsCatalogTests.swift`.

- [ ] TDD: count == 71; contains `default/ListBadgeDefault`, `education3/ListBadgeEducation3/✎`, `fitness/ListBadgeFitness`, `work5/ListBadgeWork5/★`; `symbol1` preview is literal `{}`; `symbol3` is `*`. Copy all 71 entries in exact source order (non-alphabetical). Commit `git commit -m "Phase 1: list-symbols catalog (71 entries)"`.

---

## Task 37: Command — list-symbols (static catalog)

`--json` (+ accept `--html`/`--preview` but Phase-4 paths can `throw NotImplemented`/be deferred — **for Phase 1, only the catalog json+human are required**; `--json` + `--html`/`--preview` mutual-exclusion error must still work, and bare `--html`/`--preview` should produce a clear "not yet" or be wired in Phase 4). **Decision:** Phase 1 implements `--json` and human; `--html`/`--preview` remain stubbed (`throw NotImplemented("list-symbols --preview")`) — they're Phase 4. JSON object `{count, note, symbols[]}` (`indent=2`, ensure_ascii **False**). Human table per recon; **drop `--private`** from the hint line (deviation: `--private` removed). Source: list-symbols recon.

**Files:** Modify `Sources/RemindersControl/Commands/ListCommands.swift` (`ListSymbols`); Test `ListSymbolsCommandTests.swift`.

- [ ] TDD (oracle `test_list_symbols_reports_official_reminders_emblems`, `test_list_symbols_tui_labels_approximate_preview_column`): JSON `count==71`, note substring, names include `education3`/`fitness`; human contains `approximate text fallback`, `remctl list-symbols --preview`, `approx`, `education3`. The exact `note` string (verbatim) and the human disclaimer lines per recon. Commit `git commit -m "Phase 1: list-symbols command (json + human)"`.

---

## Task 38: Output — CSV writer

Excel-dialect CSV: `,` delimiter, `"` quote, QUOTE_MINIMAL (quote only when field contains `, " \r \n`), line terminator `\r\n`, double `"` to escape. Source: export recon §CSV.

**Files:** Create `Sources/RemindersControl/Output/CSV.swift`; Test `CSVTests.swift`.

- [ ] TDD: row with a comma-containing field gets quoted; CRLF terminators; boolean cells emit `True`/`False` (capitalized) when the caller passes those strings. Implement `CSV.writeRows([[String]]) -> String`. Commit.

---

## Task 39: Command — export

`-l/--list` | `--list-id`; `--format {json,csv}` (default json); inert `--json`. Resolution errors (both/not-found/ambiguous) exit 1. Query: `q_reminders(completed:true, limit:10000)` (+ list filter), flat. JSON: flat array via `serialize_reminders` (`indent=2`, ensure_ascii **True**); empty `[]`. CSV: header `id,title,list,completed,flagged,urgent,priority,due_date,notes,url,tags` + rows (tags comma-joined into one cell; CRLF; `print(end:"")` so no extra trailing newline). Source: export recon.

**Files:** Modify `Sources/RemindersControl/Commands/OpsCommands.swift` (`Export`); Test `ExportCommandTests.swift`.

- [ ] TDD: JSON flat array incl. completed + subtasks; CSV header-only on empty; CSV boolean capitalization + quoted tags cell. Commit `git commit -m "Phase 1: export command"`.

---

## Task 40: Integration — full read-surface smoke + cleanup

Verify all 18 read commands run end-to-end against one shared fixture; confirm build is warning-free; update `CommandTreeTests` only if registration changed (it shouldn't). Confirm GRDB is now genuinely used (no dead-dep warning).

**Files:** Test `tests/RemindersControlTests/ReadSurfaceSmokeTests.swift`.

- [ ] **Step 1:** Build a fixture with ≥2 lists (one grocery w/ sections), reminders (due today/overdue/upcoming/flagged/urgent/with tags/subtasks/recurrence/early-reminder), a smart list, a template. Run each command `--json` via `CLIRunner`; assert exit 0 and parseable JSON; assert a couple of cross-command invariants (e.g. `stats.total` ≥ `today` count).
- [ ] **Step 2:** `swift build` → 0 warnings; `swift test` → all green.
- [ ] **Step 3: Commit** — `git commit -m "Phase 1: read-surface integration smoke + cleanup"`

---

## Self-review checklist (run before declaring Phase 1 done)

1. **Coverage:** all 18 commands (today, upcoming, overdue, search, flagged, urgent, tags, subtasks, sections, stats, show, info, lists, smart-lists, templates, template-info, list-symbols, export) have a task and a test. ✔ (T17–T39)
2. **JSON profiles recorded per command** (indent + ensure_ascii): today/upcoming/overdue/flagged/urgent/subtasks/stats/tags/sections/info/list-symbols(note)/export = ensure_ascii **True**; show/lists/smart-lists/templates/template-info = ensure_ascii **False**. **Each command task must verify its exact `json.dumps(...)` signature at the cited source line before locking the test.**
3. **Ordered-key contract:** serializeReminder key order pinned in T10; smart-list/list/template orders pinned in T24/T32/T34.
4. **Timezone determinism:** date assertions inject a fixed calendar/TZ (T2, T10). Don't assert local-dependent strings without pinning TZ.
5. **Deviations:** `--private` dropped only from the list-symbols human hint (T37); everything else parity.
6. **Type consistency:** `Ansi`, `JSONValue`, `ReminderRow`, `RemindersStore`, `Dispatch`, `Constants` names used uniformly across tasks. `serializeReminders(_:store:memberships:)` signature consistent (T10, used by T17/18/19/28/39).

## Execution handoff

After saving, choose execution mode (subagent-driven recommended). Foundation tasks (T1–T16) are the critical path and should be reviewed tightly (two-stage: spec compliance then code quality); command tasks (T17–T39) are repetitive and can move faster once the foundation is proven.
