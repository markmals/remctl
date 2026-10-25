# Private Metadata

RemCTL is a single Swift binary. It reads your local Reminders database directly (GRDB, read-only — needs Full Disk Access), writes ordinary fields through Apple's EventKit framework **in-process**, and writes Reminders' **private metadata** through Apple's private ReminderKit framework — also **in-process**, in the same binary. There are no separate helper executables, no daemon, no service, and no token.

Private-metadata capabilities are **first-class**. There is no `--private` flag and no opt-in mode. The relevant flags — `--section`, `--subtask`, `--urgent`, `--early-reminder`, `--image`, `-t/--tags`, `--url`, the list appearance flags, the smart-list filter flags, and the template commands — simply work. RemCTL chooses the EventKit or ReminderKit path automatically from the flags you pass.

## What "private metadata" is, and why it needs ReminderKit

EventKit is Apple's supported, public API for reminders. It exposes the basics — title, list, due date, priority, notes, recurrence, alarms, completion — but it does **not** expose much of what the modern Reminders app shows: sections, rich subtasks, synced tags, web rich links, image attachments, the real flag, urgent state, Early Reminders, exact list colors, official list symbols, emoji badges, Groceries metadata, custom smart lists, and templates.

That metadata lives behind Apple's **private ReminderKit framework**. To read it back RemCTL inspects the local SQLite store directly; to write it RemCTL links ReminderKit in-process and applies a bounded set of change items through Apple's own Reminders stack.

> **Honest caveat.** These capabilities call Apple's **private, unsupported** ReminderKit APIs. They were reverse-engineered, and Apple can rename classes, change method signatures, reject behavior, or alter sync semantics in any macOS release. They do **not** mutate the Reminders SQLite store directly, so they will not corrupt the store or break iCloud sync — but treat them as power-user functionality and verify the writes that matter (see [Verifying writes](#verifying-writes)).

RemCTL never writes the Reminders SQLite database directly. Public fields go through EventKit; private fields go through ReminderKit; reads come from GRDB.

## Public-vs-private routing (no flag)

Because there is no `--private` flag, RemCTL picks the path from **which flags are present** on a given command. A few flags carry both a public and a private meaning:

- **`--url`** — With no other private metadata present, `--url` is appended to the reminder's notes (public, EventKit). When other private metadata is present on the same command, it becomes a **synced web rich link** (private, ReminderKit).
- **`add --tags` / `add -t`** — On a bare `add` with no other private metadata, tags are written as inline `#hashtag` tokens in the title (public). When private metadata is present, they become **synced Reminders tags** (private).
- **`edit --tags` / `edit -t`** — Always a synced-tag write (private), and always additive. `edit --set-tags`, `edit --clear-tags`, and `edit --remove-tag` rewrite the set instead (private).
- **`add -f/--flag`** — Always the **real Reminders flag** (private, ReminderKit), exactly like `edit --flagged`. Passing it routes the whole command through the private path.
- **`edit -l/--list` and `edit --list-id`** — Ordinary EventKit list moves (public). Moving a reminder is not private metadata. If a move is combined with `--section` or `--grocery`, RemCTL validates that private metadata against the destination list.

Everything else (`--section`, `--subtask`, `--image`, `--urgent`, `--early-reminder`, list appearance, Groceries, smart lists, templates) is unambiguously private and always routes through ReminderKit.

## Reminder metadata

Synced web rich links, synced tags, sections, rich subtasks, image attachments, the real flag, urgent state, and Early Reminders.

