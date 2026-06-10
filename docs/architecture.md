# Architecture

RemCTL is a single self-contained Swift binary. It intentionally splits reads
from writes, but everything runs in one process — there are no helper
executables, no daemon, no localhost API, no launch agent, and no token. The
`remctl` command is the only runtime surface.

The binary uses three data paths, all in-process:

```text
remctl  (one Swift binary)
  reads:   ~/Library/Group Containers/group.com.apple.reminders/.../Data-*.sqlite
           └─ GRDB, read-only — needs Full Disk Access
  writes:  EventKit            (in-process)
           └─ title, list, due, priority, notes, recurrence, alarms, complete,
              delete, list create/rename/delete, structured-location alarms
  private: ReminderKit          (in-process, private framework)
           └─ sections, subtasks, synced tags, image attachments, real flag,
              urgent, Early Reminders, list/smart-list appearance, Groceries,
              custom smart lists, templates
```

Reads go directly to the local Reminders SQLite store for speed and detail.
Public mutations go through Apple's EventKit. The metadata Apple does not expose
through EventKit goes through Apple's private ReminderKit framework. RemCTL never
writes the SQLite store, so iCloud and Reminders stay in charge of sync.

> RemCTL was ported from a former CLI that shelled out to standalone Swift and
> Objective-C helper binaries; that EventKit and ReminderKit logic now runs
> inside this one process.

## The Read Path — GRDB, read-only

Reads open the local iCloud Reminders Core Data store directly:

```text
~/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/Data-*.sqlite
```

