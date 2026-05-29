# RemCTL → Swift Port — Design Spec

- **Date:** 2026-05-28
- **Status:** Approved (2026-05-28)
- **Author:** Mark Malstrom (mark@malstrom.me)
- **Branch:** `swift-port`
- **Companion:** [`2026-05-28-reminders-cli-contract.md`](2026-05-28-reminders-cli-contract.md) — generated per-command/module/schema parity reference.

## 1. Goal

Reimplement the entire Python surface of RemCTL as a single Swift package, distributed via Homebrew. The current product is a Python CLI (`remctl`, 8,219 lines) plus three Python helper modules, that reads the iCloud Reminders CoreData SQLite store directly and shells out to compiled Swift/Obj-C helpers for writes. The port collapses all of that into **one Swift binary**.

Non-goals: changing what RemCTL can do. This is a port at functional + JSON-contract parity, not a feature redesign.

## 2. Locked decisions

| Area             | Decision                                                                      | Rationale                                                                                      |
| ---------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Packaging        | SwiftPM package **`RemindersControl`** → one executable **`remctl`**       | Lets us use Swift Argument Parser idiomatically; one binary replaces the single Python script. |
| CLI name         | **`remctl`** (unchanged)                                                      | Kept for back-compat: env vars stay `REMCTL_*`, config stays `~/.config/remctl`. Package is `RemindersControl`. |
| Write path       | Fold **everything in-process** (EventKit + private ReminderKit)               | One binary; no subprocess hops.                                                                |
| `--private` flag | **Removed.** Formerly-private capabilities become first-class/unconditional   | Owner direction: the gate "doesn't seem necessary."                                            |
| Fidelity         | Functional + JSON-contract parity; human-output polish permitted              | Existing tests/docs are the conformance spec.                                                  |
| SQLite           | **GRDB.swift** (read-only, `?mode=ro`)                                        | Owner direction; over a raw `libsqlite3` system target.                                        |
| Private Obj-C    | Reuse `remctl-private.m` as an internal **`ReminderKitPrivate`** Obj-C target | Don't re-derive 1,429 lines of fragile private-API glue.                                       |
| Tests            | Port `tests/*.py` to **Swift Testing**                                        | Single-language verification surface.                                                          |
| Distribution     | **Homebrew** via `markmals/homebrew-tap`, CI-built bottles                    | Owner's existing tap + bottle pipeline.                                                        |
| Dependencies     | `swift-argument-parser`, `GRDB.swift` only                                    | Everything else is system frameworks.                                                          |

## 3. Architecture

One SwiftPM package, one product binary `remctl`. macOS-only.

```text
RemindersControl/                swift build -c release → ONE binary `remctl`
├─ Package.swift                 swift-tools-version pinned for macos-15 + macos-26 runners
│                                deps: swift-argument-parser, GRDB.swift
│                                linker: -framework EventKit, AppKit,
│                                        -F/System/Library/PrivateFrameworks -framework ReminderKit
├─ Sources/
│  ├─ remctl/                    executable target (Swift)
│  │   ├─ RemCTL.swift           ParsableCommand root + 45 subcommands
│  │   ├─ Commands/              one file per command group
│  │   ├─ Runtime/               ← remctl_runtime.py   (paths, env, URL-safety, date windows)
│  │   ├─ Serialization/         ← remctl_serialization.py (Reminder→JSON, recurrence, early reminders)
│  │   ├─ SmartLists/            ← remctl_smart_lists.py (filter encode/decode/validate)
│  │   ├─ Store/                 GRDB read-only reader + CoreData schema map ← inline SQLite in remctl
│  │   ├─ Writes/EventKit/       ← remctl-bridge.swift, in-process
│  │   ├─ Writes/Private/        Swift facade over ReminderKitPrivate
│  │   ├─ Permissions/           ← remctl-permissions.swift (AppKit FDA window)
│  │   └─ Output/                human formatter, color/ANSI, terminal-control neutralization, JSON
│  └─ ReminderKitPrivate/        Obj-C target ← remctl-private.m + private-framework module map
├─ Tests/
│  └─ RemindersControlTests/     ← tests/*.py ported to Swift Testing
└─ Tools/                        ← scripts/*.py (live verification matrices) as Swift utilities
```

### 3.1 Component mapping (Python → Swift)

Each Swift unit replaces a specific Python source, so parity is checkable file-by-file:

| Swift unit                                | Replaces                    | Notes                                                                                               |
| ----------------------------------------- | --------------------------- | --------------------------------------------------------------------------------------------------- |
| `Runtime/`                                | `remctl_runtime.py`         | path/env resolution, `is_safe_remote_url`, date windows, secret masking, terminal-text safety.      |
| `Serialization/`                          | `remctl_serialization.py`   | `serialize_reminder(s)`, `recurrence_from_row`, `due_date_delta_alerts_from_row`, `preload_extras`. |
| `SmartLists/`                             | `remctl_smart_lists.py`     | filter encode/decode/validate, `SmartListFilterError`, supported-shape gating.                      |
| `Store/`                                  | inline SQLite in `remctl`   | GRDB read-only; CoreData schema map; Apple-epoch timestamp conversion.                              |
| `Output/`                                 | formatting code in `remctl` | human formatter, color (`NO_COLOR`), terminal-control neutralization, JSON encoder.                 |
| `Writes/EventKit/`                        | `remctl-bridge.swift`       | now in-process.                                                                                     |
| `Writes/Private/` + `ReminderKitPrivate/` | `remctl-private.m`          | Obj-C reused as a target; Swift facade calls it.                                                    |
| `Permissions/`                            | `remctl-permissions.swift`  | AppKit Full Disk Access window, launched on demand from the CLI.                                    |