```bash
remctl add "Research" -l Projects --url "https://example.com" -t remctl --section "Research"
remctl add "Research" -l Projects --section-id DCD255E2-7CF5-4B45-9566-3F9A5D84AFA8
remctl add "Prepare screenshots" -l Projects --image ~/Desktop/mockup.png --subtask "Export final PNG"
remctl add "Launch assets" -l Projects \
  --subtask '{"title":"Export PNG","notes":"Use final crop","due":"tomorrow","url":"https://example.com","tags":["media"],"urgent":true}'
remctl add "Leave now" -l Work --urgent
remctl add "Leave early" -l Work -d "today 14:00" --early-reminder 15m

remctl edit 23880 --url "https://example.com"
remctl edit 23880 -t remctl,work
remctl edit 23880 --set-tags remctl,work
remctl edit 23880 --remove-tag stale --remove-tag old
remctl edit 23880 --clear-tags
remctl edit 23880 --section "Research"
remctl edit 23880 --section-id DCD255E2-7CF5-4B45-9566-3F9A5D84AFA8
remctl edit 23880 --new-section "Inbox Zero"
remctl edit 23880 --subtask "Follow up"
remctl edit 23880 --subtask '{"title":"Follow up","notes":"Bring latest numbers","due":"next friday at 3pm","url":"https://example.com","tags":["work"],"flagged":true}'
remctl edit 23880 --image ~/Desktop/mockup.png
remctl edit 23880 --flagged --urgent
remctl edit 23880 --early-reminder 1h
remctl edit 23880 --early-reminder clear
```

### Rich links and tags

