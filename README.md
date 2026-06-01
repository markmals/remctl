# RemCTL: The Power-User Reminders CLI

![RemCTL](https://cdn.macstories.net/images/uploads/2026/05/26/cleanshot-2026-05-26-at-1629152x-1779805785287-9271e938c2.png)

RemCTL is a fast, scriptable Apple Reminders CLI for macOS, designed for power users and AI agents. It is a single self-contained Swift binary — no helpers, no daemon, no service, no token.

RemCTL reads your local iCloud Reminders database directly (with native macOS permission access) for speed and detail, then writes through Apple's EventKit and ReminderKit frameworks **in-process** so changes sync normally to other devices. It never writes the Reminders database directly.

Unlike other Reminders CLIs, RemCTL also drives Reminders' **private metadata** — sections, subtasks, synced tags, image attachments, urgent state, Early Reminders, exact list colors, official list symbols, emoji badges, Groceries metadata, custom smart lists, and Reminders templates — by calling Apple's private ReminderKit framework directly. These capabilities are first-class: the relevant flags just work, no opt-in. Location-based alarms are written through EventKit's structured-location path because that materializes reliably on current macOS.

As a result, RemCTL is the only Reminders CLI that truly replicates the modern Reminders experience on macOS — without breaking iCloud sync.

> **Status:** v0.1.0, a fresh Swift line. The private-metadata capabilities call Apple's **private, unsupported** ReminderKit APIs (reverse-engineered, and may change across macOS releases). They do not mutate SQLite directly, so they will not corrupt the store or break sync, but treat them as power-user functionality and verify writes that matter.

## Install

```bash
brew install markmals/tap/remctl
remctl onboard                      # grant Reminders access (and Full Disk Access)
remctl doctor                       # confirm setup
remctl today
```

Requires **macOS 14 (Sonoma) or later**. Installs from a prebuilt bottle on Apple-Silicon Sonoma+ when available, otherwise builds from source (needs Xcode / a Swift 6 toolchain). Because RemCTL links Apple's private ReminderKit framework, it is distributed as a Homebrew source/bottle install — not a notarized App Store binary.

After install, grant the two macOS permissions RemCTL needs (see [macOS Permissions](#macos-permissions)): **Full Disk Access** for the direct database reads, and **Reminders access** for writes.

## How It Works

```text
remctl  (one Swift binary)
  reads:   ~/Library/Group Containers/group.com.apple.reminders/.../Data-*.sqlite   (GRDB, read-only — needs Full Disk Access)
  writes:  EventKit            (in-process)  — public fields: title, list, due, priority, notes, recurrence, alarms, complete, location alarms
  private: ReminderKit         (in-process)  — sections, subtasks, tags, attachments, urgent, Early Reminders, real flag, list/smart-list appearance, Groceries, templates
```

Why this architecture:

- **Direct SQLite reads** expose sections, subtasks, tags, attachments, deep links, list colors and badges, recurrence metadata, alarms, location alarms, and Early Reminder metadata in tens of milliseconds.
- **EventKit writes** keep Reminders and iCloud in charge of ordinary mutations. RemCTL does not write the database.
- **ReminderKit writes** cover the metadata Apple does not expose through EventKit. They use Apple's private framework (unsupported), folded into the same binary, and never touch SQLite directly.

There are no separate helper executables — the EventKit and ReminderKit logic run inside the single `remctl` binary.

## Command Map

| Task | Commands |
| --- | --- |
| See what is due | `today`, `upcoming`, `overdue` |
| Browse reminders | `lists`, `smart-lists`, `templates`, `template-info`, `show`, `search`, `flagged`, `urgent`, `info`, `subtasks`, `sections`, `tags`, `stats` |
| Create and edit | `add`, `edit`, `done`, `undone`, `delete`, `flag`, `unflag` |
| Organize lists | `list-symbols`, `list-create`, `list-edit`, `list-pin`, `list-unpin`, `list-rename`, `list-delete` |
| Smart lists & templates | `smart-list-create`, `smart-list-edit`, `smart-list-delete`, `template-create`, `template-apply`, `template-delete` |
| Share data | `export`, `import`, `link`, `open`, plus `--json` and `--format table` on read commands |
| Set up the Mac | `onboard`, `permissions`, `doctor`, `setup`, `completion` |

Common examples:

```bash
remctl today
remctl show Work --format table
remctl show --list-id 153 --json
remctl add "Review PR" -l Work -d "tomorrow 10:00" -p high
remctl add "Pay rent" -d "2026-06-01" --recurrence monthly
remctl edit 23880 -d clear
remctl edit 23880 -l Work
remctl add "Research" -l Projects --url "https://example.com" -t remctl --new-section "Research"
remctl add "Leave early" -l Work -d "today 14:00" --early-reminder 15m
remctl add "Launch assets" -l Projects --subtask '{"title":"Export PNG","notes":"Use final crop","due":"tomorrow","url":"https://example.com","tags":["media"]}'
remctl list-symbols
remctl list-symbols --preview
remctl list-create "Research" --color orange --symbol education3
remctl list-create "Cold Ideas" --color cyan --emoji 🥶
remctl list-create "Groceries" --groceries --grocery-locale en_US
remctl add "Milk" -l Groceries --grocery
remctl smart-lists --json
remctl smart-list-create "Flagged Review" --flagged
remctl smart-list-create "Priority or Today" --match any --priority high,medium --date today
remctl smart-list-edit "Priority or Today" --priority high
remctl smart-list-delete "Flagged Review" --force
remctl templates --json
remctl template-create "Packing Template" --from-list Packing --json
remctl template-apply "Packing Template" --json
remctl list-edit Projects --color orange --symbol education3
remctl list-pin "Project X"
remctl list-rename --list-id 123 --new-name "Project X Archive"
remctl info 23880 --json
```

The full command guide is in [docs/commands.md](docs/commands.md). Private-metadata behavior and guardrails are in [docs/private-metadata.md](docs/private-metadata.md). For smart lists, see [docs/commands.md#smart-lists](docs/commands.md#smart-lists); for templates, [docs/commands.md#templates](docs/commands.md#templates).

Due dates are atomic. If `-d/--due` is present and RemCTL cannot parse it, the command fails before creating or editing anything. Supported deterministic forms include `YYYY-MM-DD`, `YYYY-MM-DD HH:MM`, `today at 3pm`, `tomorrow 09:30`, `tonight at 11`, `Friday at 15:00`, `next friday at 3pm`, `+3d`, `eod`, and `eow`. Recurrence, alarm, and priority inputs are also validated before writes. Supported recurrence forms are `daily`, `weekly`, `weekly mon,wed,fri`, `monthly`, `monthly 1,15`, and `yearly`; `upcoming DAYS` requires 1 to 3650.

## Private Metadata

For the metadata Apple does not expose through EventKit, RemCTL calls Apple's private ReminderKit framework directly, in-process. There is no opt-in flag — the relevant flags simply work:

```bash
remctl add "Research" -l Projects --url "https://example.com" -t remctl --section "Research"
remctl edit 23880 --section-id DCD255E2-7CF5-4B45-9566-3F9A5D84AFA8
remctl add "Launch assets" -l Projects --subtask '{"title":"Export PNG","notes":"Use final crop","due":"tomorrow","url":"https://example.com","tags":["media"]}'
remctl add "Leave now" -l Work --urgent
remctl add "Leave early" -l Work -d "today 14:00" --early-reminder 15m
remctl edit 23880 --early-reminder clear
remctl edit 23880 --image ~/Desktop/mockup.png --flagged --urgent
remctl edit 23880 --location-title "Apple Park" --latitude 37.3349 --longitude -122.0090 --radius 200
remctl list-edit Projects --color '#FF8D28' --symbol education3
remctl list-create "Groceries" --groceries --grocery-locale en_US
remctl add "Milk" -l Groceries --grocery
remctl list-pin "Project X"
remctl smart-list-create "Priority or Today" --match any --priority high,medium --date today
remctl template-create "Packing Template" --from-list Packing
```

Private metadata covers the parts of Reminders that EventKit does not:

- **Reminder metadata:** synced web rich links (`--url`), synced tags (`-t/--tags`), sections (`--section`/`--section-id`/`--new-section`), rich subtasks (`--subtask`), image attachments (`--image`), real flag state (`-f/--flag`, `--flagged`), urgent state (`--urgent`), and Early Reminders (`--early-reminder`).
- **List metadata:** exact `#RRGGBB` colors, official list symbols (`--symbol`), emoji badges (`--emoji`), Groceries conversion/locale (`--groceries`/`--standard`/`--grocery-locale`), and list/smart-list pin state.
- **Smart lists:** custom smart-list create/edit/delete for the Reminders filters RemCTL has verified materialize correctly.
- **Templates:** whole-list template create/apply/delete. Existing public template links are read-only; RemCTL does not create iCloud sharing links.

A few rules keep this safe and predictable:

- Where a flag has both a public and a private meaning, RemCTL picks the path from context — with no other private metadata present, `--url` appends to notes and `add --tags` writes inline `#hashtag` title tokens (public); alongside other private metadata they become a synced rich link and synced tags. `edit --tags` is always a synced-tag write. `add -f/--flag` alone is EventKit's lossy priority-proxy; with private metadata (or `edit --flagged`) it writes the real flag.
- `edit -l/--list` and `edit --list-id` are ordinary EventKit moves.
- Location alarms are written through EventKit's structured-location path (they persist reliably there); verify in `info --json` under `alarms`.
- `--url` and rich subtask URLs must be public `http`/`https` hosts. Loopback, `.local`, private, link-local, multicast, reserved, and unresolved hosts are rejected before writing.
- Rich-link and image edits are additive — RemCTL adds, it does not remove or replace existing links/images.
- `--early-reminder` accepts `15m`, `1h`, `2d`, `1w`, `1mo`, or `clear`. Non-clear values require a due date.
- `list-create --color NAME` uses EventKit for normal color names; pass a `#RRGGBB` hex, `--symbol`, or `--emoji` for the ReminderKit appearance path.
- `list-symbols` prints the 71 official Reminders emblem names; `--symbol` only accepts those (arbitrary SF Symbol names render as the default icon). Use `--emoji` for custom emoji badges. `list-symbols --preview` opens a native-asset HTML contact sheet.
- Groceries writes verify Reminders' automatic sorter first, then use the private categorizer only if needed.
- Generic file/PDF attachments are intentionally rejected; only images attach.

Verify with `remctl info ID --json` (reminder metadata), `lists --json` (list `color`/`badge`/Groceries/pin), `smart-lists --json` (filters/pin), and `templates --json` / `template-info`.

## Groceries Lists

Reminders stores Groceries lists as normal lists with private grocery metadata. `lists --json` reports `listType`, `isGroceries`, and the grocery locale; human `lists`/`show` mark Groceries lists with `🥕`, and known grocery sections get category emoji such as `🥛 Dairy, Eggs & Cheese`, `🥬 Produce`, and `🧻 Household Items` (`show --json` includes `sectionEmoji`).

```bash
remctl list-create "Groceries" --groceries --grocery-locale en_US
remctl list-edit "Shopping" --groceries --grocery-locale it_IT
remctl list-edit "Shopping" --standard
remctl add "Milk" -l Groceries --grocery
```

`add --grocery` creates the reminder normally, waits for Reminders' automatic grocery sorter, verifies the resulting section from the local database, and only falls back to ReminderKit's explicit categorizer if the item is not sorted yet.

## Smart Lists

RemCTL inspects built-in and custom smart lists with `smart-lists`, and can create/edit/delete custom smart lists for the Reminders.app filters that materialize reliably: any tag, selected tags, date, time, priority, flag, vehicle-connected, specific location, one included list, and `--match all|any` across those families.

```bash
remctl smart-lists --json
remctl smart-list-create "Any Tag" --any-tag
remctl smart-list-create "#remctl Today" --tags remctl --date today
remctl smart-list-create "Projects Today" --include-list Projects --date today --date-today-include-past-due
remctl smart-list-create "Due Before June 1" --date-range 2026-05-16,2026-05-31 --color red --emoji 📆
remctl smart-list-edit --smart-list-id 170 --priority high
remctl smart-list-delete "Priority or Today" --force
```

RemCTL rejects unknown filter shapes and known zero-filter shapes before saving. Smart lists support the same appearance flags as lists (`--color`, `--symbol`, `--emoji`). Reminders.app materializes only one included-list filter at a time — do not build multi-list aggregates; use one included list or a different reliable family. See [docs/commands.md#smart-lists](docs/commands.md#smart-lists) and [docs/private-metadata.md#smart-list-examples](docs/private-metadata.md#smart-list-examples).

## Templates

Reminders templates are saved lists with saved reminders inside. RemCTL reads them from the local template tables and can create, apply, and delete them through ReminderKit. Template support is list-level: save an entire source list as a template, or apply a template to create a new list. It does not append individual reminders to existing templates or strip subtasks/due dates while saving. Existing public template links are read-only.

```bash
remctl templates --json
remctl template-info "Rome: Things To See" --json
remctl template-create "Packing Template" --from-list Packing --json
remctl template-create "Archive Template" --from-list-id 144 --include-completed
remctl template-apply "Packing Template" --json
remctl template-delete "Packing Template" --force
```

`template-create` takes one source list; `--include-completed` is the only content-selection flag. Verify with `templates --json` / `template-info`, and applied templates with `lists --json` and `show <new list> --json`.

## Output

RemCTL output is designed for both humans and agents:

- reminder IDs are shown as `#ID`, colored with the reminder's list color when readable
- flagged reminders show `⚑`; urgent reminders show `⏰`; recurring reminders show a repeat badge such as `↻ weekly Mon, Wed`
- Groceries lists show `🥕` in headings and summaries
- `info --json` reports the actual due date as `dueDate`; a separate display/alert date appears as `displayDate`; EventKit and location alarms appear as `alarms`; Early Reminders appear as labels such as `15 minutes before`
- `edit -d` carries a single matching absolute alarm forward; `edit -d clear` removes a single matching absolute alarm/display time; `edit --alarm clear` removes normal alarms explicitly
- table output keeps a dedicated `Repeat` column when any row recurs
- human output strips terminal control characters from Reminders text; every read command supports `--json`

```bash
remctl today --json
remctl --format table upcoming 14
NO_COLOR=1 remctl today
```

## macOS Permissions

RemCTL needs two macOS permission grants:

- **Reminders access** — for EventKit and ReminderKit writes (prompted on first write, or via `remctl onboard`)
- **Full Disk Access** — for the direct Reminders database reads

```bash
remctl onboard                      # triggers the Reminders prompt; guides Full Disk Access
remctl permissions full-disk-access # opens System Settings + prints the exact target
remctl doctor                       # verifies the current context
```

Full Disk Access is scoped to the **process context**. A Terminal session can pass `remctl doctor` while a different app or agent runner fails. Run `remctl doctor` from the same context that will run RemCTL; for agent setup, use `remctl doctor --for-agent`. Manual path: System Settings → Privacy & Security → Full Disk Access, add the target printed by `remctl doctor --for-agent` (in the picker, press `Command-Shift-G`, paste the path, Return, Open).

## For Agents

Use JSON when scripting:

```bash
remctl today --json
remctl show Work --json
remctl search "query" --completed --json
remctl info 23880 --json
remctl doctor --for-agent --json
```

- `search` matches titles and notes; `--completed` includes completed reminders.
- For fast writes, call `remctl add ... --json`, use the returned `numericId` when present, then verify with `remctl info <numericId> --json`. `info --json` includes rich-link URLs, attachments, alarms, location alarms, Early Reminders, and recurrence — so agents do not need raw SQLite checks.
- Pass deterministic due dates (ideally `YYYY-MM-DD HH:MM` resolved in the user's timezone). On an invalid date, RemCTL exits before writing with a structured `invalid_due_date` JSON error on stderr; retry with a corrected date rather than creating then patching.
- List names resolve exact → case-insensitive → normalized (handles emoji prefixes). If more than one matches, RemCTL fails and asks for `--list-id`. `show`, `add`, `edit`, `link`, `export`, and the `list-*` commands accept `--list-id`; `list-pin`/`list-unpin` also accept `--smart-list-id`.
- Never mutate the Reminders SQLite database — use RemCTL commands.
- For setup troubleshooting, trust the `context` object in `doctor --for-agent --json`: a green Terminal does not imply a green agent runner; grant Full Disk Access to the app/interpreter reported there.

The concise agent contract is in [SKILL.md](SKILL.md).

## Docs

- [Installation and onboarding](docs/installation.md)
- [Command guide](docs/commands.md)
- [Private metadata](docs/private-metadata.md)
- [Architecture](docs/architecture.md)
- [Agent contract](SKILL.md)

## License

MIT. See [LICENSE](LICENSE).
