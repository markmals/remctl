# Command Guide

A reference for every RemCTL command. RemCTL is a single self-contained Swift binary that reads the local Reminders database directly (read-only, needs Full Disk Access), writes ordinary fields through EventKit in-process, and writes private metadata (sections, subtasks, synced tags, attachments, urgent, Early Reminders, list/smart-list appearance, Groceries, templates) through Apple's private ReminderKit framework in-process. There is no `--private` flag and no helper subprocess: RemCTL chooses the EventKit or ReminderKit path from which flags you pass.

Run `remctl --help` for the parser-generated overview and `remctl <command> --help` for any command's exact options.

## Conventions

- **Nouns are read-only inspectors** (`lists`, `smart-lists`, `templates`, `today`, `stats`); **verb commands are writes** (`add`, `edit`, `delete`, `list-create`, `smart-list-create`, `template-create`). List management uses the `list-*` prefix, custom smart-list writes use `smart-list-*`, template writes use `template-*`.
- **List-name resolution** is conservative: exact match → case-insensitive → normalized fallback that ignores decorative punctuation and emoji prefixes (so `Weekly 513` resolves `🗓️ Weekly 513` when unambiguous). If more than one list matches, RemCTL fails and prints the candidate IDs — pass `--list-id` to disambiguate. Passing both a name and `--list-id` is an error. `show`, `add`, `edit`, `link`, `export`, `list-edit`, `list-pin`, `list-unpin`, `list-rename`, and `list-delete` accept `--list-id`; `list-pin`/`list-unpin` also accept `--smart-list-id`.
- **`--json`** works on every command. For tabular read commands (`today`, `upcoming`, `overdue`, `flagged`, `urgent`, `lists`, `show`, `search`), `--format json|table|plain` can be passed globally before the command or on the command, so both `remctl --format table show Work` and `remctl show Work --format table` are valid. `export --format json|csv` selects a file format, not a display style.
- **`NO_COLOR=1`** (or `--no-color`) disables ANSI color.
- **Exit codes:** argument-parse errors (unknown flag, bad choice, missing argument) exit `64` (Swift Argument Parser's `EX_USAGE`). In-command validation errors (e.g. an unparseable due date) exit `1`/`2`.
- **Atomic validation:** if `-d/--due`, `--recurrence`, `--alarm`, `--priority`, or a location payload is present and cannot be validated, the command fails *before* creating or editing anything. With `--json`, an invalid due date emits a structured `invalid_due_date` error on stderr with accepted examples — retry with a corrected value rather than creating then patching.

---

## Viewing and Inspecting

### `today`
Reminders due today. Tabular: `--format json|table|plain`, `-v/--verbose`. `--no-overdue` excludes overdue items.
```bash
remctl today
remctl today --json
remctl --format table today
```

### `upcoming [DAYS]`
Reminders due in the next `DAYS` days (default 7; accepts 1–3650). Zero/negative ranges fail before opening the database.
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

### `search <query> [--completed]`
Search reminder titles and notes. Active reminders only by default; `--completed` includes completed reminders.
```bash
remctl search "milk"
remctl search "milk" --completed --json
```

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
Show a reminder's subtasks. `--json`.
```bash
remctl subtasks 23880
remctl subtasks 23880 --json
```

### `sections`
Show list sections. `--json`, `--no-color`.
```bash
remctl sections
```

### `stats`
Reminder statistics. `--json`, `--no-color`.
```bash
remctl stats
```

### `show [LIST] [--list-id ID] [--completed]`
Reminders in a list (name positionally or `--list-id`). Tabular: `--format`, `-v`. `--completed` includes completed reminders. Groceries lists show `🥕`; `show --json` includes `sectionEmoji` for known Groceries categories.
```bash
remctl show Shopping
remctl show --list-id 153 --json
remctl show Work --completed
remctl show Family -v
```

### `info <id>`
Detailed reminder info. `--json`, `--no-color`. `info --json` reports `dueDate` (the actual due date) vs `displayDate` (a separate UI/alert date — do not treat as the due date), `alarms` (EventKit relative/absolute alarms and location alarms), Early Reminders as labels (e.g. `15 minutes before`), recurrence, tags, sections, subtasks, parent and subtask image attachments, the deep link, and a rich-link `url` when present. Prefer this over raw SQLite checks.
```bash
remctl info 23880
remctl info 23880 --json
```

---

## Creating and Editing

### `add <title>`
Create a reminder. Key flags: `-l/--list` or `--list-id`, `-n/--notes`, `-d/--due`, `-p/--priority high|medium|low|none`, `--recurrence`, `--alarm`, `--url`, `-f/--flag`, `-t/--tags`, `--grocery`, `--section`/`--section-id`/`--new-section`, `--subtask` (repeatable), `--image` (repeatable), `--urgent/--no-urgent`, `--early-reminder`, `--json`.

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
```

How RemCTL picks the path from context on a bare `add`:

- `--url` requires a public `http`/`https` host. With no other private metadata it appends to notes; alongside private metadata it becomes a synced web rich link.
- `-t/--tags` writes inline `#hashtag` title tokens on a bare add, but synced tags when private metadata is present (`edit --tags` is always a synced-tag write).
- `-f/--flag` alone is EventKit's lossy priority proxy; with private metadata present (or `edit --flagged`) it writes the real flag.

### `edit <id>`
Edit an existing reminder. Flags: `--title`, `-l/--list` or `--list-id` (ordinary EventKit move), `-n/--notes`, `-d/--due` (or `clear`), `-p/--priority`, `--url`, `--recurrence`, `--alarm` (or `clear`), `--location-title`/`--latitude`/`--longitude`/`--radius`/`--proximity arriving|leaving`, `-t/--tags`, `--grocery`, `--section`/`--section-id`/`--new-section`, `--subtask` (repeatable), `--image` (repeatable), `--flagged/--no-flagged`, `--urgent/--no-urgent`, `--early-reminder`, `--json`.

Rich-link and image edits are **additive** — RemCTL adds, never removes or replaces existing links/images. `--section` resolves by name inside the target list (a single non-empty match wins on duplicates; use `--section-id` otherwise). When combined with `-l/--list`, section resolution uses the destination list. `--address` is accepted but not supported for location alarms.

```bash
remctl edit 23880 --title "New title"
remctl edit 23880 -d "next friday" -p medium
remctl edit 23880 -d clear
remctl edit 23880 -l Work
remctl edit 23880 --recurrence "weekly mon,wed"
remctl edit 23880 --alarm clear
remctl edit 23880 --section "Research" --subtask "Follow up"
remctl edit 23880 --image ~/Desktop/mockup.png --flagged --urgent
remctl edit 23880 --early-reminder 1h
remctl edit 23880 --early-reminder clear
remctl edit 23880 --location-title "Apple Park" --latitude 37.3349 --longitude -122.0090 --radius 200
```

### `done <id>` / `undone <id>`
Mark a reminder complete or incomplete. `--json`.
```bash
remctl done 23880
remctl undone 23880
```

### `delete <id> [--force]`
Delete a reminder; `--force` skips the confirmation prompt. `--json`.
```bash
remctl delete 23880
remctl delete 23880 --force
```

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

`edit -d clear` clears the due date.

**Recurrence** (EventKit, on `add` and `edit`): `daily`, `weekly`, `weekly mon,wed,fri`, `monthly`, `monthly 1,15`, `yearly` — validated before write. Recurring reminders show a `↻` badge (and a `Repeat` column in table output) and decode back to a `recurrence` object in JSON.

**Alarms** (`--alarm 15m`, `1h`, `1d`, or an absolute date) are EventKit alarms; they appear under `alarms` in `info --json`. `edit --alarm clear` removes normal alarms. `edit -d` carries a single matching absolute alarm forward; `edit -d clear` removes a single matching absolute alarm/display time while preserving unrelated alarms.

**Early Reminders** (`--early-reminder`) are a *separate* Reminders Early Reminder (a private due-date delta alert, not an EventKit alarm). Accepts `15m`, `1h`, `2d`, `1w`, `1mo`, or `clear`; a non-clear value requires a due date. JSON readback includes `earlyReminder`/`earlyReminders`.

**Location alarms** (`--location-title` with `--latitude`/`--longitude`, plus `--radius` and `--proximity arriving|leaving`) are written through EventKit structured-location alarms. Verify in `info --json` under `alarms` with `type: "location"` and a `location` object (title, coordinates, radius, proximity). Available on `edit`.

### Subtasks

`--subtask` (repeatable on `add` and `edit`) accepts a plain child title or a JSON object with: `title`, `notes`, `due`, `priority`, `alarm`, `recurrence`, `earlyReminder`, `url`/`urls`, `tags`, `image`/`images`, `flagged`, `urgent`, and location fields. Rich subtask URLs follow the public-host rule. Subtask image/link edits are additive; only images attach (generic file/PDF attachments are rejected).

```bash
remctl add "Prepare screenshots" -l Projects --image ~/Desktop/mockup.png --subtask "Export PNG"
remctl edit 23880 --subtask '{"title":"Follow up","due":"next friday at 3pm","url":"https://example.com","tags":["work"]}'
```

---

## Lists

### `lists`
List all lists. `--format json|table|plain`, `--no-color`. `lists --json` includes `color`, `badge`, pin state, and Groceries fields (`listType`, `isGroceries`, `grocery` locale). Human output marks Groceries lists with `🥕`.
```bash
remctl lists
remctl lists --json
```

### `list-create <name>`
Create a list. Appearance: `--color NAME` (named colors `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `brown`, `gray`, `cyan`, `teal` use EventKit). A `--symbol` or `--emoji` uses the ReminderKit appearance path. Groceries: `--groceries` with `--grocery-locale en_US`.
```bash
remctl list-create "Project X" --color blue
remctl list-create "Research" --color orange --symbol education3
remctl list-create "Cold Ideas" --color cyan --emoji 🥶
remctl list-create "Groceries" --groceries --grocery-locale en_US
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
Toggle the Reminders.app sidebar pin for a regular list (`--list-id`) or a smart list (`--smart-list-id`). If a name matches both a regular and a smart list, RemCTL fails and asks for an explicit ID. Verify smart-list pinning with `smart-lists --json`.
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
Delete a list (by name or `--list-id`); `--force` skips confirmation.
```bash
remctl list-delete "Project Y" --force
remctl list-delete --list-id 144 --force
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
Read-only inspector for built-in and custom smart lists. Reports numeric ID, object UUID, smart-list type, pin state/date, filter byte length, and a decoded summary when RemCTL recognizes the filter payload. Use `pinned`/`pinnedDate` here (not `lists --json`) to verify smart-list pinning.
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
- **Priority:** `--priority high|medium|low`; comma-separated values map to Priority: Any
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
Delete a custom smart list by exact name or `--smart-list-id` (never a built-in); `--force` skips confirmation.
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
Delete only the saved template (not lists previously created from it); `--force` skips confirmation.
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

### `import <file>`
Import reminders from a JSON file containing an array of reminder objects. `--json` emits a one-line `created`/`errors`/`total` summary.
```bash
remctl import shopping.json
remctl import shopping.json --json
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
- `⚑` flagged, `⏰` urgent, `↻` recurrence badge (e.g. `↻ weekly Mon, Wed`), `🥕` Groceries
- priority markers: `!!!` high, `!!` medium, `!` low
- table output keeps a dedicated `Repeat` column when any row recurs
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

---

## Setup and Diagnostics

RemCTL needs two macOS permission grants: **Reminders access** (EventKit + ReminderKit writes, prompted on first write or via `onboard`) and **Full Disk Access** (direct database reads). macOS TCC is scoped to the process context — a green Terminal does not imply a green agent runner; grant Full Disk Access to the target reported by `doctor --for-agent`.

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
Install shell completions/config. `--shell auto|bash|zsh|fish|skip` (default `auto`); `--doctor` also runs a doctor check; `--json`.
```bash
remctl setup --shell auto --doctor
```

### `completion [SHELL]`
Print a shell completion script for `bash`, `zsh`, or `fish` (default `zsh`).
```bash
remctl completion zsh
```