`--url` writes a web rich link attachment when it routes private (see [routing](#public-vs-private-routing-no-flag)). Rich-link URLs — and any URL inside a rich subtask — must resolve to a public `http` or `https` host. Loopback, `.local`, private, link-local, multicast, reserved, and unresolved hosts are rejected **before** writing, as are IPv4-mapped IPv6 spellings of those addresses (`::ffff:127.0.0.1`) and literal fake-IP targets in `198.18.0.0/15`, including trailing-dot DNS spellings (`198.18.0.1.`). Host *names* that resolve into the fake-IP range stay allowed, because DNS proxies hand out those placeholders for real public names. `-t/--tags` writes real synced Reminders tags when it routes private.

`-t/--tags` only adds tags. To rewrite the set, pass exactly one of `--set-tags a,b` (the reminder ends up with exactly those tags), `--clear-tags` (no tags left), or repeatable `--remove-tag x` (drops the named tags, case-insensitive, and keeps the rest). All three go through the private `set_tags` action, which removes every hashtag on the reminder and re-adds the requested names in one save. They cannot be combined with each other or with `-t/--tags`, and an empty `--set-tags`/`--remove-tag` value is refused before anything is written.

### Sections

- `--section NAME` resolves by name inside the target list. If duplicate section names exist, RemCTL uses the only non-empty matching section when there is exactly one; if it remains ambiguous, the command fails before writing and prints the available stable IDs.
- `--section-id ID` assigns to an exact section by its stable identifier.
- `--new-section NAME` creates a section and assigns to it. The list's existing section IDs are sent with the request and the new section is appended to them, so creating a section keeps the current section order instead of replacing it.
- `--smart-list NAME` or `--smart-list-id ID` with `--section`/`--section-id` puts the reminder in one of a **custom smart list's own sections** instead (ReminderKit `assign_smart_list_section`). The smart list and section are resolved before anything is written: built-in smart lists (they have no sections), unknown or ambiguous section names, a missing `--section`/`--section-id`, and `--new-section` are refused, and the error lists the smart list's sections with their ids. The write then targets that validated section even if a sync renames sections meanwhile, and is read back from the smart list's membership record (`verified: true`). `smart-lists` shows each custom smart list's sections and ids.
- Section membership records can hold several entries for one reminder; the entry with the newest `modifiedOn` decides (a newer obsolete entry means no section). Write verification refuses to guess when undated or equally dated entries disagree, while `show`, `info`, and section counts fall back to the last live entry.
- `section-create`, `section-rename`, and `section-delete` manage a list's sections directly (ReminderKit `create_section`/`rename_section`/`delete_section`). Duplicate names within the list are refused before writing; a new section is appended to the list's persisted section order; deleting one leaves its reminders in the list, unsectioned. Each write is read back from the store before it is reported (`verified: true`).

### Assignments

Shared lists support assigning a reminder to a participant. `--assign USER` resolves `USER` against the target shared list's sharees (display name, first/last name, email or phone address, numeric sharee ID, object UUID, or `me`); `--unassign` clears the assignment. The write goes through ReminderKit's assignment context (`assign_sharee` / `clear_assignment`), replacing any existing assignment, with the current user as originator. Discover participants with `remctl sharees LIST --json`; verify with `remctl info ID --json` under `assignment`. Unshared lists fail with "target list has no sharees".

### Subtasks

`--subtask` accepts a plain child title **or** a JSON object. Supported subtask fields:

`title`, `notes`, `due`, `priority`, `alarm`, `recurrence`, `earlyReminder`, `url`/`urls`, `tags`, `image`/`images`, `flagged`, `urgent`, and location fields (`locationTitle`, `latitude`, `longitude`, `radius`, `proximity`).

Subtask due dates, priority, recurrence, and alarms use the same validators as parent reminders, and rich subtask URLs follow the same public-host rule. A date-only `due` (`today`, `2026-06-01`, `+3d`) creates an **all-day** child, exactly as on the parent; `recurrence` takes a string spec or an exported recurrence object. Invalid parent or subtask values fail before RemCTL creates or edits anything, so private metadata is never silently dropped onto a partially-created reminder.

### Moving a parent with subtasks

EventKit cannot move a reminder that owns subtasks, so `edit -l/--list` clones the parent and its subtasks into the destination through ReminderKit, waits for the clone to appear in the store, and only then deletes the original. The moved reminder gets a **new numeric id** (`--json`: `id`, `oldId`, `method: "clone-delete"`, `subtasksMoved`, `originalDeleted`), and the move cannot be combined with other edit flags. If the clone cannot be verified, nothing is deleted.

Repeated `--subtask` values are created in the order you pass them, after any subtasks the parent already has. The result reports where the batch landed in `subtaskPlacement`: `afterExisting`, `first` (the parent had none), `unconfirmed` (the existing order could not be read, so the batch keeps its order but starts first), or `unordered` (the host's ReminderKit has no subtask ordering API).

### Reminder order

`reminder-move ID --before ID|--after ID|--first|--last` reorders a reminder through ReminderKit. In a list it inserts the reminder next to its anchor in the list's ordering (`REMListChangeItem insertReminderChangeItem:before/afterReminderChangeItem:`; `--first`/`--last` anchor on the first/last other reminder). With `--smart-list`/`--smart-list-id` it rewrites an unsectioned custom smart list's manual order (`REMManualOrdering` through `updateManualOrdering:`), so reminders from different lists can be ordered against each other — only once Reminders has recorded a manual order for that smart list, and never for built-in or sectioned smart lists (refused before saving). RemCTL computes the order the move must produce and reads the persisted order back until it matches: `verified: true`, or `order_unverified` when it never does.

`reminder-move ID --parent PARENT_ID` nests a reminder under another top-level reminder of the same list, and `--top-level` returns a subtask to the list; a subtask moved with only a position is reordered among its parent's subtasks (`move_reminder_in_hierarchy`: the parent's subtask context or the list's change item takes the reminder, after `removeFromParentReminder` when it leaves a parent). The reminder keeps its identity, so its id, notes, dates, and metadata stay. RemCTL checks the one-level rule, the parent's list, and that Reminders has recorded every sibling's position before writing, then reads back both the new parent and the level's order (`verified: true`). Moved to the top level next to a sectioned reminder, it joins that section, as a drop does in Reminders.

### Attachments

Only **images** attach (`--image`, or `image`/`images` on a subtask). Generic file and PDF attachments are intentionally rejected because Reminders does not reliably display them. Rich-link and image edits are **additive**: RemCTL adds synced rich links and images but never removes or replaces existing ones.

### Flag and urgent

`--flagged`/`-f` and `--urgent` set the real Reminders flag and urgent state (with `--no-flagged`/`--no-urgent` to clear them on `edit`). `add -f/--flag`, `flag`, and `unflag` all write the real flag through ReminderKit; EventKit has no flagged API, so when that write fails the command exits 1 (`--json`: `{"status":"error","code":"flag_failed",…}` on stderr) instead of silently changing the priority.

### Early Reminders

`--early-reminder` writes a Reminders **Early Reminder** — a due-date delta alert, **not** an EventKit alarm. Accepted forms: `15m`, `1h`, `2d`, `1w`, `1mo`, or `clear`. Every non-clear value requires a due date, because Reminders anchors the delta to the reminder's due date. Verify in `info --json` under `earlyReminder`/`earlyReminders`. Readback prefers the reminder's own delta-alert envelope and falls back to the `ZREMCDDUEDATEDELTAALERT` table on stores that keep the alerts there (macOS 27), so `clear` finds the alerts to remove either way.

## Location alarms

Location-based alarms use `--location-title`, `--latitude`, `--longitude`, `--radius`, and `--proximity` (`arriving|leaving`), on both `add` and `edit`.

```bash
remctl add "Pick up prints" --location-title "Apple Park" --latitude 37.3349 --longitude=-122.0090 --radius 200
remctl edit 23880 --location-title "Apple Park" --latitude 37.3349 --longitude -122.0090 --radius 200 --proximity arriving
remctl edit 23880 --location-address "1 Apple Park Way, Cupertino, CA 95014" --proximity leaving
```

Although a location alarm is conceptually Reminders metadata, RemCTL writes it through **EventKit's structured-location path**, because that materializes reliably on current macOS. It is therefore a public write: no ReminderKit call is involved. RemCTL validates latitude, longitude, radius, and proximity before saving, and replaces any existing location alarm instead of stacking a second one — time alarms are untouched. Verify the result in `info --json` under `alarms`.

`--location-address ADDRESS` resolves a street address with Apple's geocoder before the first write and refuses anything but a single street-sized match that names the street typed in a town or postal code the address gives; see [commands.md](commands.md#due-dates-recurrence-alarms-early-reminders-locations) for the statuses and error codes, and `remctl location-lookup` to inspect an address without writing. The resolved coordinates, not the address text, are what gets saved: EventKit's structured location carries only a title, coordinates and a radius.

## List metadata

Exact `#RRGGBB` colors, official list symbols, emoji badges, Groceries conversion/locale, and list/smart-list pin state.

```bash
remctl list-symbols
remctl list-symbols --preview
remctl list-symbols --html ~/Desktop/symbols.html
remctl list-create "Research" --color orange --symbol education3
remctl list-create "Focus" --color '#34C759' --emoji 🎯
remctl list-edit Projects --color '#FF8D28' --symbol education3
remctl list-edit --list-id 144 --symbol education3
remctl list-edit Projects --emoji 📌
remctl list-rename --list-id 123 --new-name "Project Archive"
remctl list-pin "Project X"
remctl list-pin "Flagged"
remctl list-unpin --list-id 144
remctl list-unpin --smart-list-id 4
```

- `list-create --color NAME` uses **EventKit** for normal color names.
- A `#RRGGBB` hex color, `--symbol`, or `--emoji` uses the **ReminderKit** appearance path for exact colors and badges.
- `--symbol` accepts one of the **71 official Reminders emblem names** printed by `list-symbols` (Reminders' own picker uses private names such as `education3`). Arbitrary SF Symbol strings are rejected because they fall back to the default icon in Reminders.
- `--emoji` writes a custom emoji badge for standard emoji such as `🥶` or `📌`.
- `list-symbols` prints the official emblem names; its terminal glyph column is approximate. `list-symbols --preview` opens a native-asset HTML contact sheet with interactive official color swatches; `list-symbols --html PATH` writes that sheet to a file.
- `list-edit` resolves by exact list name, then safe normalized matching; if a duplicate match is ambiguous, use `--list-id`.
- `list-pin`/`list-unpin` target regular lists or smart lists by name. If a name matches both, use `--list-id` or `--smart-list-id`.
- RemCTL tells ReminderKit which smart-list kind it is targeting: custom smart lists use the custom fetch, built-ins use the generic one. A built-in object ID is not a custom one, so there is no fallback between them — on hosts without the generic fetch (tested macOS 26.2 and 27.0 builds), built-in pinning fails with `Built-in smart-list pinning is unsupported on this macOS version` **before** a save request is created. Custom smart-list pinning is unaffected.

Verify list color and badges with `lists --json` (`color`, `badge`, `badgeEmblem`). Verify regular-list pinning with `lists --json` and **smart-list** pinning with `smart-lists --json`: smart-list rows can leave `ZISPINNEDBYCURRENTUSER` empty while still updating `ZPINNEDDATE`, so RemCTL reports `pinned: true` when the smart-list pin date is positive.

## List groups

Reminders list groups are sidebar containers for lists. `groups` and `group-info` read them; `group-create`, `group-edit`, `group-delete`, and `list-create --group` write them through ReminderKit (`create_group`, `set_list_parent_group`, `delete_group`; a rename reuses `set_list_appearance`).

- Moving a list into or out of a group (`set_list_parent_group`) changes only its container. The list keeps its numeric id, object UUID, and every reminder.
- Reminders puts a list it adds to a group at the **top** of the group. `group-edit --move-list` therefore detaches every child and re-attaches them in reverse of the requested order; the final order is read back before it is reported. If a reorder stops part-way, the error names the lists left at the top level (`listsAtTopLevel`).
- `group-delete` moves each child to the top level and deletes the group only once the store shows it empty, so no list or reminder is deleted with it. ReminderKit also refuses to delete an object that is not a group when the host reports group state.
- Every write is read back from the store before the next one starts (`verified: true`; `group_write_unverified` / `group_order_unverified` when the store never shows it).

```bash
remctl groups --json
remctl group-create Writing --add-list Editorial
remctl group-edit Writing --move-list Editorial --after-list Podcasts
remctl list-create Drafts --group Writing
remctl group-delete Writing --force
```

## Groceries

Reminders stores Groceries lists as ordinary lists with private grocery metadata, not as a separate EventKit list class.

```bash
remctl lists --json
remctl show Groceries
remctl list-create "Groceries" --groceries --grocery-locale en_US
remctl list-edit "Shopping" --groceries --grocery-locale it_IT
remctl list-edit "Shopping" --standard
remctl add "Milk" -l Groceries --grocery --json
remctl edit 23880 --grocery --json
```

- `list-create --groceries` creates a list with grocery metadata; `list-edit --groceries` converts an existing list; `list-edit --standard` clears the grocery flag; `--grocery-locale` writes the locale identifier Reminders uses for grocery categorization.
- Detected Groceries lists appear in `lists --json` as `listType: "groceries"`, `isGroceries: true`, with `grocery.locale` and categorization flags. Human output marks them with `🥕` in headings, and known grocery sections get category emoji such as `🥛 Dairy, Eggs & Cheese`, `🥬 Produce`, and `🧻 Household Items`. `show --json` includes `sectionEmoji` when a reminder belongs to a known category.
- `add --grocery` and `edit --grocery` only apply to a **detected Groceries list**; RemCTL fails before writing if the target list is not one. RemCTL verifies Reminders' **automatic sorter** first — polling the local section membership because Reminders often sorts new items immediately — and reports `source: "reminders_auto"` (with `verifiedSections`) when the auto-sorter already handled it. Only if the item is still unsectioned does RemCTL fall back to ReminderKit's explicit grocery categorizer.
- The explicit categorizer is host-aware and reports which selector ran in `selector`. macOS 26 keeps `categorizeGroceryItemsWithReminderIDs:` on the grocery context with **UUID** values; macOS 27 moved the operation to `autoCategorizeRemindersWithReminderIDs:` on the list change with **`REMObjectID`** values. The receivers are checked live before dispatch; passing `REMObjectID` values to the macOS 26 selector reports success but tombstones the objects, so the two argument contracts are kept separate.

For Groceries categorization, verify with `show <list> --json`: the section membership lives on the list grouping rather than only in the reminder detail payload.

## Smart lists

`smart-lists` reads built-in and custom smart lists (read-only). RemCTL can also create, edit, and delete **custom** smart lists for the Reminders filters that materialize reliably.

```bash
remctl smart-lists
remctl smart-lists --json
remctl smart-list-create "Flagged Review" --flagged
remctl smart-list-create "Any Tag" --any-tag
remctl smart-list-create "#remctl Today" --tags remctl --date today
remctl smart-list-create "Priority or Today" --match any --priority high,medium --date today
remctl smart-list-create "Projects Today" --include-list Projects --date today --date-today-include-past-due
remctl smart-list-create "Due Before June 1" --date-range 2026-05-16,2026-05-31 --color red --emoji 📆
remctl smart-list-edit "Priority or Today" --priority high --color red --emoji 📆
remctl smart-list-edit --smart-list-id 170 --filter-json @filter.json
remctl smart-list-delete "Flagged Review" --force
```

- `smart-list-create` verifies that the active account supports custom smart lists, rejects duplicate exact custom names, and accepts the appearance flags plus the filter families below. It sets the private account-ownership and supported-version metadata Reminders.app expects; without those fields a row can survive but the edit UI can show zero filters.
- `smart-list-edit` fetches a custom smart list by exact name or numeric `--smart-list-id` and replaces its filter data and/or appearance. It never edits built-in smart lists.
- `smart-list-delete` removes a custom smart list by exact name or `--smart-list-id` and never matches built-ins.

### Supported filter families

- **Any tag** — `--any-tag`
- **Selected tags** — `--tags` (plus optional `--tag-match all|any`)
- **Date** — `--date any|today`, `--date-today-include-past-due`, `--date-on`, `--date-before`, `--date-after`, `--date-range START,END`
- **Time of day** — `--time morning|afternoon|evening|night`
- **Priority** — `--priority high|medium|low|none` (`none` is Reminders' No Priority); comma-separated (e.g. `high,medium`) = Priority: Any
- **Flag** — `--flagged`
- **Vehicle** — `--vehicle connected`
- **Specific location** — `--location-title`/`--latitude`/`--longitude`/`--radius`/`--proximity`
- **One included list** — `--include-list` / `--include-list-id`
- **Top-level match** — `--match all|any` across the families above
- **Appearance** — `--color`/`--symbol`/`--emoji`
- **Raw escape hatch** — `--filter-json` accepts raw official filter JSON, or `@path` to a file

### Rejected before saving (non-materializing)

Untagged, no-date, relative date, no-time, vehicle **disconnected**, list **exclusions**, **more than one included list**, and unknown or zero-filter shapes. Reminders.app materializes only **one** included list per smart list — do not build multi-list aggregates; use one included list or a different reliable family.

Verify smart lists with `smart-lists --json`: it exposes the decoded filter, `filter.supported`, and the supported-version metadata (`minimumSupportedVersion` / `effectiveMinimumSupportedVersion` = `20220430`).

## Smart list examples

```bash
remctl smart-list-create "Any Tag" --any-tag --json
remctl smart-list-create "#remctl Today" --tags remctl --date today --json
remctl smart-list-create "Priority: Any" --priority high,medium --json
remctl smart-list-create "Morning" --time morning --json
remctl smart-list-create "Projects Today" --include-list Projects --date today --date-today-include-past-due --json
remctl smart-list-create "Near Home" --location-title Home --latitude 41.9 --longitude 12.5 --radius 100 --proximity enter --json
remctl smart-list-create "Due Before June 1" --date-range 2026-05-16,2026-05-31 --color red --emoji 📆 --json
remctl smart-list-edit --smart-list-id 170 --filter-json @filter.json --color red --emoji 📆 --json
remctl smart-list-delete "Priority or Today" --force --json
```

## Templates

Reminders templates are saved lists with saved reminders inside, stored separately from lists. `templates` and `template-info` are read-only inspectors; RemCTL can also create, apply, and delete templates through ReminderKit.

```bash
remctl templates
remctl templates --json
remctl template-info "Rome: Things To See" --json
remctl template-create "Packing Template" --from-list Packing --json
remctl template-create "Archive Template" --from-list-id 144 --include-completed
remctl template-apply "Packing Template" --json
remctl template-delete "Packing Template" --force
```

- `template-create` saves a whole source list (`--from-list NAME` or `--from-list-id ID`) as a template, rejecting duplicate exact template names. `--include-completed` is the only content-selection flag.
- `template-apply` creates a new list from a template; the new list's name is controlled by Reminders' template behavior.
- `template-delete` removes a saved template. Lists already created from that template are separate lists and are not affected.

Template support is **whole-list only**: RemCTL does not append individual reminders to existing templates, copy selected reminders into a template, or strip subtasks or due dates while saving. Existing iCloud template links are **read-only** — they appear as `publicLink` when present, but RemCTL does not create or revoke iCloud sharing links.

Verify templates with `templates --json` and `template-info`, and verify an applied template's new list with `lists --json` and `show <new list> --json`.

## When a private step fails

A private write that ReminderKit refuses stops the command with the helper's message and exit 1; no later private step runs.

`add` is the dangerous case, because the reminder already exists by the time the private fan-out runs. RemCTL therefore checks what it can up front — `--section`/`--section-id` and `--assign` are resolved, and a rich-link `--url` or subtask URL is held to the public-host rule, **before** the reminder is created, so a typo or a blocked host fails with nothing written. If a private step still fails afterwards, RemCTL reports the created reminder instead of a bare error, and tells you to finish it with `edit`:

```
Created reminder #23880 ('Buy milk') but failed to apply set_urgent; re-run edit to finish. Do NOT re-run add (would duplicate).
Completed: add_private_metadata
Error: <helper message>
```

With `--json` the same information is a structured stderr object with exit 1: `{"status":"error","code":"private_add_partial","message":…,"id":…,"numericId":…,"title":…,"failed":"<action>","completed":["<action>",…],"error":"<helper message>"}`. Re-running `add` would create a duplicate; use the reported `numericId` with `edit`.

## Verifying writes

Because these are private, unsupported APIs, verify the writes that matter — and when cross-device sync matters, ask the user to check another device.

- **Reminder metadata** — `info <id> --json` reports the rich-link URL in `url`, parent and subtask image attachments in `attachments`, EventKit and location alarms in `alarms`, Early Reminders in `earlyReminder`/`earlyReminders`, recurrence in `recurrence`, plus sections, tags, and subtasks. It keeps the actual `dueDate` separate from Reminders' optional `displayDate`; an all-day `dueDate` is local midnight of its day, and a timed due date saved without a time zone (GoodTask, older Reminders) reads as the wall-clock time Reminders shows.
- **List metadata** — `lists --json` exposes `color`, `badge`, `badgeEmblem`, Groceries flags (`listType`, `isGroceries`, `grocery.locale`), and pin state.
- **Smart lists** — `smart-lists --json` exposes the decoded filter, `filter.supported`, supported-version metadata, and pin state.
- **Templates** — `templates --json` / `template-info`, then `show <new list> --json` after `template-apply`.

Do not query SQLite directly for ordinary metadata verification, and do not assume a sync-clean local row means the Reminders UI will display it — generic files and PDFs were the counterexample, and are intentionally rejected.
