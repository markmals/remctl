---
name: remctl
description: Use when an agent needs to read, create, edit, complete, inspect, or troubleshoot Apple Reminders through the RemCTL CLI on macOS.
---

# RemCTL

RemCTL is a power-user Apple Reminders CLI — a single Swift binary. It reads the local Reminders database directly for fast, detailed output, writes ordinary fields through EventKit, and writes private metadata (sections, subtasks, tags, attachments, urgent, Early Reminders, list/smart-list appearance, Groceries, templates) through Apple's private ReminderKit framework — both **in-process**, in the same binary. There is no `--private` flag, no helper subprocess, no daemon, token, or service. Never write the Reminders SQLite database directly.

Install: `brew install markmals/tap/remctl`. Requires macOS 14+.

## Default Workflow

- Use the installed command: `remctl ...`.
- Prefer JSON for automation and verification: `remctl today --json`, `remctl show Work --json`, `remctl info <id> --json`.
- The private-metadata flags are first-class — there is no opt-in flag. For private reminder metadata, use `add`/`edit` with `--section`, `--subtask`, `--urgent`, `--early-reminder`, `-t/--tags`, `--image`, etc. For list appearance / Groceries / pin state, use `list-create`, `list-edit`, `list-pin`, `list-unpin`. For custom smart lists, use `smart-list-create`/`-edit`/`-delete`. For templates, use `template-create`/`-apply`/`-delete`.

## Agent Routing

EventKit (public) and ReminderKit (private metadata) both run in-process; there is no flag to choose between them — RemCTL picks the path from which flags you pass.

