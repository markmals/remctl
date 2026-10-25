# Command Guide

A reference for every RemCTL command. RemCTL is a single self-contained Swift binary that reads the local Reminders database directly (read-only, needs Full Disk Access), writes ordinary fields through EventKit in-process, and writes private metadata (sections, subtasks, synced tags, attachments, urgent, Early Reminders, list/smart-list appearance, Groceries, templates) through Apple's private ReminderKit framework in-process. There is no `--private` flag and no helper subprocess: RemCTL chooses the EventKit or ReminderKit path from which flags you pass.

Run `remctl --help` for the parser-generated overview and `remctl <command> --help` for any command's exact options.

## Conventions

- **Nouns are read-only inspectors** (`lists`, `smart-lists`, `templates`, `today`, `stats`); **verb commands are writes** (`add`, `edit`, `delete`, `list-create`, `smart-list-create`, `template-create`). List management uses the `list-*` prefix, custom smart-list writes use `smart-list-*`, template writes use `template-*`.
- **List-name resolution** is conservative: exact match → case-insensitive → normalized fallback that ignores decorative punctuation and emoji prefixes (so `Weekly 513` resolves `🗓️ Weekly 513` when unambiguous). If more than one list matches, RemCTL fails and prints the candidate IDs — pass `--list-id` to disambiguate. Passing both a name and `--list-id` is an error. `show`, `search`, `add`, `edit`, `link`, `export`, `list-info`, `list-edit`, `list-pin`, `list-unpin`, `list-rename`, and `list-delete` accept `--list-id`; `list-pin`/`list-unpin` also accept `--smart-list-id`.
- **`--json`** works on commands that offer machine-readable output (`open` is human-only). For tabular read commands (`today`, `upcoming`, `overdue`, `flagged`, `urgent`, `lists`, `show`, `search`), `--format json|table|plain` can be passed globally before the command or on the command, so both `remctl --format table show Work` and `remctl show Work --format table` are valid. `export --format json|csv` selects a file format, not a display style.
- **`NO_COLOR=1`** (or `--no-color`) disables ANSI color.
- **Exit codes:** argument-parse errors (unknown flag, bad choice, missing argument) exit `64` (Swift Argument Parser's `EX_USAGE`). In-command validation errors (e.g. an unparseable due date) exit `1`/`2`.
- **Atomic validation:** if `-d/--due`, `--recurrence`, `--alarm`, `--priority`, or a location payload is present and cannot be validated, the command fails *before* creating or editing anything. With `--json`, an invalid due date emits a structured `invalid_due_date` error on stderr with accepted examples — retry with a corrected value rather than creating then patching. `import` validates the whole file the same way (structured `invalid_import`) before its first write.
- **Refusals Reminders would reject:** a relative alarm (`15m`, `1h`, `1d`) needs a due date to count back from, so `add`/`edit` refuse one when the reminder would have none (`relative_alarm_requires_due_date`), and `edit -d clear` on a repeating reminder is refused before any write (`repeating_reminder_requires_due_date`) unless the same edit also passes `--recurrence clear`. Both exit `1` and emit the structured code on stderr under `--json`.
- **Destructive commands need `--force` when nobody can answer:** `delete`, `list-delete`, `section-delete`, `group-delete`, `smart-list-delete`, and `template-delete` prompt on stderr only when stdin is a terminal and `--json` is off. With `--json`, or with a piped/redirected stdin, they refuse instead of blocking — exit `1`, `{"status":"error","code":"confirmation_required",…}` on stderr, nothing written. Pass `--force` to proceed.

### JSON error contract

For command-generated failures, `--json` (or a read command's `--format json`, including `export --format json`) writes one JSON object to stderr and leaves stdout empty. The exit status remains nonzero (usually 1; invalid date parsing remains 2). Human output keeps its existing wording. The object contains `status: "error"`, a stable snake_case `code`, and a nonempty `message`; additional keys such as `id`, `list`, `input`, `field`, `report`, `summary`, or `errors` give context. Parse `code` for decisions and display `message` for the person running the command. ArgumentParser syntax failures (unknown options, missing arguments, invalid option values) still use its exit 64 and help text; they are outside this contract.

Codes by area (the identifiers are stable; wording in `message` may vary):

| Code | Meaning |
| --- | --- |
| `database_unavailable` | The local Reminders store could not be opened. |
| `command_failed`, `write_failed`, `private_write_failed` | Unexpected command, EventKit, or ReminderKit failure; inspect `message`. |
| `reminders_access_denied`, `icloud_list_required` | Reminders access denied, or no writable iCloud list/source available. |
| `doctor_failed`, `onboarding_failed`, `setup_failed`, `unsupported_permissions_topic`, `unsupported_shell` | A setup check failed, onboarding failed, setup could not complete, a permissions topic was unsupported, or a shell was unsupported. Doctor and onboard attach the full check `report`. |
| `invalid_request`, `invalid_output_options`, `invalid_days`, `invalid_limit`, `invalid_offset` | Invalid command combination, incompatible output options, upcoming range, search limit, or search offset. |
| `not_found`, `reminder_not_found`, `no_stable_identifier`, `invalid_title` | Reminder missing, unavailable stable identifier, or missing create title. `reminder_not_found` identifies an item in a batch or reorder. |
| `invalid_due_date`, `invalid_completion_date`, `invalid_recurrence`, `invalid_alarm`, `invalid_priority`, `invalid_early_reminder`, `invalid_location` | Invalid reminder field. Date errors retain exit 2. |
| `early_reminder_requires_due_date`, `relative_alarm_requires_due_date`, `repeating_reminder_requires_due_date`, `completion_date_unsupported_for_recurring` | A due date or nonrecurring reminder is required for the requested alarm, recurrence edit, or completion date. |
| `invalid_rich_link_url`, `invalid_subtask`, `invalid_assignment`, `invalid_sharee_target`, `list_not_shared`, `sharee_ambiguous`, `sharee_not_found`, `sharee_owner_unknown`, `sharee_owner_missing` | Rejected link, subtask, or shared-list assignment; sharee resolution can be retried with a specific identifier. |
| `invalid_list_target`, `list_not_found`, `list_ambiguous`, `list_is_group`, `list_missing_identifier`, `invalid_list_edit`, `invalid_list_appearance`, `invalid_grocery_locale`, `invalid_grocery_target`, `grocery_categorization_failed`, `list_target_ambiguous` | Invalid or ambiguous list, a list group where a writable list is required, missing list identifier, list edit/appearance/Groceries failure, or a name that matches both a list and smart list. |
| `invalid_group_target`, `group_not_found`, `group_ambiguous`, `not_a_group`, `group_exists`, `group_missing_identifier`, `invalid_group_edit`, `list_not_in_group`, `group_not_empty`, `group_order_unverified`, `group_write_unverified`, `list_write_unverified` | List-group targeting, editing, membership, ordering, or verification failure. |
| `invalid_section_target`, `invalid_section_name`, `section_not_found`, `section_ambiguous`, `section_missing_identifier`, `section_exists`, `section_write_unverified` | Section targeting, name, existence, identifier, or post-write verification failure. |
| `invalid_smart_list_target`, `smart_list_not_found`, `smart_list_ambiguous`, `smart_list_not_custom`, `smart_list_missing_identifier`, `invalid_smart_list_filter`, `invalid_smart_list_edit`, `smart_list_already_exists`, `sectioned_smart_list` | Smart-list resolution, unsupported built-in/sectioned list, filter or edit validation, duplicate name, or missing identifier. |
| `invalid_template_target`, `template_not_found`, `template_ambiguous`, `template_already_exists`, `template_missing_identifier` | Template resolution, duplicate name, or missing identifier. |
| `invalid_import`, `invalid_import_json`, `import_read_failed`, `import_file_not_found`, `import_partial` | Invalid imported items or document, unreadable stdin, missing file, or a runtime failure after validation. `import_partial` includes already created identifiers in `createdIds`. |
| `batch_too_large`, `batch_failed`, `batch_partial`, `confirmation_required` | Too many reminder IDs, every item failed, some items failed, or a destructive write requires `--force`. Batch failure attaches per-item codes in `summary.results`. |
| `private_add_partial`, `flag_failed` | A reminder was created but private metadata failed, or flagging failed. Do not repeat `add` after `private_add_partial`. |
| `eventkit_read_unsupported`, `eventkit_read_failed` | Unsupported or failed limited EventKit read fallback. |
| `location_address_conflict`, `location_address_required`, `location_address_too_long`, `location_label_not_address`, `invalid_location_radius`, `invalid_timeout` | Invalid location input or geocoding timeout setting. |
| `location_ambiguous`, `location_imprecise`, `location_unconfirmed`, `location_not_found`, `location_lookup_denied`, `location_lookup_timeout`, `location_lookup_failed` | Geocoder result must be disambiguated, made more precise, confirmed, or retried. |
| `invalid_move`, `order_unavailable`, `order_unverified`, `hierarchy_unverified`, `reminder_unpositioned`, `anchor_unpositioned`, `level_unrecorded` | Reminder move/reorder is invalid, its order data is missing, or the result could not be verified. |
| `clone_move_missing_reminder_identifier`, `clone_move_missing_list_identifier`, `clone_move_missing_subtask_identifiers`, `clone_move_missing_new_identifier`, `clone_move_failed`, `clone_move_unverified`, `clone_move_original_not_deleted`, `list_move_with_subtasks_conflicts_with_edits` | Cross-list clone/delete move was refused or could not be verified; check `message` before retrying. |
| `tag_replacement_conflicts_with_tags`, `conflicting_tag_replacement_modes`, `set_tags_requires_tag`, `remove_tag_requires_tag` | Conflicting or empty synced-tag replacement arguments. |

---

## Viewing and Inspecting

### `today`
Reminders due today. Tabular: `--format json|table|plain`, `-v/--verbose`. `--no-overdue` excludes overdue items. `--via-eventkit` is a limited no-FDA fallback (see below). `today`, `upcoming`, `overdue`, and `stats` bucket and label a reminder by the date Reminders.app shows it on, which follows an absolute alarm set to another time than the due date.
```bash
remctl today
remctl today --json
remctl --format table today
remctl today --via-eventkit --json
```

### `upcoming [DAYS]`
Reminders due from today through `DAYS` more days (default 7; accepts 1–3650): the window always starts today, so `upcoming 1` covers today and tomorrow and `upcoming 7` today plus the next week. Zero/negative ranges fail before opening the database.
```bash
remctl upcoming
remctl upcoming 14
remctl --format table upcoming 14
```

### `overdue`
Reminders past their due date.
```bash
remctl overdue
remctl overdue --json
```

### `search <query> [--completed] [-l NAME|--list-id ID] [--limit N] [--offset N]`
Search reminder titles, notes, and saved rich links. Active reminders only by default; `--completed` includes completed reminders.
```bash
remctl search "milk"
remctl search "milk" --completed --json
remctl search "macstories.net" --list Work
remctl search "invoice" --list-id 153 --limit 50 --offset 50 --json
remctl search -- -urgent
```

Matching ignores case and accents, so `cafe` finds `Café`, and `%`, `_`, and `\` are ordinary characters. `-l/--list NAME` or `--list-id ID` limits the search to one list; if several lists share a name, the command stops and prints the candidate ids. Results are newest first, 100 per page. A query that starts with `-` needs the `--` separator.

With `--json` and no paging option the output stays a plain array, and stderr warns when matches were cut off. `--limit N` (1 to 500) or `--offset N` switch `--json` to a page object: `{"query", "items", "count", "total", "offset", "limit", "hasMore", "nextOffset"}`, plus `"list"` when the search is scoped. Pass `nextOffset` as the next `--offset` until `hasMore` is false. An out-of-range `--limit` or a negative `--offset` exits `1` before any read (`invalid_limit` / `invalid_offset` under `--json`).

### `flagged`
Reminders with the real flag set (shown with `⚑`).
```bash
remctl flagged
```

### `urgent`
Urgent reminders (macOS 26 urgent state, shown with `⏰`).
```bash
remctl urgent --json
```

### `tags`
List tags, or reminders grouped by tag. `--json`, `--no-color`.
```bash
remctl tags
```

### `subtasks <id>`
Show a reminder's subtasks, in Reminders' stored display order. `--json`.
```bash
remctl subtasks 23880
remctl subtasks 23880 --json
```

### `sections`
Show list sections. `--json`, `--no-color`.
```bash
remctl sections
```

### `sharees [LIST] [--list-id ID]`
Show the people available for assignment in a shared list. `--json`, `--no-color`. The current user is marked `(me)` (JSON: `currentUser: true`); `currentUserSharee` carries the owner's sharee object UUID. Unshared lists report `No sharees`.
```bash
remctl sharees Family
remctl sharees Family --json
```

### `list-info [NAME] [--list-id ID]`
One list plus what a write into it needs: the object `lists --json` emits for that list, then its `sections` (each `{id, name}`, where `id` is the section ID `--section-id` takes), its `sharees` (same objects as `sharees`), and `shared`. `--json`, `--no-color`. Pass a name or `--list-id`, not both. A list group is refused with its child lists, like any other write target. When the name only matched case-insensitively or through the normalized fallback, the JSON adds `resolvedFrom` with the name you typed. Human output prints `Sections: none` and `Not shared` for a bare list.
```bash
remctl list-info Work
remctl list-info Work --json
remctl list-info --list-id 153 --json
```

### `stats`
Reminder statistics. `--json`, `--no-color`.
```bash
remctl stats
```

### `location-lookup <query>`
Resolve an address to coordinates for a location alarm, without writing anything. `--timeout SECONDS` (1–30, default 10), `--json`. This is the same lookup `add`/`edit --location-address` run, so it is the way to check an address before a write.

`status` is `resolved` (safe to use), `ambiguous` (several matches), `imprecise` (one match covering a whole city or region), `unconfirmed` (a different street, or no town or postal code — see `reason`), or `not_found`. Only `resolved` sets `usable: true` and a `location`; the others list what the geocoder returned under `candidates` with `name`, `address`, coordinates, `precision` (`street`/`place`/`area`) and `regionRadius`, and exit 0 so a caller can inspect them. Personal labels such as `Home` or `Work` are refused (`location_label_not_address`): pass the real address and label it with `--location-title`. The lookup needs network access, but no Reminders access, no Full Disk Access and no Location Services permission.

```bash
remctl location-lookup "Piazza Navona, Rome"
remctl location-lookup "1 Apple Park Way, Cupertino, CA 95014" --json
```

### `show [LIST] [--list-id ID] [--completed]`
Reminders in a list (name positionally or `--list-id`), in Reminders' stored manual display order when the list has one; reminders not yet in that record follow, in id order. Tabular: `--format`, `-v`. `--completed` includes completed reminders. `--via-eventkit` is a limited no-FDA fallback (requires a list name, not `--list-id`). Groceries lists show `🥕`; `show --json` includes `sectionEmoji` for known Groceries categories. Naming a list group shows the reminders of its child lists instead, grouped by child list and each in that list's own manual order; `--format table` prints one table per child list (and per section), and `show <group> --json` names the owning `list` and `group` on every reminder. A group with no child lists reports `No child lists in group '<name>'`.
```bash
remctl show Shopping
remctl show --list-id 153 --json
remctl show Work --completed
remctl show Family -v
remctl show Writing          # a list group: every child list's reminders
```

### `info <id>`
Detailed reminder info. `--json`, `--no-color`. `info --json` reports `dueDate` (the actual due date) vs `displayDate` (a separate UI/alert date — do not treat as the due date), `alarms` (EventKit relative/absolute alarms and location alarms), Early Reminders as labels (e.g. `15 minutes before`), recurrence, tags, sections, subtasks, parent and subtask image attachments, the deep link, and a rich-link `url` when present. An all-day `dueDate` is local midnight of its day in every time zone, and `displayDate` is omitted when it names the same moment as `dueDate`. The human output adds a `Shown at:` line when Reminders lists a timed reminder at another time than its due date (an absolute alarm an earlier due edit left behind). Prefer this over raw SQLite checks.
```bash
remctl info 23880
remctl info 23880 --json
```
`--include-deleted` also looks in [Recently Deleted](#recently-deleted) when no live reminder has that ID.

---

### Limited EventKit Read Fallback (`--via-eventkit`)

`--via-eventkit` is a limited read-only fallback for hosts that cannot get Full Disk Access. It never opens the Reminders SQLite database — it reads through the in-process EventKit API instead, so only the macOS Reminders permission is needed. It is never the default and is supported only by `show`, `search`, `today`, and `upcoming`. It reads iCloud Reminders lists only: an unnamed scope covers every iCloud list, and a named list in a local or third-party account is refused rather than mixed in. `search` matches titles, notes, and the saved rich-link URL, and takes `-l/--list NAME`; `--list-id` and `--limit`/`--offset` are refused (exit `2`, `eventkit_read_unsupported`).

It is not full RemCTL output: no RemCTL numeric IDs, table output, sections, synced tags, private rich links, urgent state, or template/smart-list internals. JSON output is a wrapper object, not the normal read-command array:

```json
{
  "source": "eventkit",
  "fidelity": "limited",
  "mode": "show",
  "idWarning": "eventKitId is not a RemCTL numeric id and cannot be passed to info, edit, done, delete, link, open, subtasks, or any other numeric-id command.",
  "limitations": ["No RemCTL numeric ids", "..."],
  "items": [
    { "eventKitId": "EVENTKIT-CALENDAR-ITEM-ID", "title": "Review PR", "list": "Work", "completed": false, "priority": "none" }
  ]
}
```

Treat `eventKitId` as display/readback data only — never pass it to a numeric-ID command. Agents must not use `--via-eventkit` by default; it is only for when Full Disk Access blocks a basic read and the task needs neither chainable IDs nor private metadata. If an automation needs those, fix Full Disk Access and use the normal read path.

```bash
remctl show Work --via-eventkit
remctl search "milk" --via-eventkit
remctl today --via-eventkit --json
remctl upcoming 14 --via-eventkit --json
```

---

## Recently Deleted

```bash
remctl deleted --json
remctl deleted --limit 50 --offset 50 --json
remctl info 23880 --include-deleted --json
remctl restore 23880 --list Work --json
remctl restore 23880 --list-id 153 --json
```

### `deleted [--limit N] [--offset N]`
Asks Apple's Recently Deleted view for the recoverable reminders of the last 30 days. It does not
treat every deleted database row as recoverable: the deleted flag also marks rows Reminders has
already purged. This needs a supported account and macOS version; an unavailable query fails with
`recently_deleted_unavailable` instead of falling back to old deletion records.

`--json` always returns `{items, count, total, offset, limit, hasMore, nextOffset}`. Pages count
parents, with their deleted subtasks nested under `subtasks`. Each item has `deleted: true`,
`recoverable: true`, and `restoreId`, the numeric parent ID to recover. `list` can be null because
deletion clears the original list. RemCTL does not infer a deletion date or recovery deadline from
the last modification time.

### `info <id> --include-deleted`
Checks active reminders first, then Recently Deleted. Deleted details contain the saved title,
notes, dates, identity, and subtask hierarchy; they are not a complete export of private metadata.
Other reads still exclude deleted reminders.

### `restore <id> --list NAME|--list-id ID`
Restores one parent and its subtasks through ReminderKit, then checks every ID and parent
relationship before reporting `verified: true`. The destination list is required and must be in
the same account as the deleted reminder. A subtask must be recovered through its `restoreId`
(`restore_parent_required`), which brings the whole tree back. The command preserves identity
rather than creating a replacement. If that ID is already active in the requested list it returns
`already_restored` without writing or claiming that former subtasks were recovered; it never moves
an active reminder to another list (`reminder_not_deleted`).

For `restore_unconfirmed`, inspect `info ID --include-deleted --json` and `deleted` before
retrying: a write may already have happened. RemCTL does not permanently purge Recently Deleted.
Apple can expire or remove items between a read and a restore.
[Apple's recovery documentation](https://support.apple.com/guide/reminders/remna83c9566/mac).

---

## Creating and Editing

### `add <title>`
Create a reminder. Key flags: `-l/--list` or `--list-id`, `-n/--notes`, `-d/--due`, `-p/--priority high|medium|low|none`, `--recurrence`, `--alarm`, `--url`, `-f/--flag`, `-t/--tags`, `--grocery`, `--section`/`--section-id`/`--new-section`, `--smart-list`/`--smart-list-id` (with `--section`/`--section-id`), `--subtask` (repeatable), `--image` (repeatable), `--urgent/--no-urgent`, `--early-reminder`, `--assign`/`--unassign`, `--location-title`/`--latitude`/`--longitude`/`--radius`/`--proximity arriving|leaving`, `--location-address`, `--json`.

Date-only `-d` inputs (`today`, `tomorrow`, `2026-06-01`, `+3d`, `in 2 weeks`, `next friday`, and natural-language dates such as `march 30`) create **all-day** reminders; inputs with explicit times create timed reminders.

`add --json` returns `numericId` when the new reminder is resolvable in the local database — use it for `info <numericId> --json` (fall back to matching the title via `show <list> --json` if absent).

```bash
remctl add "Buy milk"
remctl add "Review PR" -l Work -d "tomorrow 10:00" -p high
remctl add "Write column" --list-id 156
remctl add "Pay rent" -d "2026-06-01" --recurrence monthly
remctl add "Standup" --recurrence "weekly mon,wed,fri" --alarm 15m
remctl add "Leave early" -l Work -d "today 14:00" --early-reminder 15m
remctl add "Research" -l Projects --url "https://example.com" -t remctl --new-section "Research"
remctl add "Launch assets" -l Projects --subtask '{"title":"Export PNG","notes":"Use final crop","due":"tomorrow","url":"https://example.com","tags":["media"]}'
remctl add "Leave now" -l Work --urgent
remctl add "Milk" -l Groceries --grocery
remctl add "Pick up groceries" -l Family --assign Alex
remctl add "Pick up prints" --location-title "Apple Park" --latitude 37.3349 --longitude=-122.0090 --radius 200
remctl add "Pick up prints" --location-address "1 Apple Park Way, Cupertino, CA 95014"
```

How RemCTL picks the path from context on a bare `add`:

- `--url` alongside private metadata becomes a synced web rich link and requires a public `http`/`https` host — loopback, private, `.local`, fake-IP (`198.18.0.0/15`) and IPv4-mapped IPv6 spellings of those are rejected before anything is written (`--json`: `{"status":"error","code":"invalid_rich_link_url",…,"url":…}` on stderr). With no other private metadata it only appends to notes.
- `-t/--tags` writes inline `#hashtag` title tokens on a bare add, but synced tags when private metadata is present (`edit --tags` is always a synced-tag write).
- `-f/--flag` always writes the real Reminders flag through ReminderKit, so it implies the private path (as `edit --flagged` does). EventKit has no flagged API, so a failed flag write is reported as an error — RemCTL never substitutes a priority change.
- Private targets that can be checked up front (`--section`, `--section-id`, `--smart-list`/`--smart-list-id`, `--assign`) are resolved **before** the reminder is created. If a private step fails after the create, `add` exits 1 reporting the created reminder, the steps that completed, and the failed one, and tells you to finish with `edit` rather than re-running `add` (`--json`: `{"status":"error","code":"private_add_partial",…}` on stderr).

### `edit <id>`
Edit an existing reminder. Flags: `--title`, `-l/--list` or `--list-id` (move; see below), `-n/--notes`, `-d/--due` (or `clear`), `-p/--priority`, `--url`, `--recurrence`, `--alarm` (or `clear`), `--location-title`/`--latitude`/`--longitude`/`--radius`/`--proximity arriving|leaving`, `--location-address`, `-t/--tags`, `--set-tags`, `--clear-tags`, `--remove-tag` (repeatable), `--grocery`, `--section`/`--section-id`/`--new-section`, `--smart-list`/`--smart-list-id` (with `--section`/`--section-id`), `--subtask` (repeatable), `--image` (repeatable), `--flagged/--no-flagged`, `--urgent/--no-urgent`, `--early-reminder`, `--assign`/`--unassign`, `--json`.

Date-only `-d` values keep the reminder all-day through the edit (re-setting the same all-day date nudges by a day, not an hour, so the change still syncs).

Rich-link and image edits are **additive** — RemCTL adds, never removes or replaces existing links/images. `--section` resolves by name inside the target list (a single non-empty match wins on duplicates; use `--section-id` otherwise). When combined with `-l/--list`, section resolution uses the destination list.

`--smart-list NAME` or `--smart-list-id ID` makes `--section`/`--section-id` name one of that custom smart list's own sections instead (on `add` too). The section is resolved before anything is written — a built-in smart list, an unknown or ambiguous section, or a combination with `--new-section` changes nothing (`smart_list_not_custom`, `section_not_found`, `section_ambiguous`, `invalid_section_target` under `--json`) — and the write is read back from the smart list (`verified: true` in the `private` result). `smart-lists` shows the section ids.

```bash
remctl edit 23880 --smart-list "This Week" --section Next
remctl add "Draft agenda" -l Work --smart-list-id 42 --section-id 6C6828D7-B2B7-45A6-82AD-D26A8A484B1F
```

`--url` on a public edit appends to the existing notes instead of replacing them; pass `-n/--notes` to replace the body first (`-n ""` clears it). A URL already present in the notes as its own word is not appended a second time, so repeating the same edit is safe.

`-t/--tags` **adds** synced tags. `--set-tags a,b` replaces the whole synced tag set with exactly `a,b`, `--clear-tags` removes every tag, and repeatable `--remove-tag x` drops the named tags (matched case-insensitively) while keeping the rest. The three replacement flags are mutually exclusive with each other and with `-t/--tags`; a conflicting or empty request is refused before anything is written (`tag_replacement_conflicts_with_tags`, `conflicting_tag_replacement_modes`, `set_tags_requires_tag`, `remove_tag_requires_tag` under `--json`).

An edit that changes nothing prints `Nothing to update.` and exits 0; under `--json` that is `{"status":"unchanged","code":"nothing_to_update","id":…,"title":…,"message":"Nothing to update."}`. Every `edit --json` result echoes `title`.

Location alarms are range-checked before the first write: `--latitude` -90 to 90, `--longitude` -180 to 180, `--radius` 1 to 100000 meters (`invalid_location_radius` under `--json`).

`--location-address ADDRESS` (`--address` is a hidden alias; passing both is an error) resolves the address to coordinates before anything is written — see [Location alarms](#due-dates-recurrence-alarms-early-reminders-locations). It cannot be combined with `--latitude`/`--longitude` (`location_address_conflict`).

**List moves.** An ordinary move goes through EventKit and keeps the reminder's id. A reminder
that owns subtasks cannot be moved that way, so RemCTL clones the parent and its subtasks into
the destination through ReminderKit, verifies the clone in the store, then deletes the original
— the same fallback runs when EventKit refuses a childless move across a list or container
boundary. The moved reminder therefore gets a **new id**: `--json` reports `method:
"clone-delete"` with `id` (new), `oldId`, `objectUUID`, `subtasksMoved`, and `originalDeleted`;
human output prints `Moved #OLD -> #NEW`. A clone-delete move cannot be combined with other edit
flags (`list_move_with_subtasks_conflicts_with_edits`) — move first, then edit the new id. When
the clone cannot be verified the original is left in place and nothing is deleted
(`clone_move_unverified`).

Writes target iCloud Reminders lists. A list that lives in a local or third-party account is
refused rather than silently written to the wrong account, and duplicate list titles are resolved
by the list's stable identifier.

```bash
remctl edit 23880 --title "New title"
remctl edit 23880 -d "next friday" -p medium
remctl edit 23880 -d clear
remctl edit 23880 -l Work
remctl edit 23880 --recurrence "weekly mon,wed"
remctl edit 23880 --alarm clear
remctl edit 23880 --section "Research" --subtask "Follow up"
remctl edit 23880 --image ~/Desktop/mockup.png --flagged --urgent
remctl edit 23880 --set-tags remctl,work
remctl edit 23880 --remove-tag stale --remove-tag old
remctl edit 23880 --clear-tags
remctl edit 23880 --early-reminder 1h
remctl edit 23880 --early-reminder clear
remctl edit 23880 --location-title "Apple Park" --latitude 37.3349 --longitude -122.0090 --radius 200
remctl edit 23880 --assign alex@example.com
remctl edit 23880 --assign me
remctl edit 23880 --unassign
```

`--assign USER` targets the reminder's shared list and resolves `USER` against its sharees by display name, first/last name, email or phone address, numeric sharee ID, object UUID, or `me`. Run `remctl sharees LIST --json` first when scripting and prefer the returned `address`, `id`, or `objectUUID` — names can collide (ambiguity fails with the candidate list). `--unassign` clears the current assignment; the two flags are mutually exclusive. Verify with `remctl info ID --json` under `assignment`.

### `reminder-move <id>`
Reorder a reminder through ReminderKit: exactly one of `--before ID`, `--after ID`, `--first`, or `--last`. Without `--smart-list`, both reminders must share a list and the move rewrites that list's order (Reminders' `ZREMINDERIDSMERGEABLEORDERING`); `show` reads the same order back. With `--smart-list NAME` or `--smart-list-id ID`, the move rewrites an **unsectioned custom smart list's** manual order instead, so reminders from different lists can be ordered against each other. RemCTL refuses before writing when the smart list is built in or sectioned, when Reminders has not recorded a manual order for it yet (reorder one reminder in Reminders.app once), or when the reminder or anchor has no recorded position. Every move is read back from the store and reported with `verified: true` (`verifiedAfterHelperError: true` when ReminderKit reported an error but the order landed anyway); an order the store never shows fails with `order_unverified`. `--json`.

Subtasks: `--parent ID` nests the reminder under another top-level reminder in the same list (placed last among its subtasks unless a position is given), and `--top-level` makes a subtask a reminder of its own (placed right after its former parent unless a position is given). A subtask moved with `--before`/`--after`/`--first`/`--last` alone is reordered among its parent's subtasks; its anchor must be one of them. The reminder keeps its id, notes, dates, and everything else. Reminders allows one level of subtasks, so a subtask cannot become a parent and a reminder with subtasks cannot be nested; a parent in another list is refused with the `edit -l` to run first; and a level whose reminders Reminders has not all recorded yet is refused (`level_unrecorded`). JSON reports `hierarchy` (`nested`, `unnested`, or `reordered`), `parentId`, and the verified structure (`hierarchy_unverified` when the store never shows it). A reminder moved to the top level next to a sectioned reminder joins that section, as a drop does in Reminders (`section`; a `section_not_set` warning if it did not).
```bash
remctl reminder-move 23880 --before 23881
remctl reminder-move 23880 --last --json
remctl reminder-move 23880 --after 23881 --smart-list "Focus"
remctl reminder-move 23880 --first --smart-list-id 170 --json
remctl reminder-move 23882 --parent 23880
remctl reminder-move 23882 --parent 23880 --after 23883
remctl reminder-move 23882 --top-level --json
```

### `done <id> [<id>…]` / `undone <id> [<id>…]`
Mark reminders complete or incomplete. `--json`. `done --date` sets an explicit completion date (`YYYY-MM-DD` or `YYYY-MM-DD HH:MM`; strict — natural-language forms are rejected before any write). `--date` is not supported on recurring reminders: completing those advances the series, so run plain `done` instead.
```bash
remctl done 23880
remctl done 23880 --date "2026-05-27 09:30"
remctl undone 23880
remctl done 23880 23881 --json
```

### `delete <id> [<id>…] [--force]`
Delete reminders; `--force` skips the confirmation prompt (and is required with `--json` or a non-interactive stdin). A batch asks once, listing every reminder it would delete. `--json`. Supported accounts keep a deleted reminder in Reminders' Recently Deleted list for up to 30 days, where Reminders.app can recover it.
```bash
remctl delete 23880
remctl delete 23880 --force
remctl delete 23880 23881 --force --json
```
Recover one with [`restore`](#restore-id---list-name--list-id-id).

### Batches of ids (`done`, `undone`, `delete`)
Pass several ids — up to 50, listed before the options — to run one batch; `--batch` gives a single id the same result shape. More than 50 ids is refused (`batch_too_large`) without reading or writing anything.

Every id is resolved before the first write, so an unknown id (`reminder_not_found`), a reminder without a stable identifier (`no_stable_identifier`), and `done --date` on a recurring reminder (`completion_date_unsupported_for_recurring`) are reported without touching the rest of the batch. Repeated ids are written once and listed under `duplicatesIgnored`. A write that fails reports `write_failed` for that id and the batch continues. A batch `delete` asks once for every reminder it would delete; its `confirmation_required` refusal lists them under `ids`. The batch exits `1` unless every id succeeded (a declined delete prompt exits `0` and writes nothing).
```bash
remctl done 23880 23881 23881 --json
```
```json
{"status": "error", "code": "batch_partial", "message": "1 reminder(s) could not be completed.", "summary": {"status": "partial", "operation": "done", "requested": [23880, 23881, 23881], "succeeded": [23880], "failed": [23881], "results": [{"id": 23880, "status": "completed", "title": "Pay rent", "list": "Home"}, {"id": 23881, "status": "not_found", "code": "reminder_not_found", "message": "#23881 not found"}], "duplicatesIgnored": [23881]}}
```
All-success batches report `completed`/`uncompleted`/`deleted` on stdout. Failed batches report `batch_partial` or `batch_failed` on stderr with the original per-item outcome in `summary` and empty stdout. Human output keeps one `Completed: #id title` line per success, one `Error: …` line per failure on stderr, and a closing `N of M completed` count.

### `flag <id>` / `unflag <id>`
Toggle the flagged state. `--json`.
```bash
remctl flag 23880
remctl unflag 23880
```

### Due dates, recurrence, alarms, Early Reminders, locations

**Due dates** are atomic (see Conventions). Accepted forms:

| Format | Example |
| --- | --- |
| ISO date | `-d 2026-04-15` |
| ISO date and time | `-d "2026-04-15 14:00"` |
| `today` / `tomorrow` | `-d today`, `-d tomorrow` |
| `today at <time>` | `-d "today at 3pm"` |
| `tomorrow <time>` | `-d "tomorrow 09:30"` |
| `tonight at <time>` | `-d "tonight at 11"` |
| `<day> at <time>` | `-d "Friday at 15:00"` |
| `next <day> at <time>` | `-d "next friday at 3pm"` |
| `+Nd` | `-d +3d` |
| `eod` / `eow` | `-d eod`, `-d eow` |

`edit -d clear` clears the due date. Date-only forms (first row, `today`/`tomorrow`, `+Nd`, `in N days/weeks/months`, bare weekdays, `eow`, natural-language dates such as `march 30`) create **all-day** reminders; forms with explicit times create timed reminders (`eod` is timed: 17:00).

**Recurrence** (EventKit, on `add` and `edit`): `daily`, `weekly`, `weekly mon,wed,fri`, `monthly`, `monthly 1,15`, `monthly 4th-fri`, `yearly` — validated before write. Each frequency takes an optional interval token `xN` (1 to 999) directly after it: `daily x2`, `weekly x2 thu`, `monthly x3 15`, `monthly x2 4th-fri`, `yearly x2`. `edit ID --recurrence clear` (also `none` or `never`) stops the repeat; a repeating reminder keeps its due date otherwise, so `edit ID -d clear --recurrence clear` is the way to remove both. Recurring reminders show a `↻` badge (and a `Repeat` column in table output) such as `↻ monthly 4th Fri` or `↻ every 2 months 4th Tue`; an occurrence count renders as `↻ daily, 5 times`. JSON decodes the rule back to a `recurrence` object; week-pinned weekdays come back as `daysOfWeekDetailed` entries carrying `weekNumber`, and the limited `--via-eventkit` read returns a flat `weekNumbers` array instead (omitted when no day is pinned).

`monthly` also accepts Nth-weekday tokens in place of day-of-month numbers: `monthly 4th-fri` is the 4th Friday, `monthly 1st-mon,3rd-mon` the 1st and 3rd Monday, and `monthly last-fri` an alias of `monthly -1-fri`, with negative forms down to `-5-fri`. The ordinal suffix must match the number (`4st-fri` is rejected); Nth-weekday tokens can't be mixed with day-of-month numbers in one rule and are monthly-only. EventKit skips months that lack the requested weekday, so `monthly 5th-fri` fires only in months with a fifth Friday; use `monthly last-fri` for the last Friday of every month.

A recurrence **object** — exactly the shape `export` and `info --json` emit (`frequency`, `interval`, `daysOfWeek`/`daysOfWeekDetailed`/`weekNumbers`, `daysOfMonth`, `monthsOfYear`, `daysOfYear`, `weeksOfYear`, `setPositions`, `count`, `endDate`) — is also accepted anywhere a recurrence spec is, so exported rules round-trip back through `import`, `--subtask` JSON, and `--recurrence`. Every field is validated before the write; an unknown field, an out-of-range value, `{}`, or `endDate` together with `count` is rejected.

**Alarms** (`--alarm 15m`, `1h`, `1d`, or an absolute date) are EventKit alarms; they appear under `alarms` in `info --json`. `edit --alarm clear` removes normal alarms. `edit -d` carries matching absolute alarms forward — Reminders stores one acknowledged copy per device, and all copies move together — or removes them when the new due date is all-day; `edit -d clear` removes matching absolute alarms/display times while preserving unrelated alarms.

**Early Reminders** (`--early-reminder`) are a *separate* Reminders Early Reminder (a private due-date delta alert, not an EventKit alarm). Accepts `15m`, `1h`, `2d`, `1w`, `1mo`, or `clear`; a non-clear value requires a due date. JSON readback includes `earlyReminder`/`earlyReminders`.

**Location alarms** (`--location-title` with `--latitude`/`--longitude`, plus `--radius` and `--proximity arriving|leaving`) are written through EventKit structured-location alarms, on both `add` and `edit`. They are a public write — no private metadata is involved. A reminder keeps at most one location alarm — editing the location replaces the existing one instead of stacking another — while time alarms are left alone. Verify in `info --json` under `alarms` with `type: "location"` and a `location` object (title, coordinates, radius, proximity).

**`--location-address ADDRESS`** replaces the coordinates with a street address. RemCTL looks it up with Apple's geocoder (10-second deadline) after every other check and **before the first write**, and uses the match only when it is the only one, is street-sized, names the street or place typed, and the address gives a town or postal code. Apple's geocoder returns a best guess even for a street it did not find, so anything else stops the command and nothing is created or changed: `location_not_found`, `location_ambiguous`, `location_imprecise`, or `location_unconfirmed` (with `reason` `street_mismatch` or `no_town`), each carrying `query` and `candidates`. Lookup problems report `location_address_required`, `location_address_too_long` (512 characters), `location_label_not_address` (a personal label such as `Home` — pass the real address and use `--location-title` for the label), `location_lookup_timeout`, `location_lookup_denied`, or `location_lookup_failed`. On success `--location-title` defaults to the match's name, `add`/`edit` print a `Location:` line, and `--json` gains `resolvedLocation` (`query`, `title`, `address`, `latitude`, `longitude`, `precision`, `radius`, `proximity`, `source: "geocoded"`). Use [`location-lookup`](#location-lookup-query) to inspect an address first. The geocoder needs network access but no Location Services permission; the resolved street address itself is not stored, because EventKit's structured location carries only a title, coordinates and a radius.

### Subtasks

`--subtask` (repeatable on `add` and `edit`) accepts a plain child title or a JSON object with: `title`, `notes`, `due`, `priority`, `alarm`, `recurrence`, `earlyReminder`, `url`/`urls`, `tags`, `image`/`images`, `flagged`, `urgent`, and location fields. A date-only `due` makes the child all-day; `recurrence` takes a string spec or an exported recurrence object. Rich subtask URLs follow the public-host rule. Subtask image/link edits are additive; only images attach (generic file/PDF attachments are rejected).

```bash
remctl add "Prepare screenshots" -l Projects --image ~/Desktop/mockup.png --subtask "Export PNG"
remctl edit 23880 --subtask '{"title":"Follow up","due":"next friday at 3pm","url":"https://example.com","tags":["work"]}'
```

---

## Lists

### `lists`
List all lists. `--format json|table|plain`, `--no-color`. `lists --json` includes `color`, `badge`, pin state, and Groceries fields (`listType`, `isGroceries`, `grocery` locale). Human output marks Groceries lists with `🥕`.

Reminders list groups are containers for lists, not for reminders, and `lists` is the view that shows the hierarchy: a group prints its child lists indented beneath it, and the footer counts lists and groups separately. In `lists --json` a group carries `listType: "group"`, `isGroup: true`, its child lists under `children` (in Reminders' child order) and summed reminder `counts`; each child repeats at the top level with `parentListId`, its `group` stub, and its own `counts`. Groups never carry Groceries metadata. Everywhere else a group is not a list: `stats` leaves groups out of its list count, and naming one as a reminder target (`add -l`, `edit -l`, `--list-id`) fails with the group's child lists listed as alternatives.
```bash
remctl lists
remctl lists --json
```

### `list-create <name>`
Create a list. Appearance: `--color NAME` (named colors `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `brown`, `gray`, `cyan`, `teal` use EventKit; an unrecognized name is an error, not a silently colorless list). A `--symbol` or `--emoji` uses the ReminderKit appearance path. Groceries: `--groceries` with `--grocery-locale en_US`. `--group NAME` or `--group-id ID` creates the list inside a list group: the group is resolved before anything is written, the list is created through ReminderKit and then moved into the group, and both are read back from the store (`verified: true`, with the new list's `id`, `objectUUID`, `group`, and `membership`). New lists are created in the iCloud Reminders account; without one, `list-create` fails instead of writing to a local or third-party account.

After the write, `list-create` polls the local store for the new row (eight tries, 0.25 s apart) and reports its numeric `id` — in JSON, and as an `ID:` line in human output. If the row is not visible yet, the list still exists: JSON then carries `warnings: ["list_id_unavailable: …"]` instead of `id`, and `lists` will show it.
```bash
remctl list-create "Project X" --color blue
remctl list-create "Research" --color orange --symbol education3
remctl list-create "Cold Ideas" --color cyan --emoji 🥶
remctl list-create "Groceries" --groceries --grocery-locale en_US
remctl list-create "Drafts" --group Writing --json
```

### `groups` / `group-info [NAME] [--group-id ID]`
`groups` lists the list groups with their child lists (in Reminders' child order) and active/completed/total reminder counts. `--format json|table|plain`, `--no-color`. `group-info` shows one group by name or `--group-id`: its id, object UUID, counts, child lists, and `suggestedCommands` for the writes below. `--json`.
```bash
remctl groups --format table
remctl group-info Writing --json
```

### `group-create <name>` / `group-edit [NAME]` / `group-delete [NAME]`
Create, edit, and delete list groups through ReminderKit. Moving a list into or out of a group changes only its container: the list keeps its id and every reminder in it.

- `group-create NAME [--add-list LIST]… [--add-list-id ID]…` refuses a name a list or group already uses (`group_exists`), creates the group, then moves the named lists into it.
- `group-edit` renames (`--new-name`), adds lists (`--add-list`/`--add-list-id`; a list already in the group is reported as skipped), removes lists to the top level (`--remove-list`/`--remove-list-id`; a list not in the group is refused with `list_not_in_group`), or reorders: `--move-list LIST`/`--move-list-id ID` with exactly one of `--before-list`/`--before-list-id`/`--after-list`/`--after-list-id`/`--first`/`--last`. The moved list may be a child already or join the group at that position. Reordering runs on its own (not with add/remove). Reminders puts a list it adds to a group at the top, so a reorder detaches every child and re-attaches them in reverse of the requested order; if it stops part-way, the error names the lists left at the top level (`listsAtTopLevel` under `--json`).
- `group-delete` moves every child list to the top level, confirms the group is empty, then deletes it. `--force` skips confirmation (and is required with `--json` or a non-interactive stdin).

Every edit is validated before the first write, and every write is read back from the store before the next one starts; JSON output reports `verified: true`, and an unconfirmed write fails with `group_write_unverified` (or `group_order_unverified`).
```bash
remctl group-create Writing --add-list Editorial --add-list-id 475 --json
remctl group-edit Writing --new-name Drafts
remctl group-edit Writing --add-list Podcasts --remove-list Socials
remctl group-edit Writing --move-list Editorial --before-list Podcasts
remctl group-edit --group-id 476 --move-list-id 137 --last --json
remctl group-delete Writing --force
```

### `list-edit [NAME] [--list-id ID]`
Edit a list's appearance and type. `--new-name`, `--color NAME` or `#RRGGBB`, `--symbol`, `--emoji`, `--groceries`/`--standard`, `--grocery-locale`. A `#RRGGBB` hex, `--symbol`, or `--emoji` uses the ReminderKit appearance path; a named `--color` uses EventKit.
```bash
remctl list-edit Projects --color orange --symbol education3
remctl list-edit "Project X" --color '#FF8D28'
remctl list-edit "Shopping" --groceries --grocery-locale it_IT
remctl list-edit "Shopping" --standard
remctl list-edit --list-id 144 --emoji 📌
```

### `list-pin [NAME]` / `list-unpin [NAME]`
Toggle the Reminders.app sidebar pin for a regular list (`--list-id`) or a smart list (`--smart-list-id`). If a name matches both a regular and a smart list, RemCTL fails and asks for an explicit ID. Verify smart-list pinning with `smart-lists --json`. Custom and built-in smart lists use different ReminderKit fetches and RemCTL says which kind it is targeting: on macOS versions whose store does not expose the built-in (generic) fetch, built-in pinning fails before saving; custom smart-list pinning is unaffected.
```bash
remctl list-pin "Project X"
remctl list-pin --smart-list-id 4
remctl list-unpin --list-id 144
```

### `list-rename [NAME] [NEW-NAME]`
Rename a list. Target by name + new name positionally, or `--list-id` + `--new-name`.
```bash
remctl list-rename "Project X" "Project Y"
remctl list-rename --list-id 123 --new-name "Project Archive"
```

### `list-delete [NAME] [--force]`
Delete a list (by name or `--list-id`); `--force` skips confirmation (and is required with `--json` or a non-interactive stdin).
```bash
remctl list-delete "Project Y" --force
remctl list-delete --list-id 144 --force
```

### `section-create <name>` / `section-rename [NAME]` / `section-delete [NAME]`
Create, rename, or delete a section in one list, named with `-l/--list` or `--list-id` (list groups are refused). `section-rename` takes `--new-name`; rename and delete target the section by name or `--section-id` (as `--section`/`--section-id` resolve on `add`/`edit`). A name another section of the list already uses (compared case-insensitively) is refused before writing (`section_exists`). A new section is appended to the list's current section order, so creating one keeps the order Reminders shows. Deleting a section keeps its reminders in the list, unsectioned; `--force` skips confirmation (and is required with `--json` or a non-interactive stdin). Every write is read back from the store and reported with `verified: true`; if the store never shows it, the command fails with `section_write_unverified`. Under `--json`, errors are structured on stderr (`list_not_found`, `list_is_group`, `section_not_found`, `section_exists`, `private_write_failed`, …).
```bash
remctl section-create "Research" -l Projects --json
remctl section-rename "Research" --new-name "Reading" -l Projects
remctl section-rename --section-id DCD255E2-7CF5-4B45-9566-3F9A5D84AFA8 --new-name "Reading" --list-id 153
remctl section-delete "Reading" -l Projects --force --json
```

### `list-symbols`
Print the 71 official Reminders emblem names bundled in RemindersUICore. The terminal glyph column is an approximate fallback, not the native icon. `--symbol` accepts only these official names — arbitrary SF Symbol strings render as the default list icon; use `--emoji` for custom badges. `--preview` generates and opens a native-asset HTML contact sheet with interactive official color swatches; `--html PATH` writes that contact sheet without opening it.
```bash
remctl list-symbols
remctl list-symbols --json
remctl list-symbols --preview
remctl list-symbols --html ~/Desktop/remctl-list-symbols.html
```

### Groceries

Reminders stores Groceries lists as normal lists with private grocery metadata. Create with `list-create --groceries --grocery-locale`, convert existing lists with `list-edit --groceries`/`--standard`. `add --grocery` (and `edit --grocery`) only apply to detected Groceries lists: RemCTL creates the reminder normally, waits for Reminders' automatic grocery sorter, verifies the resulting section from the local database, and only falls back to ReminderKit's explicit categorizer if the item is not sorted yet. Human output marks Groceries lists with `🥕` and decorates known category headings (e.g. `🥛 Dairy, Eggs & Cheese`, `🥬 Produce`, `🧻 Household Items`); `show --json` includes `sectionEmoji`.

```bash
remctl list-create "Groceries" --groceries --grocery-locale en_US
remctl list-edit "Shopping" --groceries --grocery-locale it_IT
remctl add "Milk" -l Groceries --grocery
```

---

## Smart Lists

### `smart-lists`
Read-only inspector for built-in and custom smart lists. Reports numeric ID, object UUID, smart-list type, pin state/date, filter byte length, and a decoded summary when RemCTL recognizes the filter payload. Use `pinned`/`pinnedDate` here (not `lists --json`) to verify smart-list pinning. Custom smart lists also list their own sections (`sections: [{"id", "name"}]`), the ids `add`/`edit --smart-list-id … --section-id` take.
```bash
remctl smart-lists
remctl smart-lists --json
```

### `smart-list-create <name>` / `smart-list-edit [NAME] [--smart-list-id ID]`
Create or edit a custom smart list (ReminderKit) for the Reminders filters that materialize reliably. `smart-list-edit` replaces the filter on an existing custom smart list by exact name or `--smart-list-id` and never matches built-ins.

Appearance: `--color NAME`/`#RRGGBB`, `--symbol`, `--emoji`. Top-level `--match all|any`.

Supported filter families:

- **Any tag:** `--any-tag`
- **Selected tags:** `--tags a,b` with optional `--tag-match all|any`
- **Date:** `--date any|today` (with `--date-today-include-past-due`), `--date-on YYYY-MM-DD`, `--date-before`, `--date-after`, `--date-range START,END`
- **Time of day:** `--time morning|afternoon|evening|night`
- **Priority:** `--priority high|medium|low|none` (`none` is Reminders' No Priority); comma-separated values map to Priority: Any
- **Flag:** `--flagged`
- **Vehicle:** `--vehicle connected`
- **Specific location:** `--location-title`/`--latitude`/`--longitude`/`--radius`/`--proximity`
- **One included list:** `--include-list NAME` or `--include-list-id ID`
- **Advanced escape hatch:** `--filter-json` (raw official filter JSON, or `@path`)

```bash
remctl smart-list-create "Flagged Review" --flagged
remctl smart-list-create "Any Tag" --any-tag
remctl smart-list-create "#remctl Today" --tags remctl --date today
remctl smart-list-create "Priority or Today" --match any --priority high,medium --date today
remctl smart-list-create "Projects Today" --include-list Projects --date today --date-today-include-past-due
remctl smart-list-create "Due Before June 1" --date-range 2026-05-16,2026-05-31 --color red --emoji 📆
remctl smart-list-edit "Priority or Today" --priority high
remctl smart-list-edit --smart-list-id 170 --filter-json @filter.json --color red
```

**Rejected before saving** (these do not materialize reliably): untagged, no-date, relative date, no-time, vehicle disconnected, list exclusions, and **more than one included list** — Reminders.app materializes only one included list per smart list. Unknown filter shapes and known zero-filter shapes are also rejected.

### `smart-list-delete [NAME] [--smart-list-id ID] [--force]`
Delete a custom smart list by exact name or `--smart-list-id` (never a built-in); `--force` skips confirmation (and is required with `--json` or a non-interactive stdin).
```bash
remctl smart-list-delete "Flagged Review" --force
remctl smart-list-delete --smart-list-id 170 --force
```

---

## Templates

Reminders templates are saved lists with their reminders inside. RemCTL reads them from the local template tables and creates/applies/deletes them through ReminderKit. Template support is **whole-list only**: save an entire source list, or apply a template to create a new list. RemCTL does not append individual reminders to a template, strip subtasks/due dates while saving, or create iCloud sharing links — existing public template links are read-only metadata.

### `templates`
Read-only inspector. Reports numeric ID, object UUID, deep link, item/section counts, dates, badge metadata, and any existing public template link. `--json`, `--no-color`.
```bash
remctl templates
remctl templates --json
```

### `template-info [NAME] [--template-id ID]`
Read one template by exact name or `--template-id`, including saved reminder rows, decoded metadata keys, tags, recurrence rules, alarm trigger dictionaries, and template sections.
```bash
remctl template-info "Rome: Things To See"
remctl template-info --template-id 2 --json
```

### `template-create <name>`
Save an entire existing list as a template, by `--from-list` or `--from-list-id`. `--include-completed` is the only content-selection flag (include completed reminders in the saved template).
```bash
remctl template-create "Packing Template" --from-list Packing --json
remctl template-create "Archive Template" --from-list-id 144 --include-completed
```

### `template-apply [NAME] [--template-id ID]`
Create a new list from a saved template.
```bash
remctl template-apply "Packing Template" --json
remctl template-apply --template-id 2
```

### `template-delete [NAME] [--template-id ID] [--force]`
Delete only the saved template (not lists previously created from it); `--force` skips confirmation (and is required with `--json` or a non-interactive stdin).
```bash
remctl template-delete "Packing Template" --force
remctl template-delete --template-id 2 --force --json
```

Verify template writes with `templates --json` / `template-info`, and applied templates with `lists --json` and `show <new list> --json`.

---

## Sharing: Export, Import, Link, Open

### `export`
Export reminders to a file format. `-l/--list` or `--list-id` scopes to one list (otherwise all). `--format json|csv` (default `json`) selects the file format. `--json` is accepted for compatibility but output is governed by `--format`.
```bash
remctl export --list Shopping --format json > shopping.json
remctl export --list-id 153 --format json > shopping.json
remctl export --format csv > all-reminders.csv
```

### `import <file|->`
Import reminders from a JSON file containing an array of reminder objects, or from standard input with `-` (piped only, up to 8 MiB). Each object may carry `title` (required), `list`, `notes`, `due`/`dueDate`, `priority`, `url`, `recurrence` (string spec or exported object), `alarm`, and `flagged`.

The **whole document is validated first**: if any item has a non-string field, an unparseable due date, recurrence or alarm, an unknown priority, or a non-boolean `flagged`, nothing is created and the command exits 1 — with `--json`, a structured `invalid_import` error on stderr listing every bad item by index.

`--dry-run` stops at that gate and prints `{"status": "valid", "count": N, "created": 0}` without creating anything; an invalid document still fails the same way.

Once validation passes, items are created one by one. Successful `--json` imports print a one-line `completed` summary on stdout and per-item progress on stderr. If an item fails to write, the command exits 1 with `import_partial` on stderr, empty stdout, and already created ids under `createdIds`. The error includes indexed failures under `errors`; those ids must not be imported a second time.
```bash
remctl import shopping.json
remctl import shopping.json --json
remctl import shopping.json --dry-run
remctl import - --json < shopping.json
```

### `link [IDS...]`
Print deep link(s). Pass reminder IDs, or `-l/--list`/`--list-id` for all active reminders in a list; `--completed` includes completed reminders. `--json`, `--no-color`.
```bash
remctl link 23880
remctl link -l Shopping
remctl link --list-id 153 --json
```

### `open [ID]`
Open a specific reminder in Reminders.app via its deep link, or open the app with no argument.
```bash
remctl open 23880
remctl open
```

---

## Output

RemCTL output serves both humans and agents:

- reminder IDs print as `#ID`, colored with the reminder's list color when readable
- `⚑` flagged, `⏰` urgent, `↻` recurrence badge (e.g. `↻ weekly Mon, Wed`, `↻ monthly last Fri`), `🥕` Groceries
- `🔗` rich link and `🌄` image attachment close a human one-liner ([List Badges](#list-badges))
- priority markers: `!!!` high, `!!` medium, `!` low
- table output keeps a dedicated `Repeat` column when any row recurs, and `show`/`search` with `--completed` replace the `Due` column with a `Completed` timestamp
- human output strips terminal control characters from Reminders text; every read command supports `--json`
- `NO_COLOR=1` (or `--no-color`) disables color

```bash
remctl today --json
remctl --format table upcoming 14
NO_COLOR=1 remctl today
```

Example `info --json` shape:

```json
{
  "id": 23880,
  "title": "Standup",
  "list": "Work",
  "flagged": false,
  "urgent": false,
  "dueDate": "2026-05-05T09:00:00",
  "displayDate": "2026-05-05T08:45:00",
  "alarms": [
    { "type": "relative", "relativeOffset": -900, "relativeOffsetMinutes": -15, "label": "15 minutes before due date" }
  ],
  "earlyReminder": { "unit": "minutes", "count": -15, "value": 15, "direction": "before", "label": "15 minutes before" },
  "recurrence": { "frequency": "weekly", "interval": 1, "daysOfWeek": [2, 4, 6] }
}
```

## Attachments in JSON

`info --json` and list-command JSON (`show`, `today`, `upcoming`, `overdue`, `flagged`, `urgent`, `search`, and `export --format json`) include an `attachments` array on any reminder that has attachments; the key is omitted when a reminder has none. `info --json` also reports each subtask's attachments.

Each entry has this shape:

```json
{
  "filename": "mockup.png",
  "type": "image",
  "path": "/Users/you/Library/Group Containers/group.com.apple.reminders/Container_v1/Files/Account-ABCD/Attachments/<sha512>.png",
  "resolved": true,
  "uti": "public.png",
  "width": 1200,
  "height": 800
}
```

`path` is the SHA-512-verified on-disk file inside Reminders' group container: RemCTL hashes the candidate file and reports it only when the digest matches the attachment's stored sum, so a vision-capable agent can open it directly. For legacy attachments that were never downloaded to this Mac — and for files whose bytes no longer match — `path` is `null` and `resolved` is `false`; treat those as unavailable rather than an error. Files larger than 16 MB are never hashed, so they stay unresolved. `width`/`height` are `null` for rows that carry no pixel dimensions.

Attachments are batch-loaded per listing (one query per attachment table, no per-reminder queries), and path verification is memoized per process.

## List Badges

Plain human list output can end a reminder's one-line summary with up to two trailing emoji badges:

- `🔗` — the reminder has at least one rich link (a `ZREMCDOBJECT` URL row, or a saved attachment typed `url`).
- `🌄` — the reminder has at least one image attachment.

When both apply they print in that order, space-separated, at the end of the line after tags and any `[N subtasks]` count:

```text
[ ] #30165 Try Halo app on iOS again 🌄
[ ] #30174 Read the new MacStories piece 🔗
[ ] #30180 Review layout mockups 🔗 🌄
```

The badges appear in `show` (including a list group's child lists), `search`, `today`, `upcoming`, `overdue`, `flagged`, `urgent`, and on subtask lines in `subtasks` and `info`. Completed reminders keep their badges. They are loaded in batch alongside the other list metadata, so they add no per-reminder queries.

Badges are a plain human output affordance only: they are never present in `--json`, CSV export, `--format table`, or `--via-eventkit` payloads. Agents should read the `attachments` and `url` JSON fields instead.

---

## Setup and Diagnostics

RemCTL needs two macOS permission grants: **Reminders access** (EventKit + ReminderKit writes, prompted on first write or via `onboard`) and **Full Disk Access** (direct database reads). macOS TCC is scoped to the process context — a green Terminal does not imply a green agent runner; grant Full Disk Access to the target reported by `doctor --for-agent`. When a write fails because this context has no Reminders access, the error names the context and says to run `remctl onboard`, then `remctl doctor --for-agent`, from that same context.

### `onboard`
First-run onboarding: triggers the Reminders access prompt and guides Full Disk Access. `--json`, `--no-color`.
```bash
remctl onboard
```

### `permissions <topic>`
Guided Full Disk Access setup. Topic: `full-disk-access` — opens System Settings and prints the exact target. `--wait` waits for the helper to exit. `--json`.
```bash
remctl permissions full-disk-access
```

### `doctor`
Diagnose setup and permissions; run from the same context that will run RemCTL. `--for-agent` prints agent-focused context and TCC guidance. `--json`, `--no-color`. The checks that matter are `platform`, `store_dir`, `database`, and `cli`; `eventkit`/`reminderkit` report access/availability as warnings.
```bash
remctl doctor
remctl doctor --for-agent --json
```

### `setup`
Install shell completions/config. `--shell auto|bash|zsh|fish|skip` (default `auto`); `--doctor` also runs a doctor check; `--json`. Completion files are installed for the invoked name and for every alias (`rctl`, `reminders`) sitting next to the binary; `--json` lists the extra files under `completion_alias_paths`.
```bash
remctl setup --shell auto --doctor
```

### `completion [SHELL]`
Print a shell completion script for `bash`, `zsh`, or `fish` (default `zsh`). The script completes the name it was invoked under, so `rctl completion zsh` completes `rctl`.
```bash
remctl completion zsh
```