### 3.2 Data flow

- **Reads:** GRDB opens the `Data-*.sqlite` store read-only (`?mode=ro`, matching the current Python; no WAL/shm or `immutable=1`) → schema-mapped row access → `Serialization`/`Output`. Note: Early-Reminder data is read from the `ZREMCDREMINDER.ZDUEDATEDELTAALERTSDATA` JSON blob, **not** by querying the `ZREMCDDUEDATEDELTAALERT` table.
- **Writes:** `Commands` validate input → call EventKit (supported ops) or `ReminderKitPrivate` (formerly-private ops) in-process → re-fetch and report.
- **External processes:** retained only where genuinely required — `open` (deep links / Reminders.app) and `osascript` (AppleScript automation fallback).

## 4. Key substitutions for the Python stdlib / deps

| Python                                                               | Swift                                                                                                                                                     |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sqlite3`                                                            | GRDB read-only `DatabaseQueue`, `?mode=ro` open.                                                                                                          |
| optional `parsedatetime`                                             | Foundation `NSDataDetector` for natural-language dates + explicit ISO/relative parsing. **Same graceful fallback** when a phrase won't parse.             |
| `argparse`                                                           | Swift Argument Parser.                                                                                                                                    |
| `completion`/`setup` machinery                                       | ArgumentParser native completion-script generation, **shimmed** so `remctl completion zsh` still emits a script (`install.sh` and the tap rely on it). |
| runtime `swift -` asset extraction (`list-symbols --preview/--html`) | done in-process against RemindersUICore.                                                                                                                  |
| `subprocess` to bridge/private                                       | direct in-process API calls.                                                                                                                              |

## 5. Behavior changes from strict parity

These are the deliberate deviations. Everything else is parity.

1. **`--private` removed.** Capabilities formerly gated behind `--private` (rich URL/subtask/image attachments, real flag/urgent state, Early Reminders, location alarms, list appearance/pin, Groceries metadata, smart-list CRUD, templates) become first-class. Where a command currently forks public-vs-private on the flag, the Swift version defaults to the **richer** behavior:
    - `--url`: creates a real rich attachment for safe `http(s)` targets (subject to the existing `is_safe_remote_url` gate); falls back to a notes URL for non-`http(s)`/unsafe targets.
    - The full per-command fork list will be enumerated from the contract reference and is a spec-review checkpoint (§9).
2. **No CLI rename.** Binary stays `remctl`, completion file `_remctl`, config dir `~/.config/remctl`, env vars `REMCTL_*` — full back-compat for existing users. Only the **helper-path** env vars (`REMCTL_BRIDGE_PATH`, `REMCTL_PRIVATE_PATH`, `REMCTL_PERMISSIONS_PATH`) **retire**, since those helpers are folded into the one binary. `REMCTL_STORE_DIR`, `REMCTL_CONFIG_DIR`, and `NO_COLOR` remain. The **package** is `RemindersControl`; the executable product is `remctl`.
3. **Human-output polish** is permitted where Swift idioms improve readability; JSON shape stays at strict parity for automation.

## 6. Risks & mitigations

| Risk                                                                                               | Severity                 | Mitigation                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **In-process private framework fault** kills the whole CLI (no process isolation, no consent gate) | High — accepted by owner | `ReminderKitPrivate` wraps every private call in Obj-C `@try/@catch` → `NSError`; faults surface as clean CLI errors. Input validation (URL safety, payload-shape checks) preserved. |
| **EventKit + ReminderKit in one process/store session**                                            | Medium                   | Serialize saves; re-fetch after write; verify against current behavior per write command.                                                                                            |
| **Gatekeeper notarization** rejects private-framework linkage                                      | Medium (future)          | Current distribution is local source-compile + (new) Homebrew source build; neither notarizes. Flagged for any future signed/notarized release.                                      |
| **Offline bottle build** — SwiftPM wants to fetch deps in Homebrew's no-network sandbox            | High                     | Hermetic release tarball (see §7); fully offline `swift build`.                                                                                                                      |
| **CoreData schema drift** across macOS versions                                                    | Medium                   | Schema map centralized in `Store/`; parity tests run against the same fixture DB the Python tests use.                                                                               |

## 7. Distribution — Homebrew

**Tap:** `markmals/homebrew-tap` (existing). Its `test-bot` (matrix `macos-15`, `macos-26`) builds bottles on PRs; `pr-pull` (label `pr-pull`) commits bottles and pushes. Both reused unchanged.

**New formula `Formula/remctl.rb`** — Swift source build:

```ruby
class Remctl < Formula
  desc "Power-user CLI for Apple Reminders"
  homepage "https://github.com/markmals/remctl"
  url "https://github.com/markmals/remctl/releases/download/vX.Y.Z/remctl-vX.Y.Z-vendored.tar.gz"
  sha256 "..."
  license "MIT"
  depends_on :macos
  depends_on xcode: :build

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/remctl"
    generate_completions_from_executable(bin/"remctl", "completion")
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/remctl --version")
  end