| User intent | Command path | Verify with |
| --- | --- | --- |
| Read due items, lists, reminders, tags, sections, subtasks | `today`, `upcoming`, `overdue`, `lists`, `show`, `search`, `info`, `tags`, `sections`, `subtasks` | same command with `--json` |
| Create/edit ordinary reminder fields | `add`, `edit`, `done`, `undone`, `delete` | `info <id> --json` or `show <list> --json` |
| Due date, priority, notes, recurrence, EventKit alarm | `add`/`edit` with `-d`, `-p`, `-n`, `--recurrence`, `--alarm` | `info <id> --json`; recurrence appears as `recurrence` |
| Move a reminder to another list | `edit <id> -l LIST` or `edit <id> --list-id ID` | `info <id> --json` or `show <destination> --json` |
| Reorder a reminder in its list or an unsectioned custom smart list; nest or unnest a subtask | `reminder-move <id> --before ID/--after ID/--first/--last` (add `--smart-list NAME` for the smart list's manual order); `reminder-move <id> --parent ID` / `--top-level` | the command reports `verified: true` from the store; `show <list> --json` / `subtasks <parent>` follow the new order; the reminder keeps its id |
| Synced rich URL, synced tags, section, shared-list assignment, subtask, image, real flag, urgent, Early Reminder, location alarm | `add`/`edit` with `--url`, `-t`, `--section`, `--assign`/`--unassign`, `--subtask`, `--image`, `--flagged`, `--urgent`, `--early-reminder`, `--location-*` | `info <id> --json`; UI/device check when sync matters |
| Replace or remove synced reminder tags | `edit <id> --set-tags a,b`, `edit <id> --clear-tags`, `edit <id> --remove-tag x` | `info <id> --json` under `tags` |
| List appearance, Groceries metadata, list/smart-list pin | `list-create`, `list-edit`, `list-pin`, `list-unpin` | `lists --json` (color/badge/Groceries/pin); `smart-lists --json` (smart-list appearance/pin) |
| Create, rename, delete a list's sections | `section-create NAME -l LIST`, `section-rename NAME --new-name NEW -l LIST`, `section-delete NAME -l LIST --force` (or `--section-id`) | `sections --json`; each write already reports `verified: true` |
| List groups: inspect, create, rename, add/remove/reorder child lists, delete, create a list inside one | `groups`, `group-info`, `group-create NAME --add-list LIST`, `group-edit NAME --new-name/--add-list/--remove-list/--move-list LIST --before-list/--after-list/--first/--last`, `group-delete NAME --force`, `list-create NAME --group GROUP` | `groups --json` / `group-info --json`; writes report `verified: true`. Lists keep their reminders when they move. |
| Custom smart list create/edit/delete | `smart-list-create`, `smart-list-edit`, `smart-list-delete` | `smart-lists --json` |
| Saved Reminders templates | `templates`, `template-info`, `template-create`, `template-apply`, `template-delete` | `templates --json`, `template-info`, then `show <new list> --json` after apply |
| Check an address before setting a location alarm | `location-lookup "ADDRESS" --json` | nothing to verify — the command writes nothing |

High-value guardrails:

- Recurrence and normal `--alarm` are EventKit features. `--early-reminder` is a separate Reminders Early Reminder (a private due-date delta alert), not an EventKit alarm.
- Location alarms (`--location-title`/`--latitude`/`--longitude`/`--radius`/`--proximity`) work on both `add` and `edit`, are written through EventKit structured-location alarms, and are a public write; verify in `info --json` under `alarms`.
- `--location-address "1 Apple Park Way, Cupertino, CA"` geocodes before the first write and only accepts a single street-sized match that names the street typed in a town or postal code the address gives; anything else (`location_ambiguous`, `location_imprecise`, `location_unconfirmed`, `location_not_found`) stops the command with the candidates, and nothing is created or changed. Personal labels such as `Home`, `Work` or `my office` are refused (`location_label_not_address`) — pass the real address and label it with `--location-title`. The lookup needs network access but no Location Services permission; run `location-lookup` first when an address looks uncertain. It cannot be combined with `--latitude`/`--longitude`.
- Synced rich URLs require public `http`/`https` hosts; loopback, `.local`, private, link-local, multicast, reserved, fake-IP (`198.18.0.0/15`) literals, IPv4-mapped IPv6 spellings of those, and unresolved hosts fail before writing. With no other private metadata present, `--url` is just a notes append and `add --tags` writes inline title hashtags.
- Human output strips terminal control characters; use JSON when exact raw values matter.
- Reminder JSON carries `attachments` only when the reminder has some. Read `attachments[].path` when `resolved` is `true` — it is the SHA-512-verified file and is safe to open; `resolved: false` means the file is not on this Mac, which is not an error.
- Plain human list output may end reminder lines with trailing `🔗` (rich link) and/or `🌄` (image attachment) badges. Those badges are never in JSON — read the `attachments` and `url` JSON fields instead.
- Invalid due dates, recurrence, alarms, priorities, and location payloads fail before writing. `upcoming DAYS` accepts 1–3650 and always starts today: `upcoming 1` is today and tomorrow, `upcoming 7` today plus the next week.
- Verify smart-list pinning with `smart-lists --json`, not `lists --json`. Built-in smart-list pinning depends on the host's ReminderKit and fails before saving when unsupported; custom smart lists always pin.
- If `add` fails after creating the reminder (`code: "private_add_partial"`), finish the missing private step with `edit <numericId>` — never re-run `add`, which would duplicate.
- Do not promise template link creation or editing individual reminders inside a template.
- Reminders.app materializes only one included list per smart list — do not build multi-list aggregates.

## Common Commands

```bash
remctl today --json
remctl upcoming 7 --json
remctl overdue --json
remctl lists --json
remctl show Work --json
remctl show --list-id 153 --json
remctl search "query" --completed --json
remctl search "macstories.net" --list Work --limit 50 --offset 50 --json
remctl info 23880 --json
remctl add "Review PR" -l Work -d "tomorrow 10:00" -p high --json
remctl add "Write column" --list-id 156 -d "2026-05-20 15:00" --json
remctl add "Weekly report" -l Work --recurrence "weekly mon,wed,fri" --alarm 15m --json
remctl smart-lists --json
remctl templates --json
remctl template-info "Rome: Things To See" --json
remctl list-symbols --json
remctl edit 23880 -d clear --json
remctl edit 23880 -l Work --json
remctl edit 23880 --recurrence monthly --json
remctl done 23880 --json
remctl done 23880 --date "2026-05-27 09:30" --json
remctl done 23880 23881 --json
remctl delete 23880 23881 --force --json
remctl sharees Family --json
remctl list-info Work --json
remctl list-info --list-id 153 --json
remctl edit 23880 --assign Alex --json
remctl link --list-id 153 --json
remctl export --list-id 153 --format json
remctl import - --dry-run < shopping.json
remctl list-rename --list-id 123 --new-name "Project Archive" --json
remctl list-delete --list-id 123 --force --json
```

## Syntax Rules

- Nouns are read-only inspectors: `lists`, `smart-lists`, `templates`, `today`, `stats`. Verb commands are writes: `add`, `edit`, `delete`, `list-create`, `smart-list-create`, `template-create`.
- List management uses the `list-*` prefix; custom smart-list writes use `smart-list-*`; template writes use `template-*`.
- `--json` works on subcommands. For tabular read commands (`today`, `upcoming`, `overdue`, `flagged`, `urgent`, `lists`, `show`, `search`), `--format json|table|plain` can be passed globally before the command or on the command. `export --format json|csv` selects a file format, not display style.
- List targets resolve exact name → case-insensitive → normalized (e.g. `Weekly 513` for `🗓️ Weekly 513`). If multiple match, RemCTL fails; use `--list-id`. `show`, `search`, `add`, `edit`, `link`, `export`, `list-info`, `list-edit`, `list-pin`, `list-unpin`, `list-rename`, `list-delete`, and smart-list `--include-list-id` accept numeric targeting; `list-pin`/`list-unpin` also accept `--smart-list-id`. Passing both a name and `--list-id` is an error.
- `search` matches titles, notes, and saved rich links of active reminders, ignoring case and accents (`cafe` finds `Café`); `%`, `_`, and `\` are literal. Add `--completed` for completed ones, `-l/--list NAME` or `--list-id ID` to scope it to one list. Results are newest first, 100 per page: with `--limit`/`--offset`, `--json` returns `{"query", "items", "count", "total", "offset", "limit", "hasMore", "nextOffset"}` — keep calling with `offset: nextOffset` while `hasMore` is true. Plain `--json` stays an array and warns on stderr when matches were cut off. `--via-eventkit search` takes `--list` but refuses `--list-id` and paging.
- Note on exit codes: argument-parse errors (unknown flag, bad choice, missing argument) exit with `64` (Swift Argument Parser's `EX_USAGE`), not `2`. In-command validation errors (e.g. an unparseable due date) still exit `1`/`2` as documented per command.
- `delete`, `list-delete`, `smart-list-delete`, and `template-delete` require `--force` whenever `--json` is set or stdin is not a terminal — without it they exit `1` with `code: confirmation_required` on stderr and write nothing. Always pass `--force` when scripting. A deleted reminder stays in Reminders' Recently Deleted list for up to 30 days on supported accounts, where the user can recover it in Reminders.app.
- `import` takes a JSON file path or `-` for piped stdin (max 8 MiB; a terminal is refused). `--dry-run` validates the whole document and prints `{"status": "valid", "count": N, "created": 0}` without creating anything.
- `done`, `undone`, and `delete` accept several ids (up to 50, listed before the options) as one batch; `--batch` gives a single id the same result shape. Every id is resolved before the first write, repeats are written once, and the call exits `1` unless every id succeeded — read `results` for the per-id `status`/`code`.

## Recurring Schedules

Recurrence is a normal EventKit write.

```bash
remctl add "Standup" --recurrence "weekly mon,wed,fri" --alarm 15m --json
remctl add "Pay rent" --recurrence monthly --json
remctl add "Team sync" --recurrence "monthly 4th-fri" --json
remctl add "Deep clean" --recurrence "daily x2" --json
remctl edit 23880 --recurrence "monthly x2 last-fri" --json
remctl edit 23880 --recurrence clear --json    # stop repeating (also none or never)
```

Accepted forms: `daily`, `weekly`, `monthly`, `yearly`, `weekly mon,wed,fri`, `monthly 1,15`, each with an optional interval token directly after the frequency (`daily x2`, `weekly x2 thu`, `monthly x3 15`, `monthly x2 4th-fri`, `yearly x2`; N is 1–999), plus monthly Nth-weekday rules: `monthly 4th-fri`, `monthly 1st-mon,3rd-mon`, `monthly last-fri`, and `monthly -1-fri` through `-5-fri` (`last-fri` = `-1-fri`). Nth-weekday tokens are monthly-only, check their ordinal suffix (`4st-fri` fails), and can't be mixed with day-of-month numbers in one rule. For "the last Friday" use `last-fri`, not `5th-fri`: EventKit skips months without a fifth Friday. Invalid recurrence/alarm/priority fail before writing. Recurring reminders include a `recurrence` object in JSON (week pinning appears as `daysOfWeekDetailed[].weekNumber`) and a repeat badge in human/table output such as `↻ monthly 4th Fri`, `↻ every 2 months last Fri`, or `↻ daily, 5 times` (an occurrence count, not the `xN` interval). `--alarm 15m` is an EventKit alarm (verify in `info --json` under `alarms`); `edit ID --alarm clear` removes normal alarms. Early Reminders are separate: `--early-reminder`.

## Private Metadata

Private-metadata flags are first-class — no opt-in flag. Use them when the user wants synced rich links, synced tags, sections, subtasks, image attachments, real flags, urgent state, Early Reminders, location alarms, list appearance, Groceries metadata/categorization, list/smart-list pinning, custom smart lists, or templates.

```bash
remctl add "Research" -l Projects --url "https://example.com" -t remctl --section "Research" --json
remctl add "Research" -l Projects --section-id DCD255E2-7CF5-4B45-9566-3F9A5D84AFA8 --json
remctl add "Prepare screenshots" -l Projects --image ~/Desktop/mockup.png --subtask "Export PNG" --json
remctl add "Leave now" -l Work --urgent --json
remctl add "Leave early" -l Work -d "today 14:00" --early-reminder 15m --json
remctl add "Launch assets" -l Projects --subtask '{"title":"Export PNG","notes":"Use final crop","due":"tomorrow","url":"https://example.com","tags":["media"]}' --json
remctl edit 23880 --url "https://example.com" -t remctl --json
remctl edit 23880 --set-tags remctl,work --json
remctl edit 23880 --remove-tag stale --json
remctl edit 23880 --clear-tags --json
remctl edit 23880 --section "Research" --subtask "Follow up" --json
remctl edit 23880 --flagged --urgent --json
remctl edit 23880 --early-reminder 1h --json
remctl edit 23880 --early-reminder clear --json
remctl edit 23880 --location-title "Apple Park" --latitude 37.3349 --longitude -122.0090 --radius 200 --json
remctl add "Pick up prints" --location-address "1 Apple Park Way, Cupertino, CA 95014" --json
remctl location-lookup "1 Apple Park Way, Cupertino, CA 95014" --json
remctl list-create "Research" --color orange --symbol education3 --json
remctl list-create "Cold Ideas" --color cyan --emoji 🥶 --json
remctl list-create "Groceries" --groceries --grocery-locale en_US --json
remctl add "Milk" -l Groceries --grocery --json
remctl list-edit "Shopping" --standard --json
remctl list-edit Projects --color '#FF8D28' --symbol education3 --json
remctl list-pin "Project X" --json
remctl list-unpin --smart-list-id 4 --json
remctl smart-list-create "Flagged Review" --flagged --json
remctl smart-list-create "Priority or Today" --match any --priority high,medium --date today --json
remctl smart-list-edit --smart-list-id 170 --priority high --json
remctl smart-list-delete "Flagged Review" --force --json
remctl template-create "Packing Template" --from-list Packing --json
remctl template-apply "Packing Template" --json
remctl template-delete "Packing Template" --force --json
```

Private metadata rules:

- `--url` creates a synced web rich link (public `http`/`https` host required) when other private metadata is present; otherwise it appends to notes.
- `-t/--tags` creates synced tags when private metadata is present or on `edit`; on a bare `add` it writes inline `#hashtag` title tokens. It is additive: use `edit --set-tags a,b` to replace the whole set, `edit --clear-tags` to empty it, or repeatable `edit --remove-tag x` to drop named tags (case-insensitive). The three replacement flags cannot be combined with each other or with `-t/--tags`, and are refused before any write.
- `edit -l/--list` and `edit --list-id` move a reminder. A reminder with subtasks (or a move EventKit refuses across accounts) is moved by clone-delete and gets a **new id**: read `id` (new) and `oldId` from `--json` (`method: "clone-delete"`, `subtasksMoved`, `originalDeleted`) and chain the new id afterwards. Such a move cannot be combined with other edit flags — move first, then edit.
- `--section` resolves by name (single non-empty match wins on duplicates); use `--section-id` for exact assignment, reading the ids from `remctl list-info LIST --json`. Both are resolved before `add` creates anything. `--new-section` appends to the list's existing section order.
- `--early-reminder` writes Reminders' Early Reminder due-date delta alert: `15m`, `1h`, `2d`, `1w`, `1mo`, or `clear`; non-clear values require a due date. Verify in `info --json`.
- `--location-title` + `--latitude`/`--longitude` persist through EventKit structured-location alarms on `add` and `edit`; verify in `info --json` under `alarms`. `--location-address` resolves the coordinates first (see the guardrails above) and adds `resolvedLocation` to the `--json` result; the street address itself is not stored, because EventKit's structured location carries only a title, coordinates and a radius.
- `--subtask` accepts a plain child title or a JSON object: `title`, `notes`, `due`, `priority`, `alarm`, `recurrence`, `earlyReminder`, `url`/`urls`, `tags`, `image`/`images`, `flagged`, `urgent`, and location fields. A date-only `due` makes the child all-day; `recurrence` takes a string spec or an exported recurrence object. Rich subtask URLs follow the public-host rule. Repeated `--subtask` values land in the given order after existing subtasks (`subtaskPlacement` reports where).
- Rich-link and image edits are additive (RemCTL adds, never removes/replaces). Generic file/PDF attachments are rejected; only images attach.
- `add -f/--flag`, `flag`, and `unflag` write the real flag through ReminderKit (there is no EventKit flag API); a failed flag write exits 1 with `code: flag_failed` under `--json` instead of changing the priority.
- `list-symbols` prints the 71 official emblem names (its terminal glyph column is approximate). `list-symbols --preview` opens a native-asset HTML contact sheet; `list-symbols --html PATH` writes one. `--symbol` accepts only official names (arbitrary SF Symbols render as the default icon); use `--emoji` for custom badges. `list-create --color NAME` uses EventKit; a `#RRGGBB` hex, `--symbol`, or `--emoji` uses the ReminderKit appearance path — verify via `color`/`badge`/`badgeEmblem` in `lists --json`/`smart-lists --json`.
- `list-create --json` reports the new list's numeric `id` once the row reaches the local store; chain it with `--list-id`. If the row is still invisible, the payload carries `warnings: ["list_id_unavailable: …"]` instead — the list exists, so find its id with `lists --json` rather than creating it again.
- Groceries lists show in `lists --json` as `listType: "groceries"`, `isGroceries: true`, `grocery.locale`; headings show `🥕`; `show --json` includes `sectionEmoji`. `add --grocery`/`edit --grocery` only apply to detected Groceries lists; RemCTL verifies Reminders' auto-sort first (`source: "reminders_auto"`) and falls back to the private categorizer only for unsectioned items.
- Reminders list groups hold lists, not reminders. `lists` nests a group's child lists under it and counts lists and groups separately; `lists --json` gives a group `listType: "group"`, `isGroup: true`, `children`, and summed `counts`, and gives each child `parentListId` plus its `group` stub. `stats` excludes groups from `Lists:`. A group is never a reminder target — `add -l`, `edit -l`, and `--list-id` fail and name its child lists — but `show <group>` reads through to every child list's reminders, grouped by list.
- `smart-list-create`/`-edit`/`-delete` use the private ReminderKit path for the filters that materialize reliably; unknown or zero-filter shapes are rejected before writing. Verify with `smart-lists --json` (check the decoded filter, `filter.supported`, and `minimumSupportedVersion`/`effectiveMinimumSupportedVersion` `20220430`). Smart-list pinning can leave `ZISPINNEDBYCURRENTUSER` empty while setting `ZPINNEDDATE`; RemCTL reports `pinned: true` from a positive smart-list `pinnedDate`.
- `template-create`/`-apply`/`-delete` are whole-list operations only (no appending individual reminders, no stripping subtasks/due dates). Verify with `templates --json`/`template-info`, and applied templates with `show <new list> --json`. Existing iCloud template links are read-only.
- If cross-device sync matters, ask the user to check iPhone/iPad after CLI verification.

## Smart List Filters

`smart-list-create` and `smart-list-edit` accept the Reminders filters that materialize reliably:

```bash
remctl smart-list-create "Any Tag" --any-tag --json
remctl smart-list-create "#remctl Today" --tags remctl --date today --json
remctl smart-list-create "Priority: Any" --priority high,medium --json
remctl smart-list-create "Morning" --time morning --json
remctl smart-list-create "Projects Today" --include-list Projects --date today --date-today-include-past-due --json
remctl smart-list-create "Near Home" --location-title Home --latitude 41.9 --longitude 12.5 --radius 100 --proximity enter --json
remctl smart-list-edit --smart-list-id 170 --filter-json @filter.json --color red --emoji 📆 --json
```

Supported families: any tag (`--any-tag`), selected tags (`--tags` + optional `--tag-match all|any`), date (`--date any|today`, `--date-today-include-past-due`, `--date-on`, `--date-before`, `--date-after`, `--date-range START,END`), time (`morning|afternoon|evening|night`), priority (`high|medium|low`; comma-separated = Priority: Any), flag (`--flagged`), vehicle connected (`--vehicle connected`), specific location (`--location-title`/`--latitude`/`--longitude`/`--radius`/`--proximity enter|leave|arriving|leaving`), one included list (`--include-list`/`--include-list-id`), and top-level `--match all|any`. Appearance flags `--color`/`--symbol`/`--emoji` also apply.

Rejected before saving (non-materializing): untagged, no-date, relative date, no-time, vehicle disconnected, list exclusions, and more than one included list. `--filter-json` is an advanced escape hatch for raw official filter JSON or `@path`; unsupported shapes are rejected. `smart-list-edit`/`-delete` target custom smart lists by exact name or `--smart-list-id` and never match built-ins.

## Limited EventKit Fallback

`--via-eventkit` (on `show`, `search`, `today`, `upcoming` only) is a read-only fallback for hosts without Full Disk Access. Never use it by default. Its JSON is a wrapper object (`source: "eventkit"`, `fidelity: "limited"`, per-item `eventKitId`) — `eventKitId` is NOT a RemCTL numeric id and must never be passed to `info`, `edit`, `done`, `delete`, `link`, `open`, or `subtasks`. If the task needs chainable IDs or private metadata, fix Full Disk Access and use the normal read path.

## Verification Rules

- Treat `remctl doctor --json` as the first setup check; for agents prefer `remctl doctor --for-agent --json`. `doctor` must pass in the same execution context that runs the write. Its `eventkit` and `reminderkit` checks report access/availability as warnings; the failing checks that matter are `platform`, `store_dir`, `database`, and `cli`.
- Do not run `doctor` before every ordinary task once the context is known-good; it is a setup/TCC diagnostic.
- Verify writes against live Reminders data after the command succeeds.
- `remctl add --json` returns `numericId` when the new reminder is resolvable; use it for `remctl info <numericId> --json`. If absent, resolve the `id` via `show <list> --json` by matching the title.
- Prefer deterministic due-date strings; normalize "today at 3pm" to `YYYY-MM-DD HH:MM` in the user's timezone, or pass an accepted form. `add`/`edit` are atomic for due dates — on a parse failure they exit before writing and (with `--json`) emit a structured `invalid_due_date` error on stderr. Retry with a corrected date; do not create then patch.
- Accepted due forms: `YYYY-MM-DD`, `YYYY-MM-DD HH:MM`, `today at 3pm`, `tomorrow 09:30`, `tonight at 11`, `Friday at 15:00`, `next friday at 3pm`, `+3d`, `eod`, `eow`.
- `dueDate` is the reminder's due date as a real instant; a separate UI/alert date is reported as `displayDate`, and `today`/`upcoming`/`overdue` bucket by the date Reminders shows (the display date). An all-day `dueDate` is local midnight of its day. For rescheduling, `edit ID -d "YYYY-MM-DD HH:MM"` carries matching absolute alarms forward — all acknowledged copies move together — while a date-only `-d` and `edit ID -d clear` remove them. A repeating reminder must keep its due date: `edit ID -d clear` refuses with `code: "repeating_reminder_requires_due_date"` and changes nothing unless the same edit also passes `--recurrence clear`. When debugging time mismatches, compare `dueDate`, `displayDate`, and `alarms`.

Fast create path:

```bash
remctl add "Title" -l Projects --section "Section" -d "YYYY-MM-DD HH:MM" --url "https://example.com" --json
remctl info <numericId> --json
```

`info --json` includes section, due/display dates, tags, subtasks, parent and subtask attachments, EventKit alarms, location alarms, Early Reminders, deep link, and rich-link `url` when present. Avoid raw SQLite checks.

## Permissions

```bash
remctl onboard
remctl permissions full-disk-access
remctl doctor
```

RemCTL needs **Reminders access** (EventKit + ReminderKit writes, prompted on first write or via `onboard`) and **Full Disk Access** (direct database reads). The guided helper opens System Settings for the CLI target. macOS TCC is scoped to the process context: Terminal can pass `remctl doctor` while another agent runner fails from its own context — that is expected scoping, not a broken install. Grant Full Disk Access to the target printed by `remctl doctor --for-agent`, or run a one-off command through an already-authorized Terminal. A write refused for missing Reminders access prints the blocked context and says to run `remctl onboard`, then `remctl doctor --for-agent`, from that same context; do not retry the write until that doctor passes.
