# Phase 2 — Manual EventKit Smoke Test

> **Why this exists:** Every Phase-2 write command was unit-tested against a mock
> writer + SQLite fixtures, and the full suite is green in CI. But one assumption
> **cannot** be exercised without a real Reminders account, Full Disk Access, and a
> TCC consent prompt — so it was deferred to this manual run:
>
> **The DB's `ZCKIDENTIFIER` (a reminder's stable CloudKit id, read via GRDB) is the
> same string EventKit returns as `EKReminder.calendarItemIdentifier`.**
>
> Every pk-targeted write (`done`/`undone`/`edit`/`delete`) resolves a numeric
> `#<id>` (Z_PK) → `ZCKIDENTIFIER` from the DB, then asks EventKit to fetch the item
> by that identifier. If the equality holds, the round trip works. If it does **not**,
> those commands will report `#<id> not found` even though the reminder exists. The
> code **refuses** to fall back to a title-based match (that would be unsafe), so a
> broken assumption fails loudly rather than touching the wrong reminder.
>
> **Step 3 below is the linchpin.** If it passes, the assumption holds.

## Prerequisites

1. macOS 14+ (the package targets `.macOS(.v14)`).
2. Build the release binary:
   ```sh
   swift build -c release
   BIN="$(pwd)/.build/release/remctl"
   ```
3. **Full Disk Access** for the terminal app you're running this from
   (System Settings → Privacy & Security → Full Disk Access). Without it, the
   *read* side (resolving `#<id>`) fails with the "Direct CLI reads are blocked…"
   message — that's the DB-unavailable path, not a bug.
4. **Reminders access** — the *first* write command triggers a one-time TCC prompt
   ("remctl would like to access your Reminders"). Click **OK**. If you miss it,
   re-run; `remctl doctor` reports the current grant state.

> These steps create and then delete a throwaway list named `remctl-smoke` in your
> real Reminders. Nothing else is touched. If anything goes wrong mid-run, the
> cleanup step removes the list.

## The round trip

Run each command, compare to **Expect**, and glance at Reminders.app where noted.

### 1. Create a throwaway list
```sh
$BIN list-create "remctl-smoke"
```
**Expect:** `Created list: remctl-smoke` (exit 0). Reminders.app shows a new empty
list `remctl-smoke`.

### 2. Add a reminder — capture the id
```sh
$BIN add "Smoke test" -l "remctl-smoke" --json
```
**Expect:** one-line JSON `{"status": "created", "id": "<ID>", "title": "Smoke test"}`.
**Note the `id`** — call it `$ID` below. The reminder appears in the list.

```sh
ID=<paste the id>
```

### 3. ⭐ pk → ckid round trip (the linchpin)
```sh
$BIN edit $ID --notes "edited by smoke test"
```
**Expect:** `Updated #<ID>` (exit 0), and the reminder's notes change in Reminders.app.

- ❌ **If you see `Error: #<ID> not found`** → the DB row exists but EventKit could
  not fetch it by that identifier → **the `ZCKIDENTIFIER` ↔ `calendarItemIdentifier`
  assumption is broken.** Stop and report this; it is the one thing this run exists
  to catch.
- ❌ **If you see `… has no stable identifier. Refusing unsafe title-based fallback …`**
  → the row's `ZCKIDENTIFIER` was null/empty. Note whether new EventKit-created
  reminders get a ckid immediately or only after an iCloud sync.

### 4. Complete / uncomplete
```sh
$BIN done $ID      # Expect: Completed: Smoke test   (checkbox ticks in the app)
$BIN undone $ID    # Expect: Uncompleted (or the undone message); checkbox clears
```

### 5. Due date + double-tap nudge
```sh
$BIN edit $ID -d "tomorrow 9am"   # Expect: Updated #<ID>; due shows tomorrow 09:00
$BIN edit $ID -d "tomorrow 9am"   # same instant again — exercises the nudge path
```
**Expect:** both succeed. The second run sets the due to the same wall-clock time;
internally it briefly bumps +1h then re-sets it (the "double-tap nudge" that forces
Reminders to re-evaluate). No error, final due = tomorrow 09:00.

### 6. Priority, recurrence, alarm (optional spot-checks)
```sh
$BIN edit $ID -p high
$BIN edit $ID --recurrence "weekly mon,wed"
$BIN edit $ID --alarm 30m
$BIN info $ID            # or: $BIN show "remctl-smoke"
```
**Expect:** each `Updated #<ID>`; `info`/`show` reflects priority, the recurrence
rule, and a 30-minutes-before alarm. Cross-check against Reminders.app.

### 7. Deep link + open
```sh
$BIN link $ID            # Expect: #<ID> Smoke test  /  x-apple-reminderkit://REMCDReminder/<ckid>
$BIN open $ID            # Expect: Opened #<ID> in Reminders.app  (app comes to front on that reminder)
```

### 8. Delete the reminder
```sh
$BIN delete $ID --force   # Expect: Deleted: Smoke test  ; reminder disappears
```
(Without `--force` you get the `Delete '…' from remctl-smoke? [y/N]` prompt.)

### 9. Cleanup — delete the list
```sh
$BIN list-delete "remctl-smoke" --force   # Expect: Deleted list: remctl-smoke
```
(Without `--force`: `Delete list 'remctl-smoke'? This cannot be undone. [y/N]`.)

## Optional: side-by-side parity vs the Python `remctl`

If the original Python script is still runnable, repeat steps 2–9 with it on a second
throwaway list and diff the human/`--json` output. Known, intentional Phase-2
differences (not failures):

- **Exit code 64 vs 2** for bad CLI *usage* (unknown flag, bad `--proximity` value,
  missing argument). swift-argument-parser uses `EX_USAGE` (64); Python argparse uses
  2. Documented, framework-wide, accepted.
- **`flag` / `--flagged`, `--tags`, `--symbol`/`--emoji`/`--groceries`, `--urgent`,
  sections, subtasks, images** — these are **Phase-3 (ReminderKit)** and currently
  error with `… requires the private metadata layer (Phase 3); not yet implemented.`
- **`Failed to read JSON: <…>`** (import) — the exception *text* differs from Python's;
  only the prefix is parity-stable.

## What to report back

The single most important data point: **did step 3 succeed?** Then, anything that
diverged from an **Expect** line (with the exact command + output). That tells us
whether the EventKit write surface is fully verified end-to-end on real hardware.
