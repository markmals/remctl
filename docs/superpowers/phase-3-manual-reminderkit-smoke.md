# Phase 3 — Manual ReminderKit Smoke Test

> **Why this exists:** Phase 3 folded the private `ReminderKit.framework` write surface in-process
> (the `ReminderKitPrivate` ObjC target, ported from `remctl-private.m`). Every Phase-3 command was
> unit-tested against a `MockPrivateWriter` + SQLite fixtures, and the full suite is green in CI. But
> two things **cannot** be verified without a real Reminders account + Full Disk Access + a TCC consent
> prompt, so they were deferred to this manual run:
>
> 1. **THE GATING UNKNOWN — does an entitlement-free in-process `save` actually materialize?**
>    Recon empirically confirmed `REMStore` *links, loads, and instantiates* with zero entitlements
>    under ad-hoc signing — but **no `saveSynchronouslyWithError:` was ever executed** (it would mutate
>    the live store). Whether a save routes through `remindd` under your existing Reminders TCC grant
>    (rather than the caller's app-group/private-TCC entitlements) is the load-bearing assumption of the
>    entire phase. **Step 1 below is the binary go/no-go test.**
> 2. **Runtime-only selector correctness.** There are no public ReminderKit headers; every `REM*`
>    selector is a hand-written forward declaration resolved from the dyld cache. A selector typo is an
>    unrecognized-selector fault at runtime, invisible to the compiler and CI. The `@try/@catch` barrier
>    turns such a fault into a clean `{status:error}` (no crash), but the feature silently fails. Each
>    command below exercises a distinct selector chain.

## Prerequisites
1. macOS 14+.
2. Build the release binary:
   ```sh
   swift build -c release
   BIN="$(pwd)/.build/release/remctl"
   ```
3. **Full Disk Access** for the terminal running it (System Settings → Privacy & Security → Full Disk
   Access) — needed for the SQLite reads that resolve `#<id>`/names → ckids. Without it you get the
   "Direct CLI reads are blocked…" message (the DB-unavailable path, not a bug).
4. **Reminders access** — the first private write triggers a one-time TCC prompt; click **OK**.

> This creates and deletes throwaway items named `remctl-p3-*` in your real Reminders. The cleanup
> section removes them. Phase 3 also needs Phase 2's EventKit writes working — if you haven't run
> `docs/superpowers/phase-2-manual-eventkit-smoke.md` yet, do that first (its step 3 is the EventKit
> linchpin; this doc's step 1 is the ReminderKit linchpin).

## 1. ⭐ GATING TEST — does an entitlement-free private save materialize?
```sh
# Pick any existing reminder's numeric id (from `remctl today` / `remctl ls`), call it $ID.
$BIN flag $ID
```
**Expect:** `Flagged: <title>` (exit 0), AND the reminder shows a **flag** in Reminders.app (the real
`ZFLAGGED`, not a priority change).

- ✅ **Flag appears in Reminders.app** → the entitlement-free in-process ReminderKit save WORKS. The
  whole private layer is viable. Proceed.
- ❌ **`flag` reports success but no flag appears, OR the value is wrong** → `set_flagged` fell back to
  the EventKit priority-proxy (you'll see a priority change instead of a flag), meaning the private
  `setFlagged` save did NOT materialize → **the gating assumption is broken.** Stop and report this; it
  is the single most important result of this run. (Check `remctl info $ID --json` for `flagged` vs
  `priority`.)
- ❌ **An `Error:` mentioning a private-API fault / unrecognized selector** → a selector typo in the
  ported `set_flagged` handler. Report the exact message.

```sh
$BIN unflag $ID   # Expect: Unflagged: <title>; flag clears in the app.
```

## 2. List pin / appearance (selectors: set_list_pinned, set_smart_list_pinned, set_list_appearance)
```sh
$BIN list-create "remctl-p3-list" --symbol education3 --color blue   # private create_list
#   Expect: Created list: remctl-p3-list / Applied private metadata: color=blue, symbol=education3
#   Verify in Reminders.app: list exists with the blue color + education symbol badge.
$BIN list-pin "remctl-p3-list"        # Expect: Pinned list: remctl-p3-list ; list pins to the top.
$BIN list-unpin "remctl-p3-list"      # Expect: Unpinned list: remctl-p3-list
$BIN list-edit "remctl-p3-list" --new-name "remctl-p3-renamed" --color green --emoji 🎯
#   Expect: Updated list: remctl-p3-renamed ; name/color/emoji-badge change in the app.
```

## 3. Reminder private metadata (selectors: add_private_metadata, assign_section, add_section_and_assign, set_urgent, set_early_reminder, add_subtasks, add_attachments, categorize_grocery_items)
```sh
$BIN add "remctl-p3-rem" -l "remctl-p3-renamed" --tags "work,errand" --urgent --early-reminder 1h -d "tomorrow 9am"
#   Expect: Created: remctl-p3-rem / Private metadata: applied N updates
#   Verify: tags #work #errand attached, urgent badge, an early reminder 1h before, due tomorrow 9am.
$BIN add "remctl-p3-parent" -l "remctl-p3-renamed" --subtask "child A" --subtask '{"title":"child B","flagged":true}'
#   Verify: parent with two subtasks; "child B" is flagged. (dual-writer: EventKit child fields + private flag)
$BIN edit <id of remctl-p3-rem> --new-section "Errands"   # add_section_and_assign
#   Verify: a new "Errands" section in the list with the reminder under it.
```
(Grocery: create a Groceries list via `list-create "remctl-p3-groc" --groceries --grocery-locale en_US`,
add a reminder to it with `--grocery`, and verify it auto-categorizes into a grocery section.)

## 4. ⭐ Smart-list filter byte-parity (selectors: create/update/delete_smart_list) — the ENCODE proof
```sh
$BIN smart-list-create "remctl-p3-smart" --flagged --priority high
#   Expect: Created smart list: remctl-p3-smart / Filter: <description>
#   ⭐ Verify in Reminders.app: the smart list opens and shows the CORRECT filter (flagged AND high
#      priority). If it renders an EMPTY or GARBAGE filter, the filterData bytes are wrong (the encode
#      diverged from what Reminders.app expects) — report it. This is the byte-parity live proof.
$BIN smart-list-edit "remctl-p3-smart" --color purple    # update_smart_list (appearance-only; filter preserved)
$BIN smart-list-delete "remctl-p3-smart" --force          # delete_smart_list
```

## 5. Templates (selectors: create_template, apply_template, delete_template)
```sh
$BIN template-create "remctl-p3-tmpl" --from-list "remctl-p3-renamed" --include-completed
#   Expect: Created template: remctl-p3-tmpl ; verify it appears in `remctl templates`.
$BIN template-apply "remctl-p3-tmpl"        # Expect: Created list from template: remctl-p3-tmpl ; a new list appears.
$BIN template-delete "remctl-p3-tmpl" --force   # NOTE: delete is modeled as updateTemplate: — verify it actually removes the template from `remctl templates`.
```

## 6. Cleanup
```sh
$BIN delete <ids of remctl-p3-rem / remctl-p3-parent> --force
$BIN list-delete "remctl-p3-renamed" --force
$BIN list-delete "remctl-p3-groc" --force
# delete any list created by template-apply
```

## Known minor divergences (not bugs — for the record)
- **Subtask `--json` `private` array** is FLAT (each child update appended) rather than Python's nested
  `{bridgeUpdates, childPrivateUpdates}` inside the parent subtask result. Same writes occur; only the
  echoed JSON envelope shape differs.
- **`resolveRequiredListTarget` ambiguous message** uses plain single-quotes vs Python `{name!r}`
  (`pyRepr`) — identical except for names containing quotes/backslashes. (P8 list-pin uses `pyRepr`;
  list-edit/rename/delete use the shared helper. Minor inconsistency.)
- **`WriteFormatting.resolveMethod`** uses `.lowercased()` for the cosmetic JSON `method` label; a
  casefold-only name match (e.g. `ß`/`ss`) could mislabel `normalized` vs `case_insensitive`.
- **Grocery / template post-write polls** reuse a single injected attempts/delay for all re-reads
  (Python used split 8/24 attempt counts) — behaviorally identical on a settled store.
- **`set_early_reminder` unit codes 0–4** and **`delete_template` via `updateTemplate:`** are
  empirically-derived idioms — confirm them against live ReminderKit (steps 3 & 5).

## What to report back
The single most important result: **did step 1 (flag) materialize a real flag in Reminders.app?**
Then step 4 (smart-list filter renders correctly), and any command that returned an `Error:` about a
private-API fault / unrecognized selector (= a selector typo to fix), with the exact message.