`RemindersStore` (`Sources/RemindersControl/Store/RemindersStore.swift`) opens the
largest `Data-*.sqlite` under the store directory through
[GRDB.swift](https://github.com/groue/GRDB.swift) with `Configuration.readonly = true`.
RemCTL opens the database **read-only and never writes to SQLite**. Queries live
alongside it in `Sources/RemindersControl/Store/Queries+*.swift`, with the schema
column lookups cached on the store.

Direct reads are the fast, detailed path. They expose fields EventKit does not
surface cleanly for list views, in tens of milliseconds:

- sections
- subtasks
- tags
- attachments
- deep links
- list colors and badge emblems
- recurrence rules
- urgent state
- Early Reminder due-date delta alerts

The store file is TCC-protected, so this path requires **Full Disk Access** for
the process context running `remctl` (see [Permissions](#permissions)).

## The Public-Write Path — EventKit

Ordinary mutations go through Apple's EventKit, in-process. `EventKitWriter`
(`Sources/RemindersControl/Writes/EventKitWriter.swift`) wraps a single
`EKEventStore` and covers:

- create, edit, complete/uncomplete, and delete reminders
- title, target list, due date (timed or all-day: date-only inputs store
  date-only `dueDateComponents`), priority, notes, and notes-appended URLs
- explicit completion dates (`done --date`)
- recurrence rules and normal (relative/absolute) alarms
- moving a reminder between lists
- list create, rename, and delete
- structured-location alarms (written through EventKit's structured-location
  path because they materialize reliably there on current macOS)

EventKit also backs the **limited read fallback** (`--via-eventkit` on `show`,
`search`, `today`, `upcoming`): `EventKitReader`
(`Sources/RemindersControl/Reads/EventKitReader.swift`) fetches through
`EKEventStore` predicates without touching the SQLite store, so it works
without Full Disk Access — at reduced fidelity (no RemCTL numeric IDs,
sections, synced tags, urgent state, or private rich links).

Using EventKit for these keeps Reminders and iCloud in charge of ordinary
mutations: RemCTL hands the change to Apple's supported API and lets the
Reminders daemon persist and sync it. RemCTL does not write the database for
these operations.

The writer validates user input — malformed due dates, recurrence rules,
alarms, priorities, and location payloads fail before anything is written.

## The Private-Write Path — ReminderKit

For the metadata Apple does not expose through EventKit — sections, synced
tags and rich links, shared-list assignments, subtasks, image attachments,
real flag/urgent state, Early Reminders, list appearance, Groceries metadata,
smart lists, and templates — RemCTL calls Apple's **private, unsupported**
ReminderKit framework directly, in-process. There is no
opt-in flag; the path is selected from which flags are present, not an explicit
mode.

This logic lives in a dedicated Objective-C target, `ReminderKitPrivate`
(`Sources/ReminderKitPrivate/`), which links
`/System/Library/PrivateFrameworks/ReminderKit.framework`. Apple ships no public
ReminderKit headers, so the target carries `@interface` forward declarations and
resolves the real classes at runtime via `NSClassFromString` — selector
correctness is a runtime property. It also links AppKit (`NSImage`, to validate
image attachments).

The target exposes a small, dictionary-in / dictionary-out C entry point
(`Sources/ReminderKitPrivate/include/ReminderKitPrivate.h`):

- `RKPProbe()` — a probe that returns `reminderkit-ok` when `REMStore` resolves
  at runtime, `reminderkit-missing` otherwise. No writes.
- `RKPDispatch(NSDictionary *request)` — dispatches one allow-listed private
  action and returns a response dict (`status` of `created`/`updated`/`deleted`,
  or `{"status": "error", "message": ...}`). It never throws and never calls
  `exit()`; any private-API fault is caught and returned as an error dict.

Private writes cover the parts of Reminders that EventKit does not:

- **Reminder metadata:** synced web rich links, synced tags, sections, rich
  subtasks, image attachments, the real flag, urgent state, and Early Reminders.
- **List metadata:** exact `#RRGGBB` colors, official list symbols, emoji
  badges, Groceries conversion/locale and item categorization, and list /
  smart-list pin state.
- **Custom smart lists:** create/edit/delete for the Reminders filters RemCTL
  has verified materialize correctly.
- **Templates:** whole-list template create/apply/delete.

These call private APIs that are reverse-engineered and may change across macOS
releases. They are **sync-safe because they never write SQLite directly** — they
go through ReminderKit save requests, so they will not corrupt the store or
break iCloud sync. Treat them as power-user functionality and verify writes that
matter. Generic file/PDF attachments are intentionally rejected; only images
attach. See [private-metadata.md](private-metadata.md) for supported fields,
known limits, and verification rules.

## Package & Target Layout

RemCTL is built with SwiftPM (`swift-tools-version: 6.0`), targeting macOS 14+.
The CLI uses Swift Argument Parser; reads use GRDB. The package declares one
executable product, `remctl`, over four targets (see `Package.swift`):

| Target | Kind | Role |
| --- | --- | --- |
| `ReminderKitPrivate` | Obj-C `.target` | The private-write boundary. Links `ReminderKit.framework` (from `/System/Library/PrivateFrameworks`), Foundation, and AppKit; public header in `include/`. Exposes `RKPProbe`/`RKPDispatch`. |
| `RemindersControl` | Swift `.target` | The library holding all CLI commands, reads, writes, serialization, and smart-list logic. Depends on `ArgumentParser`, `GRDB`, and `ReminderKitPrivate`; links EventKit, AppKit, and CoreLocation. |
| `remctl` | Swift `.executableTarget` | A thin `@main` wrapper over the `RemindersControl` library's root command. |
| `RemindersControlTests` | `.testTarget` | Unit tests for `RemindersControl` (and `ReminderKitPrivate`, listed explicitly because the private-link tests import it directly). |

Keeping the command logic in the `RemindersControl` library — with the
executable a thin wrapper — is what makes the CLI unit-testable. Inside the
library, the source is organized into `Commands/` (Argument Parser shells plus
their testable cores), `Store/` (GRDB reads), `Writes/` (the EventKit and
ReminderKit write paths), `SmartLists/` (filter encode/decode),
`Serialization/`, `Output/`, and `Runtime/` (path resolution, date windows).

## Testability Seams

Write logic is testable without touching live Reminders data, through two
parallel protocol seams:

- **EventKit seam:** the `RemindersWriter` protocol
  (`Sources/RemindersControl/Writes/RemindersWriter.swift`) is implemented by the
  production `EventKitWriter` and by a `MockWriter` in tests.
  `WriterFactory.make` returns the real writer in production and can be
  overridden in tests.
- **Private seam:** the `PrivateWriter` protocol
  (`Sources/RemindersControl/Writes/PrivateWriter.swift`) is implemented by the
  production `ReminderKitWriter` (which marshals each typed call into an
  `RKPDispatch` request dict and unmarshals the response) and by a
  `MockPrivateWriter` in tests. `PrivateWriterFactory.make` returns the real
  writer in production.

Command cores return a `WriteOutcome` (stdout/stderr/exit code) instead of
printing or exiting directly, and accept an injected writer, so a test can drive
a full command against a mock and assert on both the recorded calls and the
rendered output. The live `EventKitWriter` and `ReminderKitWriter` paths require
a real Reminders store and a granted TCC permission, so they are verified
manually; their pure helpers (color parsing, transient-error detection,
response marshalling) are unit-tested.

**Smart-list filter byte-parity.** Custom smart-list filters are stored on disk
in Reminders' own compact JSON format. `FilterEncode.swift` encodes filter
arguments to those bytes; `FilterDecode.swift` decodes them for reads. The two
are inverses: bytes emitted by the encoder must round-trip back through the same
decoder used for read commands, using the space-free compact serializer. Tests
encode an argument set, then assert the produced `filterData` decodes to the
expected filter — byte-verifying the write path against the read path without a
live store.

Tests use **Swift Testing** (`import Testing`, `@Test`). They live under
`tests/RemindersControlTests/` (an explicit lowercase path pinned in
`Package.swift`) and run on every push and PR via SwiftPM CI in the project repo,
independent of the distribution pipeline.

## Distribution

RemCTL is distributed through the Homebrew tap `markmals/homebrew-tap`:

```bash
brew install markmals/tap/remctl
```

Because the binary links a **private** framework (ReminderKit), it is **not
notarized and not App-Store distributed**. Instead it ships as a Homebrew
**bottle** — a prebuilt binary. The tap's `brew test-bot` CI builds bottles on
Apple-Silicon macOS 15 (Sequoia) and 26 (Tahoe) and publishes them to GitHub
Releases. For configurations without a matching bottle, Homebrew falls back to a
**source build** (`swift build --disable-sandbox -c release`), which needs Xcode
or a Swift 6 toolchain.

RemCTL **requires macOS 14 (Sonoma) or later**.

## Output Safety

Human output neutralizes terminal control characters from Reminders-controlled
text — titles, notes, URLs, list names, section names, and tags. JSON output
preserves the raw stored values for automation.

Synced rich-link URLs (and rich subtask URLs) are validated before writing:
RemCTL accepts only public `http`/`https` hosts and rejects loopback, `.local`,
private, link-local, multicast, reserved, and unresolved hosts. With no other
private metadata present, a `--url` is a plain notes append rather than a synced
rich link.

## Permissions

RemCTL needs two macOS permission grants:

- **Full Disk Access** — for the direct, read-only Reminders database reads.
- **Reminders access** — for the EventKit and ReminderKit writes (prompted on
  first write, or via `remctl onboard`).

```bash
remctl onboard                      # triggers the Reminders prompt; guides Full Disk Access
remctl permissions full-disk-access # opens System Settings + prints the exact target
remctl doctor --for-agent           # verifies the current execution context
```

TCC grants are **context-specific**. Terminal, an agent runner, a CI host, and
another app can each have different access to the same Reminders store. A green
report from Terminal does not prove an agent context can read the database, so
run `remctl doctor` from the same context that will run RemCTL.

## Environment Overrides

```bash
REMCTL_STORE_DIR=/path/to/reminders/store   # override the read store directory
REMCTL_CONFIG_DIR=/path/to/config           # override the config directory
NO_COLOR=1                                   # disable colored output
```