end
```

**Hermetic release tarball (CI, no committed artifacts).** A tag-triggered release workflow **in the RemCTL repo (`github.com/markmals/remctl`)** runs `swift package resolve`, bundles the resolved dependency checkouts + `Package.resolved` into a source tarball, and uploads it as the GitHub Release asset that the formula's `url` points at. `swift build` then runs fully offline inside Homebrew's sandbox. Nothing vendored is committed to the repo.

**Optional `update-remctl.yml`** in the tap mirrors `update-vite-plus.yml` to bump the formula `url`/`sha256` on new releases.

**`install.sh`** retained as a lean non-Homebrew source-install fallback (`swift build -c release` + copy), with Homebrew as the documented primary path.

> Source repo: `github.com/markmals/remctl` (your fork). New major tag default `v2.0.0` (confirmed at release).

## 8. Phases

Bottom-up, reads-first. Each phase produces a working binary subset verified against the current Python output, and gets its own implementation plan (writing-plans) executed in sequence.

| Phase                               | Scope                                                                                                                                                                                                                                                                                                           | Acceptance                                                               |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| **0 — Scaffold**                    | `Package.swift` (ArgumentParser + GRDB), command skeleton with all 45 subcommand stubs, `--version` global, `--json` as a **shared per-subcommand** option (matching Python: there is **no** global `--json`/`--store`/`--config`), color suppressed via `NO_COLOR`, fold the 3 helpers in as targets, CI green | `swift build` + `swift test` run; `remctl --help` lists all commands. |
| **1 — Reads**                       | `Runtime` + `Serialization` + `Store` (GRDB) + `Output`; all read/inspect commands (today, upcoming, overdue, search, flagged, urgent, tags, subtasks, sections, stats, show, info, lists, smart-lists, templates, template-info, list-symbols, export)                                                         | Human + JSON output matches Python for the shared fixture DB.            |
| **2 — EventKit writes**             | add, edit, done, undone, delete, flag, unflag, link, list-create, list-edit, list-rename, list-delete (EventKit ops), recurrence, alarms, move-between-lists                                                                                                                                                    | Writes verified against Reminders; JSON/exit parity.                     |
| **3 — Private writes + SmartLists** | `SmartLists`; formerly-private writes (rich url/subtasks/images, urgent, Early Reminders, location alarms, list appearance/pin, groceries, smart-list create/edit/delete, template create/apply/delete)                                                                                                         | Verified materialization in Reminders.app; `--private` removed cleanly.  |
| **4 — Permissions & ops**           | Permissions AppKit GUI, doctor (+`--for-agent`), onboard, setup, completion, RemindersUICore asset extraction (`list-symbols --preview/--html`)                                                                                                                                                                 | `doctor` + guided FDA flow work; completions install.                    |
| **5 — Tests, tools, distribution**  | Swift Testing port of `tests/*.py`; `scripts/*.py` → `Tools/`; `Formula/remctl.rb` + hermetic release workflow + tap CI; `install.sh` rewrite; docs update                                                                                                                                                   | `swift test` passes; a tagged release produces installable bottles.      |

## 9. Open items for spec review

1. **Per-command `--private` fork behavior** — **Accepted:** default to the richer behavior. The contract reference annotates every formerly-gated option with `[was --private]`; revisit only if a specific command needs the public fallback.
2. **Env var / config naming** — **Resolved:** keep `REMCTL_*` and `~/.config/remctl` (full back-compat); package is `RemindersControl`, binary `remctl`.
3. **Formula source repo + tag** — **Resolved:** `github.com/markmals/remctl` (your fork); major tag default `v2.0.0`, confirmed at release.
4. **Human-output polish scope** — **Accepted:** minimal deviation from current human formatting.

> The contract reference flags **19 `INSUFFICIENT DATA` items** — concrete constant tables to copy verbatim from the Python source during implementation (the 71-entry `list-symbols` catalog, grocery-category emoji map, smart-list built-in type→display-name map, priority/proximity/alarm-unit enums, recurrence weekday numbering, Apple-epoch→ISO timezone behavior, `CUSTOM_SMART_LIST_TYPE`). None block the design; each is a copy-from-source task for its phase.

## 10. Testing strategy

Swift Testing. Black-box CLI tests drive the `remctl` binary as a subprocess and assert human + JSON parity against the contract reference; unit tests cover `Runtime`/`Serialization`/`SmartLists`/`Store`. Where practical, port diffs against the current `remctl` output for the same fixture DB during each phase. CI `test do` block stays limited to `--version`/`--help` (runners lack Full Disk Access and a Reminders store).
