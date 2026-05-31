# Phase 4 — Ops/Setup Commands: Deviations + Manual Verification

Phase 4 implemented the last 6 commands (`completion`, `doctor`, `onboard`, `permissions`, `setup`,
`list-symbols --preview/--html`). The CLI is now **fully ported — zero `NotImplemented` stubs, 45
commands, 866 tests, release build clean.** This note records the intentional divergences from the
Python `remctl` (all forced by the single-binary / in-process architecture, signed off during recon)
and the manual checks that can't run in CI.

## Intentional divergences from Python (parity notes)

1. **`doctor` checks re-framed for the in-process reality.** The Python `bridge` / `private_helper` /
   `permissions_helper` checks probed sibling helper *binaries* that no longer exist (EventKit +
   ReminderKit are folded in-process). The Swift `doctor` therefore:
   - `python` → **`macos`** (reports the macOS version; always `ok` — there is no interpreter to gate).
   - `bridge` → **`eventkit`** (`EKEventStore.authorizationStatus(for:.reminder)`, non-prompting; `ok`
     iff `.fullAccess`/legacy `.authorized`, else **WARN**).
   - `private_helper` → **`reminderkit`** (`RKPProbe()`; `ok`/**WARN**).
   - `permissions_helper` → **dropped** (no in-process analog).
   - Net: `checks[]` is **9 entries** (Python had 10) with the renamed names above. The re-framed
     checks are **always WARN, never FAIL**, preserving exit-code parity (Python's helper checks were
     WARN too — only platform/store_dir/database/cli failures cause exit 1).
   - Consumers parsing `doctor --json` `checks[].name` must use the new names.

2. **`permissions --json` `available` is always `false`.** The single binary does not bundle the
   AppKit GUI helper (`remctl-permissions.swift`) — folding it would force the whole CLI to become an
   `NSApplication`, breaking headless/agent/CI invocation. So `permissionHelperAvailable()` is hardcoded
   `false`; both `permissions` and `onboard` deterministically take the **printed-guidance** branch
   (open System Settings via `/usr/bin/open` + guidance text), which is the contract fallback every
   headless context already hits. The `helper` JSON key still reports the conventional sibling path.

3. **`list-symbols --html` degrades instead of exit-1 on a missing framework.** Python `exit(1)`s with
   `RemindersUICore framework not found...` if the private framework is absent. The Swift port always
   writes the sheet (exit 0): per-asset misses render the fallback glyph, and a wholly-absent framework
   yields a glyph-only sheet (optional stderr note). It also exports badge PNGs **in-process via AppKit**
   (`Bundle(path:).image(forResource:)` → `NSBitmapImageRep`), dropping the Python `swift -` subprocess
   and its runtime toolchain dependency. (Live-verified: 71/71 native badge assets exported on macOS 26.)
   The dead `Swift is required…` error string is gone; the in-HTML usage hint drops `--private` to match
   the plain-output hint.

4. **`completion` ships the hand-written scripts verbatim** (not ArgumentParser's generator), preserving
   byte-parity including the deliberate cross-shell inconsistencies (bash/fish carry
   `--date-today-include-past-due`; zsh omits it).

5. **`list-symbols --html` value-optional flag** (`--html` with or without a path) is reproduced via a
   small argv normalizer in `main()` (ArgumentParser can't express argparse's `nargs='?' const=''`).
   Only affects `list-symbols`; `--html=PATH`, `--html PATH`, and bare `--html`→default all work.

6. **`--private` gate removed project-wide** (Phases 2–3): no Ops command emits a "requires --private"
   string.

## Manual verification (not CI-runnable)

CI covers every pure path (golden completion scripts, `doctor`/`onboard` check-gathering with injected
probes, `setup` file ops with temp HOME/CONFIG_DIR, `permissions` JSON + topic validation, the pure
`buildListSymbolsHTML`). The following need a real machine and were exercised manually where noted:

- **`doctor`** — run `remctl doctor` and `remctl doctor --json --for-agent` on your Mac; confirm the
  `eventkit`/`reminderkit`/`macos` checks report sensibly, the execution-context block populates (or
  degrades to `unknown`), and exit code is 0 unless a real FAIL (platform/store/db/cli).
- **`setup`** — `remctl setup --shell zsh` writes `~/.zsh/completions/_remctl`; `remctl setup --doctor`
  appends the report. Verify completion actually activates in a new shell.
- **`onboard`** — `remctl onboard` SHOULD trigger the macOS Reminders (EventKit) + Automation TCC
  prompts, launch Reminders.app, write `~/.config/remctl/onboard-state.json`, and (if FDA missing)
  print guidance + open System Settings. **This grants real TCC permissions to the `remctl` binary** —
  expected and required for the write commands to work.
- **`permissions full-disk-access`** — opens System Settings → Full Disk Access and prints guidance;
  `--json` is informational only (no GUI). Add the `remctl` binary to FDA so the SQLite reads work.
- **`list-symbols --preview`** — writes `~/.config/remctl/list-symbols.html` and opens it; confirm the
  73 native badge images render (not glyph fallbacks) — proves the in-process RemindersUICore export.

This complements the Phase-2 (`phase-2-manual-eventkit-smoke.md`) and Phase-3
(`phase-3-manual-reminderkit-smoke.md`) checklists; the Phase-3 step-1 flag test remains the binary
go/no-go for the private-write save path.
