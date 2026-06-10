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
| Synced rich URL, synced tags, section, shared-list assignment, subtask, image, real flag, urgent, Early Reminder, location alarm | `add`/`edit` with `--url`, `-t`, `--section`, `--assign`/`--unassign`, `--subtask`, `--image`, `--flagged`, `--urgent`, `--early-reminder`, `--location-*` | `info <id> --json`; UI/device check when sync matters |
| List appearance, Groceries metadata, list/smart-list pin | `list-create`, `list-edit`, `list-pin`, `list-unpin` | `lists --json` (color/badge/Groceries/pin); `smart-lists --json` (smart-list appearance/pin) |
| Custom smart list create/edit/delete | `smart-list-create`, `smart-list-edit`, `smart-list-delete` | `smart-lists --json` |
| Saved Reminders templates | `templates`, `template-info`, `template-create`, `template-apply`, `template-delete` | `templates --json`, `template-info`, then `show <new list> --json` after apply |

High-value guardrails:

- Recurrence and normal `--alarm` are EventKit features. `--early-reminder` is a separate Reminders Early Reminder (a private due-date delta alert), not an EventKit alarm.
- Location alarms (`--location-title`/`--latitude`/`--longitude`/`--radius`/`--proximity`) are written through EventKit structured-location alarms; verify in `info --json` under `alarms`.
- Synced rich URLs require public `http`/`https` hosts; loopback, `.local`, private, link-local, multicast, reserved, and unresolved hosts fail before writing. With no other private metadata present, `--url` is just a notes append and `add --tags` writes inline title hashtags.
- Human output strips terminal control characters; use JSON when exact raw values matter.
- Invalid due dates, recurrence, alarms, priorities, and location payloads fail before writing. `upcoming DAYS` accepts 1–3650.
- Verify smart-list pinning with `smart-lists --json`, not `lists --json`.
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
remctl sharees Family --json
remctl edit 23880 --assign Alex --json
remctl link --list-id 153 --json
remctl export --list-id 153 --format json
remctl list-rename --list-id 123 --new-name "Project Archive" --json
remctl list-delete --list-id 123 --force --json
```

## Syntax Rules

- Nouns are read-only inspectors: `lists`, `smart-lists`, `templates`, `today`, `stats`. Verb commands are writes: `add`, `edit`, `delete`, `list-create`, `smart-list-create`, `template-create`.
- List management uses the `list-*` prefix; custom smart-list writes use `smart-list-*`; template writes use `template-*`.
- `--json` works on subcommands. For tabular read commands (`today`, `upcoming`, `overdue`, `flagged`, `urgent`, `lists`, `show`, `search`), `--format json|table|plain` can be passed globally before the command or on the command. `export --format json|csv` selects a file format, not display style.
- List targets resolve exact name → case-insensitive → normalized (e.g. `Weekly 513` for `🗓️ Weekly 513`). If multiple match, RemCTL fails; use `--list-id`. `show`, `add`, `edit`, `link`, `export`, `list-edit`, `list-pin`, `list-unpin`, `list-rename`, `list-delete`, and smart-list `--include-list-id` accept numeric targeting; `list-pin`/`list-unpin` also accept `--smart-list-id`. Passing both a name and `--list-id` is an error.
- Note on exit codes: argument-parse errors (unknown flag, bad choice, missing argument) exit with `64` (Swift Argument Parser's `EX_USAGE`), not `2`. In-command validation errors (e.g. an unparseable due date) still exit `1`/`2` as documented per command.

## Recurring Schedules

Recurrence is a normal EventKit write.

```bash
remctl add "Standup" --recurrence "weekly mon,wed,fri" --alarm 15m --json
remctl add "Pay rent" --recurrence monthly --json
remctl edit 23880 --recurrence "weekly mon,wed" --json
```

Accepted forms: `daily`, `weekly`, `weekly mon,wed,fri`, `monthly`, `monthly 1,15`, `yearly`. Invalid recurrence/alarm/priority fail before writing. Recurring reminders include a `recurrence` object in JSON and a repeat badge in human/table output. `--alarm 15m` is an EventKit alarm (verify in `info --json` under `alarms`); `edit ID --alarm clear` removes normal alarms. Early Reminders are separate: `--early-reminder`.

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
remctl edit 23880 --section "Research" --subtask "Follow up" --json
remctl edit 23880 --flagged --urgent --json
remctl edit 23880 --early-reminder 1h --json
remctl edit 23880 --early-reminder clear --json
remctl edit 23880 --location-title "Apple Park" --latitude 37.3349 --longitude -122.0090 --radius 200 --json
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
- `-t/--tags` creates synced tags when private metadata is present or on `edit`; on a bare `add` it writes inline `#hashtag` title tokens.
- `edit -l/--list` and `edit --list-id` are ordinary EventKit moves.
- `--section` resolves by name (single non-empty match wins on duplicates); use `--section-id` for exact assignment.
- `--early-reminder` writes Reminders' Early Reminder due-date delta alert: `15m`, `1h`, `2d`, `1w`, `1mo`, or `clear`; non-clear values require a due date. Verify in `info --json`.
- `--location-title` + `--latitude`/`--longitude` persist through EventKit structured-location alarms; verify in `info --json` under `alarms`.
- `--subtask` accepts a plain child title or a JSON object: `title`, `notes`, `due`, `priority`, `alarm`, `recurrence`, `earlyReminder`, `url`/`urls`, `tags`, `image`/`images`, `flagged`, `urgent`, and location fields. Rich subtask URLs follow the public-host rule.
- Rich-link and image edits are additive (RemCTL adds, never removes/replaces). Generic file/PDF attachments are rejected; only images attach.
- `add -f/--flag` alone writes EventKit's priority proxy; with private metadata (or `edit --flagged`) it writes the real flag.
- `list-symbols` prints the 71 official emblem names (its terminal glyph column is approximate). `list-symbols --preview` opens a native-asset HTML contact sheet; `list-symbols --html PATH` writes one. `--symbol` accepts only official names (arbitrary SF Symbols render as the default icon); use `--emoji` for custom badges. `list-create --color NAME` uses EventKit; a `#RRGGBB` hex, `--symbol`, or `--emoji` uses the ReminderKit appearance path — verify via `color`/`badge`/`badgeEmblem` in `lists --json`/`smart-lists --json`.
- Groceries lists show in `lists --json` as `listType: "groceries"`, `isGroceries: true`, `grocery.locale`; headings show `🥕`; `show --json` includes `sectionEmoji`. `add --grocery`/`edit --grocery` only apply to detected Groceries lists; RemCTL verifies Reminders' auto-sort first (`source: "reminders_auto"`) and falls back to the private categorizer only for unsectioned items.
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
- `dueDate` is the actual `ZDUEDATE`; a separate UI/alert date is reported as `displayDate`. For rescheduling, `edit ID -d "YYYY-MM-DD HH:MM"` carries a single matching absolute alarm forward; `edit ID -d clear` removes it. When debugging time mismatches, compare `dueDate`, `displayDate`, and `alarms`.

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

RemCTL needs **Reminders access** (EventKit + ReminderKit writes, prompted on first write or via `onboard`) and **Full Disk Access** (direct database reads). The guided helper opens System Settings for the CLI target. macOS TCC is scoped to the process context: Terminal can pass `remctl doctor` while another agent runner fails from its own context — that is expected scoping, not a broken install. Grant Full Disk Access to the target printed by `remctl doctor --for-agent`, or run a one-off command through an already-authorized Terminal.
