# RemCTL → `reminders` — CLI Parity Contract

> Generated parity reference for the Swift port (package `RemindersControl`, binary `reminders`). The source of truth is the current Python at HEAD (`remctl` 1.0.3). Produced by a 13-reader recon pass over the CLI, shared modules, the three folded-in helpers, and the test suite. Companion to [`2026-05-28-reminders-swift-port-design.md`](2026-05-28-reminders-swift-port-design.md).

## Contents

- [Read/query/listing commands](#readquerylisting-commands)
- [Inspect reminders & lists](#inspect-reminders--lists)
- [Reminder mutation](#reminder-mutation)
- [Link / open / export / import](#link--open--export--import)
- [Lists management](#lists-management)
- [Smart lists](#smart-lists)
- [Templates](#templates)
- [Ops / meta commands](#ops--meta-commands)
- [Program scaffolding](#program-scaffolding)
- [Store & CoreData schema](#store--coredata-schema)
- [Shared modules](#shared-modules)
- [Folded-in helpers (EventKit / private / AppKit)](#folded-in-helpers-eventkit--private--appkit)
- [Parity-critical test contract](#parity-critical-test-contract)

## Read/query/listing commands

<!-- recon: cmds:reads-core (agent-a3b6730be974d5856) -->

All six commands route through `run_handler_with_fallback`, so `RemindersDBUnavailable` becomes `Error: <msg>` on stderr + exit 1. I have everything. Here is the complete contract.

### `search`

- **Summary:** Substring search across reminder titles and notes (LIKE-based), newest first, capped at 100 results.
- **Positional args:** `query` — str — required — the search text (matched as `%query%` against `ZTITLE` and `ZNOTES`).
- **Options:**
    - `--completed` — no value (store_true) — default False — when set, include completed reminders (drops the `r.ZCOMPLETED = 0` filter).
    - `-v`/`--verbose` — no value (store_true) — default False — adds extra detail lines per reminder (List/Notes/URL/Repeats/Early/Flagged/Urgent).
    - `--json` — no value (store_true) — default False — emit JSON array.
    - `--format` — value (per-command, `dest=command_format`, choices `plain|table|json`) — default None — `table` renders the box table; `json` forces JSON (via global propagation); also the global `--format plain|table|json` (default `plain`) feeds the same `a.format`.
- **Reads:** `ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK`. WHERE `r.ZMARKEDFORDELETION = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND (r.ZTITLE LIKE ? ESCAPE '\' OR r.ZNOTES LIKE ? ESCAPE '\')` plus `r.ZCOMPLETED = 0` unless `--completed`. `ORDER BY r.Z_PK DESC LIMIT 100`. Columns via `rem_cols(db)` (Z_PK, ZTITLE, ZNOTES, ZCOMPLETED, ZFLAGGED, ZPRIORITY, urgent col AS ZISURGENTSTATEENABLEDFORCURRENTUSER, delta-alerts col AS ZDUEDATEDELTAALERTSDATA, ZDUEDATE, display-date col AS ZDISPLAYDATEDATE, ZALLDAY, ZCOMPLETIONDATE, ZCREATIONDATE, ZPARENTREMINDER, ZLIST, ZICSURL, ZCKIDENTIFIER, `l.ZNAME as list_name`, recurrence cols). `preload_extras` additionally reads subtask counts and hashtag labels for the result PKs.
- **Writes:** none.
- **Human output:**
    - Empty: `No reminders matching '<query>'` (query passed through `safe_display`).
    - Else header line `Search: <bold(query)>`, then one `fmt(...)` line per item (no indent, verbose honored), then blank line and `\n<N> result` / `results` (plural unless N==1).
    - `fmt` line format: `<status> <id_str><pri_str><marker_str> <title><due_str><recur_str><tag_str><sub_str>`. `status` = green `[x]` if completed else dim `[ ]`. `id_str` = `#<Z_PK>` colored by the list's RGB color (or cyan if list has no color, dim if no list). `pri_str` = ` ` + colored marker: `!!!` (red, pri 1), `!!` (yellow, pri 5), `!` (green, pri 9), none for 0. `marker_str` = space-joined `red ⏰` (urgent) and `yellow ⚑` (flagged). `title` via safe_display or `(untitled)`. `due_str` from `fmt_due`: ` (today HH:MM)` or ` (today)`, ` (tomorrow)`, red ` (overdue Nd)`, else ` (YYYY-MM-DD)`. `recur_str` = ` ` + magenta `↻ <summary>`. `tag_str` = ` ` + space-joined `#<tag>`. `sub_str` = ` [N subtask(s)]`. If completed, title is dim+strikethrough and due/recur/tag/sub are dimmed. Verbose appends indented lines: `    List: <colored list>`, `    Notes: <dim notes[:200]>`, `    URL: <dim url>`, `    Repeats: <magenta recurrence summary>`, `    Early: <cyan labels>`, `    Flagged: <yellow Yes>`, `    Urgent: <red Yes>`.
- **JSON output (`--json`):** array of objects from `serialize_reminder`. Always-present keys: `id` (int Z_PK), `title`, `list` (list_name, may be null), `completed` (bool), `flagged` (bool), `urgent` (bool), `priority` (`none|high|medium|low`), `subtaskCount` (int), `isSubtask` (bool). Conditional keys (omitted when falsy): `notes`, `url` (ZICSURL or resolved rich link), `dueDate` (ISO 8601 local, `ts(...).isoformat()`), `displayDate` (only if present and != ZDUEDATE), `allDay` (bool, only if column not null), `createdDate`, `completionDate`, `parentID`, `tags` (array), `recurrence` (object), `earlyReminder` (first) + `earlyReminders` (array), `deepLink` (`x-apple-reminderkit://REMCDReminder/<ZCKIDENTIFIER>`). `json.dumps(..., indent=2)`. JSON has no header/count and ignores `--verbose`.
- **Exit/errors:** DB unavailable → handler raises `RemindersDBUnavailable`, caught by wrapper → stderr `Error: <message>` and exit 1. Messages: `No Reminders database found. Is iCloud Reminders enabled?` or the Full-Disk-Access blocked text. No error for empty results (exit 0). `--format json` is converted to `a.json=True` at top level.
- **Parity notes:** LIKE escaping is critical — backslash, `%`, and `_` in the query are escaped (`\\`, `\%`, `\_`) with `ESCAPE '\'`, so `search "%"` must NOT dump everything. Hard `LIMIT 100`. `ORDER BY Z_PK DESC` (insertion/PK order, not due date). Both `ZTITLE` and `ZNOTES` searched. `safe_display` replaces control chars (`\x00-\x1f`, `\x7f-\x9f`, U+2028/U+2029) with spaces. `fmt_due` uses local `datetime.now()` and `datetime.fromtimestamp(v + 978307200)` (Apple epoch, local TZ). Table branch (`a.format=='table'`) returns before the empty-check, so an empty table prints empty string.

### `today`

- **Summary:** Reminders due today, including overdue (unless suppressed), split into Overdue and Due Today groups.
- **Positional args:** none.
- **Options:**
    - `--no-overdue` — store_true — default False — when set, only items strictly within today's window (`>= start_of_day AND < start_of_day+1day`); when unset, all items with `ZDUEDATE < end_of_today` (i.e. includes overdue).
    - `-v`/`--verbose` — store_true — default False — (passed only via the empty namespace path; the `fmt` calls here do NOT pass verbose, so verbose has no visible effect in human output).
    - `--json` — store_true — default False.
    - `--format` — per-command + global, as in `search`.
- **Reads:** `q_due_today`. `ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK` WHERE `r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND <window>`. Window: include-overdue → `r.ZDUEDATE < <ts(end_of_today)> AND r.ZDUEDATE IS NOT NULL`; no-overdue → `r.ZDUEDATE >= <ts(sod)> AND r.ZDUEDATE < <ts(eod)>`. `ORDER BY r.ZDUEDATE`. (Timestamps are SQL literals computed via `to_ts(dt) = dt.timestamp() - APPLE_EPOCH`.) Same `rem_cols`/`preload_extras` as search.
- **Writes:** none.
- **Human output:**
    - Empty: `Nothing due today (<YYYY-MM-DD>)` using `datetime.now()`.
    - Else compute `sod = now @ 00:00:00`. `overdue` = items whose `ts(ZDUEDATE) < sod`; `due` = the rest. If overdue: red header `Overdue (<count>):` then each item via `fmt(... indent="  ")`, then a blank line. If due: bold header `Due Today (<count>):` then each item via `fmt(... indent="  ")`. Trailing blank line + `<N> total`.
    - Note: items in this command are rendered with `indent="  "` and NO verbose, regardless of the `-v` flag.
- **JSON output (`--json`):** flat array (NOT grouped) of serialized reminders, same shape as `search`. The overdue/due split is human-only.
- **Exit/errors:** same DB-unavailable handling (exit 1 with `Error: ...`). Empty result exits 0.
- **Parity notes:** Two notions of "today" coexist: the SQL window uses `due_today_window()` (sod, sod+1day) while the overdue/due partition in the handler uses a freshly recomputed `datetime.now()` start-of-day (line 5675) — a Swift port must recompute "now" per call, and the partition uses strict `<` against midnight. The default INCLUDES overdue. Sorting is by raw `ZDUEDATE` ascending across both groups, but display re-partitions; within each group order is preserved from the SQL order. Empty-state date string uses `now`, not the window.

### `flagged`

- **Summary:** All incomplete flagged reminders, due date ascending with nulls last.
- **Positional args:** none.
- **Options:**
    - `-v`/`--verbose` — store_true — default False — passed to `fmt` here (verbose detail lines appear).
    - `--json` — store_true — default False.
    - `--format` — per-command + global.
- **Reads:** `q_flagged`. Same join/base filters plus `r.ZFLAGGED = 1`. `ORDER BY r.ZDUEDATE NULLS LAST`. Same `rem_cols`/`preload_extras`.
- **Writes:** none.
- **Human output:**
    - Empty: `No flagged reminders`.
    - Else bold header `Flagged:`, then each item via `fmt(... verbose=a.verbose, indent="  ")`, then blank line + `<N> flagged`.
- **JSON output (`--json`):** array of serialized reminders (same shape as search). No header/count; verbose ignored.
- **Exit/errors:** DB-unavailable → `Error: ...` exit 1. Empty exits 0.
- **Parity notes:** `NULLS LAST` ordering must be preserved (reminders with no due date appear after dated ones). Honors verbose (unlike `today`). Each line is indented two spaces.

### `urgent`

- **Summary:** All incomplete reminders with the "urgent" flag enabled for the current user, due ascending nulls last.
- **Positional args:** none.
- **Options:** identical set to `flagged`: `-v`/`--verbose` (honored by `fmt`), `--json`, `--format`.
- **Reads:** `q_urgent`. Same join/base filters plus `urgent_where_clause(db)`: if column `ZISURGENTSTATEENABLEDFORCURRENTUSER` exists → `r.ZISURGENTSTATEENABLEDFORCURRENTUSER = 1`, else the clause is literally `0 = 1` (matches nothing). `ORDER BY r.ZDUEDATE NULLS LAST`.
- **Writes:** none.
- **Human output:**
    - Empty: `No urgent reminders`.
    - Else bold header `Urgent:`, each item via `fmt(... verbose=a.verbose, indent="  ")`, blank line + `<N> urgent`.
- **JSON output (`--json`):** array of serialized reminders. The `urgent` boolean comes from `ZISURGENTSTATEENABLEDFORCURRENTUSER` (aliased in `rem_cols`).
- **Exit/errors:** DB-unavailable → `Error: ...` exit 1. Empty exits 0.
- **Parity notes:** Must gracefully degrade when the schema lacks the urgent column — return zero rows (`0 = 1`), never error. The urgent column is itself schema-detected in `rem_cols` via `urgent_column_expr(db)` and aliased to `ZISURGENTSTATEENABLEDFORCURRENTUSER`; the `⏰` marker and JSON `urgent` derive from it.

### `upcoming`

- **Summary:** Reminders due within the next N days (default 7), grouped by day with Today/Tomorrow labels.
- **Positional args:** `days` — int — optional (`nargs="?"`, default 7) — number of days to look ahead.
- **Options:**
    - `-v`/`--verbose` — store_true — default False — (NOT passed to `fmt` in the grouped output; no visible effect).
    - `--json` — store_true — default False.
    - `--format` — per-command + global.
- **Reads:** `q_upcoming(db, days)`. Window via `upcoming_window(days)` = `(start_of_day, start_of_day + (days+1) days)`. WHERE base filters + `r.ZDUEDATE IS NOT NULL AND r.ZDUEDATE >= <ts(sod)> AND r.ZDUEDATE < <ts(future)>`. `ORDER BY r.ZDUEDATE`. (Note the window is `days+1` days from start-of-day, i.e. inclusive of the full Nth day.)
- **Writes:** none.
- **Human output:**
    - Validation first: if `days < 1` or `days > 3650` → stderr `Error: upcoming days must be between 1 and 3650.`, exit 1.
    - Empty: `Nothing due in the next <days> days`.
    - Else bold header `Upcoming (<days> days):`. Group items by `dt.strftime("%Y-%m-%d")` key; label = `dt.strftime("%A, %b %d")` (e.g. `Monday, May 28`), overridden to `Today` if `dt.date()==today` and `Tomorrow` if `dt.date()==today+1`. Iterate groups sorted by `(day_key, day_label)` ascending; per group print `\n  <bold(day_label)>:` then each item via `fmt(... indent="    ")` (no verbose). Trailing blank line + `<N> upcoming`.
- **JSON output (`--json`):** flat array of serialized reminders (NOT grouped by day). Grouping/labels are human-only.
- **Exit/errors:** `days` out of `[1, 3650]` → `Error: upcoming days must be between 1 and 3650.` exit 1. DB-unavailable → `Error: ...` exit 1. Empty exits 0.
- **Parity notes:** Window end is `days + 1` days (line 101 of remctl_runtime: `sod + timedelta(days=days + 1)`) — Swift must replicate this off-by-one (a 1-day query covers today + tomorrow start). Grouping sort is by `(YYYY-MM-DD string, label)` tuple — but Today/Tomorrow labels would sort lexicographically among real day labels; since the day_key (date string) is the primary sort key and is chronological, ordering stays chronological. `today` recomputed per item inside the loop via `datetime.now()`. Items already excluded if overdue (`>= sod`). Default 7 applies both from argparse default and the handler's `if days is None: days = 7` guard.

### `overdue`

- **Summary:** All incomplete reminders with a due date strictly before today (start of day).
- **Positional args:** none.
- **Options:**
    - `-v`/`--verbose` — store_true — default False — passed to `fmt` via `getattr(a, 'verbose', False)` (honored).
    - `--json` — store_true — default False.
    - `--format` — per-command + global.
- **Reads:** `q_overdue`. `sod = start_of_day()`. WHERE base filters + `r.ZDUEDATE IS NOT NULL AND r.ZDUEDATE < <ts(sod)>`. `ORDER BY r.ZDUEDATE`.
- **Writes:** none.
- **Human output:**
    - Empty: `No overdue reminders`.
    - Else header `Overdue (<count>):` styled red AND bold (`C.red(C.bold(...))`), then each item via `fmt(... verbose, indent="  ")`, blank line + `<N> overdue`.
- **JSON output (`--json`):** array of serialized reminders (same shape as search).
- **Exit/errors:** DB-unavailable → `Error: ...` exit 1. Empty exits 0.
- **Parity notes:** "Overdue" boundary is strict `<` start-of-today (anything earlier today but past its time is NOT overdue here — only items dated before midnight today). Items without a due date are excluded (`IS NOT NULL`). Header is red+bold (compose both ANSI codes). Honors verbose. Sorted ascending by due date.

---

**Cross-command parity notes (apply to all six):**

- **Format resolution:** Global `--format {plain,table,json}` (default `plain`, parsed at top level) sets `a.format`. The per-command `--format` (these listing commands attach it via `display_format`, `dest="command_format"`, default None, choices `plain|table|json`) overrides: at dispatch `if command_format: a.format = command_format`. Then `if a.format == "json": a.json = True`. Handlers branch: `--json`/`a.json` → JSON array first; else `a.format == 'table'` → `fmt_table(reminders_to_table_data(items, db))` (returns BEFORE the empty-result message, so empty input prints an empty string); else human output.
- **Table output (`--format table`):** columns `ID, Title, List, Due` always, `Repeat` only if any row has a recurrence, then `Pri`. Unicode box-drawing (`┌┬┐ ├┼┤ └┴┘ │ ─`), header row bolded, title column truncated with `…` to fit terminal width (`os.get_terminal_size().columns`, fallback 80; min title width 10). Per-row `due`: `Today`/`Today HH:MM`/`Tomorrow`/red `Overdue Nd`/`YYYY-MM-DD`. ID colored by list color; list name colored; pri colored; recurrence magenta. Truncation strips ANSI then cuts.
- **Color:** `C.enabled` is False if `--no-color`, `NO_COLOR` env set, or stdout is not a TTY. All `C.*` helpers then return plain text. RGB list colors come from `get_list_colors(db)`; unknown list → cyan; no list → dim.
- **Dates/timezone:** `ts(v) = datetime.fromtimestamp(v + 978307200)` (Apple/Core Data epoch 2001-01-01, converted to LOCAL time, naive). JSON dates use `.isoformat()` (local, no `Z`). All "now"/"today" comparisons use naive local `datetime.now()`.
- **safe_display:** strips control chars via regex `[\x00-\x1f\x7f-\x9f\u2028\u2029]` → space, applied to all printed titles/notes/urls/tags/queries (but NOT to JSON values, which are raw).
- **JSON encoding:** `json.dumps(list, indent=2)` (2-space indent, default ASCII escaping/`ensure_ascii=True`). Conditional keys are omitted when falsy/absent (do not emit nulls). Key order as listed in `serialize_reminder`.
- **Base SQL filters shared by all queries:** `r.ZMARKEDFORDELETION = 0`, `r.ZACCOUNT IS NOT NULL`, `l.Z_PK IS NOT NULL` (LEFT JOIN but requires a real list), and `r.ZCOMPLETED = 0` (except `search --completed`).

Source: `/Users/orion/Developer/Playgrounds/remctl/remctl` (handlers 5642-6084, queries 1574-1641, `fmt` 1820, `fmt_due` 1644, `fmt_table`/`reminders_to_table_data` 1910-2019, argparse 7789-7828, format dispatch 8128-8214) and `/Users/orion/Developer/Playgrounds/remctl/remctl_serialization.py` (`serialize_reminder` 167-244) and `/Users/orion/Developer/Playgrounds/remctl/remctl_runtime.py` (`start_of_day`/`due_today_window`/`upcoming_window` 89-101).

## Inspect reminders & lists

<!-- recon: cmds:inspect (agent-a0bffbd66c50f2cdc) -->

I have all the information I need. Here is the behavioral contract for my assigned commands.

### `show`

- **Summary:** Show top-level reminders in a single list, grouped by section, with optional completed items.
- **Positional args:** `list` — string — optional (nargs="?") — list name to show (mutually exclusive with `--list-id`; one is required at runtime).
- **Options:**
    - `--list-id` — takes value (int) — default None — show a list by stable numeric Z_PK instead of name.
    - `--completed` — flag (store_true) — default False — include completed reminders.
    - `-v`/`--verbose` — flag — default False — adds per-item detail lines (List, Notes truncated to 200 chars, URL, Repeats, Early, Flagged, Urgent).
    - `--json` — flag — default False — machine-readable JSON output.
    - `--format` — value, choices `plain|table|json`, dest `command_format`, default None (per-command). Note: a separate global `--format` (default `"plain"`) feeds `a.format`; in main(), `command_format` (if set) overwrites `a.format`, and `a.format == "json"` forces `a.json = True`. Handler branches on `a.json` first, then `getattr(a, 'format', None) == 'table'`.
- **Reads:**
    - `resolve_list_or_die` -> `resolve_list_ref`: exact match on `ZREMCDBASELIST.ZNAME`, else casefold, else normalized; `--list-id` queries `ZREMCDBASELIST WHERE Z_PK=? AND ZMARKEDFORDELETION=0 AND Z_ENT=3 AND ZNAME IS NOT NULL AND ZNAME != ''`.
    - `q_reminders(list_pk, completed, top_level=True)`: `SELECT <rem_cols> FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST=l.Z_PK WHERE r.ZMARKEDFORDELETION=0 AND r.ZACCOUNT IS NOT NULL [AND r.ZCOMPLETED=0] AND r.ZLIST=? AND (r.ZPARENTREMINDER IS NULL OR r.ZPARENTREMINDER=0) ORDER BY r.Z_PK LIMIT 500`. `rem_cols` pulls title, notes, completed, flagged, priority, urgent (`ZISURGENTSTATEENABLEDFORCURRENTUSER` or `0`), `ZDUEDATEDELTAALERTSDATA`, due (`r.ZDUEDATE`), display date, ZALLDAY, completion/creation dates, parent, list, ZICSURL, ZCKIDENTIFIER, `list_name`, plus 10 recurrence subselects against `ZREMCDOBJECT` where `ZREMINDER4=r.Z_PK AND Z_ENT=34`.
    - `preload_extras(pks)`: batch subtask counts (`ZPARENTREMINDER IN (...) AND ZMARKEDFORDELETION=0 AND ZCOMPLETED=0 GROUP BY`) and hashtags (`ZREMCDOBJECT o JOIN ZREMCDHASHTAGLABEL h ON o.ZHASHTAGLABEL=h.Z_PK WHERE o.ZREMINDER3 IN (...)`).
    - `q_sections(pk)`: `SELECT Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER FROM ZREMCDBASESECTION WHERE ZMARKEDFORDELETION=0 AND ZLIST=? ORDER BY Z_PK`.
    - `q_section_memberships(pk)`: reads `ZREMCDBASELIST.ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA` (JSON), maps `memberID -> section displayName` via section `ZCKIDENTIFIER`. Only called when sections exist.
- **Writes:** none (read-only; DB opened `mode=ro`).
- **Human output:**
    - Empty: `No active reminders in '<list>'` (the word `active ` is present only when NOT `--completed`; with `--completed`, `No reminders in '<list>'`). List name run through `safe_display`.
    - Header: `<bold colored list name>:` — list name colored via its Reminders RGB (`color_list_name`), bolded; if grocery list, header is `<name> 🥕` then bolded+`:`.
    - Unsectioned items printed first (no indent), then for each section in `q_sections` order (by Z_PK) that has items: a blank line, then `  [<section heading>]` (bold), then its items indented with `"  "`. Grocery lists transform section name via emoji prefix (`format_grocery_section_name`, HTML-unescaped).
    - Each item via `fmt`: `<indent>[ ] #<id> <pri> <markers> <title><due><recur><tags><sub>`. Status `[x]` green if completed else `[ ]` dim. `#<id>` colored by list RGB. Priority marker from `PRI = {1:"!!!",5:"!!",9:"!"}` colored red/yellow/green. Markers: `⏰` red (urgent) and/or `⚑` yellow (flagged), space-joined. Title `safe_display` or `(untitled)`. Due via `fmt_due`: ` (today HH:MM)`/` (today)`, ` (tomorrow)`, ` (overdue Nd)` red, or ` (YYYY-MM-DD)`. Recurrence badge `↻ <summary>` magenta. Tags ` #tag` each. Subtasks ` [N subtask(s)]` (only active subtasks counted). Completed items render title dim+strikethrough and due/recur/tags/sub dim.
    - Footer: blank line then `<N> reminder` / `<N> reminders`.
    - `--format table`: returns early printing `fmt_table` of `reminders_to_table_data` (Unicode box table; columns ID, Title, List, Due, [Repeat if any], Pri; due labels `Today [HH:MM]`/`Tomorrow`/`Overdue Nd` red/`YYYY-MM-DD`; title truncated to fit terminal width with `…`). No section grouping in table mode.
- **JSON output (--json):** array of reminder objects from `to_dict`/`serialize_reminder`. Keys per item (only present when truthy/applicable): `id`, `title`, `list`, `completed`, `flagged`, `urgent`, `priority` (string "none"/"low"/"medium"/"high"), `subtaskCount`, `isSubtask`, optional `section`, `notes`, `url`, `dueDate` (ISO), `displayDate` (ISO, only if differs from due), `allDay`, `createdDate`, `completionDate`, `parentID`, `tags`, `recurrence` (object), `earlyReminder` (first) + `earlyReminders` (list), `deepLink` (`x-apple-reminderkit://REMCDReminder/<ckid>`). For grocery lists each item additionally gets `sectionEmoji` when a category emoji is resolved (`add_grocery_section_metadata`). JSON is `indent=2, ensure_ascii=False`. JSON shows ALL items flat (sections only via `section` key); human view groups by section.
- **Exit/errors:**
    - No list and no `--list-id`: `Error: pass a list name or --list-id.` (stderr, exit 1).
    - Both name and `--list-id`: `Error: pass either a list name or --list-id, not both.` (exit 1).
    - List not found: `Error: list not found: <name>` or `Error: list not found: id <n>` (exit 1).
    - Ambiguous name: `Error: multiple lists match '<name>'. Use the exact list name or --list-id with one of: <id> (<title>), ...` (exit 1).
- **Parity notes:** Timestamps use Apple epoch offset (`ts(v)=datetime.fromtimestamp(v+APPLE_EPOCH)`, local time, naive). Item ordering strictly `ORDER BY r.Z_PK ASC`, LIMIT 500. Only top-level reminders (parent NULL or 0). Color disabled when `--no-color`, `NO_COLOR` env, or non-tty stdout; when disabled `color_list_name`/badges return plain text. `safe_display` strips terminal control chars (replaces with space) for human output but JSON uses raw values. Empty-message wording hinges exactly on `--completed`. Grocery marker `🥕` and emoji-prefixed section names only when `list_ref.isGroceries`.

### `tags`

- **Summary:** List all hashtag labels (Reminders tags) defined in the store.
- **Positional args:** none.
- **Options:** `--json` — flag — default False — JSON output. (No `-v`, no `--format`.)
- **Reads:** `SELECT ZNAME FROM ZREMCDHASHTAGLABEL WHERE ZNAME IS NOT NULL ORDER BY ZNAME`.
- **Writes:** none.
- **Human output:**
    - Empty: `No tags found`.
    - Else: `Tags:` (bold), then for each row `  #<name>` where `#<name>` is magenta and name run through `safe_display`. Footer: blank line then `<N> tag` / `<N> tags`.
- **JSON output (--json):** `[{"name": "<ZNAME>"}, ...]`, `indent=2` (NOT `ensure_ascii=False` — non-ASCII tag names are escaped in JSON here). Raw `ZNAME` values (no `#` prefix, no `safe_display`). Empty store yields `[]`.
- **Exit/errors:** none beyond DB-open failures (`open_db`/`RemindersDBUnavailable` handled upstream).
- **Parity notes:** Sort is by `ZNAME` ascending at SQL level (SQLite default binary collation). Magenta `#` prefix added only in human output. JSON omits the `#`. No deduplication beyond what the table provides.

### `subtasks`

- **Summary:** Show the subtasks (children) of a given reminder, including completed ones.
- **Positional args:** `id` — int — required — parent reminder Z_PK.
- **Options:**
    - `-v`/`--verbose` — flag — default False — verbose item rendering in `fmt` (note: verbose is parsed but only affects the non-JSON `fmt` calls; here `fmt(... )` is called WITHOUT passing `verbose`, so `-v` has no visible effect on the subtask lines).
    - `--json` — flag — default False — JSON output.
- **Reads:**
    - `q_reminder(id)`: `SELECT <rem_cols> ... WHERE r.Z_PK=? AND ZMARKEDFORDELETION=0 AND ZACCOUNT IS NOT NULL`.
    - `q_reminders(parent_pk=id, completed=True)`: children where `ZPARENTREMINDER=? AND ZMARKEDFORDELETION=0 AND ZACCOUNT IS NOT NULL` (completed included), `ORDER BY r.Z_PK LIMIT 500`.
    - `preload_extras` over subtask PKs.
- **Writes:** none.
- **Human output:**
    - `Parent: <safe_display(parent ZTITLE)>`.
    - If no subtasks: `  No subtasks`.
    - Else: each subtask via `fmt(s, db, indent="  ", ...)` (same item format as `show`, indented two spaces; no `verbose` passed). Footer: blank line then `<N> subtask` / `<N> subtasks`.
- **JSON output (--json):** `to_dict(parent)` object (same shape as `show` JSON item) with an added key `"subtasks": [<to_dict(child)>, ...]`. `indent=2` (NO `ensure_ascii=False`). Parent dict's own `subtaskCount` reflects only ACTIVE children (from `preload_extras`/`q_subtask_count` which filter `ZCOMPLETED=0`), whereas the `subtasks` array includes completed children.
- **Exit/errors:** Parent not found: `Error: #<id> not found` (stderr, exit 1).
- **Parity notes:** Subtask list includes completed children (`completed=True`) but the parent's `subtaskCount` counts only active. `fmt` here intentionally does not pass `verbose`. Children ordered by `Z_PK` ascending.

### `info`

- **Summary:** Full detail view of one reminder (status, dates, notes, tags, recurrence, subtasks, attachments, alarms, deep link).
- **Positional args:** `id` — int — required — reminder Z_PK.
- **Options:** `--json` — flag — default False. (No `-v`, no `--format`.)
- **Reads:**
    - `q_reminder(id)`.
    - `q_reminders(parent_pk=id, completed=True)` — subtasks incl. completed.
    - `q_attachments(id)`: UNION of `ZREMCDSAVEDATTACHMENT` (ZFILENAME, ZUTI, ZATTACHMENTTYPERAWVALUE where ZREMINDER=? and not deleted) and `ZREMCDOBJECT` (ZFILENAME, ZUTI, derived type `image` if ZWIDTH/ZHEIGHT else `file`, where ZREMINDER2=? and filename non-empty and not deleted), `ORDER BY ZFILENAME`.
    - `q_alarms(id)`: `ZREMCDOBJECT a` self-join on trigger; `WHERE a.ZREMINDER=? AND a.Z_ENT=15 AND a.ZMARKEDFORDELETION=0 AND (t.Z_PK IS NULL OR t.ZMARKEDFORDELETION=0) ORDER BY a.Z_PK`. Fields: time_interval, date_components, location_title/lat/long/radius/address/proximity.
    - `q_hashtags(id)`: `ZREMCDOBJECT o JOIN ZREMCDHASHTAGLABEL h ON o.ZHASHTAGLABEL=h.Z_PK WHERE o.ZREMINDER3=?`.
    - `q_rich_link(id)`: first `ZURL` from `ZREMCDOBJECT WHERE ZREMINDER2=? AND ZURL non-empty AND not deleted ORDER BY Z_PK`.
    - Section: if `r["ZLIST"]`, `q_section_memberships(ZLIST)` then `.get(r["ZCKIDENTIFIER"])`.
- **Writes:** none.
- **Human output (order, all lines 2-space indented except the header):**
    - Header: `Reminder #<id>` where `Reminder` is bold and `#<id>` colored by list RGB (`reminder_id_text`).
    - `  Title:     <safe_display title>`
    - `  List:      <color_list_name(r['list_name'])>`
    - `  Section:   <bold safe_display(section)>` (only if section)
    - `  Status:    <Completed (green) | Active (yellow)>`
    - `  Priority:  <name>` from `PRI_NAME` ({0:none,1:high,5:medium,9:low}); colored red (high), yellow (medium), green (low); "none" uncolored.
    - `  Flagged:   <Yes (yellow) | No>`
    - `  Urgent:    <Yes (red) | No>` (urgent from `ZISURGENTSTATEENABLEDFORCURRENTUSER`)
    - `  Due:       <%b %d, %Y at %I:%M %p>` (only if ZDUEDATE) — e.g. `May 28, 2026 at 03:00 PM`.
    - `  Early:     <cyan comma-joined labels>` (only if early reminders; labels like `15 minutes before`)
    - `  Repeats:   <magenta recurrence_summary>` (only if recurrence)
    - `  Created:   <%b %d, %Y at %I:%M %p>` (if ZCREATIONDATE)
    - `  Completed: <...>` (if ZCOMPLETIONDATE)
    - `  Notes:     <safe_display notes>` (if notes)
    - `  URL:       <safe_display(ZICSURL or rich_url)>` (if either)
    - `  Tags:      <magenta #tag, #tag>` (if tags)
    - `  Parent:    #<pp> (<safe_display title>)` (if ZPARENTREMINDER; title parenthetical only if parent row found)
    - `  Subtasks (N):` then each via `fmt(s, indent="    ")` (4-space indent), using `preload_extras` over subtask PKs.
    - `  Attachments (N):` then `    - <safe_display(ZFILENAME or 'untitled')> (<type or '?'>)` per attachment.
    - `  Alarms (N):` then `    - <label>` per alarm. Label = `alarm.label` or `alarm.date` or `alarm.type`; for location alarms `<title> (<proximity>)` (e.g. `Apple Park (arriving)`).
    - `  Deep link: <dim x-apple-reminderkit://REMCDReminder/<ckid>>` (if ZCKIDENTIFIER).
- **JSON output (--json):** `hydrate_reminder_detail(to_dict(r, section=sec), id)` — i.e. the `serialize_reminder` object (same keys as `show` JSON) PLUS, when present: `attachments` (`[{"filename","type"}]`) and `alarms` (list from `alarm_rows_to_json`: each `{id, type}` where type ∈ relative/location/absolute/unknown; relative adds `relativeOffset`,`relativeOffsetMinutes`,`label`; absolute adds `dateComponents`,`date` ISO,`timeZone`; location adds nested `location{title,latitude,longitude,radius,proximity,proximityCode[,address]}`). If subtasks exist, adds `"subtasks"` = list of full hydrated detail dicts (each subtask also hydrated with its own attachments/alarms). `indent=2` (NO `ensure_ascii=False`). JSON includes `section` key inline (human shows it as a line); JSON exposes alarm/attachment/recurrence structured data not all shown in human text.
- **Exit/errors:** Not found: `Error: #<id> not found` (stderr, exit 1).
- **Parity notes:** Date format strings are exact: due/created/completed use `%b %d, %Y at %I:%M %p` (zero-padded 12-hour with AM/PM, e.g. `03:05 PM`). All dates are local-time naive via `ts`. Section resolved through the list's membership JSON keyed by reminder `ZCKIDENTIFIER`. URL prefers `ZICSURL` over rich link. Subtask block reuses `fmt` with 4-space indent. Alarm label fallback chain (`label` -> `date` -> `type`) must be preserved; location proximity code 2 => "leaving" else "arriving".

### `sections`

- **Summary:** List all sections across all lists, grouped by list.
- **Positional args:** none.
- **Options:** `--json` — flag — default False. (No `-v`, no `--format`.)
- **Reads:** `q_sections()` (no list_pk): `SELECT s.Z_PK, s.ZDISPLAYNAME, s.ZLIST, s.ZCKIDENTIFIER, l.ZNAME as list_name FROM ZREMCDBASESECTION s LEFT JOIN ZREMCDBASELIST l ON s.ZLIST=l.Z_PK WHERE s.ZMARKEDFORDELETION=0 ORDER BY l.ZNAME, s.Z_PK`.
- **Writes:** none.
- **Human output:**
    - Empty: `No sections found`.
    - Else iterate rows (already ordered by list name, then Z_PK). On each change of `list_name` (null -> `"?"`): if not the first group, print a blank line; then print `<bold color_list_name(ln)>:`. For each section: `  - <safe_display(ZDISPLAYNAME)>`. Footer: blank line then `<N> section` / `<N> sections`.
- **JSON output (--json):** object mapping list name -> array of section display names: `{"<list_name or '?'>": ["<ZDISPLAYNAME>", ...], ...}`. Built with `setdefault`, so list-name keys appear in first-encounter order (which follows the SQL `ORDER BY l.ZNAME`). `indent=2` (NO `ensure_ascii=False`). No grocery emoji transformation in either output here (unlike `show`).
- **Exit/errors:** none beyond DB-open failures.
- **Parity notes:** Null list name maps to literal `"?"` in both human and JSON. Ordering: by list name (SQLite collation), then section Z_PK. Section names are raw `ZDISPLAYNAME` (no grocery emoji applied here). Grouping boundary triggers only when the list name changes between consecutive rows.

### `stats`

- **Summary:** Aggregate counts across the whole store (totals, active/completed, overdue, flagged, urgent, list/section counts).
- **Positional args:** none.
- **Options:** `--json` — flag — default False. (No `-v`, no `--format`.)
- **Reads:** (all against `ZREMCDREMINDER`, base filter `ZMARKEDFORDELETION=0 AND ZACCOUNT IS NOT NULL`)
    - `total`: `SELECT COUNT(*) FROM ZREMCDREMINDER WHERE ZMARKEDFORDELETION=0 AND ZACCOUNT IS NOT NULL`.
    - `active`: + `ZCOMPLETED=0`.
    - `flagged`: + `ZCOMPLETED=0 AND ZFLAGGED=1`.
    - `urgent`: + `ZCOMPLETED=0 AND <urgent_where_clause>` where clause is `r.ZISURGENTSTATEENABLEDFORCURRENTUSER = 1` if the column exists, else `0 = 1` (always 0).
    - `overdue`: + `ZCOMPLETED=0 AND r.ZDUEDATE IS NOT NULL AND r.ZDUEDATE < <to_ts(datetime.now())>` (the threshold is computed in Python via `to_ts` = `now.timestamp() - APPLE_EPOCH` and inlined into the SQL string).
    - `lists`: `len(q_lists(db))`; `sections`: `len(q_sections(db))`.
    - `completed` is derived as `total - active` (not queried).
- **Writes:** none.
- **Human output (header bold, lines 2-space indented):**
    - `Reminders Stats` (bold)
    - `  Total:      <total>`
    - `  Active:     <green active>`
    - `  Completed:  <dim (total-active)>`
    - `  Overdue:    <red overdue if overdue>0 else '0'>`
    - `  Flagged:    <yellow flagged if flagged>0 else '0'>`
    - `  Urgent:     <red urgent if urgent>0 else '0'>`
    - `  Lists:      <lists_count>`
    - `  Sections:   <sections_count>`
- **JSON output (--json):** `{"total":, "active":, "completed": total-active, "overdue":, "flagged":, "urgent":, "lists":, "sections":}`, `indent=2` (NO `ensure_ascii=False`). All integer values. Key order as listed.
- **Exit/errors:** none beyond DB-open failures.
- **Parity notes:** Overdue threshold uses `datetime.now()` converted to Apple-epoch-relative timestamp and compared against raw `ZDUEDATE` column (Apple epoch units) — the Swift port must use the same Apple-epoch offset and local "now". Urgent count silently becomes 0 when `ZISURGENTSTATEENABLEDFORCURRENTUSER` column is absent (older schemas). `completed` is `total - active` (never directly counted). Color thresholds: overdue/flagged/urgent are colored only when their value is nonzero; when zero they print the literal string `'0'` (uncolored). `total`, `active` (always green), `completed` (always dim), `lists`, `sections` are always colored/plain as shown regardless of value.

Source: handlers in `/Users/orion/Developer/Playgrounds/remctl/remctl` (lines 5075, 5728, 5744, 5766, 5850, 5872); argparse at lines 7677-7681, 7800, 7802-7803, 7805, 7807, 7809 plus globals at 7635-7651; serialization helpers in `/Users/orion/Developer/Playgrounds/remctl/remctl_serialization.py`.

## Reminder mutation

<!-- recon: cmds:mutate (agent-a4b3ee9884e51c691) -->

I now have a complete picture. Here is the behavioral contract for the assigned commands.

### `add`

- **Summary:** Create a reminder via EventKit bridge (preferred) or AppleScript fallback; with `--private`, write extra synced metadata afterward through the unsupported private ReminderKit helper.
- **Positional args:** `title` — string — required — the reminder name (and inline `#hashtags` appended when `-t` given without `--private`).
- **Options:**
    - `-l/--list` — value — none — target list name (resolved via fuzzy lookup).
    - `--list-id` — int — none — target list by stable numeric Z_PK.
    - `-n/--notes` — value — none — body text.
    - `-d/--due` — value — none — due date string (see Parity for grammar).
    - `-p/--priority` — value — none — `high/h`, `medium/med/m`, `low/l`, `none` (case-insensitive); maps to 1/5/9/0.
    - `-f/--flag` — flag — false — set flagged (via bridge `flagged:true` / AppleScript; routed to private `set_flagged` when `--private` active). **[was --private]** when `--private` is active, flag is excluded from bridge data and applied via private `set_flagged`.
    - `-t/--tags` — value — none — comma-separated. Without `--private`: appends inline `#tag` to title (each tag prefixed with `#` if not already, only if not already in title). **[was --private]** with `--private`: creates synced Reminders tags (not appended to title).
    - `--url` — value — none — without `--private`: appended to bridge `url`/notes. **[was --private]** with `--private`: synced web rich link via `add_private_metadata`; excluded from bridge `url`.
    - `--recurrence` — value — none — bridge only; `daily/weekly/monthly/yearly` optionally `weekly mon,wed,fri` / `monthly 1,15`.
    - `--alarm` — value — none — bridge only; `15m/1h/1d` (→ `-15m/-1h/-1d`) or ISO datetime.
    - `--private` — flag — false — opt into private ReminderKit writes.
    - `--private-metadata` — flag (SUPPRESS) — false — hidden alias enabling private mode.
    - `--grocery` — flag — false — **[was --private]** categorize in a Groceries list; requires a target list pk.
    - `--section` — value — none — **[was --private]** assign to existing section.
    - `--section-id` — value — none — **[was --private]** assign to section by stable ID.
    - `--new-section` — value — none — **[was --private]** create+assign a section.
    - `--subtask` — value (append, repeatable) — none — **[was --private]** subtask title or JSON object.
    - `--image` — value (append, repeatable) — none — **[was --private]** image attachment path.
    - `--urgent` — BooleanOptionalAction (`--urgent`/`--no-urgent`) — None — **[was --private]** set urgent state.
    - `--early-reminder` — value — none — **[was --private]** early reminder delta `15m/1h/2d/1w/1mo` or `clear`.
    - `--json` — flag — false — machine-readable output.
- **Reads:** When `-l`/`--list-id`/`--private`/`--grocery` involved: opens SQLite. `resolve_list_ref` queries `ZREMCDBASELIST` (by `Z_PK` with `ZMARKEDFORDELETION=0 AND Z_ENT=3 AND ZNAME IS NOT NULL AND ZNAME != ''`, or by name via `q_lists`). `q_reminder_by_identifier` re-reads created row: `SELECT {rem_cols} FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST=l.Z_PK WHERE lower(r.ZCKIDENTIFIER)=lower(?) AND r.ZMARKEDFORDELETION=0 AND r.ZACCOUNT IS NOT NULL ORDER BY r.Z_PK DESC LIMIT 1`. `--grocery` reads list row via `q_list_by_pk` + `is_grocery_list_row`.
- **Writes:** EventKit (bridge `{"action":"create",...}`) — sets title/list/notes/due(ISO)/priority/flagged/url/recurrence/alarm; OR AppleScript fallback (`make new reminder` with name, body, priority, flagged, due via `as_date_assign`). With `--private`: additional private(ReminderKit) calls (`add_private_metadata`, `assign_section`, `add_section_and_assign`, `add_subtasks`, `add_attachments`, `set_flagged`, `set_urgent`, `set_early_reminder`, location alarm, grocery categorization).
- **Human output:** `Created: {title}` (control-sanitized). If list resolved non-exact: `List: {title} (resolved from {requested})`. If created row found: `ID: #{Z_PK}`. If private updates: `Private metadata: applied {n} update{s}` (pluralized when n != 1). AppleScript fallback prints only `Created: {title}`.
- **JSON output (--json):** `{"status":"created","id":<bridge id>,"title":<title>}`; adds `"resolvedList":{"requested","title","id","method"}` when list method != "exact"; adds `"numericId":<Z_PK>` when row found; adds `"private":[...action results...]` when private applied. AppleScript fallback: `{"status":"created","id":<applescript rid>,"title":<title>}` (no numericId/private).
- **Exit/errors:**
    - Unparseable `-d` → `fail_invalid_due_date` exit code **2**. Human: `Error: could not parse due date '<v>'.` / `No reminder was created or changed.` / blank / `Use exact forms like:` then 6 examples. JSON: `{"status":"error","code":"invalid_due_date","field":"due","input":<v>,"message":"Could not parse due date. No reminder was created or changed.","examples":[...]}` to stderr.
    - Bad alarm → exit **1**: `Error: could not parse alarm '<v>'. Use 15m, 1h, 1d, or an absolute date.`
    - Bad priority → exit **1**: `Error: priority must be high, medium, low, or none.`
    - `--early-reminder` set (non-clear) but no due → `fail_early_reminder_without_due` exit **1**: `Error: Early Reminder requires a reminder due date.` (JSON: `{"status":"error","code":"early_reminder_requires_due_date","message":"Early Reminder requires a reminder due date."}`).
    - `wants_private` but no bridge → exit **1**: `Error: private metadata creation requires remctl-bridge so the reminder has a stable ID.`
    - Rich subtasks needing bridge but no bridge → exit **1**: `Error: rich private subtasks require remctl-bridge for notes, due dates, priority, recurrence, or alarms.`
    - `--grocery` without target list → exit **1**: `Error: --grocery requires a target Groceries list via -l/--list or --list-id.`
    - Non-grocery target with `--grocery` → exit **1**: `Error: target list '<name>' is not a Groceries list. Use \`remctl list-edit ... --private --groceries\` first.`
    - Private-only args without `--private` → `refuse_private_args_without_opt_in` exit **1**: `Error: grocery, section, subtask, image, urgent, early-reminder, flagged, and location writes require --private. Example: remctl add "Milk" -l Groceries --private --grocery`
    - `require_private_metadata`: exit **1** `Error: private metadata writes require --private.` or `Error: remctl-private is unavailable. Reinstall or set REMCTL_PRIVATE_PATH.`
    - `validate_private_args` failures (exit 1): `Error: --private --url requires an http or https URL.` / `Error: --private --url must resolve to a public http or https host.` / `Error: --early-reminder must be like 15m, 1h, 2d, 1w, 1mo, or clear.` / `Error: image attachment is not readable: <path>` / location validations.
    - `private_action` failure exits **1** with `Error: <helper message>`.
    - List resolution failure: exit **1** `Error: list not found: <requested>` or `Error: multiple lists match '<name>'. Use the exact list name or --list-id with one of: <id (title), ...>`.
    - AppleScript path errors exit **1** via `osa`: `AppleScript error: <stderr>` or `Error: AppleScript timed out (Reminders.app may be unresponsive)`.
- **Parity notes:**
    - Bridge-first: only if `bridge_available()`. If bridge returns `status=="created"` it returns immediately (private writes run after). Otherwise AppleScript fallback runs.
    - Fallback warns to stderr if `url`/`recurrence`/`alarm` were requested but bridge unavailable: `Warning: bridge unavailable; <fields> cannot be set via AppleScript and will be dropped.` (comma-joined, ordered url, recurrence, alarm).
    - `add` priority map includes extra keys (`h/med/m/l`) that `edit` does not.
    - Due parsing (`parse_due`) uses **local time** `datetime.now()`; due sent to bridge as `.isoformat()` (naive local). All date math is naive local datetime. Grammar: `today`, `tomorrow`, `eod` (17:00), `eow` (next Friday 00:00, days_ahead 4-weekday, +7 if <=0), `today/tomorrow [at] <time>`, `tonight [at] <time>` (bare 1–11 → +12, rolls to next day if past), `+Nd/+Nw/+Nh/+Nm` (m = N\*30 days, h relative to now), `[next|this] <weekday> [at <time>]` (next forces +7 when same day; without next, past time rolls +7), `in N day(s)/week(s)/hour(s)/month(s)`, ISO `%Y-%m-%d`, `%Y-%m-%d %H:%M`, `%Y-%m-%dT%H:%M`, `%Y-%m-%dT%H:%M:%S`, then optional `parsedatetime` fallback. `parse_clock_time` rejects minute>59, validates am/pm.
    - Tag append loop only runs when `not wants_private`.
    - List resolution swallows `RemindersDBUnavailable` only when `list_id is None and not wants_private` (keeps name as-is for AppleScript); re-raises otherwise.
    - Pluralization uses `update` vs `updates` based on `len != 1`.
    - `safe_display` strips terminal control chars from human output only; JSON keeps raw.

### `done`

- **Summary:** Mark a reminder completed (bridge-first, AppleScript fallback).
- **Positional args:** `id` — int — required — numeric Z_PK.
- **Options:** `--json` — flag — false.
- **Reads:** `q_reminder(db, id)`: `SELECT {rem_cols} FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST=l.Z_PK WHERE r.Z_PK=? AND r.ZMARKEDFORDELETION=0 AND r.ZACCOUNT IS NOT NULL`.
- **Writes:** EventKit bridge `{"action":"complete","id":<ZCKIDENTIFIER>}` (accepts `status=="completed"`); else AppleScript `set completed of r to true` matched by `x-apple-reminder://<ZCKIDENTIFIER>` within `list_name`.
- **Human output:** `Completed: {ZTITLE}` (safe_display).
- **JSON output (--json):** `{"status":"completed","id":<id>,"title":<ZTITLE>}` (title raw, not safe_display).
- **Exit/errors:**
    - Not found → exit **1**: `Error: #<id> not found`.
    - No stable identifier (`rid` None) → exit **1**: `Error: The reminder has no stable identifier. Refusing unsafe title-based fallback for #<id> ('<title>') while trying to complete it.`
    - Both bridge and AppleScript failed → exit **1**: `Error: Identifier-based writes failed. Refusing unsafe title-based fallback for #<id> ('<title>') while trying to complete it.`
- **Parity notes:** Bridge only attempted when `bridge_available() and ZCKIDENTIFIER`. `_rem_id` = `x-apple-reminder://{ZCKIDENTIFIER}` or None. Never falls back to title-based matching — refuses instead. `_refuse_unsafe_title_fallback` uses `Z_PK` (or `?`) and title `(untitled)` when null.

### `undone`

- **Summary:** Mark a reminder not completed (bridge-first, AppleScript fallback). Identical structure to `done`.
- **Positional args:** `id` — int — required — numeric Z_PK.
- **Options:** `--json` — flag — false.
- **Reads:** `q_reminder(db, id)` (same SQL as `done`).
- **Writes:** EventKit bridge `{"action":"uncomplete","id":<ZCKIDENTIFIER>}` (accepts `status=="uncompleted"`); else AppleScript `set completed of r to false`.
- **Human output:** `Uncompleted: {ZTITLE}` (safe_display).
- **JSON output (--json):** `{"status":"uncompleted","id":<id>,"title":<ZTITLE>}`.
- **Exit/errors:** Not found → exit **1** `Error: #<id> not found`. No identifier → exit **1** `Error: The reminder has no stable identifier. Refusing unsafe title-based fallback for #<id> ('<title>') while trying to uncomplete it.` Writes failed → `Error: Identifier-based writes failed. Refusing unsafe title-based fallback for #<id> ('<title>') while trying to uncomplete it.`
- **Parity notes:** Same as `done` but operation phrase is `uncomplete it`.

### `delete`

- **Summary:** Delete a reminder with optional confirmation prompt (bridge-first, AppleScript fallback).
- **Positional args:** `id` — int — required — numeric Z_PK.
- **Options:** `--force` — flag — false — skip the interactive confirmation. `--json` — flag — false.
- **Reads:** `q_reminder(db, id)` (same SQL as `done`).
- **Writes:** EventKit bridge `{"action":"delete","id":<ZCKIDENTIFIER>}` (accepts `status=="deleted"`); else AppleScript `delete r`.
- **Human output:** If not `--force`: prompt `Delete '{ZTITLE}' from {list_name}? [y/N] ` (both safe_display). On cancel (answer not starting with `y`/`Y`, case-insensitive): prints `Cancelled.` and returns (exit 0, no JSON even with `--json`). On success: `Deleted: {ZTITLE}`.
- **JSON output (--json):** `{"status":"deleted","id":<id>,"title":<ZTITLE>}`. Note: the cancel path prints plain `Cancelled.` regardless of `--json`.
- **Exit/errors:** Not found → exit **1** `Error: #<id> not found`. No identifier → exit **1** `Error: The reminder has no stable identifier. Refusing unsafe title-based fallback for #<id> ('<title>') while trying to delete it.` Writes failed → `Error: Identifier-based writes failed. Refusing unsafe title-based fallback for #<id> ('<title>') while trying to delete it.`
- **Parity notes:** Confirmation reads via `input()`; `ans.lower().startswith("y")` is the only accept condition. Bridge attempted only when `bridge_available() and ZCKIDENTIFIER`. The confirmation prompt is the only command among these with interactive input.

### `edit`

- **Summary:** Edit fields of an existing reminder (bridge-first with double-tap defense and absolute-alarm carry/clear logic; AppleScript fallback for simple fields). With `--private`, applies guarded ReminderKit metadata.
- **Positional args:** `id` — int — required — numeric Z_PK.
- **Options:**
    - `--title` — value — none — new name.
    - `-l/--list` — value — none — move to list by name (bridge only).
    - `--list-id` — int — none — move to list by stable numeric ID (bridge only).
    - `-n/--notes` — value — none — replace body.
    - `-d/--due` — value — none — new due date or the literal string `clear` to remove it.
    - `-p/--priority` — value — none — `high/medium/low/none` (case-insensitive; note: `edit`'s map has NO short aliases unlike `add`).
    - `--url` — value — none — without `--private`: merged into notes (`notes + "\n\n" + url`, or url alone). **[was --private]** with `--private`: synced web rich link, excluded from notes merge.
    - `--recurrence` — value — none — bridge only.
    - `--alarm` — value — none — bridge only; `15m/1h/1d`/ISO, or a clear-keyword (`clear/none/off/remove/delete`) to clear all alarms.
    - `--private` — flag — false — opt into guarded metadata writes.
    - `--private-metadata` — flag (SUPPRESS) — false — hidden alias.
    - `-t/--tags` — value — none — **[was --private]** add comma-separated synced hashtag labels (requires `--private`, errors otherwise).
    - `--grocery` — flag — false — **[was --private]** categorize in its Groceries list.
    - `--section` / `--section-id` / `--new-section` — value — none — **[was --private]** section assignment/creation.
    - `--subtask` — value (append) — none — **[was --private]** subtask title or JSON.
    - `--image` — value (append) — none — **[was --private]** image attachment path.
    - `--flagged` — BooleanOptionalAction (`--flagged`/`--no-flagged`) — None — **[was --private]** set real flagged state via `set_flagged`.
    - `--urgent` — BooleanOptionalAction — None — **[was --private]** set urgent state.
    - `--early-reminder` — value — none — **[was --private]** early reminder delta or `clear`.
    - `--location-title` — value — none — **[was --private]** location alarm title (saved through EventKit bridge).
    - `--latitude` — float — none — **[was --private]** location alarm latitude.
    - `--longitude` — float — none — **[was --private]** location alarm longitude.
    - `--radius` — float — **100.0** — **[was --private]** location alarm radius (meters).
    - `--proximity` — choice `arriving`/`leaving` — **arriving** — **[was --private]** trigger direction (maps to 1/2).
    - `--address` — value (SUPPRESS) — none — **[was --private]** reserved; currently errors if combined with location alarm.
    - `--json` — flag — false.
- **Reads:** `q_reminder(db, id)`. List move: `resolve_required_list_target_or_die` → `resolve_list_ref`. Alarm carry/clear: `q_alarms(db, Z_PK)` via `should_carry_absolute_alarm_to_new_due` / `should_clear_matching_absolute_alarm` (reads `ZDUEDATE`, `ZDISPLAYDATEDATE`). `--grocery`: `q_list_by_pk`. Section resolution reads sections table. Early reminder reads existing early-reminder identifiers.
- **Writes:** EventKit bridge `{"action":"update","id":<ZCKIDENTIFIER>,...}` with any of `title`, `list`, `notes`, `priority`, `due` (ISO or `null` for clear), `recurrence`, `alarm`/`clearAlarms`. Optionally a pre-emptive nudge update with `due:<dt+1h>`. AppleScript fallback (`set name/body/priority/due date`/`set due date to missing value`) for plain fields only. private(ReminderKit) for `--private` metadata; location alarm goes through EventKit bridge via `private_location_action`.
- **Human output:** Success: `Updated #<id>`; then `List: {target_list_name}` if list moved; then `Private metadata: applied {n} update{s}` if private applied. Private-only branch (no bridge field changes) prints `Updated #<id>` + `Private metadata: applied {n} update{s}`. No-op: `Nothing to update.`
- **JSON output (--json):** Main path: `{"status":"updated","id":<id>}`; adds `"list":<name>` when moved; adds `"resolvedList":{...}` when method != "exact"; adds `"private":[...]` when private applied. Private-only branch: `{"status":"updated","id":<id>,"private":[...]}` printed with `indent=2`. AppleScript fallback: `{"status":"updated","id":<id>}` (compact).
- **Exit/errors:**
    - `-t/--tags` without `--private` → exit **1**: `Error: editing synced tags requires --private.`
    - Not found → exit **1** `Error: #<id> not found`.
    - Invalid `-d` (non-`clear`, unparseable) → `fail_invalid_due_date` exit **2** (same text/JSON as `add`).
    - `--early-reminder` non-clear with `-d clear` → `fail_early_reminder_without_due` exit **1**.
    - `--early-reminder` non-clear, no new due AND no existing `ZDUEDATE` → exit **1** same message.
    - Bad alarm (non-clear, unparseable) → exit **1**: `Error: could not parse alarm '<v>'. Use 15m, 1h, 1d, an absolute date, or clear.`
    - Bad priority → exit **1**: `Error: priority must be high, medium, low, or none.`
    - List move both name+id → exit **1** `Error: pass either a list name or --list-id, not both.`; neither but flag present → not reachable here (only called when one is set); resolution failure → `Error: list not found: <requested>` / ambiguous message.
    - `carry_absolute_alarm or clear_matching_absolute_alarm` but bridge path didn't run (no bridge) → exit **1**: `Error: this edit requires remctl-bridge to keep due/display/alarm state aligned.`
    - No identifier with bridge-only fields or failed AppleScript → exit **1** `Error: The reminder has no stable identifier. Refusing unsafe title-based fallback for #<id> ('<title>') while trying to edit it.` / `Error: Identifier-based writes failed. ... while trying to edit it.`
    - All private/grocery/subtask validation errors as in `add`.
- **Parity notes:**
    - **Double-tap defense (`dt_nudge`):** if new `dt` equals current `ZDUEDATE` to the second (`int(current.timestamp())==int(dt.timestamp())`), set `dt_nudge = dt + 1h`. Bridge path fires a separate `{"action":"update","id":...,"due":<dt_nudge>}` BEFORE the real update; AppleScript path inserts the nudge `as_date_assign(dt_nudge)` line before the real date assignment. Must preserve this to force a real CKRecord change.
    - **Absolute-alarm carry:** `should_carry_absolute_alarm_to_new_due` returns True only when no explicit alarm, db present, new due present, the reminder has exactly ONE alarm which is absolute, and that alarm equals the OLD due (`ts(ZDUEDATE)`) to the second. Then bridge sends `alarm:<dt.isoformat()>` to move it.
    - **Absolute-alarm clear:** `clear_matching_absolute_alarm` true when `-d clear`, no explicit alarm clear, exactly one alarm (absolute) matching OLD due OR `ZDISPLAYDATEDATE`; bridge sends `clearAlarms:true` alongside the due-clear.
    - Both carry/clear require bridge; if bridge unavailable the command hard-fails (does NOT silently fall to AppleScript).
    - `has_changes` gates the bridge update: if no scalar bridge fields changed but `wants_private`, the private-only branch runs (note its JSON uses `indent=2`, distinct from other paths).
    - URL→notes merge uses exactly `notes + "\n\n" + url` (or url alone), identical between bridge and AppleScript; only when NOT `--private`.
    - `notes_body is not None` (not truthiness) gates bridge notes — empty string still sets notes; AppleScript uses truthiness (`if notes_body:`), a subtle divergence to preserve.
    - AppleScript fallback only runs when `ZCKIDENTIFIER` set, `has_applescript_fields` true, and `has_bridge_only` false (recurrence/alarm/private/list move are bridge-only). `has_applescript_fields = title or notes or due or priority or (url and not private)`.
    - Priority map for `edit` lacks short aliases (`h/m/l`) that `add` has — preserve the difference.
    - `target_list_pk` defaults to current `r["ZLIST"]` (used as private `list_pk` even without a move).
    - All date handling naive local time; due sent as `.isoformat()` or JSON `null`.

### `flag`

- **Summary:** Set a reminder's real flagged state — AppleScript-first (bridge only as lossy fallback).
- **Positional args:** `id` — int — required — numeric Z_PK.
- **Options:** `--json` — flag — false.
- **Reads:** `q_reminder(db, id)` (same SQL as `done`).
- **Writes:** AppleScript-first: `set flagged of r to true` via `osa_by_id_try` matched by `x-apple-reminder://<ZCKIDENTIFIER>`. Only if that fails: EventKit bridge `{"action":"flag","id":<ZCKIDENTIFIER>}` (accepts `status=="flagged"`) — noted as lossy (bridge approximates flag with priority=1).
- **Human output:** `Flagged: {ZTITLE}` (safe_display).
- **JSON output (--json):** `{"status":"flagged","id":<id>,"title":<ZTITLE>}`.
- **Exit/errors:** Not found → exit **1** `Error: #<id> not found`. No identifier → exit **1** `Error: The reminder has no stable identifier. Refusing unsafe title-based fallback for #<id> ('<title>') while trying to flag it.` Both paths failed → `Error: Identifier-based writes failed. Refusing unsafe title-based fallback for #<id> ('<title>') while trying to flag it.`
- **Parity notes:** Order is INVERTED vs done/undone/delete — AppleScript first (touches real `ZFLAGGED`), bridge second. Bridge only attempted when `bridge_available() and ZCKIDENTIFIER`. `osa_by_id_try` uses a 120s timeout. The Swift port must keep AppleScript as the primary path to avoid the priority-proxy data loss.

### `unflag`

- **Summary:** Clear a reminder's real flagged state — AppleScript-first (bridge only as lossy fallback). Mirror of `flag`.
- **Positional args:** `id` — int — required — numeric Z_PK.
- **Options:** `--json` — flag — false.
- **Reads:** `q_reminder(db, id)` (same SQL as `done`).
- **Writes:** AppleScript-first: `set flagged of r to false`. Fallback: EventKit bridge `{"action":"unflag","id":<ZCKIDENTIFIER>}` (accepts `status=="unflagged"`).
- **Human output:** `Unflagged: {ZTITLE}` (safe_display).
- **JSON output (--json):** `{"status":"unflagged","id":<id>,"title":<ZTITLE>}`.
- **Exit/errors:** Not found → exit **1** `Error: #<id> not found`. No identifier → exit **1** `Error: The reminder has no stable identifier. Refusing unsafe title-based fallback for #<id> ('<title>') while trying to unflag it.` Both failed → `Error: Identifier-based writes failed. Refusing unsafe title-based fallback for #<id> ('<title>') while trying to unflag it.`
- **Parity notes:** Same inverted order as `flag` (AppleScript first). Operation phrase is `unflag it`.

Source file: `/Users/orion/Developer/Playgrounds/remctl/remctl` (handlers: add 5133, done 5309, undone 5344, delete 5377, edit 5415, flag 5957, unflag 5993; argparse: add 7683, edit 7732, done/undone 7729-7730, delete 7786, flag/unflag 7821-7822). Key helpers: `parse_due` (3886), `parse_alarm` (4041), `parse_recurrence`/`recurrence_or_die` (3991/4035), `parse_early_reminder` (4093), `apply_private_changes` (3003), `should_carry_absolute_alarm_to_new_due` (1522), `should_clear_matching_absolute_alarm` (1547), `resolve_list_ref` (803), `bridge_call` (2050), `private_action` (2568), `private_location_action` (2585), `osa_by_id_try` (3766), `as_date_assign` (3814), `_refuse_unsafe_title_fallback` (3296), `fail_invalid_due_date` (3873).

## Link / open / export / import

<!-- recon: cmds:link-io (agent-aee6e2e580bfc08dc) -->

I have all the information needed. Note that import sets `aa.priority` directly from the JSON value (which `cmd_add` maps via the `pm` dict expecting strings like "high"/"medium"/"low"), and it does NOT set several fields cmd_add may reference via `getattr`. Let me verify the import AddArgs omissions don't crash by checking which attrs cmd_add accesses with bare `a.X` vs `getattr`.

I have enough to document parity precisely. Here is the contract.

### `link`

- **Summary:** Print the `x-apple-reminderkit://` deep link(s) for one or more reminders, either by ID or for all (top-level) reminders in a list.
- **Positional args:** `ids` — int (nargs=`*`, zero or more) — optional — reminder Z_PK IDs to link.
- **Options:**
    - `-l/--list` — takes value (string) — default None — get links for all active top-level reminders in the named list.
    - `--list-id` — takes value (int) — default None — same as `--list` but by stable numeric list ID.
    - `--completed` — boolean flag (store_true) — default False — when targeting a list, include completed reminders (passed as `completed=` to `q_reminders`).
    - `--json` — boolean flag — default False — emit JSON.
- **Reads:** `open_db()`. For list targeting, `resolve_required_list_target_or_die` then `q_reminders(db, list_pk=pk, completed=a.completed, top_level=True)`. For each id, `q_reminder(db, pk)`: `SELECT {rem_cols} FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE r.Z_PK = ? AND r.ZMARKEDFORDELETION = 0 AND r.ZACCOUNT IS NOT NULL`. Uses columns `ZCKIDENTIFIER`, `ZTITLE`, `list_name`. `q_reminders` filter: `r.ZMARKEDFORDELETION = 0 AND r.ZACCOUNT IS NOT NULL` plus `r.ZCOMPLETED = 0` (unless completed), `r.ZLIST = ?`, and top-level `(r.ZPARENTREMINDER IS NULL OR r.ZPARENTREMINDER = 0)`, `ORDER BY r.Z_PK LIMIT 500`.
- **Writes:** none.
- **Human output:** For each result (only reminders whose `ZCKIDENTIFIER` is non-null), two lines:
    - Line 1: `{reminder_id_text} {safe_display(title)}` where `reminder_id_text` = `#<id>` colored by the list's Reminders color (via `color_by_list` → `C.rgb`; if no rgb, cyan when a list name exists else dim).
    - Line 2: two leading spaces then the link rendered with `C.dim(...)`: `  x-apple-reminderkit://REMCDReminder/<ZCKIDENTIFIER>`.
- **JSON output (--json):** A JSON array (indent=2) of objects, each with keys exactly `id`, `title`, `link` (internal keys prefixed with `_`, i.e. `_list_name`, are stripped). Reminders with null `ZCKIDENTIFIER` are omitted entirely (both human and JSON).
- **Exit/errors:**
    - `exit(1)` + stderr `Error: pass reminder IDs or a list target, not both.` if both `ids` and (`--list` or `--list-id`) given.
    - `exit(1)` + stderr `No reminders specified.` if neither ids nor a resolved list produce any ids.
    - Non-fatal stderr `Warning: #<rid> not found` for an id with no matching reminder (continues).
    - `resolve_required_list_target_or_die` exits with its own messages: `Error: pass either a list name or --list-id, not both.`, `Error: pass a list name or --list-id.`, or `resolve_list_or_die` errors.
- **Parity notes:** Link template is literally `x-apple-reminderkit://REMCDReminder/<ZCKIDENTIFIER>`. Reminders lacking a CloudKit identifier silently produce no output line and no JSON entry. List mode pulls only `top_level=True` reminders (subtasks excluded). Default `q_reminders` LIMIT is 500 (link does not override it). ID coloring depends on list color lookup; preserve `color_by_list` fallback (cyan/dim).

### `open`

- **Summary:** Open a specific reminder in Reminders.app via deep link, or just launch Reminders.app.
- **Positional args:** `id` — int (nargs=`?`, default None) — optional — reminder Z_PK to open via deep link.
- **Options:** none (no `--json`).
- **Reads:** Only when `id` is given: `open_db()` + `q_reminder(db, a.id)` (same SQL as above), using `ZCKIDENTIFIER`.
- **Writes:** `open` (launches macOS `open`). Three branches:
    - id given + has `ZCKIDENTIFIER`: `subprocess.run(["open", "x-apple-reminderkit://REMCDReminder/<ZCKIDENTIFIER>"])`.
    - id given + no `ZCKIDENTIFIER`: `subprocess.run(["open", "-a", "Reminders"])`.
    - no id: `subprocess.run(["open", "-a", "Reminders"])`.
- **Human output:**
    - With deep link: `Opened #<id> in Reminders.app`
    - id but no deep link: `Opened Reminders.app (no deep link available)`
    - No id: `Opened Reminders.app`
- **JSON output (--json):** None — `open` has no `--json` flag; always plaintext.
- **Exit/errors:** `exit(1)` + stderr `Error: #<id> not found` when an id is given but no matching reminder. The `subprocess.run` return code is not checked (no error on `open` failure).
- **Parity notes:** Same deep-link template as `link`. The check is `hasattr(a, 'id') and a.id` — so `id` of 0 would be treated as "no id" (falsy), launching the app generically. Falls back to opening the app (not erroring) when the reminder exists but has no `ZCKIDENTIFIER`. Output strings differ per branch and must match verbatim including the parenthetical.

### `export`

- **Summary:** Export reminders (all lists or one list) to JSON (default) or CSV, including completed reminders and subtasks.
- **Positional args:** none.
- **Options:**
    - `-l/--list` — takes value (string) — default None — export only this list.
    - `--list-id` — takes value (int) — default None — export only this list by stable numeric ID.
    - `--format` (dest `export_format`) — takes value — choices `["json","csv"]`, default `"json"` — output format.
    - `--json` — boolean flag — present but has NO effect on export (output is governed solely by `--format`).
- **Reads:** `open_db()`. With a list target: `resolve_required_list_target_or_die` then `q_reminders(db, list_pk=pk, completed=True, top_level=False, limit=10000)`. Without: `q_reminders(db, completed=True, top_level=False, limit=10000)`. So filter is `ZMARKEDFORDELETION = 0 AND ZACCOUNT IS NOT NULL` (NO `ZCOMPLETED=0` since completed=True), no top-level restriction (subtasks included), `ORDER BY r.Z_PK LIMIT 10000`. CSV path also calls `preload_extras(db, pks)` → `shared_preload_extras` for subtask counts and hashtags, and per-row `to_dict(item, db, _sc=sc, _ht=ht)`. JSON path calls `reminders_to_dicts(items, db)`.
- **Writes:** none (prints to stdout).
- **Human output:** There is no "human" vs JSON distinction; output is determined by `--format`:
    - **CSV** (`--format csv`): printed via `csv.writer` to stdout (`print(output.getvalue(), end="")`, no trailing extra newline beyond csv's own). Header row exactly: `id,title,list,completed,flagged,urgent,priority,due_date,notes,url,tags`. Each data row columns in order: `d["id"]`, `d["title"]`, `d.get("list","")` — note key is `list`, `d["completed"]` (Python bool → `True`/`False`), `d["flagged"]`, `d.get("urgent", False)`, `d["priority"]` (string name e.g. `none`/`high`/`medium`/`low`), `d.get("dueDate","")` (ISO 8601 local), `d.get("notes","")`, `d.get("url","")`, `",".join(d.get("tags", []))` (tags comma-joined into one cell).
    - **JSON** (default): `json.dumps(data, indent=2)` of `reminders_to_dicts`.
- **JSON output (--json):** Array (indent=2) of reminder dicts from `serialize_reminder`. Keys per object: always `id`, `title`, `list`, `completed`, `flagged`, `urgent`, `priority` (name string via `PRI_NAME`, default `"none"`), `subtaskCount`, `isSubtask`. Conditionally present: `notes` (if `ZNOTES`), `url` (`ZICSURL` or resolved rich link), `dueDate` (`ts(ZDUEDATE).isoformat()`), `displayDate` (if `ZDISPLAYDATEDATE` differs from due), `allDay` (if `ZALLDAY` not None), `createdDate`, `completionDate`, `parentID` (if `ZPARENTREMINDER`), `tags`, `recurrence`, `earlyReminder` + `earlyReminders`, `deepLink` (if `ZCKIDENTIFIER`). CSV exposes only the 11 named columns; JSON is the full superset. Note CSV's `priority` column is the same name string used in JSON.
- **Exit/errors:** No own non-zero exits beyond `resolve_required_list_target_or_die` (`Error: pass either a list name or --list-id, not both.` / `Error: pass a list name or --list-id.` / `resolve_list_or_die` errors). Empty list → empty JSON array `[]` or CSV header-only.
- **Parity notes:** LIMIT is 10000 (not 500). Includes completed reminders AND subtasks (top_level=False, completed=True) — the export superset differs from normal listing. Dates are `ts()` = `datetime.fromtimestamp(coreDataValue + 978307200)` rendered as local-time `.isoformat()` (no timezone suffix, Core Data epoch 2001-01-01). CSV booleans are serialized as Python `True`/`False` strings (capitalized). CSV `tags` are comma-joined within the single cell. `--json` flag is accepted but ignored. Preserve conditional key omission (keys only present when source value truthy/non-null) for byte-identical JSON.

### `import`

- **Summary:** Import reminders from a JSON file (array of objects) by replaying each through the `add` code path; prints a created/errors/total summary.
- **Positional args:** `file` — string path — required — path to a JSON file containing an array of reminder objects.
- **Options:** `--json` — boolean flag — default False — emit summary as one-line JSON instead of text.
- **Reads:** Reads the file at `Path(a.file)` and `json.load`s it. Per item, indirectly performs all DB reads/writes of `cmd_add` (list resolution, etc.).
- **Writes:** EventKit | private(ReminderKit) | AppleScript — whatever `cmd_add` does for each item (creates reminders). `import` itself does no direct DB writes; it constructs a fake args namespace and calls `cmd_add(aa)`.
- **Per-item field mapping** (into the `AddArgs` namespace passed to `cmd_add`):
    - `aa.title` = `item.get("title")` (required; item skipped if falsy)
    - `aa.list` = `item.get("list")`
    - `aa.notes` = `item.get("notes")`
    - `aa.due` = `item.get("due") or item.get("dueDate")` (accepts either key; `due` wins)
    - `aa.priority` = `item.get("priority")` (passed straight to cmd_add, which expects strings `high`/`medium`/`low`/`none` via its `pm` map — an integer priority like `1` would NOT map and would error)
    - `aa.flag` = `item.get("flagged", False)`
    - `aa.tags` = `None` (tags from the JSON are ignored on import)
    - `aa.url` = `item.get("url")`
    - `aa.recurrence` = `item.get("recurrence")`
    - `aa.alarm` = `item.get("alarm")`
    - `aa.json` = `False` (each cmd_add call is silenced to non-JSON; its prints still go to stdout)
- **Human output:** After processing, prints a leading blank line then: `\nImported <created>/<total> reminders (<errors> errors)` (note the literal leading `\n`). Per-item `cmd_add` may also print its own success lines to stdout (since `aa.json=False`). Skipped items print stderr `Warning: Skipping item without title`.
- **JSON output (--json):** Single-line `json.dumps(summary)` (NOT indented) where summary is exactly `{"created": <int>, "errors": <int>, "total": <int>}`. `total` = `len(data)` (number of array elements, including title-less skipped ones).
- **Exit/errors:**
    - `exit(1)` + stderr `Error: File '<file>' not found` if path does not exist.
    - `exit(1)` + stderr `Error: Failed to read JSON: <exception>` on `json.JSONDecodeError`/`IOError`.
    - `exit(1)` + stderr `Error: JSON must be an array of reminder objects` if top-level is not a list.
    - Per-item: missing title → stderr `Warning: Skipping item without title`, `errors += 1`, continue. A `cmd_add` that raises `SystemExit` (e.g. its own `exit(1)`) is caught → `errors += 1`, loop continues (import does NOT abort on a single failed item). `created` only increments on successful `cmd_add`.
- **Parity notes:** Import is JSON-only (no CSV import). Input must be a top-level JSON array. `due` key takes precedence over `dueDate`. Tags are deliberately dropped (`aa.tags=None`). `priority` is forwarded unmodified — round-tripping an `export` JSON (which writes `priority` as a name string like `"none"`) works, but `"none"`/integer values must match cmd_add's expectations; cmd_add maps `none`→0 and errors on anything not in `{high,h,medium,med,m,low,l,none}`. `cmd_add`'s `SystemExit` is swallowed into the error count, so import is best-effort/partial. `total` counts every array element (including skipped). Summary JSON is compact (no indent), unlike export's indented JSON. The created reminders inherit all of `cmd_add`'s private/EventKit/AppleScript fork behavior (the AddArgs namespace omits private-metadata fields like `--symbol`/`--emoji`/`--color`, so `private_changes_from_args` sees none and the private path is not triggered for imports).

## Lists management

<!-- recon: cmds:lists (agent-a98072f550fbcbc26) -->

I have all the information needed. Note the `list-symbols`, `list-create`, etc. parsers use only `js(c)` (no `display_format`), so they have `--json` but no `--format`. The `lists` command has both. The `getattr(a, 'format', None)` for non-`lists` private commands won't be 'table'. Let me verify `_row_value` is just a safe getter and confirm `--format json` sets `a.json` for `lists`.

`_row_value` is the safe row accessor (returns None if key absent). I have enough to write the contract.

### `lists`

- **Summary:** List all iCloud reminder lists, alphabetically by name, with per-list section count and pinned badge.
- **Positional args:** none
- **Options:**
    - `--json` — no value — default off — emit machine-readable JSON array (one object per list).
    - `--format` — takes value, `dest=command_format`, choices `plain`/`table`/`json`, default `None` — output format. In `main()`, `command_format` is copied onto `a.format`; `--format json` also sets `a.json = True` (so JSON branch wins). `--format table` triggers the table branch.
- **Reads:** `q_lists(db)` → `SELECT <cols> FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != '' ORDER BY ZNAME`. Columns always include `Z_PK, ZNAME, ZCKIDENTIFIER`, plus any present optional columns from: `ZBADGEEMBLEM, ZCOLOR, ZISPINNEDBYCURRENTUSER, ZPINNEDDATE, ZSHOULDCATEGORIZEGROCERYITEMS, ZSHOULDAUTOCATEGORIZEITEMS, ZSHOULDSUGGESTCONVERSIONTOGROCERYLIST, ZGROCERYLOCALEID, ZAUTOCATEGORIZATIONLOCALCORRECTIONSCHECKSUM`, and `length(ZAUTOCATEGORIZATIONLOCALCORRECTIONSASDATA) AS ZAUTOCATEGORIZATIONLOCALCORRECTIONSASDATA_LENGTH` if present (schema-tolerant via `PRAGMA table_info`). For human output, per list calls `q_sections(db, Z_PK)` → `SELECT Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER FROM ZREMCDBASESECTION WHERE ZMARKEDFORDELETION = 0 AND ZLIST = ? ORDER BY Z_PK`. Colorizing reads `ZCOLOR` from all lists via `load_list_colors` (cached): `SELECT ZNAME, ZCOLOR FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL`.
- **Writes:** none (read-only DB connection opened `mode=ro`).
- **Human output:** Header line `Reminder Lists:` (bold). Then for each row: two-space indent + `{list_name} {id_dim}{sec_info}{pin_info}`.
    - `list_name` = `format_list_title(r, db)`: the name colored by its Reminders list color via 24-bit ANSI `\033[38;2;{r};{g};{b}m...\033[0m` (`color_list_name`); if color disabled and a known list, falls back to `C.cyan` (ANSI `36`); names go through `safe_display` (control chars `[\x00-\x1f\x7f-\x9f\u2028\u2029]` → space). If grocery list (`ZSHOULDCATEGORIZEGROCERYITEMS` truthy), appends ` 🥕` (space + carrot, `GROCERY_LIST_MARKER`).
    - `id_dim` = dim `(id: {Z_PK})`.
    - `sec_info` = dim ` [{n} sections]` only if the list has ≥1 section (no singular form — always "sections").
    - `pin_info` = dim ` [pinned]` only if `ZISPINNEDBYCURRENTUSER` column present AND truthy.
    - Final line: blank line then `{n} list` / `{n} lists` (singular when n==1).
- **JSON output (--json):** Top-level JSON array (`indent=2, ensure_ascii=False`), each element from `list_to_dict(row)`:
    - Always: `id` (Z_PK int), `title` (ZNAME), `listType` (`"groceries"` or `"standard"`), `isGroceries` (bool).
    - `objectUUID` only if ZCKIDENTIFIER present/truthy.
    - `color` only if ZCOLOR present/truthy → `{ "name": <symbolic name>, "hex": <#RRGGBB> }` parsed from the NSKeyedArchiver plist (defaults `{"name":"blue","hex":"#007AFF"}` on parse failure/absence).
    - `badge` only if ZBADGEEMBLEM present/truthy → `parse_badge_emblem` result `{ "raw": ..., optional "emoji", optional "symbol" }`; plus `badgeEmblem` = raw stored value.
    - `grocery` only if grocery payload present and (isGroceries or any truthy value) → `{ shouldCategorizeItems, shouldAutoCategorizeItems, shouldSuggestConversion, optional locale, optional localCorrectionsLength, optional localCorrectionsChecksum }`.
    - `pinned` (bool) only if ZISPINNEDBYCURRENTUSER column present; `pinnedDate` only if ZPINNEDDATE present and not None (raw Apple timestamp, NOT converted).
    - JSON omits section counts entirely (human-only).
- **Table output (--format table):** `fmt_table` of rows `{id: Z_PK, title: format_list_title(r, color=False), list: "", due: "", pri: ""}`. Note title is uncolored; box-drawing table with columns ID/Title/List/Due/Pri (Repeat column omitted since no `repeat` key). Grocery 🥕 still appended (color=False path still adds marker).
- **Exit/errors:** No explicit non-zero exits in handler. DB unavailability raises `RemindersDBUnavailable` from `open_db()` (handled by outer `run_handler_with_fallback`, not here).
- **Parity notes:** Sorting is SQLite `ORDER BY ZNAME` (binary/byte ordering, not locale collation) — Swift must replicate byte-wise ordering, not localized. Section-count badge uses no singular form ("1 sections"). Pin badge/`pinned` JSON key only appear when the column physically exists in the schema (older DBs omit it) — Swift must conditionalize on column presence, not just value. List colors are cached process-wide after first load. Color RGB values come from `LIST_COLOR_MAP` keyed by symbolic name; unknown name → default blue `(0,122,255)` in `load_list_colors` but `parse_list_color` default is `"blue"/#007AFF`. `pinnedDate` is emitted as the raw Core Data timestamp without epoch conversion.

### `list-symbols`

- **Summary:** List the 73 official bundled Reminders list badge symbols (name/asset/approx text), or generate a standalone HTML contact-sheet preview of the native badge assets.
- **Positional args:** none
- **Options:**
    - `--html` — optional value (`nargs="?", const=""`, metavar `PATH`) — default attribute absent unless flag given; bare `--html` → `""`, `--html PATH` → PATH. Writes the HTML preview to PATH (or default `CONFIG_DIR/list-symbols.html` when empty).
    - `--preview` — no value (`store_true`) — default False — generate the HTML and `open` it in the browser.
    - `--json` — no value — default off — JSON output. Mutually exclusive with `--html`/`--preview`.
- **Reads:** No DB. Symbol data is the in-code constant `OFFICIAL_LIST_SYMBOLS` (73 tuples `(name, asset, preview)`). HTML color swatches come from `list_color_preview_rows()` derived from `LIST_COLOR_MAP` (10 colors red→teal).
- **Writes:** `open` (only with `--preview`, via `subprocess.run(["open", path], check=False)`). HTML branch writes a file to disk (default `CONFIG_DIR/list-symbols.html` or `--html` PATH, `parent.mkdir(parents=True, exist_ok=True)`, UTF-8). Asset export shells out to `swift` (an inline Swift program) which loads `/System/Library/PrivateFrameworks/RemindersUICore.framework`, renders each `ListBadge*` asset via `NSBitmapImageRep` to PNG, base64-encoded and embedded as `data:image/png;base64,...`.
- **Human output (plain):**
    - Line 1 (bold): `Official Reminders list symbols ({count}):` (count = 73).
    - Line 2 (dim): `Use these with: remctl list-create "Name" --private --symbol <name>`
    - Line 3 (dim): `The left column is an approximate text fallback, not native Reminders/SF Symbol rendering.`
    - Line 4 (dim): `Tip: run \`remctl list-symbols --preview\` to open the native badge preview in your browser.`
    - Header row: `  {dim 'approx':<2}  {dim 'name':<width}  {dim 'asset'}` where `width = max(len(name))`.
    - Each row: `  {preview:<2}  {name:<width}  {dim asset}`. `preview` is the Unicode fallback glyph (e.g. ☺ ☷ 🎁 ✎), `name` e.g. `education3`, `asset` e.g. `ListBadgeEducation3` (dim).
- **HTML/preview branch output:** prints `HTML preview: {output_path}` to stdout (and opens the file when `--preview`). The HTML is an Apple-styled responsive contact sheet: title "Official Reminders List Symbols", count badge "{n} symbols", a color-swatch fieldset (the 2nd swatch — orange — starts active/pressed and drives `--badge`/`--badge-highlight` CSS vars via inline JS), and a grid of `.symbol` cards each with a circular orange `.badge` containing either the white-filtered PNG `<img>` or a `.fallback` span with the preview glyph, plus `<code>{name}</code>` and `<span>{asset}</span>`.
- **JSON output (--json):** Single object (`indent=2, ensure_ascii=False`):
    - `count` — int (73).
    - `note` — exact string: `"These are Reminders' bundled list badge emblems; emoji badges are separate. The preview field is an approximate Unicode text fallback, not the native Reminders/SF Symbol rendering."`
    - `symbols` — array of `{ "name": ..., "asset": ..., "preview": ... }` in the fixed `OFFICIAL_LIST_SYMBOLS` order.
- **Exit/errors:**
    - `--json` combined with `--html` or `--preview`: stderr `Error: --json cannot be combined with --html or --preview.`, exit 1.
    - HTML generation failure (raised `RuntimeError`): stderr `Error: {e}`, exit 1. RuntimeError messages: `Swift is required to export Reminders badge assets for the HTML preview.`; `RemindersUICore framework not found at {REMINDERS_UI_CORE_BUNDLE}.`; or the swift subprocess's stderr/stdout (e.g. `Missing badge assets: <list>`) when the swift process exits non-zero.
- **Parity notes:** The list of 73 symbols and their exact ordering, names, asset IDs, and preview glyphs are load-bearing and must be reproduced verbatim (see full table in `OFFICIAL_LIST_SYMBOLS` — note duplicates: `fitness`/`sport1` both map preview 🏋, and the order is NOT alphabetical). `width` for column alignment is the max symbol-name length. The `--html` arg uses argparse `nargs="?"` with `const=""`; handler tests `getattr(a,"html",None) is not None` so bare `--html` (value `""`) still triggers HTML mode, and `write_list_symbols_html(a.html or None)` maps `""`→default path. `--preview` both writes the file AND opens it. The HTML embeds PNGs as base64 data URIs rendered white via CSS `filter: brightness(0) invert(1)`; the badge background gradient defaults to orange `#ff9f0a`. JSON's `preview` is explicitly documented as an approximation, not the native render. Asset export requires macOS `swift` + the private RemindersUICore framework — a Swift port should keep the asset rendering optional and fall back to the preview glyph per-card when a PNG is missing.

### `list-create`

- **Summary:** Create a new reminder list; with `--private` uses ReminderKit for symbol/emoji/exact-color/grocery metadata, otherwise uses the EventKit bridge (with AppleScript fallback) for a plain (optionally public-color) list.
- **Positional args:** `name` — string — required — the list title.
- **Options:**
    - `--color` — takes value — default None — list color name (public path: must be one of red/orange/yellow/green/blue/purple/brown/gray/cyan/teal via `LIST_COLOR_MAP`); with `--private` also accepts `#RRGGBB`. **[was --private]** hex colors and any color in the private create path.
    - `--private` — flag — default False — opt into ReminderKit private writes (required for symbol/emoji/hex-color/grocery).
    - `--symbol` — takes value — default None — official symbol name (validated against `OFFICIAL_LIST_SYMBOL_NAMES`). **[was --private]**
    - `--emoji` — takes value — default None — emoji badge. **[was --private]**
    - `--groceries` — flag — default False — create as a Groceries list. **[was --private]**
    - `--grocery-locale` — takes value — default None — locale id like `en_US`/`it_IT`. **[was --private]**
    - `--json` — flag — default off.
- **Reads:** When the private payload is needed, `open_db()` then `q_list_exact_name_count(db, name)` (`SELECT COUNT(*) ... FROM ZREMCDBASELIST WHERE ... ZNAME = ?` exact). Retry path (`private_create_list_call`) re-reads the same count to detect transient-error recovery.
- **Writes:**
    - Private path: ReminderKit via `private_call` action `create_list` with `{name, [color], [symbol], [emoji], [shouldCategorizeGroceryItems, groceryLocaleID]}` (color included with public names here). Retries up to 3× on transient helper errors, verifying by name re-read.
    - Public path: EventKit bridge `bridge_call({action:"create_list", title:name, [color]})` (color only if `is_supported_public_list_color`); on failure falls back to `create_list_with_applescript(name)` → `osascript` `make new list with properties {name:...}`.
- **Human output:**
    - Private success: `Created list: {safe_display(name)}` then, if any private metadata, `Applied private metadata: ` + comma-joined details: `color={normalize_list_color(color)}` (lowercased name or uppercased hex), `symbol={symbol}`, `emoji={emoji}`, `groceries locale={normalize_grocery_locale(grocery_locale) or en_US}`.
    - Public success: `Created list: {safe_display(name)}`.
- **JSON output (--json):**
    - Private: `{"status":"created","name":<name>,"private":<full private_call result dict>}` (`ensure_ascii=False`).
    - Public: `{"status":"created","name":<name>}`.
- **Exit/errors (all exit 1, stderr):**
    - Private path, list already exists: `Error: list already exists: {name}. Use list-edit with --list-id for existing lists.`
    - Private helper failure: `Error: Failed to create list '{name}': {message}` (`message` = result `message` field or `private helper failed`).
    - Public path total failure: `Error: Failed to create list '{name}'` (+ `: {message}` if a message present).
    - Validation errors from `validate_list_appearance_args` (each exit 1): `Error: pass either --symbol or --emoji, not both.`; `Error: --symbol cannot be empty.`; `Error: --emoji cannot be empty.`; `Error: list and smart-list symbols/emojis require --private. Example: remctl list-create "Projects" --private --symbol education3`; `Error: unsupported list symbol {symbol!r}. Run \`remctl list-symbols\` to see official names, or use --emoji for custom emoji badges.`; `Error: unsupported list color {value!r}. Use red, orange, yellow, green, blue, purple, brown, gray, or cyan.`(public) /`... or #RRGGBB.`(private); grocery errors`Error: pass either --groceries or --standard, not both.`, `Error: --grocery-locale cannot be combined with --standard.`, `Error: grocery list metadata requires --private. Example: remctl list-create "Groceries" --private --groceries --grocery-locale en_US`, `Error: --grocery-locale cannot be empty.`, `Error: --grocery-locale must look like en_US or it_IT.`
    - `require_private_metadata` (when private payload needed but flag/helper missing): `Error: private metadata writes require --private.` or `Error: remctl-private is unavailable. Reinstall or set REMCTL_PRIVATE_PATH.`
- **Parity notes:** `private_payload_needed` is computed via `list_private_appearance_payload(a, include_public_color_names=False)` — i.e. a _named_ public color alone does NOT force the private path (only hex color, symbol, emoji, grocery, or `--new-name` which doesn't exist here do). So `--color red` without `--private` goes through the bridge with `color="red"` only if `is_supported_public_list_color`. With `--private`, the create request sends color via `include_public_color_names=True` (names allowed). Duplicate-name preflight only happens on the private path. `normalize_list_color` lowercases names and uppercases hex. Grocery locale normalization: `lang_REGION` casing (`en_US`). The transient-retry logic (`private_create_list_call`: 3 attempts, 0.25s×4 re-read polls, 0.75s×attempt backoff, sets `verifiedAfterTransientError: true`) must be preserved to avoid duplicate lists. `--symbol`/`--emoji` are stripped before sending.

### `list-edit`

- **Summary:** Edit a list's private appearance (rename, color, symbol, emoji, grocery conversion/locale) by name or numeric ID via ReminderKit.
- **Positional args:** `name` — string — optional (`nargs="?"`) — list name to edit (mutually exclusive with `--list-id`).
- **Options:**
    - `--list-id` — takes int value — default None — edit by stable numeric Z_PK.
    - `--new-name` — takes value — default None — rename via ReminderKit.
    - `--color` — takes value — default None — color name or `#RRGGBB`.
    - `--symbol` — takes value — default None — official symbol name. **[was --private]** (symbol always requires private)
    - `--emoji` — takes value — default None — emoji badge. **[was --private]**
    - `--groceries` — flag — convert to Groceries list. **[was --private]**
    - `--standard` — flag — convert Groceries list back to standard. **[was --private]**
    - `--grocery-locale` — takes value — Groceries locale id. **[was --private]**
    - `--private` — flag — default False — required for all writes here (handler calls `require_private_metadata` unconditionally).
    - `--json` — flag.
- **Reads:** `resolve_required_list_target_or_die(db, name, list_id)` → `resolve_list_ref`. By ID: `SELECT <cols> FROM ZREMCDBASELIST WHERE Z_PK = ? AND ZMARKEDFORDELETION=0 AND Z_ENT=3 AND ZNAME IS NOT NULL AND ZNAME != ''`. By name: `q_lists` then exact match → casefold match → normalized (`normalize_list_lookup_name`, NFKC casefold, alnum + collapsed separators) match, each requiring uniqueness. `apply_private_list_appearance` reads `q_list_ckid(db, list_pk)` → `SELECT ZCKIDENTIFIER ... WHERE Z_PK=? AND ZMARKEDFORDELETION=0 AND Z_ENT=3`.
- **Writes:** ReminderKit `private_call` action `set_list_appearance` with `{listId: <ckid>, [name], [color], [symbol], [emoji], [shouldCategorizeGroceryItems], [groceryLocaleID]}` (color via `include_public_color_names=True`). Success requires result `status == "updated"`.
- **Human output:** `Updated list: {safe_display(output_name)}` where `output_name = --new-name or resolved title`.
- **JSON output (--json):** `{"status":"updated","id":<list Z_PK>,"name":<output_name>,"private":<private_call result>}`.
- **Exit/errors (exit 1, stderr):**
    - No change requested: `Error: pass at least one of --new-name, --color, --symbol, --emoji, --groceries, --standard, or --grocery-locale.`
    - `require_private_metadata`: `Error: private metadata writes require --private.` / `Error: remctl-private is unavailable. ...`
    - Resolution: `Error: pass either a list name or --list-id, not both.`; `Error: pass a list name or --list-id.`; `Error: list not found: {requested}`; `Error: multiple lists match {name!r}. Use the exact list name or --list-id with one of: {id (title), ...}`.
    - No ckid: `Error: target list has no stable CloudKit identifier.`
    - Helper failure: `Error: {message}` (message from result or `private helper failed`).
    - Plus all `validate_list_appearance_args` errors (same strings as list-create).
- **Parity notes:** `require_private_metadata` is called even though the change-required check runs first — so the "pass at least one" error precedes the private check. `--groceries`/`--standard`/`--grocery-locale` map to payload as: groceries → `shouldCategorizeGroceryItems=True` + `groceryLocaleID` (or default `en_US`); standard → `shouldCategorizeGroceryItems=False` (no locale); locale-only → `groceryLocaleID` only. `output_name` for display/JSON uses `--new-name` if given, else the resolved current title (NOT the input name). Resolution prefers ID, then exact, casefold, NFKC-normalized — Swift must implement the same 4-tier fallback and ambiguity handling. `apply_private_list_appearance` returns None and the handler still prints "Updated"/JSON status updated if payload is empty — but the no-change guard upstream prevents reaching it with an empty payload in practice.

### `list-pin`

- **Summary:** Pin a list or smart list in Reminders.app via ReminderKit, resolving by name (auto-detecting list vs smart list), `--list-id`, or `--smart-list-id`.
- **Positional args:** `name` — string — optional (`nargs="?"`) — list or smart-list name.
- **Options:**
    - `--list-id` — int — default None — pin a list by Z_PK.
    - `--smart-list-id` — int — default None — pin a smart list by Z_PK.
    - `--private` — flag — default False — required (`require_private_metadata`). **[gates the whole command]**
    - `--json` — flag.
- **Reads:** `resolve_smart_list_or_die` / `resolve_list_or_die` / `resolve_list_ref` + `resolve_smart_list_ref`. Smart lists via `q_smart_lists` (`SELECT Z_PK, ZNAME, ZCKIDENTIFIER, ZSMARTLISTTYPE, ZFILTERDATA, ZMINIMUMSUPPORTEDAPPVERSION, ZEFFECTIVEMINIMUMSUPPORTEDAPPVERSION [,ZBADGEEMBLEM,ZCOLOR] FROM ZREMCDBASELIST ...`; empty if `ZSMARTLISTTYPE` column absent). Then `q_list_ckid` (Z_ENT=3) or `q_smart_list_ckid` (`Z_ENT=4 OR ZSMARTLISTTYPE IS NOT NULL`).
- **Writes:** ReminderKit `private_call`: lists → `{action:"set_list_pinned", listId:<ckid>, pinned:true}`; smart lists → `{action:"set_smart_list_pinned", smartListId:<ckid>, pinned:true}`. Success requires result `status == "updated"`.
- **Human output:** `Pinned {label}: {safe_display(title)}` where `label` = `smart list` (when smart) or `list`. (Capitalized: `Pinned`.)
- **JSON output (--json):** `{"status":"pinned","kind":<"list"|"smart-list">,"id":<Z_PK>,"name":<title>,"private":<result>}` (`ensure_ascii=False`). Note JSON `kind` uses hyphen `smart-list` while human label uses space `smart list`.
- **Exit/errors (exit 1, stderr):**
    - Both ids: `Error: pass either --list-id or --smart-list-id, not both.`
    - No target: `Error: pass a list/smart-list name, --list-id, or --smart-list-id.`
    - `require_private_metadata` errors.
    - Name matches both a list and a smart list: `Error: {name!r} matches both a list and a smart list. Use --list-id or --smart-list-id.`
    - Name matches neither: `Error: list or smart list not found: {name}`
    - Ambiguous list: `Error: multiple lists match {name!r}. Use the exact list name or --list-id with one of: ...`; ambiguous smart list: `Error: multiple smart lists match {name!r}. Use the exact smart-list name or --smart-list-id with one of: ...`
    - No ckid: `Error: target list has no stable CloudKit identifier.` / `Error: target smart list has no stable CloudKit identifier.`
    - Helper failure: `Error: {message}` (or `private helper failed`).
- **Parity notes:** Name resolution does BOTH `resolve_list_ref` and `resolve_smart_list_ref`; if both return non-error matches it errors out (ambiguity across kinds). If either returns an `error` (ambiguous), it prints that kind's resolution error and exits before the both-match check. `kind` value differs between JSON (`smart-list`) and human (`smart list`). `--list-id` path uses `resolve_list_or_die` (so a bad id → `Error: list not found: id {n}`); `--smart-list-id` path uses `resolve_smart_list_or_die`. Shares implementation with `list-unpin` via `_cmd_list_pin_state(a, pinned)`.

### `list-unpin`

- **Summary:** Unpin a list or smart list in Reminders.app via ReminderKit (identical resolution logic to `list-pin`, `pinned=False`).
- **Positional args:** `name` — string — optional (`nargs="?"`).
- **Options:** `--list-id` (int), `--smart-list-id` (int), `--private` (flag, required, **gates command**), `--json`. Same meanings as `list-pin`.
- **Reads:** Identical to `list-pin`.
- **Writes:** ReminderKit `private_call` with `pinned:false`: `set_list_pinned` / `set_smart_list_pinned`. Success requires `status == "updated"`.
- **Human output:** `Unpinned {label}: {safe_display(title)}` (label `list` or `smart list`).
- **JSON output (--json):** `{"status":"unpinned","kind":<"list"|"smart-list">,"id":<Z_PK>,"name":<title>,"private":<result>}`.
- **Exit/errors:** Identical set/strings to `list-pin`.
- **Parity notes:** Same as `list-pin`; only the boolean `pinned=False` and the status word (`unpinned`/`Unpinned`) differ. Both share `_cmd_list_pin_state`.

### `list-rename`

- **Summary:** Rename a list via the EventKit bridge (bridge required — no AppleScript fallback).
- **Positional args:**
    - `name` — string — optional (`nargs="?"`) — current list name (or use `--list-id`).
    - `new_name` — string — optional (`nargs="?"`) — new list name (positional; alternatively `--new-name`).
- **Options:**
    - `--list-id` — int — default None — target by stable numeric ID.
    - `--new-name` — takes value (`dest=new_name_option`) — default None — new name, useful with `--list-id`.
    - `--json` — flag.
- **Reads:** `resolve_required_list_target_or_die(db, name, list_id)` (same SQL/resolution tiers as list-edit) to get the current title.
- **Writes:** EventKit bridge `bridge_call({action:"rename_list", title:<current title>, newTitle:<new_name>})`. NO AppleScript fallback. Success requires `status == "renamed"`.
- **Human output:** `Renamed: {safe_display(old)} -> {safe_display(new)}` (ASCII arrow `->`).
- **JSON output (--json):** `{"status":"renamed","id":<Z_PK>,"old_name":<resolved title>,"new_name":<new_name>}`.
- **Exit/errors (exit 1, stderr):**
    - Both positional `new_name` and `--new-name`: `Error: pass the new list name as an argument or --new-name, not both.`
    - Missing new name: `Error: pass a new list name.`
    - Resolution errors (same as list-edit, including `Error: pass either a list name or --list-id, not both.`).
    - Bridge unavailable: `Error: remctl-bridge required for list management`
    - Bridge failure: `Error: Failed to rename list '{old}'` (+ `: {message}` if present).
- **Parity notes:** New name precedence: `new_name_option` (`--new-name`) is checked first in `new_name = ... or ...`, but if BOTH positional and option given it errors. The bridge is sent the _resolved_ current title (`list_ref["title"]`), not the raw `name` arg — important when resolving via `--list-id` or fuzzy name. No private/AppleScript path at all; bridge must be present and executable (`BRIDGE_PATH.exists()` + exec bit). Arrow is literal `->`.

### `list-delete`

- **Summary:** Delete a list via the EventKit bridge (with AppleScript fallback), bridge required, with an interactive confirmation unless `--force`.
- **Positional args:** `name` — string — optional (`nargs="?"`) — list name to delete (or `--list-id`).
- **Options:**
    - `--list-id` — int — default None — target by stable numeric ID.
    - `--force` — flag — default False — skip the confirmation prompt.
    - `--json` — flag.
- **Reads:** `resolve_required_list_target_or_die(db, name, list_id)` for the current title.
- **Writes:** EventKit bridge `bridge_call({action:"delete_list", title:<title>})`; if that doesn't return `status=="deleted"`, falls back to `delete_list_with_applescript(title)` → `osascript` `delete list "..."`. Success requires final result `status == "deleted"`.
- **Human output:**
    - If not `--force`: interactive prompt to stdin `Delete list '{safe_display(title)}'? This cannot be undone. [y/N] `. If the answer does not (case-insensitively) start with `y`: prints `Cancelled.` and returns (exit 0, no deletion).
    - Success: `Deleted list: {safe_display(title)}`.
- **JSON output (--json):** `{"status":"deleted","id":<Z_PK>,"name":<title>}`. Note: even in `--json` mode the confirmation prompt still fires unless `--force` (the prompt is plain text on stdout); `Cancelled.` is plain text, not JSON.
- **Exit/errors (exit 1, stderr):**
    - Resolution errors (same as list-edit / list-rename).
    - Bridge unavailable: `Error: remctl-bridge required for list management` (checked before the prompt).
    - Deletion failure: `Error: Failed to delete list '{title}'` (+ `: {message}` if present).
- **Parity notes:** The `bridge_available()` guard runs and exits BEFORE the confirmation prompt, but `bridge_call` is still re-guarded with `if bridge_available() else None` before falling back to AppleScript. Confirmation default is No (anything not starting with `y`/`Y`). The prompt and `Cancelled.` are printed even in JSON mode — Swift must replicate that the JSON contract is broken by the interactive prompt unless `--force`. The bridge is sent the resolved title (not raw `name`). `Cancelled.` cancellation returns success (exit 0) without emitting JSON. AppleScript fallback always reports `status:"deleted"` regardless of whether the list existed (it does not verify).

**File:** All code is in `/Users/orion/Developer/Playgrounds/remctl/remctl`. Handlers at the assigned lines; argparse at lines 7654 (`lists`), 7830 (`list-symbols`), 7835 (`list-create`), 7974 (`list-edit`), 7987 (`list-pin`), 7994 (`list-unpin`), 8001 (`list-rename`), 8008 (`list-delete`). Key constants: `OFFICIAL_LIST_SYMBOLS` (line 229), `LIST_COLOR_MAP` (line 214), `GROCERY_LIST_MARKER = "🥕"` (line 451).

## Smart lists

<!-- recon: cmds:smart-lists (agent-a1e70224eeae2a087) -->

I have all the information needed. Here is the behavioral contract.

### `smart-lists`

- **Summary:** Lists/inspects all Reminders smart lists (built-in and custom) with decoded filter summaries.
- **Positional args:** none
- **Options:** `--json` — no value (store_true) — default `False` — output machine-readable JSON.
- **Reads:** `ZREMCDBASELIST` via `q_smart_lists`. Always selects `Z_PK, ZNAME, ZCKIDENTIFIER, ZSMARTLISTTYPE, ZFILTERDATA, ZMINIMUMSUPPORTEDAPPVERSION, ZEFFECTIVEMINIMUMSUPPORTEDAPPVERSION`; conditionally appends `ZBADGEEMBLEM`, `ZCOLOR`, `ZISPINNEDBYCURRENTUSER`, `ZPINNEDDATE` only if those columns exist in the table. SQL: `SELECT ... FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND (Z_ENT = 4 OR ZSMARTLISTTYPE IS NOT NULL) ORDER BY COALESCE(ZNAME, ''), Z_PK`. If table has no `ZSMARTLISTTYPE` column at all, returns `[]` (no rows). No joins.
- **Writes:** none.
- **Human output:** If empty: prints `No smart lists`. Otherwise header `Smart Lists:` (bold via `C.bold`). For each item, two lines:
    - Line 1: `  {name} {C.dim("(id: {id}, {kind})")}{pin_info}` where `kind` is `custom` or `built-in`; `pin_info` is `C.dim(" [pinned]")` if `pinned` truthy else empty.
    - Line 2: `    {smart_type} · filter bytes: {length} · {desc}` (separator is middle-dot `·`). `smart_type` is `item["smartListType"]` or literal `(none)` if null; `length` is `filterLength` (byte length of `ZFILTERDATA` or 0). `desc` = `safe_display(summary["description"] or "No filter data")`; if a summary exists and `summary["supported"]` is falsy, `desc` becomes `f"{desc}: {safe_display(', '.join(summary['keys']) or 'unknown keys')}"`.
    - Footer: blank line then `{N} smart list` / `{N} smart lists` (plural unless N==1).
    - `safe_display` strips terminal control sequences (replaces with spaces).
- **JSON output (--json):** Prints `json.dumps(payload, indent=2, ensure_ascii=False)` where payload is a JSON array of `smart_list_to_dict(row)`. Each object always has: `id` (Z_PK int), `objectUUID` (ZCKIDENTIFIER), `name` (see Parity for fallback), `kind` (`"custom"` if `ZSMARTLISTTYPE == "com.apple.reminders.smartlist.custom"` else `"built-in"`), `smartListType` (raw ZSMARTLISTTYPE, may be null), `filterLength` (int). Conditionally: `color` (`parse_list_color(ZCOLOR)`) when ZCOLOR present+truthy; `badge` (`parse_badge_emblem`) and `badgeEmblem` (raw) when ZBADGEEMBLEM present+truthy; `minimumSupportedVersion`, `effectiveMinimumSupportedVersion` when not null; `pinned` (bool) when `ZISPINNEDBYCURRENTUSER` column present OR pinnedDate not null (computed: `ZISPINNEDBYCURRENTUSER` truthy, else `float(ZPINNEDDATE) > 0`); `pinnedDate` (raw) when not null; `filter` = decoded `summary` object when summary not None; `filterEncoding` (`"json"` or `"keyed_archive_json"`) and `filterJSON` (decoded payload dict) when decoding succeeded; else `filterError` (string) when decode produced an error. The human path reads the same dicts but only surfaces `description`/`keys`/`supported`.
- **Exit/errors:** No explicit non-zero exits in handler. `open_db()` may raise/exit if DB unavailable (out of scope here). Decode errors are captured into `filterError`, not fatal.
- **Parity notes:**
    - Sorting is `COALESCE(ZNAME,'') ASC, Z_PK ASC` (SQLite collation; unnamed/null names sort first as empty string).
    - Display name fallback (`smart_list_display_name`): if `ZNAME` truthy use it; else map raw `ZSMARTLISTTYPE` through `SMART_LIST_TYPE_NAMES` (all→All, today→Today, scheduled→Scheduled, flagged→Flagged, completed→Completed, assigned→Assigned, urgent→Urgent); else last dot-segment of the type, or `(unnamed)` if empty.
    - Column presence is feature-detected — Swift must replicate optional columns and not assume they exist.
    - `pinned` heuristic: prefer boolean column; if false/absent but `ZPINNEDDATE > 0`, treat as pinned.
    - Filter decode accepts BOTH raw UTF-8 JSON (blob starts with `{` after `lstrip`) → encoding `"json"`, and NSKeyedArchiver-wrapped JSON (via `$objects`/`$top`/`root`→`data`) → encoding `"keyed_archive_json"`. Empty/None blob → all-None decode result (no `filter`/`filterEncoding`/`filterError` keys added). Decode summary semantics matter for the `supported`/`keys` human line (see codec parity below).

### `smart-list-create`

- **Summary:** Creates a custom Reminders smart list via the private ReminderKit helper (`remctl-private`), encoding a supported filter to base64 JSON; never writes SQLite directly.
- **Positional args:** `name` — string — required — smart list name.
- **Options:**
    - `--private` — store_true — default `False` — **required** gate; entire command is **[was --private]** (errors out without it).
    - `--color` — value — default None — color name or `#RRGGBB`. Validated via `validate_list_color(color, private=...)`. Only emitted to helper when `--private`. **[was --private]** (color only takes effect with --private).
    - `--symbol` — value — default None — official Reminders symbol name; must be in `OFFICIAL_LIST_SYMBOL_NAMES`. **[was --private]**
    - `--emoji` — value — default None — emoji badge. **[was --private]**
    - Filter family options from `add_smart_list_filter_arguments`:
        - `--match {all,any}` — default `"all"` — combine filters (maps all→`and`, any→`or`).
        - `--filter-json` — value — default None — raw official filter JSON, or `@path` to read from file. Bypasses all builder validation.
        - `--flagged` — store_true — default False.
        - `--priority` — value — default None — `high`/`medium`/`low` or comma-separated.
        - `--tags` — value — default None — comma-separated tag names, `#` prefix optional.
        - `--tag-match {all,any}` — default `"any"`.
        - `--any-tag` — store_true — default False.
        - `--untagged` — store_true — default False — SUPPRESSED in help; always rejected before save (see errors).
        - `--date {any,today}` — default None.
        - `--date-today-include-past-due` — store_true — default False.
        - `--date-on`, `--date-before`, `--date-after` — value — default None — single dates.
        - `--date-range` — value — default None — `START,END` (also accepts `..` separator).
        - `--date-relative` — value — default None — SUPPRESSED; always rejected before save.
        - `--time {morning,afternoon,evening,night}` — default None.
        - `--include-list` — value, `append` (repeatable) — default None — list name(s).
        - `--exclude-list` — value, append — default None — SUPPRESSED; always rejected before save.
        - `--include-list-id` — int, append — default None — numeric list ID(s).
        - `--exclude-list-id` — int, append — default None — SUPPRESSED.
        - `--list-match {all,any}` — default None — SUPPRESSED.
        - `--vehicle {connected}` — default None.
        - `--location-title` — value — default None.
        - `--latitude`, `--longitude` — float — default None.
        - `--radius` — float — default `100.0`.
        - `--proximity {enter,leave,arriving,leaving}` — default `"enter"`.
    - `--json` — store_true — default False.
- **Reads:** `ZREMCDBASELIST` via `q_custom_smart_list_exact_name_count` (`SELECT COUNT(*) ... WHERE ZMARKEDFORDELETION = 0 AND ZSMARTLISTTYPE = 'com.apple.reminders.smartlist.custom' AND ZNAME = ?`) for duplicate check. If `--include-list`/`--include-list-id` (or exclude) used, resolves each via `resolve_list_or_die` to its `objectUUID` (reads lists table). `--filter-json @path` reads a file.
- **Writes:** private(ReminderKit) only, via `private_call` to `remctl-private` with JSON `{"action":"create_smart_list","name":<name>,"filterData":<base64>}` plus appearance keys. `filterData` is base64 of the compact UTF-8 JSON filter. Never touches SQLite or EventKit.
- **Human output:** On success prints `Created smart list: {safe_display(name)}`; if the decoded summary is non-empty, also prints `Filter: {safe_display(summary["description"])}`.
- **JSON output (--json):** Single object (NOT indented; `ensure_ascii=False`): `{"status":"created","name":<name>,"filter":<summary object or null>,"private":<raw helper response dict>}`. `filter` is the decoded summary of the just-encoded blob.
- **Exit/errors (all exit 1, to stderr):**
    - No `--private`: `Error: smart-list-create requires --private.`
    - Appearance validation (`validate_list_appearance_args`): both symbol+emoji → `Error: pass either --symbol or --emoji, not both.`; empty symbol → `Error: --symbol cannot be empty.`; empty emoji → `Error: --emoji cannot be empty.`; symbol/emoji without --private → `Error: list and smart-list symbols/emojis require --private. Example: remctl list-create "Projects" --private --symbol education3`; unknown symbol → `Error: unsupported list symbol '<sym>'. Run \`remctl list-symbols\` to see official names, or use --emoji for custom emoji badges.`; plus `validate_list_color`and grocery validation errors (grocery args N/A for this parser — no`--groceries`).
    - Any `SmartListFilterError` during build/encode → `Error: {exc}` (exact messages below).
    - `require_private_metadata`: if not private → `Error: private metadata writes require --private.`; if helper missing/not-executable → `Error: remctl-private is unavailable. Reinstall or set REMCTL_PRIVATE_PATH.`
    - Duplicate name: `Error: smart list already exists: {name}. Choose a unique test name.`
    - Helper failure (result falsy or `status != "created"`): `Error: Failed to create smart list '{name}': {message}` where message is `result["message"]` if result is a dict else literal `private helper failed`.
- **Filter families allowed to write (pass `summarize`/`encode`):** `flagged` (True), `priorities` (subset of low/medium/high), `hashtags` (`{"any":""}`, OR structured `{"hashtags":{"operation":and|or,"include":[...],"exclude":[...]}}`), `date` (`{"any":""}`, `{"today":bool}`, `onDate`/`beforeDate`/`afterDate`, `dateRange` 2-element, `relativeRange`), `time` (`morning|afternoon|evening|night|noTime`), `lists` (`include`/`exclude`/`operation`), `location` (`{"vehicle":connected|disconnected}` or `{"location":{title,latitude,longitude,radius,proximity}}`).
- **Shapes rejected BEFORE save:**
    - `validate_materializing_smart_list_args` (skipped entirely if `--filter-json` given): `--untagged` → `Untagged smart-list writes do not materialize reliably in Reminders.app.`; `--date no-date` → `No-date smart-list writes...`; `--date-relative` → `Relative-date smart-list writes...`; `--time no-time` → `No-time smart-list writes...`; `--vehicle disconnected` → `Vehicle-disconnected smart-list writes...`; any exclude list → `List exclusion filters do not materialize reliably in Reminders.app.`; include count >1 → `Reminders.app only materializes one included-list filter at a time.`; include + `--list-match` → `Do not pass --list-match with a single included list.`
    - `encode_supported_filter_payload`: rejects unsupported shape or the empty/all filter → `Unsupported smart list filter shape.` (i.e. `{}` summary kind `"all"` is rejected — a zero-filter smart list cannot be created).
    - Builder-level errors (from `build_supported_filter_payload`/normalizers): no filters → `Pass at least one smart list filter.`; bad match → `Smart list match must be all or any.`; bad priority → `Unsupported smart list priority. Use low, medium, or high.`; >1 tag filter → `Pass only one tag filter: --tags, --any-tag, or --untagged.`; >1 date filter → `Pass only one date filter.`; empty date → `Smart list date cannot be empty.`; bad date format → `Smart list dates must be YYYY-MM-DD or DD-MM-YYYY.`; bad range → `Date range must be START,END.`; relative parse errors (`Relative date range must be direction:magnitude:unit[:past-due].`, `Relative date direction must be in-next or in-past.`, `Relative date magnitude must be a positive integer.`, `Relative date unit must be minute, hour, day, week, month, or year.`); bad time → `Time filter must be morning, afternoon, evening, night, or no-time.`; bad vehicle → `Vehicle filter must be connected or disconnected.`; both vehicle+location → `Pass either --vehicle or a specific location, not both.`; incomplete location → `Specific location requires title, latitude, and longitude.`; non-numeric loc → `Specific location latitude, longitude, and radius must be numbers.`; bad proximity → `Specific location proximity must be enter or leave.`; `--filter-json` JSON errors → `Could not read filter JSON file: {exc}` / `Invalid filter JSON: {exc}` / `Smart list filter JSON must be an object.`
- **base64/JSON payload flow:** args → `smart_list_filter_payload_from_args` (if `--filter-json` set, that raw dict is used verbatim and ALL materialization validation is skipped; else `validate_materializing_smart_list_args` then `build_supported_filter_payload`) → `encode_supported_filter_payload` (re-`summarize`s, rejects unsupported/all, then `json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")`) → `base64.b64encode(...).decode("ascii")` → helper field `filterData`. The compact JSON uses no spaces (`,`/`:` separators) and preserves non-ASCII.
- **Appearance payload (`list_private_appearance_payload`):** adds `name` only if `a.new_name` (not present on this parser); `color` = `normalize_list_color(color)` only when color set AND `--private` (and `include_public_color_names` True here, so any normalized color is included); `symbol` = `a.symbol.strip()`; `emoji` = `a.emoji.strip()`; grocery keys only if `--groceries`/`--standard`/`--grocery-locale` (not present on this parser).
- **Parity notes:**
    - `--match`/`--tag-match`/`--list-match` map all→`and`, any→`or` (also accept literal `and`/`or`).
    - `operation` key is added to the JSON payload only when there is >1 filter OR operation is `or`. With a single AND filter, no `operation` key.
    - Dates are normalized to `DD-MM-YYYY` storage format from input `YYYY-MM-DD`/`DD-MM-YYYY`/`DD/MM/YYYY`/`YYYY/MM/DD`.
    - Priorities deduped preserving order; tags `#`-stripped and trimmed, empties dropped.
    - `--radius` default 100.0; location object field order in JSON is `title, latitude, radius, longitude, proximity`; proximity synonyms map arrive/arriving→enter, leave/leaving/exit→leave.
    - `lists` filter `operation`: if `list_match` None → `or` when >1 include and no exclude, else `and`; operation key only emitted when op is `or` OR >1 include OR exclude present.
    - The `all`/empty filter is explicitly un-creatable.

### `smart-list-edit`

- **Summary:** Edits an existing custom smart list's filter and/or appearance via `remctl-private` (`update_smart_list`); only custom smart lists are matched, never built-ins.
- **Positional args:** `name` — string — optional (`nargs="?"`) — custom smart list name (one of name/`--smart-list-id` required).
- **Options:**
    - `name` positional (above) and `--smart-list-id` — int — default None — select by numeric ID. **[was --private]** (whole command requires --private).
    - `--private` — store_true — default False — **required** gate.
    - `--color`, `--symbol`, `--emoji` — same as create (appearance). **[was --private]**
    - All filter family options via `add_smart_list_filter_arguments` (identical set/defaults to create).
    - `--json` — store_true — default False.
- **Reads:** `ZREMCDBASELIST` via `q_custom_smart_list_delete_matches` — by ID: `SELECT Z_PK, ZNAME, ZCKIDENTIFIER, ZSMARTLISTTYPE, ZFILTERDATA FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND ZSMARTLISTTYPE = 'com.apple.reminders.smartlist.custom' AND Z_PK = ?`; by name: same with `ZNAME = ? ORDER BY Z_PK`. Plus list resolution for include/exclude (same as create). No joins.
- **Writes:** private(ReminderKit) via `private_call` with `{"action":"update_smart_list","smartListId":<row ZCKIDENTIFIER>}`, plus `filterData` (base64) only if filter changes were requested, plus appearance keys.
- **Human output:** On success prints `Updated smart list: {safe_display(display_name)}`; if filter was changed and summary non-empty, also `Filter: {safe_display(summary["description"])}`.
- **JSON output (--json):** Object (not indented, ensure_ascii=False): `{"status":"updated","id":<Z_PK>,"objectUUID":<ZCKIDENTIFIER>,"name":<display_name>,"private":<helper response>}`, and `"filter":<summary>` added only when filter data was rebuilt (filter changes present).
- **Exit/errors (exit 1, stderr):**
    - No `--private`: `Error: smart-list-edit requires --private.`
    - Neither name nor id: `Error: provide a smart list name or --smart-list-id.`
    - Appearance validation errors (same set as create).
    - `require_private_metadata` errors (same as create) — note `require_private_metadata` runs BEFORE the DB query here.
    - No matches: `Error: custom smart list not found: {target}` where target is `id {smart_list_id}` if id given else the name.
    - Multiple matches: `Error: multiple custom smart lists match. Use --smart-list-id.` followed by one line per match `  {Z_PK}: {display_name}` (all to stderr).
    - Nothing to change: `Error: pass at least one smart-list filter or appearance option.`
    - `SmartListFilterError` during filter build/encode → `Error: {exc}`.
    - Helper failure (result falsy or `status != "updated"`): `Error: Failed to edit smart list '{display_name}': {message}`.
- **Parity notes:**
    - Change detection: `smart_list_filter_changes_from_args` returns True if `--filter-json`, `--flagged`, `--any-tag`, `--untagged`, `--date-today-include-past-due`, or any of `priority, tags, date, date_on, date_before, date_after, date_range, date_relative, time, include_list, exclude_list, include_list_id, exclude_list_id, vehicle, location_title, latitude, longitude` is not None/""/[]. `list_appearance_changes_from_args` returns True for any of color/symbol/emoji/grocery args. At least one must be present.
    - `filterData` is OMITTED from the helper request when only appearance changes were made (the existing filter is preserved). Only included when filter changes detected.
    - Same encode/base64/validation flow as create (including the materializing-rejection rules and `Unsupported smart list filter shape.` for empty/all). An edit cannot set the filter to the all/empty shape.
    - `smartListId` sent to helper is the row's `ZCKIDENTIFIER` (CloudKit identifier string), NOT `Z_PK`.
    - Only rows with `ZSMARTLISTTYPE = "com.apple.reminders.smartlist.custom"` are eligible; built-ins never match.
    - Color is only included in the appearance payload when `--private` (always true here) and is `normalize_list_color`-ed.

### `smart-list-delete`

- **Summary:** Deletes a custom smart list via `remctl-private` (`delete_smart_list`) after an interactive confirmation unless `--force`; only custom smart lists are matched.
- **Positional args:** `name` — string — optional (`nargs="?"`) — custom smart list name (one of name/id required).
- **Options:**
    - `--smart-list-id` — int — default None — delete by numeric ID. **[was --private]**
    - `--private` — store_true — default False — **required** gate.
    - `--force` — store_true — default False — skip the confirmation prompt.
    - `--json` — store_true — default False.
- **Reads:** `ZREMCDBASELIST` via `q_custom_smart_list_delete_matches` (same SQL as edit). No joins.
- **Writes:** private(ReminderKit) via `private_call({"action":"delete_smart_list","smartListId":<ZCKIDENTIFIER>})`.
- **Human output:** Without `--force`, prompts on stdout: `Delete custom smart list '{safe_display(name)}'? [y/N] ` (via `input()`). If the (stripped, lowercased) answer is not `y`/`yes`, prints `Aborted.` and returns with exit 0 (no deletion). On success prints `Deleted smart list: {safe_display(name)}`.
- **JSON output (--json):** Object (not indented, ensure_ascii=False): `{"status":"deleted","id":<Z_PK>,"objectUUID":<ZCKIDENTIFIER>,"name":<display_name>,"private":<helper response>}`. Note: the confirmation prompt still occurs unless `--force` even in `--json` mode (would emit non-JSON prompt text to stdout); to script cleanly you must pass `--force`.
- **Exit/errors (exit 1, stderr unless noted):**
    - No `--private`: `Error: smart-list-delete requires --private.`
    - Neither name nor id: `Error: provide a smart list name or --smart-list-id.`
    - `require_private_metadata` errors (runs before DB query): same two messages as above.
    - No matches: `Error: custom smart list not found: {target}` (`id {id}` or name).
    - Multiple matches: `Error: multiple custom smart lists match. Use --smart-list-id.` then `  {Z_PK}: {display_name}` per match.
    - User declines: prints `Aborted.` to stdout, returns exit 0 (NOT an error).
    - Helper failure (result falsy or `status != "deleted"`): `Error: Failed to delete smart list '{name}': {message}` (message = `result["message"]` if dict else `private helper failed`).
- **Parity notes:**
    - Confirmation acceptance is exactly `{"y","yes"}` after `.strip().lower()`; everything else aborts.
    - `smartListId` sent to helper is `ZCKIDENTIFIER` (not Z_PK).
    - Custom-only matching (`ZSMARTLISTTYPE = "com.apple.reminders.smartlist.custom"`).
    - This parser has NO `--color`/`--symbol`/`--emoji`/filter args — only name, `--smart-list-id`, `--private`, `--force`, `--json`.

---

Codec parity (shared by create/edit, critical for Swift):

- `summarize_smart_list_filter` special-cases: `{}` → kind `all` (description `All reminders`) — and `encode` REJECTS this; `{"flagged": True}` → kind `flagged`; a payload whose only non-`operation` key is `priorities` (all in low/medium/high) → kind `priority` with `keys = ["priorities"] + (["operation"] if operation else [])`. General case: strips `operation`, summarizes each remaining family; if all supported → kind `compound` (if >1 part) else the single part's kind, description `"; ".join(...)`, prefixed `Match all:`/`Match any:` when >1 part or operation==`or`; if any unsupported → kind `unsupported`, `supported: False`, `materializes: False` if any part flagged non-materializing else `None`. `keys` is always `sorted(str(k) for k in payload.keys())`.
- `match` mapping in summaries: `and`→`all`, `or`→`any`, default `all`.
- Decode path tries raw-JSON first (after `lstrip`, blob beginning with `{`), then NSKeyedArchiver extraction (`$top.root` UID → `$objects[root].data` UID → bytes → JSON). On `UnicodeDecodeError/JSONDecodeError/InvalidFileException/ValueError` returns `error` string; if nothing matched returns `error: "unsupported filter blob"`.
- `encode_supported_filter_payload` output is compact JSON (`separators=(",", ":")`, `ensure_ascii=False`), UTF-8 bytes, then base64.

Relevant file paths: `/Users/orion/Developer/Playgrounds/remctl/remctl` (handlers + argparse), `/Users/orion/Developer/Playgrounds/remctl/remctl_smart_lists.py` (filter codec/build/validate). Private helper invoked: `remctl-private` (path `PRIVATE_PATH`, overridable via `REMCTL_PRIVATE_PATH`), implemented in `/Users/orion/Developer/Playgrounds/remctl/remctl-private.m`.

## Templates

<!-- recon: cmds:templates (agent-a8a40fc59d1e4ef61) -->

I now have a complete picture. Note one important detail in `cmd_template_info`: the priority symbol uses `PRI.get({'high': 1, 'medium': 5, 'low': 9}.get(item.get('priority'), 0), '')` — mapping the priority name string back to a numeric key then into `PRI` symbols. Let me verify `template_select_columns` does NOT include `ZPUBLICLINKURLUUID` reading in `q_templates` path — it does via optional columns. I have everything needed.

### `templates`

- **Summary:** Read-only inspector that lists all saved Reminders templates with item/section counts and shared-link indicator.
- **Positional args:** none
- **Options:** `--json` — no value (store_true) — default False — emit machine-readable JSON instead of human text.
- **Reads:** `ZREMCDTEMPLATE` via `q_templates`. Selects columns from `template_select_columns` (always `Z_PK, ZNAME, ZCKIDENTIFIER, ZCREATIONDATE, ZLASTMODIFIEDDATE, ZPUBLICLINKCREATIONDATE, ZPUBLICLINKEXPIRATIONDATE, ZPUBLICLINKLASTMODIFIEDDATE`, plus optional `ZBADGEEMBLEM, ZCOLOR, ZPUBLICLINKURLUUID, ZPUBLICLINKCONFIGURATIONDATA` if present in the table). Adds two correlated subqueries: `item_count` = `COUNT(*) FROM ZREMCDSAVEDREMINDER sr WHERE sr.ZTEMPLATE = ZREMCDTEMPLATE.Z_PK AND sr.ZMARKEDFORDELETION = 0`; `section_count` = `COUNT(*) FROM ZREMCDBASESECTION s WHERE s.ZTEMPLATE = ZREMCDTEMPLATE.Z_PK AND s.ZMARKEDFORDELETION = 0`. WHERE: `ZMARKEDFORDELETION = 0 AND ZNAME IS NOT NULL AND ZNAME != ''`. `ORDER BY ZNAME, Z_PK`.
- **Writes:** none
- **Human output:** If no templates: prints `No templates`. Otherwise header line `Templates:` (bold, ANSI code 1). Then one line per template, two-space indented: `  {name} ({bits})` where the parenthesized `bits` part is dim (ANSI code 2). `bits` joined by `, ` and always starts with `id: {id}` and `{itemCount} item` (pluralized to `items` when itemCount != 1). If `sectionCount` truthy, append `{sectionCount} section`/`sections`. If a `publicLink` exists, append literal `shared`. Names passed through `safe_display` (terminal-control chars → spaces). Trailing summary after a blank line: `\n{N} template`/`templates` (pluralized when N != 1).
- **JSON output (--json):** Prints `json.dumps(payload, indent=2, ensure_ascii=False)` where payload is a JSON array of template dicts from `template_to_dict(row)` (no items). Each object: `id` (int), `name` (str), `objectUUID` (str|null = `ZCKIDENTIFIER`), `deepLink` (`x-apple-reminderkit://REMCDTemplate/{objectUUID}` or null), `itemCount` (int), `sectionCount` (int). Optional keys only when present/truthy: `createdDate`/`modifiedDate` (ISO 8601 from `_template_time`), `badgeEmblem` (str), `publicLink` (object: `uuid`, `url`, optional `createdDate`/`modifiedDate`/`expirationDate`, optional `configurationLength`). JSON includes counts and full metadata; human view only shows id/counts/shared marker.
- **Exit/errors:** No non-zero exits in handler. (`open_db()` may raise upstream.)
- **Parity notes:** Empty array prints `[]` (still valid JSON) but human path prints `No templates`. Sorting is by `ZNAME` then `Z_PK` (SQL ASC); preserve. Pluralization rules exact: singular when count == 1, else plural — note `sections` only shown when sectionCount is truthy (0 omitted) but items always shown even at 0. `publicLink.url` is built by `template_public_link` = `https://www.icloud.com/reminders/template/{public_uuid}#{fragment}` where fragment = `quote(name.replace(" ","_"), safe=":_")` and public_uuid is derived via `uuid_from_blob(ZPUBLICLINKURLUUID)` (uppercased UUID from 16-byte blob). Dates use Apple epoch offset `978307200` added to raw value then `datetime.fromtimestamp(...)` in LOCAL time, `.isoformat()` (naive local datetime, no tz suffix). `deepLink` is null when no objectUUID.

### `template-info`

- **Summary:** Read-only detailed view of one saved template including its saved reminders and sections.
- **Positional args:** `name` — str — optional (`nargs="?"`) — template name. Required _together-or-or_ with `--template-id`: exactly one of name/`--template-id` must be given.
- **Options:** `--template-id` — takes int value — default None — read by numeric template `Z_PK`. `--json` — store_true — default False — JSON output.
- **Reads:** Resolves target via `resolve_required_template_target_or_die` → `resolve_template_ref` → `q_template_matches` (same select shape as `templates`, WHERE by `Z_PK = ?` for id, or `ZNAME = ? ORDER BY Z_PK` for name). Then re-fetches `q_template_matches(template_id=ref["id"])[0]`. `template_to_dict(..., include_items=True)` additionally queries `q_template_sections` (`ZREMCDBASESECTION` cols `Z_PK, ZDISPLAYNAME, ZCKIDENTIFIER, ZCANONICALNAME, ZCREATIONDATE` filtered to existing columns; WHERE `ZMARKEDFORDELETION = 0 AND ZTEMPLATE = ? ORDER BY Z_PK`) and `q_template_saved_reminders` (`ZREMCDSAVEDREMINDER` cols from `saved_reminder_select_columns`: `Z_PK, ZTITLE, ZCKIDENTIFIER, ZPARENTSAVEDREMINDERIDENTIFIER, ZPRIORITY, ZDISPLAYDATEISALLDAY, ZDISPLAYDATEDATE, ZCREATIONDATE, ZMETADATA` filtered to existing; WHERE `ZMARKEDFORDELETION = 0 AND ZTEMPLATE = ? ORDER BY Z_PK`).
- **Writes:** none
- **Human output:** Line 1: template name (bold), `safe_display`-sanitized. Then `ID: {id}`. If objectUUID present: `Object UUID: {objectUUID}`. If deepLink present: `Deep link: {deepLink}`. Always: `Items: {itemCount}` and `Sections: {sectionCount}`. If publicLink present: `Existing public link: {publicLink.url}`. If sections present: blank line, header `Sections:`, then per section `  {name} (id: {id})` with the `(id: …)` portion dim. If items present: blank line, header `Saved Reminders:`, then per item `  - {title}{priority}{tags}`. `priority` = a leading space + the symbol from `PRI` (`1→!!!`, `5→!!`, `9→!`, else `""`), computed as ` ` + `PRI[{'high':1,'medium':5,'low':9}.get(priorityName,0)]` then `.rstrip()` (so empty when none). `tags` = ` #tag1 #tag2` (each `safe_display`-sanitized) or empty.
- **JSON output (--json):** `json.dumps(payload, indent=2, ensure_ascii=False)` of `template_to_dict(row, db, include_items=True)`. Top-level keys same as `templates` plus always `sections` (array of `template_section_to_dict`: `id`, `name` = `ZDISPLAYNAME` or `ZCANONICALNAME` or "", `objectUUID`, optional `createdDate`, optional `canonicalName` when it differs from name) and `items` (array of `saved_reminder_to_dict`). Each saved-reminder object: `id`, `title` (`ZTITLE` or metadata title or ""), `objectUUID`, `priority` (name string via `PRI_NAME`: `none/high/medium/low`), optional `createdDate`, optional `displayDate`+`displayDateIsAllDay`, optional `parentObjectUUID` (UUID from `ZPARENTSAVEDREMINDERIDENTIFIER` blob), and if metadata present: `metadataKeys` (sorted), `flagged` (bool), optional `tags`, `dueDateComponents`, `startDateComponents`, `recurrenceRules`, `alarmTriggers`, `hasNotes` (true when `notesDocumentData` present). JSON exposes far more (components, recurrence, alarms, metadata keys) than the human view, which only shows title/priority symbol/tags.
- **Exit/errors:** Exit 1 with `Error: pass either a template name or --template-id, not both.` if both given; `Error: pass a template name or --template-id.` if neither. On unresolved: if ambiguous, `Error: multiple templates match {requested!r}. Use --template-id with one of: {id (name), …}` (note Python `repr` quoting of requested); else `Error: template not found: {requested}` (for id path requested is `id {n}`). All to stderr, exit 1.
- **Parity notes:** Name resolution is EXACT-match only (`ZNAME = ?`) — no case-insensitive/normalized fallback (unlike list/smart-list resolution). Multiple exact name matches → ambiguous error (templates can share names). `priority` in JSON derives from `ZPRIORITY` with metadata fallback `ZPRIORITY or metadata.priority or 0`, mapped through `PRI_NAME`; human view maps the name BACK to a numeric key to pick the symbol — preserve this two-step mapping exactly. `metadataKeys` is a sorted list of the decoded metadata dict's keys. `decode_template_metadata` strips a leading `0x01` byte then JSON-decodes UTF-8 (returns None on any failure). UUID blobs are 16-byte little? — actually `uuid.UUID(bytes=...)` standard big-endian, uppercased. Optional keys are omitted entirely when falsy (must not emit nulls except `objectUUID`/`deepLink` which can be null). Dates are naive local-time ISO (Apple epoch + value).

### `template-create`

- **Summary:** Saves an entire existing list as a new Reminders template via the private ReminderKit helper (write); whole-list granularity only.
- **Positional args:** `name` — str — required — the new template name.
- **Options:** `--from-list` — takes value (str) — default None — source list name. **[was --private]** (write gated). `--from-list-id` — takes int value — default None — source list numeric ID. **[was --private]**. `--include-completed` — store_true — default False — include completed reminders in the saved template. **[was --private]**. `--private` — store_true — default False — REQUIRED to run this command at all. `--json` — store_true — default False — JSON output.
- **Reads:** `q_template_exact_name_count` (`SELECT COUNT(*) FROM ZREMCDTEMPLATE WHERE ZMARKEDFORDELETION = 0 AND ZNAME = ?`). Source list resolved via `resolve_required_list_target_or_die` → `resolve_list_or_die`/`resolve_list_ref` (full list resolution: exact, then case-insensitive/normalized fallbacks). `q_list_reminder_count_for_template`: `SELECT COUNT(*) AS count FROM ZREMCDREMINDER WHERE ZMARKEDFORDELETION = 0 AND ZLIST = ? AND ZACCOUNT IS NOT NULL` plus `AND ZCOMPLETED = 0` unless `--include-completed`. After write, polls up to 12 times (sleep 0.25s each, on a freshly `open_db()`'d connection) calling `q_template_matches(name=...)` until a match exists and `itemCount >= expected_items`.
- **Writes:** private (ReminderKit) via `private_call({"action":"create_template","name":<name>,"listId":<list objectUUID>,"includeCompleted":<bool>})`. Creates a new template object from the whole source list. Does NOT touch SQLite directly.
- **Human output:** On success: `Created template: {name}` then `Source list: {list title}` (both `safe_display`-sanitized). No counts in human output.
- **JSON output (--json):** `json.dumps(payload, indent=2, ensure_ascii=False)`. Keys: `status` = `"created"`; `name` (the requested name); `sourceList` (the list ref dict: `id`, `title`, `objectUUID`, `requested`, `method`, `isGroceries`, plus grocery fields if any); `private` (the raw helper JSON response dict); optional `expectedItemCount` (int, when count query succeeded — may be 0); optional `template` (full `template_to_dict(..., include_items=True)` of the freshly created template, present only if the poll found it).
- **Exit/errors:** Exit 1, all to stderr:
    - Not `--private`: `Error: template-create requires --private.`
    - Both `--from-list` and `--from-list-id`: `Error: pass either --from-list or --from-list-id, not both.`
    - Neither source given: `Error: pass --from-list or --from-list-id.`
    - `require_private_metadata` failures: `Error: private metadata writes require --private.` or (helper missing/non-executable) `Error: remctl-private is unavailable. Reinstall or set REMCTL_PRIVATE_PATH.`
    - Duplicate template name: `Error: template already exists: {name}. Use a unique template name.`
    - List resolution failure (from `resolve_required_list_target_or_die`): list ambiguity/not-found errors (exit 1).
    - Source list lacks CloudKit id: `Error: source list has no stable CloudKit identifier.`
    - Helper failure (no result or `status != "created"`): `Error: Failed to create template '{name}': {message}` where message is `result.get("message")` if result is a dict else `private helper failed`.
- **Parity notes:** Order of checks matters: `--private` gate first, then mutually-exclusive source check, then required-source check, then `require_private_metadata` (re-checks private AND helper availability), then duplicate-name check, then list resolve, then objectUUID presence, then count, then helper call. The duplicate check is EXACT-name (`ZNAME = ?`). Source `listId` sent to helper is the list's `objectUUID` (ZCKIDENTIFIER), not Z_PK. The polling loop short-circuits and breaks immediately if `expected_items in (None, 0)` even on first iteration after one match attempt; otherwise it retries up to 12×0.25s waiting for itemCount to catch up to expected. `includeCompleted` is coerced to bool. Whole-list granularity: the command intentionally cannot append individual reminders to an existing template, strip subtasks/due dates, or create iCloud links (per description). `expectedItemCount` only added to payload when the count query returned non-None.

### `template-apply`

- **Summary:** Creates a new list from a saved template via the private ReminderKit helper (write); does not modify the template.
- **Positional args:** `name` — str — optional (`nargs="?"`) — template name; one of name/`--template-id` required.
- **Options:** `--template-id` — takes int value — default None — apply by numeric template ID. `--private` — store_true — default False — REQUIRED to run. `--json` — store_true — default False — JSON output.
- **Reads:** Resolves template via `resolve_required_template_target_or_die` (exact-name or by `Z_PK`). After the write, if helper returns an `id`, re-reads the created list on a fresh `open_db()`: `SELECT {list_select_columns} FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZCKIDENTIFIER = ?` (the returned UUID).
- **Writes:** private (ReminderKit) via `private_call({"action":"apply_template","templateId":<template objectUUID>})`. Creates a new Reminders list. No direct SQLite writes.
- **Human output:** On success: `Created list from template: {name}` where name = `payload["list"]["title"]` if the list was re-read, else `result.get("name")`, else the template ref's `name` (`safe_display`-sanitized).
- **JSON output (--json):** `json.dumps(payload, indent=2, ensure_ascii=False)`. Keys: `status` = `"created"`; `template` (template ref dict: `id`, `name`, `objectUUID`, `requested`, `method`); `private` (raw helper response dict); optional `list` (`list_to_dict` of the newly created list row, present only if the re-read found it: `id`, `title`, `listType`, `isGroceries`, optional `objectUUID`/`color`/`badge`/`badgeEmblem`/`grocery`/`pinned`/`pinnedDate`).
- **Exit/errors:** Exit 1, stderr:
    - Not `--private`: `Error: template-apply requires --private.`
    - `require_private_metadata`: `Error: private metadata writes require --private.` / `Error: remctl-private is unavailable. Reinstall or set REMCTL_PRIVATE_PATH.`
    - Template resolution: `Error: pass either a template name or --template-id, not both.` / `Error: pass a template name or --template-id.` / `Error: multiple templates match {requested!r}. Use --template-id with one of: …` / `Error: template not found: {requested}`.
    - Helper failure (no result or `status != "created"`): `Error: Failed to create list from template '{ref name}': {message}` (message = `result.get("message")` if dict else `private helper failed`).
- **Parity notes:** `templateId` sent to helper is the template's `objectUUID` (ZCKIDENTIFIER), not Z_PK. The created-list lookup is keyed by `Z_ENT = 3` AND `ZCKIDENTIFIER = result["id"]` on `ZREMCDBASELIST` — preserve the `Z_ENT = 3` filter and table. Human-output name fallback chain is list.title → result.name → ref.name; the `payload.get("list", {})` access tolerates missing list. Template resolution is exact-name only. No retry/poll loop here (unlike create). The template itself is unmodified.

### `template-delete`

- **Summary:** Deletes a saved template via the private ReminderKit helper (write), with an interactive confirmation unless `--force`.
- **Positional args:** `name` — str — optional (`nargs="?"`) — template name; one of name/`--template-id` required.
- **Options:** `--template-id` — takes int value — default None — delete by numeric template ID. `--private` — store_true — default False — REQUIRED to run. `--force` — store_true — default False — skip the confirmation prompt. `--json` — store_true — default False — JSON output.
- **Reads:** Resolves template via `resolve_required_template_target_or_die` (exact-name or `Z_PK`). No post-write re-read.
- **Writes:** private (ReminderKit) via `private_call({"action":"delete_template","templateId":<template objectUUID>})`. Deletes the template. No direct SQLite writes.
- **Human output:** If not `--force`: prompts on stdout via `input(...)`: `Delete template '{name}'? [y/N] ` (name `safe_display`-sanitized). If the answer (stripped, lowercased) is not in `("y","yes")`, prints `Aborted.` and returns with exit 0 (no deletion). On success: `Deleted template: {name}`.
- **JSON output (--json):** On success only: `json.dumps({...}, ensure_ascii=False)` (NOTE: no `indent` — single-line compact JSON, unlike the other template commands which use `indent=2`). Keys: `status` = `"deleted"`; `template` (ref dict: `id`, `name`, `objectUUID`, `requested`, `method`); `private` (raw helper response dict). If the user aborts, NO JSON is printed even with `--json` — it prints plain `Aborted.` and returns.
- **Exit/errors:** Exit 1, stderr:
    - Not `--private`: `Error: template-delete requires --private.`
    - `require_private_metadata`: `Error: private metadata writes require --private.` / `Error: remctl-private is unavailable. Reinstall or set REMCTL_PRIVATE_PATH.`
    - Template resolution: `Error: pass either a template name or --template-id, not both.` / `Error: pass a template name or --template-id.` / `Error: multiple templates match {requested!r}. Use --template-id with one of: …` / `Error: template not found: {requested}`.
    - Helper failure (no result or `status != "deleted"`): `Error: Failed to delete template '{ref name}': {message}` (message = `result.get("message")` if dict else `private helper failed`).
    - Abort path returns exit 0 (`Aborted.`), not an error.
- **Parity notes:** `templateId` sent to helper is the template's `objectUUID`. Confirmation prompt accepts only `y`/`yes` (case-insensitive after `.strip().lower()`); everything else (including empty/EOF input — which would raise `EOFError` in non-interactive contexts) aborts. The Swift port MUST replicate the `--json` output being COMPACT (no indent) here, diverging from create/apply/info which pretty-print with `indent=2`. Abort short-circuits before any JSON/helper call. Whole-template granularity: deletes the entire template object, no partial deletion.

## Ops / meta commands

<!-- recon: cmds:ops-meta (agent-aeca413158441db4f) -->

I now have the complete picture. Here is the behavioral contract for my assigned commands.

### `completion`

- **Summary:** Print a shell completion script for remctl to stdout (zsh/bash/fish).
- **Positional args:** `shell` — string — optional (`nargs="?"`, `default="zsh"`, `choices=["bash", "zsh", "fish"]`) — which shell's completion script to emit.
- **Options:** none (no `--json`; this command does NOT get `js(c)` applied). The global `--no-color`/`--format`/`--version` are still parsed at the top-level parser, but `--format json` does not affect output here.
- **Reads:** none (no DB/EventKit). Returns one of three hardcoded string constants `ZSH_COMPLETION`, `BASH_COMPLETION`, `FISH_COMPLETION`.
- **Writes:** none — only writes to stdout via `sys.stdout.write(...)` (no trailing newline added beyond what the constant contains; each constant ends with a newline before the closing `'''`).
- **Human output:** The exact verbatim script for the requested shell.
    - zsh: begins `#compdef remctl`, defines `_remctl()` with a `local -a commands=( ... )` array of 47 `'name:description'` entries (in the source order: lists, smart-lists, templates, template-info, show, add, done, undone, edit, delete, search, today, upcoming, overdue, flagged, urgent, flag, unflag, tags, subtasks, info, sections, stats, link, open, export, import, list-symbols, list-create, smart-list-create, smart-list-edit, smart-list-delete, template-create, template-apply, template-delete, list-edit, list-pin, list-unpin, list-rename, list-delete, onboard, doctor, setup, permissions, completion), a `case "$words[2]" in` block with per-command `_arguments` specs, ends with `_describe 'command' commands`, `}` and `compdef _remctl remctl`.
    - bash: begins `_remctl() {`, sets `commands="lists smart-lists ... completion"` (space-separated, same 45 commands listed once), an `if/elif` chain on `"${COMP_WORDS[1]}"` for per-command flag lists via `compgen -W`, ends with `complete -F _remctl remctl`.
    - fish: begins `# Fish completion for remctl`, a long sequence of `complete -c remctl -n "__fish_use_subcommand" -a <cmd> -d "<desc>"` lines followed by `complete -c remctl -n "__fish_seen_subcommand_from <cmd>" ...` flag lines.
- **JSON output (--json):** Not supported — no `--json` flag on this subcommand. (If `--format json` is passed globally, `cmd_completion` ignores it and still emits the raw script.)
- **Exit/errors:** Invalid shell values are rejected by argparse `choices` (exit 2, argparse usage error) before the handler. If somehow `get_completion_script` raises `ValueError` (e.g. handler reached with an unsupported shell), it prints to stderr `Error: <exc>. Use bash, zsh, or fish.` and exits 1. Note `get_completion_script` raises `ValueError(f"Unsupported shell '{shell}'")`, so the full message would be e.g. `Error: Unsupported shell 'xyz'. Use bash, zsh, or fish.`
- **Parity notes:** Default shell when positional omitted is `"zsh"` (handler also re-defaults to `"zsh"` if attr missing). The three scripts are large static blobs that must be reproduced byte-for-byte for parity (full bodies captured above at remctl lines 6410–6708 zsh, 6710–6782 bash, 6784–6949 fish). Output goes to stdout with no added newline. Note: bash `commands` string and the zsh/fish command lists are maintained separately and can drift from the real subparser set — Swift port should embed the same literal text, not regenerate from the command table.

### `doctor`

- **Summary:** Run environment/runtime diagnostics for the CLI and report ok/warn/fail per check; non-zero exit on any failure.
- **Positional args:** none.
- **Options:**
    - `--for-agent` — flag (no value) — default `False` — adds agent-focused TCC guidance (an `agent_note` key in JSON and an "Agent note:" line + uses `remctl doctor --for-agent` as the rerun command in the database fix text).
    - `--json` — flag (no value) — default `False` (via `js(c)`) — emit JSON instead of human report. Also enabled by global `--format json`.
- **Reads:** Filesystem and process state only — no SQL. Specifically: `sys.platform`, `platform.system()/mac_ver()/release()/python_version()`, `sys.version_info`, `STORE_DIR.exists()` and readability (`os.access(STORE_DIR, os.R_OK)` via `reminders_store_access_error()`), `find_main_db_path()` (globs `STORE_DIR/Data-*.sqlite`, picks largest by `st_size`), `shutil.which("remctl")`, existence+`os.access(..., os.X_OK)` of bridge/private/permissions helper paths, `CONFIG_DIR.exists()`, `$SHELL` (via `detect_shell_name()`), and completion target path existence. Execution context probes process ancestry via `ps` and `$TERM_PROGRAM`, optionally `mdfind` for app bundles.
- **Writes:** none. (No EventKit, no DB write, no `open`.)
- **Human output (no --json):**
    - `RemCTL doctor` (bold)
    - `Context: <effective_context or 'unknown'>`
    - `Python: <sys.executable>`
    - If parent process known: `Parent process: <name> (pid <pid>)`
    - If host_app: `Host app: <host_app>`
    - If terminal_app: `Terminal app: <terminal_app>`
    - If `--for-agent`: `Agent note: \`doctor\` must pass in the same context that will run the write; Terminal may be green while this runner is blocked.`
    - blank line
    - Then `print_check_report(None, checks)`: for each check a line `[<STATUS>] <name>: <detail>` where STATUS is colored `OK` (green, code 32), `WARN` (yellow, 33), or `FAIL` (red, 31); each non-empty `fix` printed on following lines indented 6 spaces and dimmed (code 2), split on `\n`. Final summary line: `<N> checks, <W> warning(s), <F> failure(s)` colored red if any failures, else yellow if any warnings, else green. Pluralization: `warning`/`warnings`, `failure`/`failures` (singular when count == 1).
    - Checks emitted in this fixed order with these exact names: `platform`, `python`, `store_dir`, `database`, `cli`, `bridge`, `private_helper`, `permissions_helper`, `config_dir`, `completion`.
    - Exact detail/fix strings (verbatim):
        - platform: detail `<system> <mac_ver|release>`; fail fix `RemCTL only supports macOS.`
        - python: detail `<python_version>`; fail fix `Install Python 3.10 or newer.` (ok requires `>= (3,10)`).
        - store_dir: detail `<STORE_DIR>`; fail fix `Set REMCTL_STORE_DIR if your Reminders store lives elsewhere.`
        - database: if store unreadable, status `fail`, detail = the `reminders_store_access_error()` text `Direct CLI reads are blocked because the Reminders store at <STORE_DIR> is not readable from this process context (<sys.executable>). This usually means Full Disk Access is missing for the app or interpreter that is running remctl here.`, fix = `full_disk_access_fix_text(rerun_command="remctl doctor --for-agent", mention_onboard=True)` (multi-line, see below). Else status ok if db_path found (detail = path), else fail detail `No Reminders database found` fix `Enable iCloud Reminders and open Reminders.app once, or run remctl onboard.`
        - cli: detail `<current_cli_path()>`; ok iff `cli_path.exists()`; fix (when `remctl` not on PATH) `Add <cli_path.parent> to PATH.`
        - bridge: status `ok`/`warn` (never fail); detail `<current_bridge_path()>`; warn fix `Run ./install.sh or compile remctl-bridge.swift with swiftc, then run remctl onboard.`
        - private_helper: ok/warn; detail `<current_private_path()>`; warn fix `Run ./install.sh to compile remctl-private, or avoid --private writes.`
        - permissions_helper: ok/warn; detail `<current_permissions_path()>`; warn fix `Run ./install.sh to compile remctl-permissions for the guided Full Disk Access flow.`
        - config_dir: ok/warn; detail `<CONFIG_DIR>`; warn fix `Run remctl setup to create config files.`
        - completion: if `$SHELL` name in {zsh,bash,fish}: detail `<shell>: <completion_target_path>`, ok iff path exists, warn fix `Run remctl setup --shell <shell> to install completion.`; else status warn, detail `Unsupported shell '<shell>'`, fix `Run remctl setup --shell zsh|bash|fish.`
    - `full_disk_access_fix_text` body (joined with `\n`): line1 = intro (`mention_onboard=True` → `\`remctl onboard\` can open a guided permission helper, but macOS still requires you to add the access target manually.`); `Current execution context: <effective_context> (<sys.executable>).`; `A green \`remctl doctor\` in Terminal does not grant access to a separate agent or app runner.`; `For the guided flow, run: remctl permissions full-disk-access`; `Open System Settings > Privacy & Security > Full Disk Access and add:`; then each target indented 2 spaces; `Tip: click +, press Command-Shift-G, paste the path, press Return, then click Open.`; `Then relaunch the app or terminal that will run remctl and rerun \`remctl doctor --for-agent\` from that same context.`
- **JSON output (--json):** `print(json.dumps(result, indent=2))` where `result` keys (in this order): `ok` (bool, `fail_count == 0`), `warnings` (int), `failures` (int), `context` (object), `checks` (array). With `--for-agent`, additionally `agent_note` (string) = `This report only applies to the process context shown in \`context\`. \`doctor\` must pass in the same context that will run the write. Terminal and Codex or other agent runners can have different Full Disk Access grants.`(inserted before the json-vs-human branch, so it appears after`checks`in dict order). Each check object:`{"name","status","detail","fix"}` (`fix`is`null`when absent).`context`object keys:`python`(sys.executable),`pid`, `parent_process`(object`{pid,ppid,name,command}`or null),`terminal_app`(string or null),`host_app`(string or null),`effective_context`(e.g. "Terminal", "Codex", an app name without`.app`, or "unknown"). JSON differs from human: human omits the raw `fix`/`status`fields formatting and renders colored labels; JSON includes raw`ok/warnings/failures`, `pid`, full `parent_process`, and the literal `agent_note`.
- **Exit/errors:** Exits `1` if `fail_count` (number of checks with status `"fail"`) > 0; otherwise exit 0 (warnings do not fail). No explicit stderr error text in the handler.
- **Parity notes:** (1) Only `status == "fail"` checks affect exit code, never `warn`. (2) bridge/private*helper/permissions_helper/config_dir/completion can only be `ok` or `warn` — they never `fail`. (3) `python` ok threshold is `>= (3,10)`. (4) database "ok" requires the \_largest* `Data-*.sqlite` by file size; tie-broken by `sorted(..., reverse=True)` (Python stable sort). (5) Execution-context detection: walks `os.getppid()` ancestry up to 8 levels via `ps -o ppid= -o ucomm= -o command=`; `$TERM_PROGRAM` normalized via `KNOWN_TERMINAL_APPS` map (case-insensitive, stripped); a process name containing `codex` (case-insensitive) maps host_app to `Codex.app` and effective_context to `Codex`; `effective_context` strips a trailing `.app`. (6) `current_cli_path()` resolves `shutil.which("remctl")` then falls back to `Path(__file__).resolve()`. (7) Env overrides honored: `REMCTL_STORE_DIR`, `REMCTL_CONFIG_DIR`/`XDG_CONFIG_HOME`, `REMCTL_BRIDGE_PATH`, `REMCTL_PRIVATE_PATH`, `REMCTL_PERMISSIONS_PATH`. (8) Color disabled when `--no-color` or `NO_COLOR` set or stdout not a TTY (set in main before dispatch). (9) `doctor` is in `AUTO_ONBOARD_SKIP_COMMANDS`, so first-launch auto-onboarding never fires for it.

### `onboard`

- **Summary:** Open Reminders.app, trigger EventKit + AppleScript permission prompts, verify direct DB readiness, and (if Full Disk Access missing) launch the guided permission helper or print guidance.
- **Positional args:** none.
- **Options:** `--json` — flag — default `False` (via `js(c)`) — emit JSON. Also enabled by global `--format json`.
- **Reads:** No SQL. Runs `open -a Reminders` (15s timeout, then `time.sleep(1)`); invokes bridge with `{"action":"authorize"}` via `bridge_call_result` (reads `payload.status`, `calendarCount`, `defaultList`, `message`, plus `returncode`/`stderr`); runs AppleScript `tell application "Reminders" to get name of default list` via `osascript` (30s timeout); checks `reminders_store_access_error()` and `find_main_db_path()`.
- **Writes:** EventKit (authorization trigger via bridge); AppleScript(osascript) (automation probe + opens Reminders via `open -a`); writes onboarding state file. `open` is used to launch Reminders.app. If FDA missing it may launch the `remctl-permissions` helper subprocess (which itself opens System Settings) or fall back to `open_full_disk_access_settings()` (tries `x-apple.systempreferences:` URLs). **State write:** always writes `<CONFIG_DIR>/onboard-state.json` (creating `CONFIG_DIR`) via `write_onboard_state` with JSON `{"version", "seenAt" (ISO seconds), "auto" (False here), "ok", "warnings", "failures"}` + trailing newline.
- **Human output (no --json):**
    - `RemCTL onboard` (bold)
    - `Approve any macOS prompts for Reminders or Automation access.` (dim)
    - blank line
    - `print_check_report(None, result["checks"])` — same format as doctor (see above), in this fixed check order/names: `open_reminders`, `eventkit`, `automation`, `database`.
    - Then, if the `database` check needs FDA guidance (`needs_full_disk_access_guidance`: true when "Full Disk Access" appears in its `fix` or `detail`): try `launch_full_disk_access_helper(include_cli=True)`; on success print `print_permission_helper_opened()` block:
        - blank line; `Guided Full Disk Access` (bold); `  Opened the RemCTL permission helper.` (dim); `  It opens System Settings, copies the first target path, and provides draggable targets.` (dim); `  In the file picker, press Command-Shift-G if drag-and-drop is not accepted.` (dim).
        - On failure, call `print_full_disk_access_guidance(settings_opened=open_full_disk_access_settings(), rerun_command="remctl doctor")` (note: this attempts to open Settings as a side effect). Output: blank line; `Full Disk Access` (bold); either `  Opened System Settings > Privacy & Security > Full Disk Access.` or `  Open System Settings > Privacy & Security > Full Disk Access.` (dim); `  macOS requires you to add the access target manually for this process context.`; `  Current context: <effective_context|unknown> (<sys.executable>)`; per-target `  Add: <target>`; clipboard line `  Copied path to clipboard: <python_path>` (or `  Copy this path if you need the file picker: <python_path>` if pbcopy failed); `  In the file picker, press Command-Shift-G, paste the path, press Return, then click Open.`; `  Then relaunch the app or terminal that will run remctl and rerun \`remctl doctor\`.`
    - Per-check exact strings:
        - open_reminders: ok detail `Opened Reminders.app.`; warn variants: `Opening Reminders.app timed out.` / `Could not open Reminders.app: <exc>` / stderr-or-`open -a Reminders failed.`, fix `Open Reminders.app manually, then rerun \`remctl onboard\`.`
        - eventkit: warn (helper missing) `<bridge_path> is unavailable.` fix `Run ./install.sh to install remctl-bridge, then rerun \`remctl onboard\`.`; warn (bad response) `<bridge_path> did not return a valid authorization response.`fix`Rebuild remctl-bridge with ./install.sh, then rerun \`remctl onboard\`.`; ok detail `Reminders access granted to <bridge_path>`+ optional` (<N> list(s), default: <defaultList>)`+`.`; fail detail = payload message/stderr/`Reminders authorization failed.`, fix `Re-run \`remctl onboard\` from the same terminal and click Allow when macOS asks for Reminders access.`
        - automation: ok `AppleScript automation access confirmed.` or `AppleScript automation access confirmed (default list: <name>).`; warn timeout/OSError/failure variants with fix `Re-run \`remctl onboard\` from the same terminal and approve the Automation prompt if macOS asks. Flagged operations and AppleScript fallback writes rely on this access.` (the OSError/timeout fixes are shorter variants).
        - database: same as doctor's database check EXCEPT the fix uses `full_disk_access_fix_text(rerun_command="remctl doctor --for-agent")` with `mention_onboard=False` (intro line differs: `Full Disk Access is missing for this process context; macOS cannot grant it from the command line.`); "no db" fail fix here is `Enable iCloud Reminders and open Reminders.app once, then rerun \`remctl onboard\`.`
- **JSON output (--json):** `print(json.dumps(result, indent=2))` of `run_onboarding(auto=False)` result: keys `ok` (bool), `warnings` (int), `failures` (int), `checks` (array of `{name,status,detail,fix}`). NOTE: JSON does NOT include `context` or any FDA helper invocation; the helper-launch/guidance side effects only happen in the human branch (the `if getattr(a, "json", False)` skips them).
- **Exit/errors:** Exits `1` if `result["failures"]` > 0 (any check with status `"fail"` — i.e. eventkit fail or database fail). Warnings do not fail. No direct stderr error text from the handler (sub-probes print their own AppleScript errors only via `osa`, not used here).
- **Parity notes:** (1) Onboarding always writes `onboard-state.json` (with `"auto": false` for explicit `onboard`) — this state file gates first-launch auto-onboarding (`should_auto_onboard` returns false once it exists). (2) FDA helper/guidance side effects (launching `remctl-permissions`, opening System Settings, copying python path to clipboard via `pbcopy`) occur only in human (non-JSON) mode and only when the database check mentions "Full Disk Access". (3) `open -a Reminders` is followed by a 1-second `time.sleep`. (4) eventkit list-count pluralization: ` (N lists...)` vs ` (1 list...)`. (5) `onboard` is in `AUTO_ONBOARD_SKIP_COMMANDS`. (6) The rerun command embedded in onboarding's database fix is `remctl doctor --for-agent`, but the printed guidance rerun command is `remctl doctor` — two distinct strings.

### `permissions`

- **Summary:** Open the guided macOS Full Disk Access helper (or print guidance fallback) for the current process context.
- **Positional args:** `topic` — string — required — `choices=["full-disk-access"]`; the only permission flow supported.
- **Options:**
    - `--wait` — flag — default `False` — when launching the helper, run it synchronously (`subprocess.run`, success = returncode 0) instead of detached (`subprocess.Popen(..., start_new_session=True)`).
    - `--json` — flag — default `False` (via `js(c)`) — emit JSON describing targets without launching the helper. Also enabled by global `--format json`.
- **Reads:** No SQL. Reads `current_permissions_path()` existence + executability; builds `full_disk_access_target_specs(include_cli=True)` (uses execution context: `sys.executable`, host app bundle via `find_app_bundle`/`mdfind`, terminal app bundle).
- **Writes:** Launches the `remctl-permissions` helper subprocess (which opens System Settings + copies the first target path to clipboard and shows draggable targets), OR on fallback calls `open_full_disk_access_settings()` (runs `open <x-apple.systempreferences URL>`) and copies the current python path to clipboard via `pbcopy`. Classify as: `open` + external helper. No EventKit/DB writes.
- **Human output (no --json):**
    - If `launch_full_disk_access_helper(include_cli=True, wait=a.wait)` succeeds: prints `print_permission_helper_opened()` block (blank line; `Guided Full Disk Access` bold; `  Opened the RemCTL permission helper.`; `  It opens System Settings, copies the first target path, and provides draggable targets.`; `  In the file picker, press Command-Shift-G if drag-and-drop is not accepted.` — all dim) and returns.
    - Else prints `print_full_disk_access_guidance(settings_opened=open_full_disk_access_settings(), rerun_command="remctl doctor")` block (same as described in onboard's fallback above — blank line, `Full Disk Access` bold header, opened/open Settings line, manual-add line, current context line, `  Add: <target>` per target, clipboard line, file-picker tip, relaunch+rerun `remctl doctor` line).
- **JSON output (--json):** `print(json.dumps(result, indent=2))` then return immediately (helper is NOT launched in JSON mode). Keys: `helper` (str = `current_permissions_path()`), `available` (bool = `permission_helper_available()`, i.e. exists and X_OK), `targets` (array). Each target object: `{"title","path","subtitle"}` where `path` is `Path(...).expanduser().resolve(strict=False)` stringified; titles include `Current Python interpreter` (subtitle `Required when direct CLI reads cannot see the Reminders database.`), optionally the host `.app` (subtitle `Required when this host app launches remctl or an agent runner.`), optionally the terminal app (subtitle `Alternative target for direct CLI reads from this terminal app.`). Duplicate paths (case-insensitive) are de-duplicated.
- **Exit/errors:** If `topic != "full-disk-access"` → stderr `Error: Unsupported permissions topic '<topic>'` and `sys.exit(1)`. (In practice argparse `choices` blocks any other value with exit 2 first, so this branch is effectively unreachable via normal CLI but must be preserved.) Otherwise exit 0 (no failure exit even if helper launch fails — it just prints guidance).
- **Parity notes:** (1) `--wait` only changes helper launch mode (sync vs detached `start_new_session=True`); default is detached. (2) JSON mode never launches the helper or opens Settings — it is purely informational. (3) The helper is invoked with args: `--title "RemCTL Full Disk Access"`, `--subtitle "Drag these targets into System Settings, or use Command-Shift-G and paste the copied path."`, then `--target <title> <path> <subtitle>` per target, then `--after "Run Doctor" "<shlex-quoted cli path> doctor"`. (4) If `full_disk_access_target_specs` returns empty it retries with `include_cli=True`. (5) `current_permissions_path()` honors `REMCTL_PERMISSIONS_PATH` env override. (6) Target path resolution uses `resolve(strict=False)` and lowercased-path dedup. (7) `permissions` is in `AUTO_ONBOARD_SKIP_COMMANDS`.

### `setup`

- **Summary:** Create the RemCTL config directory (mode 0700) and install shell completion for the chosen/detected shell; optionally run doctor afterward.
- **Positional args:** none.
- **Options:**
    - `--shell` — takes value — `choices=["auto","bash","zsh","fish","skip"]`, default `"auto"` — which shell completion to install. `auto` detects from `$SHELL`; `skip` installs none.
    - `--doctor` — flag — default `False` — run doctor after setup (adds a `doctor` block to JSON; in human mode prints the full `cmd_doctor` human report).
    - `--json` — flag — default `False` (via `js(c)`) — emit JSON. Also enabled by global `--format json`.
- **Reads:** No SQL. `detect_shell_name()` reads `$SHELL` env (basename; defaults to `"zsh"` if unset). With `--doctor`, runs `gather_doctor_checks()` (all the doctor reads).
- **Writes:** Filesystem only: `CONFIG_DIR.mkdir(parents=True, exist_ok=True)` then `chmod(0o700)` (OSError ignored). Writes the completion script to the shell's target path via `install_completion` (`target.parent.mkdir(parents=True, exist_ok=True)` then `target.write_text(script)`). Target paths: zsh → `~/.zsh/completions/_remctl`; bash → `~/.local/share/bash-completion/completions/remctl`; fish → `~/.config/fish/completions/remctl.fish`. Not EventKit/DB/AppleScript.
- **Human output (no --json):**
    - `RemCTL setup` (bold)
    - `Config directory: <CONFIG_DIR>`
    - `Shell completion: <completion_path>` if a shell was installed, else `Shell completion: skipped`
    - blank line
    - `Next:`
    - `  1. remctl onboard   # trigger macOS Reminders and Automation prompts`
    - `  2. remctl permissions full-disk-access   # visual Full Disk Access setup`
    - `  3. remctl doctor    # verify the CLI`
    - If `--doctor`: blank line then the full human doctor report via `cmd_doctor(SimpleNamespace(json=False))` (NOTE: this re-runs doctor; that nested call can itself `sys.exit(1)` on failures, terminating setup — see errors).
- **JSON output (--json):** `print(json.dumps(result, indent=2))`. Keys (order): `ok` (always `True`), `config_dir` (str), `completion_shell` (`None` if shell resolved to `"skip"`, else the shell name string), `completion_path` (str path or `None`). With `--doctor`: additionally `doctor` = `{"ok": <bool, no fails>, "checks": [...]}` (note: this nested doctor object does NOT include `warnings`/`failures`/`context` keys — only `ok` and `checks`, unlike the top-level `doctor --json` shape). JSON differs from human: human shows the "Next:" steps and (with `--doctor`) the full colored doctor report; JSON shows the structured result and an embedded doctor checks array.
- **Exit/errors:** If `install_completion` raises `ValueError` (unsupported shell), prints stderr `Error: <exc>` and `sys.exit(1)`. In `--doctor` + human mode, the nested `cmd_doctor(SimpleNamespace(json=False))` call will `sys.exit(1)` if any doctor check fails (so setup exits non-zero on doctor failures). In `--doctor` + JSON mode, doctor failures do NOT cause non-zero exit (the nested `cmd_doctor` is not invoked; only `gather_doctor_checks()` runs). Otherwise exit 0.
- **Parity notes:** (1) `resolve_setup_shell`: if `--shell` != `auto`, returns it verbatim (including `skip`); if `auto`, returns `$SHELL` basename if in {zsh,bash,fish} else `"skip"`. `detect_shell_name()` defaults to `"zsh"` when `$SHELL` unset. (2) `CONFIG_DIR` honors `REMCTL_CONFIG_DIR`/`XDG_CONFIG_HOME` overrides; chmod 0700 best-effort. (3) Completion target paths are fixed absolute-under-`$HOME` locations (above) — Swift must mkdir parents and overwrite. (4) The `--doctor` human path actually executes a second doctor run that can short-circuit the process with exit 1; the JSON `--doctor` path embeds a _different_ (smaller) doctor shape and never exits non-zero. (5) `completion_shell` is `null` only when resolved shell == `"skip"`. (6) `setup` is in `AUTO_ONBOARD_SKIP_COMMANDS`.

**Cross-cutting env/global notes (apply to all five):** Global flags parsed at top-level parser: `--version` (prints `VERSION` = `"1.0.3"`), `--no-color`, `--format {plain,table,json}` (default `plain`; `--format json` is propagated to `a.json = True`). Color is disabled when `--no-color` OR `NO_COLOR` env set OR stdout is not a TTY (`C.enabled=False` → ANSI codes omitted). All five commands are in `AUTO_ONBOARD_SKIP_COMMANDS = {"completion","doctor","onboard","permissions","setup"}`, so first-launch auto-onboarding never triggers for them. `REMCTL_SKIP_ONBOARD` env also disables auto-onboard globally. Unknown command tokens are caught before dispatch with stderr `remctl: error: unknown command: '<token>'`, an optional `Did you mean: remctl <suggestion>` (suggestion logic: `symbols`→`list-symbols`, or unique `*-<token>` suffix match), an `Available commands:` column listing, `Run \`remctl <command> --help\` for command-specific options.`, and `sys.exit(2)`.

## Program scaffolding

<!-- recon: core:skeleton (agent-a607c4ad08fd854c7) -->

I have all the data I need. Let me verify the `as_date` continuation and the splash/color usage once more, plus confirm there is genuinely no `--store`/`--config`/`--json` at the root level. I've already confirmed the root parser only has `--version`, `--no-color`, `--format`. The `--json` flag is per-subcommand via `js(c)`. Let me write the structured report.

### (1) argparse root parser, program description, global flags

Defined in `def main()` at line 7608 of `/Users/orion/Developer/Playgrounds/remctl/remctl`.

Root parser:

```python
p = argparse.ArgumentParser(
    prog="remctl",
    description="Power-user Reminders CLI — reads sections/subtasks/tags/attachments/colors, "
                "writes via remctl-bridge (EventKit) with AppleScript fallback.",
    epilog=(...),                 # multi-line "Normal setup flow:" + "Examples:" block
    formatter_class=HelpFormatter,
)
```

`HelpFormatter` (line 81) subclasses `argparse.RawDescriptionHelpFormatter` and `argparse.ArgumentDefaultsHelpFormatter`.

Global (root-level) flags — these are the ONLY three options on the root parser (lines 7635-7638):

- `"--version"` — `action="version", version=VERSION`
- `"--no-color"` — `action="store_true", help="Disable color output"`
- `"--format"` — `choices=["plain", "table", "json"], default="plain", help="Output format"`

Subparsers: `sub = p.add_subparsers(dest="cmd", metavar="command")` (line 7640). `dest="cmd"` is the routing key.

Per-subcommand flag helpers defined as nested closures inside `main()` (lines 7642-7651):

- `js(c)` → adds `"--json"`, `action="store_true", help="Output machine-readable JSON"`
- `display_format(c)` → adds `"--format"` with `dest="command_format"`, `choices=["plain","table","json"]`, `default=None`, `help="Output format for this read command"`
- `vb(c)` → adds `"-v"/"--verbose"`, `action="store_true"`

INSUFFICIENT DATA for `--store`, `--config`, `--json` _as global flags_: they do NOT exist at the root parser. `--json` exists only per-subcommand (via `js(c)`). There is NO `--store` or `--config` flag anywhere; store/config dirs are resolved purely from env vars (see area 5). The Swift port must NOT add `--store`/`--config` flags to match parity.

`--private` / `--private-metadata` are per-subcommand flags (not global) gating private ReminderKit writes (referenced at line 2062 via `getattr(a, "private", ...)` and `getattr(a, "private_metadata", ...)`).

### (2) main()/dispatch flow and how cmd\_ handlers are wired

Flow inside `main()` (lines 8116-8215):

1. `command_token = first_command_token(sys.argv[1:])` (line 8117). `first_command_token` (line 7580) walks argv, returns `None` if it hits `-h`/`--help`/`--version`, skips the value after `--format`, skips `--format=...`, `--no-color`, and any `-`-prefixed token; returns first bare token.
2. If `command_token` is set but not in `sub.choices`: prints `remctl: error: unknown command: {command_token!r}` to stderr, then `suggest_command(command_token, sub.choices)` (line 7599; maps `"symbols"`→`"list-symbols"`, or a unique `-{command}` suffix match), prints `Did you mean: remctl {suggestion}`, `Available commands:` plus columns from `format_command_columns` (line 7564, width 88), then `Run \`remctl <command> --help\` for command-specific options.`and`sys.exit(2)`.
3. `a = p.parse_args()` (line 8128).
4. Per-command `command_format` override: `if command_format: a.format = command_format` (lines 8129-8131).
5. Color setup (line 8134): `if a.no_color or os.environ.get("NO_COLOR") or not sys.stdout.isatty(): C.enabled = False`.
6. JSON propagation (lines 8138-8141): if `a.format == "json"`, sets `a.json = True`.
7. `maybe_run_first_launch_onboarding(a)` (line 8143).
8. No-command case (lines 8146-8156): if `not a.cmd`, sets `a.no_overdue=False`, `a.verbose=False`; if `a.format=="json"` sets `a.json=True` and runs `cmd_today`; else `a.json=False`, `show_splash()`, then `cmd_today`. Both via `run_handler_with_fallback`.
9. Dispatch: a literal dict `cmds` (lines 8163-8209) maps each command string to its `cmd_*` handler function. `handler = cmds.get(a.cmd)`; if found, `run_handler_with_fallback(a, handler)`; else `p.print_help()`.

The dispatch is a **string→function dict**, NOT argparse `set_defaults(func=...)`. (Confirmed: no `set_defaults`/`func=` wiring exists.) Full mapping (line 8163):
`"lists":cmd_lists, "smart-lists":cmd_smart_lists, "templates":cmd_templates, "template-info":cmd_template_info, "show":cmd_show, "add":cmd_add, "done":cmd_done, "undone":cmd_undone, "edit":cmd_edit, "delete":cmd_delete, "search":cmd_search, "today":cmd_today, "flagged":cmd_flagged, "urgent":cmd_urgent, "tags":cmd_tags, "subtasks":cmd_subtasks, "info":cmd_info, "sections":cmd_sections, "stats":cmd_stats, "link":cmd_link, "open":cmd_open, "flag":cmd_flag, "unflag":cmd_unflag, "upcoming":cmd_upcoming, "overdue":cmd_overdue, "list-symbols":cmd_list_symbols, "list-create":cmd_list_create, "smart-list-create":cmd_smart_list_create, "smart-list-edit":cmd_smart_list_edit, "smart-list-delete":cmd_smart_list_delete, "template-create":cmd_template_create, "template-apply":cmd_template_apply, "template-delete":cmd_template_delete, "list-edit":cmd_list_edit, "list-pin":cmd_list_pin, "list-unpin":cmd_list_unpin, "list-rename":cmd_list_rename, "list-delete":cmd_list_delete, "export":cmd_export, "import":cmd_import, "onboard":cmd_onboard, "doctor":cmd_doctor, "setup":cmd_setup, "permissions":cmd_permissions, "completion":cmd_completion`.

`run_handler_with_fallback(args, handler)` (line 7301): wraps `handler(args)` in `try/except RemindersDBUnavailable as exc`, printing `Error: {exc}` to stderr and `sys.exit(1)`. This is the single DB-unavailability guard around every command. Entrypoint: `if __name__ == "__main__": main()` (line 8218).

### (3) VERSION, APPLE_EPOCH, and the ts()/timestamp-conversion helpers

- `VERSION = "1.0.3"` (line 47).
- `APPLE_EPOCH = 978307200` (line 49) — seconds between Unix epoch (1970-01-01) and Apple/CoreData epoch (2001-01-01 UTC).

Conversion helpers (lines 202-207):

```python
def ts(v):
    if not v: return None
    return datetime.fromtimestamp(v + APPLE_EPOCH)

def to_ts(dt):
    return dt.timestamp() - APPLE_EPOCH
```

- `ts(v)`: CoreData seconds → Python `datetime`. Falsy input (`None`, `0`, `0.0`) returns `None`. Uses `datetime.fromtimestamp` with NO tz argument → returns a **naive datetime in the system local timezone** (Apple stores the value as a Unix offset once `APPLE_EPOCH` is added). The Swift port must convert to local time, not UTC.
- `to_ts(dt)`: inverse — `dt.timestamp()` (interprets a naive `dt` as local) minus `APPLE_EPOCH` → CoreData-epoch seconds.

Note: window helpers in `remctl_runtime.py` (`start_of_day`, `due_today_window`, `upcoming_window`) operate on `datetime.now()` (naive local) and feed `to_ts` for DB comparisons; `upcoming_window(days)` returns `(sod, sod + timedelta(days=days+1))` (note the `+1`).

### (4) priority name maps and other module-level constants

Priority maps (lines 209-210):

```python
PRI      = {0: "", 1: "!!!", 5: "!!", 9: "!"}      # symbol display
PRI_NAME = {0: "none", 1: "high", 5: "medium", 9: "low"}   # name display
```

Note the encoding: 1=high, 5=medium, 9=low, 0=none (matches Apple's `priority` integers).

Other module-level constants in `remctl`:

- `STORE_DIR = resolve_store_dir()` (50); `BRIDGE_PATH` (51), `PRIVATE_PATH` (52), `PERMISSIONS_PATH` (53) via `resolve_binary_path(__file__, name, env_var)`; `CONFIG_DIR = resolve_config_dir("remctl")` (54); `ONBOARD_STATE_FILE = CONFIG_DIR / "onboard-state.json"` (55).
- `AUTO_ONBOARD_SKIP_ENV = "REMCTL_SKIP_ONBOARD"` (56).
- `AUTO_ONBOARD_SKIP_COMMANDS = {"completion", "doctor", "onboard", "permissions", "setup"}` (57).
- `FULL_DISK_ACCESS_SETTINGS_URLS` (58) — two `x-apple.systempreferences:` URLs.
- `KNOWN_TERMINAL_APPS` (62) — dict mapping `TERM_PROGRAM` values → `.app` bundle names.
- `TERMINAL_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f\u2028\u2029]")` (122).
- `LOGO_LINES` (133), `LOGO_COLORS` (141) — splash ASCII + 5 RGB tuples.
- `LIST_COLOR_MAP` (214) — 10 named colors → RGB tuples (red `(255,41,104)`, orange `(255,141,40)`, yellow `(255,204,0)`, green `(99,218,56)`, blue `(0,136,255)`, purple `(204,115,225)`, brown `(162,132,94)`, gray `(91,98,106)`, cyan `(90,200,250)`, teal `(48,176,199)`).
- `HEX_COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")` (227).
- `OFFICIAL_LIST_SYMBOLS` (229) — list of `(name, "ListBadge..." identifier, glyph)` tuples; `OFFICIAL_LIST_SYMBOL_NAMES` (303) = set of names.
- `GROCERY_LIST_MARKER = "🥕"` (451); `GROCERY_CATEGORY_EMOJI` (661) dict.
- `_RECURRENCE_COLS` (1213), `_REMINDER_COLUMN_CACHE = {}` (1225).
- Imported module-level constants: from `remctl_serialization` — `DUE_DATE_DELTA_UNITS`; from `remctl_smart_lists` — `CUSTOM_SMART_LIST_TYPE`; from `remctl_runtime` — `DEFAULT_STORE_SUBPATH = Path("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores")` and `TRUTHY = {"1","true","yes","on"}`.

### (5) environment variables read, config/store dir resolution

Env vars read across the codebase:

- `REMCTL_STORE_DIR` — `resolve_store_dir()` (`remctl_runtime.py:27`). If set, `Path(override).expanduser()`; else `Path.home() / DEFAULT_STORE_SUBPATH` = `~/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores`.
- `REMCTL_CONFIG_DIR` — `resolve_config_dir()` (`remctl_runtime.py:34`). Precedence: `REMCTL_CONFIG_DIR` (expanduser) → else base from `XDG_CONFIG_HOME` (expanduser) or `~/.config` → `base / app_name` (`app_name="remctl"`). So default config dir is `~/.config/remctl`.
- `XDG_CONFIG_HOME` — read in `resolve_config_dir` (`remctl_runtime.py:37`) as the base when `REMCTL_CONFIG_DIR` is unset.
- `REMCTL_BRIDGE_PATH`, `REMCTL_PRIVATE_PATH`, `REMCTL_PERMISSIONS_PATH` — passed as the `env_var` arg to `resolve_binary_path` (`remctl:51-53`), and re-read directly in `current_bridge_path`/`current_private_path`/`current_permissions_path` (`remctl:7002,7014,7026`). `resolve_binary_path` precedence (`remctl_runtime.py:66`): env override → `script_dir/name` → `script_dir/bin/name` → `~/bin/name` → `~/.local/bin/name` → `shutil.which(name)` → fallback `script_dir/name`.
- `REMCTL_SKIP_ONBOARD` (via `AUTO_ONBOARD_SKIP_ENV`) — `should_auto_onboard` (`remctl:3692`); if truthy-present, skips auto-onboard.
- `NO_COLOR` — `main()` (`remctl:8134`); any non-empty value disables color.
- `TERM_PROGRAM` — `remctl:3184` (terminal-app detection for permission prompts).
- `SHELL` — `remctl:6962` (completion-shell autodetect).
- `env_bool(name, default)` helper (`remctl_runtime.py:19`) parses truthy via `TRUTHY = {"1","true","yes","on"}` (lowercased, stripped). INSUFFICIENT DATA: `env_bool` is defined but no call site for it was found in `remctl` itself; the Swift port should still replicate the `TRUTHY` semantics for any boolean env handling.

DB resolution: `find_main_db_path()` (`remctl:191`) globs `STORE_DIR/"Data-*.sqlite"`, sorts by file size descending, returns the largest (or `None`). `open_db()` (`remctl:197`) opens `sqlite3.connect(f"file:{find_main_db()}?mode=ro", uri=True)` read-only with `row_factory = sqlite3.Row`. `reminders_store_access_error()` (`remctl:171`) returns a guidance string if `STORE_DIR` exists but is not `os.R_OK` readable (Full Disk Access missing).

### (6) bridge/private invocation wrappers and osascript/AppleScript fallback

Bridge (EventKit helper) — `remctl:2023-2055`:

- `bridge_available()`: `BRIDGE_PATH.exists() and BRIDGE_PATH.stat().st_mode & 0o111` (exists + any execute bit).
- `bridge_call_result(data, timeout=30)`: runs `subprocess.run([str(BRIDGE_PATH)], input=json.dumps(data), capture_output=True, text=True, timeout=timeout)`. argv is just the binary path; the request is JSON on **stdin**. On `subprocess.TimeoutExpired | FileNotFoundError | OSError` returns `None`. Otherwise parses `proc.stdout` as JSON (swallowing `json.JSONDecodeError`→`payload=None`) and returns dict `{"returncode","stdout","stderr","payload"}`.
- `bridge_call(data)`: returns `result["payload"]` only when `result and returncode==0 and isinstance(payload, dict)`, else `None`.

Private (ReminderKit helper) — `remctl:2067-2139`:

- `private_metadata_enabled(a)`: True if `a.private` or `a.private_metadata` (`remctl:2060`).
- `private_available()`: same exists+exec-bit check as bridge (`remctl:2067`).
- `private_call_result(data, timeout=30)`: identical structure to `bridge_call_result` but uses `PRIVATE_PATH` (`remctl:2072`).
- `private_call(data)`: returns `payload` when `isinstance(payload, dict)` — note it does NOT require `returncode==0` (differs from `bridge_call`) (`remctl:2096`).
- `private_helper_error_is_transient(result)` (`remctl:2104`): True if `result` is a dict whose `message` contains the substring `"communicate with a helper application"`.
- `private_create_list_call(request, name, attempts=3)` (`remctl:2111`): retry loop. Returns immediately on `status=="created"` or non-transient error. On transient error, re-reads the DB up to 4 times (`time.sleep(0.25)` each) via `q_list_exact_name_count(open_db(), name)`; if the list now exists, returns a recovered dict with `status:"created"`, `action`, `name`, `verifiedAfterTransientError:True`. Backoff between attempts `time.sleep(0.75 * (attempt + 1))`.
- `require_private_metadata(a)` (`remctl:2142`): if not opted in → stderr `Error: private metadata writes require --private.` + `sys.exit(1)`; if helper missing → stderr `Error: remctl-private is unavailable. Reinstall or set REMCTL_PRIVATE_PATH.` + `sys.exit(1)`.

AppleScript fallback — `remctl:3725-3818`:

- `osa(script)` (`3725`): `subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=30)`. On `TimeoutExpired` → stderr `Error: AppleScript timed out (Reminders.app may be unresponsive)` + `sys.exit(1)`. On nonzero return → stderr `AppleScript error: {r.stderr.strip()}` + `sys.exit(1)`. Returns `r.stdout.strip()`. **This is fatal/exit-on-error.**
- `osa_by_id(list_name, rem_id, action)` (`3755`): builds `tell application "Reminders" / tell list "<esc>" / set r to (first reminder whose id is "<esc>") / <action> / end tell / end tell`, runs through `osa`.
- `osa_by_id_try(list_name, rem_id, action, timeout=120)` (`3766`): **non-fatal** variant; returns `True` on returncode 0, `False` on nonzero or `TimeoutExpired`. Generous 120s timeout (comment: Reminders AppleScript can take 30–90s on busy stores). Used for AppleScript-first write paths that fall back to bridge.
- `create_list_with_applescript(name)` (`3737`) → `{"status":"created","id":rid,"fallback":"applescript"}`; `delete_list_with_applescript(name)` (`3747`) → `{"status":"deleted","fallback":"applescript"}`.
- `esc(s)` (`3787`): escapes for AppleScript double-quoted literals — `\`→`\\`, `"`→`\"`, then replaces `\r \n \t U+0085 U+2028 U+2029` with spaces, then replaces any remaining char `< 0x20` with a space.
- `applescript_date_var(dt, varname="d")` (`3798`) / `as_date_assign(dt, target="due date of r")` (`3814`): build locale-neutral date by numeric field assignment (`set year of d to ...`, month/day/hours/minutes/seconds) rather than `date "..."` string parsing (locale-dependent). Swift port must reproduce numeric field assignment for locale safety.

Other osascript probe wrappers: `applescript_access_check_for_onboarding` (`remctl:3604`) runs an automation probe with `timeout=30`; onboarding/permission helpers at lines ~3193, 3222, 3310, 3408-3429, 3530 use `timeout=5`/`15`/`30` with `OSError, subprocess.TimeoutExpired` handling. Doctor/onboarding constructs `bridge_access_check_for_onboarding` (`remctl:3562`) and `applescript_access_check_for_onboarding` (`remctl:3604`); the latter emits messages like `AppleScript automation probe timed out while talking to Reminders.app.`, `Could not run osascript: {exc}`, `AppleScript automation access confirmed.` / `... (default list: {default_list}).`, `AppleScript automation probe failed.`

### (7) terminal control-character neutralization, color/ANSI handling

Control-char neutralization (`remctl:122-129`):

```python
TERMINAL_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f\u2028\u2029]")

def safe_display(value):
    """Return text safe to print in a terminal while preserving JSON/raw data."""
    if value is None:
        return ""
    return TERMINAL_CONTROL_RE.sub(" ", str(value))
```

- `safe_display` replaces all C0 controls (`\x00-\x1f`), DEL+C1 (`\x7f-\x9f`), and line/paragraph separators (`U+2028`, `U+2029`) with a single space; `None`→`""`. This is for HUMAN output only — JSON/raw paths must NOT use it (so JSON preserves original data).
- Companion predicate in runtime: `is_safe_terminal_text(text)` (`remctl_runtime.py:148`) returns False if any char is `< 0x20` or in `0x7F–0x9F` (note: this one does NOT flag `U+2028/U+2029`, unlike the regex).

Color/ANSI handling — class `C` (`remctl:91-119`):

- `C.enabled = True` class attribute (global toggle).
- `C._c(code, text)` returns `f"\033[{code}m{text}\033[0m"` when enabled, else `str(text)` (plain).
- Named helpers (each calls `_c`): `red`("31"), `green`("32"), `yellow`("33"), `blue`("34"), `magenta`("35"), `cyan`("36"), `dim`("2"), `bold`("1"), `strikethrough`("9").
- `rgb(r,g,b,t)` returns `f"\033[38;2;{r};{g};{b}m{t}\033[0m"` (24-bit truecolor foreground) when enabled, else `str(t)`.
- Disable logic (`main()`, `remctl:8134`): `C.enabled = False` if `a.no_color` OR `os.environ.get("NO_COLOR")` is set (any value) OR `not sys.stdout.isatty()`. So color is auto-disabled when piped/redirected, plus the `--no-color` flag and `NO_COLOR` env each force it off.
- List-color helpers (`color_list_name`, `color_for_list_name`, `color_by_list` at `remctl:416-451`) map a list's stored color to `C.rgb(...)`; `LIST_COLOR_MAP` provides named-color RGBs; `blend_rgb(rgb, target=(255,255,255), amount=0.34)` (`remctl:337`) lightens toward white for readable display.

Relevant files (all absolute): `/Users/orion/Developer/Playgrounds/remctl/remctl` (main CLI), `/Users/orion/Developer/Playgrounds/remctl/remctl_runtime.py` (dir/env/url/window helpers), `/Users/orion/Developer/Playgrounds/remctl/remctl_serialization.py`, `/Users/orion/Developer/Playgrounds/remctl/remctl_smart_lists.py`, and the helper binaries `/Users/orion/Developer/Playgrounds/remctl/remctl-bridge.swift`, `/Users/orion/Developer/Playgrounds/remctl/remctl-private.m`, `/Users/orion/Developer/Playgrounds/remctl/remctl-permissions.swift`.

## Store & CoreData schema

<!-- recon: core:store-schema (agent-aac4fa28f93176a13) -->

I now have a complete picture. I have all SQL queries, the DB open path, column-alias conventions, entity constants, and command mappings. Producing the final inventory.

# CoreData SQLite Read-Only Access Inventory (remctl 1.0.3)

This is the exact inventory of every read-only CoreData SQLite access the GRDB layer must reproduce. All access is via Python `sqlite3` opened read-only; there are NO writes (writes go through `remctl-bridge` EventKit, not SQLite).

## DB file location & opening

- **Store directory** (`STORE_DIR`, `remctl:50` → `resolve_store_dir()` in `remctl_runtime.py:26`):
    - `$REMCTL_STORE_DIR` if set (expanded), else `~/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores` (`DEFAULT_STORE_SUBPATH`, `remctl_runtime.py:13`).
- **File glob & selection** (`find_main_db_path`, `remctl:191-195`): `STORE_DIR.glob("Data-*.sqlite")`, sorted by file size **descending**, picks the **largest** (`candidates[0]`). Largest `Data-*.sqlite` is assumed to be the main store.
- **Access pre-check** (`reminders_store_access_error`, `remctl:171-178`): if `STORE_DIR` exists but is not `os.R_OK`, raises `RemindersDBUnavailable` (Full Disk Access missing). `find_main_db` raises if no file found.
- **Open** (`open_db`, `remctl:197-200`):
    ```python
    conn = sqlite3.connect(f"file:{find_main_db()}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    ```
    Read-only via URI `?mode=ro` (NOT `immutable=1`; no WAL/shm handling, no explicit `immutable`). GRDB equivalent: open with read-only configuration. **INSUFFICIENT DATA:** no `immutable=1` is used despite the task wording "read-only/immutable"; only `mode=ro` is present.
- **Timestamp convention** (`ts`, `remctl:202-204`; `to_ts`, `remctl:206-207`): CoreData stores Apple/NSDate epoch seconds. `APPLE_EPOCH = 978307200` (`remctl:49`). Python date = `datetime.fromtimestamp(value + 978307200)`; reverse subtracts it. All `Z*DATE`/`ZENDDATE` columns are stored as Apple-epoch REAL seconds.
- **Schema-tolerance helpers** (queries adapt to schema variation across OS versions):
    - `table_column_names(db, table)` → `PRAGMA table_info({table})` returning set of column names (`remctl:454-455`).
    - `reminder_has_column(db, col)` → `PRAGMA table_info(ZREMCDREMINDER)`, cached in `_REMINDER_COLUMN_CACHE` (`remctl:1227-1235`).
    - Optional columns are appended to SELECT lists only if present (see per-query notes). The GRDB layer must replicate this column-existence probing.

## Z_ENT entity-type constants (CoreData entity discriminators)

Z_ENT values are NOT stable across stores in CoreData, but remctl hard-codes these (must be reproduced exactly as used):

| Z_ENT | Meaning (as used)      | Table                       | Used in                                                                       |
| ----- | ---------------------- | --------------------------- | ----------------------------------------------------------------------------- |
| `3`   | Concrete user list     | `ZREMCDBASELIST`            | list queries (`remctl:397,482,808,961,978,988,4364`)                          |
| `4`   | Smart list             | `ZREMCDBASELIST`            | smart-list queries (`remctl:503,970`), OR'd with `ZSMARTLISTTYPE IS NOT NULL` |
| `15`  | Alarm object           | `ZREMCDOBJECT` (alias `a`)  | `q_alarms` (`remctl:1381`)                                                    |
| `34`  | Recurrence rule object | `ZREMCDOBJECT` (alias `rr`) | `_RECURRENCE_COLS` subqueries (`remctl:1214-1223`)                            |

Other entity-type constants:

- `CUSTOM_SMART_LIST_TYPE = "com.apple.reminders.smartlist.custom"` (`remctl_smart_lists.py:10`) — string value of `ZSMARTLISTTYPE` distinguishing custom vs built-in smart lists (`remctl:511,520,526,886,4147`). Not a Z_ENT.
- Alarm trigger entity (`t.Z_ENT AS trigger_entity`, `remctl:1375`) is selected but matched in Python (`alarm_rows_to_json`), not filtered in SQL.

## Column-alias conventions used by serialization

`remctl_serialization.py` reads rows by these alias names; the SQL must produce them. The central producer is `rem_cols(db)` (`remctl:1260-1267`):

| SQL source column / expr                                   | Alias (consumed by serialization)     | Notes                                                                                   |
| ---------------------------------------------------------- | ------------------------------------- | --------------------------------------------------------------------------------------- |
| `r.Z_PK`                                                   | `Z_PK`                                | reminder id                                                                             |
| `r.ZTITLE`                                                 | `ZTITLE`                              |                                                                                         |
| `r.ZNOTES`                                                 | `ZNOTES`                              |                                                                                         |
| `r.ZCOMPLETED`                                             | `ZCOMPLETED`                          |                                                                                         |
| `r.ZFLAGGED`                                               | `ZFLAGGED`                            |                                                                                         |
| `r.ZPRIORITY`                                              | `ZPRIORITY`                           | mapped via `PRI_NAME {0:none,1:high,5:medium,9:low}` (`remctl:210`)                     |
| `r.ZISURGENTSTATEENABLEDFORCURRENTUSER` **or literal `0`** | `ZISURGENTSTATEENABLEDFORCURRENTUSER` | `urgent_column_expr` (`remctl:1237-1240`); literal `0` when column absent               |
| `r.ZDUEDATEDELTAALERTSDATA` **or literal `NULL`**          | `ZDUEDATEDELTAALERTSDATA`             | `due_date_delta_alerts_expr` (`remctl:1247-1250`); JSON blob parsed for early reminders |
| `r.ZDUEDATE`                                               | `ZDUEDATE`                            | `due_expr` (`remctl:1257-1258`)                                                         |
| `r.ZDISPLAYDATEDATE` **or literal `NULL`**                 | `ZDISPLAYDATEDATE`                    | `display_due_expr` (`remctl:1252-1255`)                                                 |
| `r.ZALLDAY`                                                | `ZALLDAY`                             |                                                                                         |
| `r.ZCOMPLETIONDATE`                                        | `ZCOMPLETIONDATE`                     |                                                                                         |
| `r.ZCREATIONDATE`                                          | `ZCREATIONDATE`                       |                                                                                         |
| `r.ZPARENTREMINDER`                                        | `ZPARENTREMINDER`                     | drives `isSubtask`/`parentID`                                                           |
| `r.ZLIST`                                                  | `ZLIST`                               | FK to `ZREMCDBASELIST.Z_PK`                                                             |
| `r.ZICSURL`                                                | `ZICSURL`                             | reminder url; fallback to rich-link resolver                                            |
| `r.ZCKIDENTIFIER`                                          | `ZCKIDENTIFIER`                       | CloudKit identifier; used for deepLink + section membership keys                        |
| `l.ZNAME` (joined)                                         | `list_name` (lowercase alias)         | from LEFT JOIN `ZREMCDBASELIST l ON r.ZLIST = l.Z_PK`                                   |

Recurrence aliases (`_RECURRENCE_COLS`, `remctl:1213-1223`; consumed in `recurrence_from_row`, `remctl_serialization.py:53-94`) — each is a correlated subquery on `ZREMCDOBJECT rr` (Z_ENT 34):

| Subquery column       | Alias                       | Serialization output key                                  |
| --------------------- | --------------------------- | --------------------------------------------------------- |
| `rr.ZFREQUENCY`       | `recurrence_frequency`      | `frequency` (map `{0:daily,1:weekly,2:monthly,3:yearly}`) |
| `rr.ZINTERVAL`        | `recurrence_interval`       | `interval`                                                |
| `rr.ZOCCURRENCECOUNT` | `recurrence_count`          | `count`                                                   |
| `rr.ZENDDATE`         | `recurrence_end_date`       | `endDate` (ts)                                            |
| `rr.ZDAYSOFTHEWEEK`   | `recurrence_days_of_week`   | `daysOfWeek`/`daysOfWeekDetailed` (JSON blob)             |
| `rr.ZDAYSOFTHEMONTH`  | `recurrence_days_of_month`  | `daysOfMonth` (JSON)                                      |
| `rr.ZMONTHSOFTHEYEAR` | `recurrence_months_of_year` | `monthsOfYear` (JSON)                                     |
| `rr.ZDAYSOFTHEYEAR`   | `recurrence_days_of_year`   | `daysOfYear` (JSON)                                       |
| `rr.ZWEEKSOFTHEYEAR`  | `recurrence_weeks_of_year`  | `weeksOfYear` (JSON)                                      |
| `rr.ZSETPOSITIONS`    | `recurrence_set_positions`  | `setPositions` (JSON)                                     |

Alarm aliases (`q_alarms`, `remctl:1373-1385`): `alarm_id`, `trigger_id`, `trigger_entity`, `time_interval`, `date_components`, `location_title`, `latitude`, `longitude`, `radius`, `address`, `proximity`. Early-reminder JSON parsed from `ZDUEDATEDELTAALERTSDATA` payload key `dueDateDeltaAlerts`, units `{0:minute,1:hour,2:day,3:week,4:month}` (`remctl_serialization.py:15-21,97-140`). Date-component alarms parse `ZDATECOMPONENTSDATA` as JSON.

---

## Queries

### 1. List colors — `load_list_colors` (`remctl:395-398`)

```sql
SELECT ZNAME, ZCOLOR FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL
```

- Table: `ZREMCDBASELIST`. Columns: `ZNAME`, `ZCOLOR`. Filters: `ZMARKEDFORDELETION = 0`, `Z_ENT = 3`, `ZNAME IS NOT NULL`.
- Used by: list-color cache `get_list_colors` → coloring in nearly all display paths (`lists`, `show`, etc.). Wrapped in try/except (best-effort).

### 2. All user lists — `q_lists` (`remctl:480-484`)

```sql
SELECT {columns} FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != '' ORDER BY ZNAME
```

- `{columns}` from `list_select_columns` (`remctl:458-475`): required `Z_PK, ZNAME, ZCKIDENTIFIER`; optional-if-present: `ZBADGEEMBLEM, ZCOLOR, ZISPINNEDBYCURRENTUSER, ZPINNEDDATE, ZSHOULDCATEGORIZEGROCERYITEMS, ZSHOULDAUTOCATEGORIZEITEMS, ZSHOULDSUGGESTCONVERSIONTOGROCERYLIST, ZGROCERYLOCALEID, ZAUTOCATEGORIZATIONLOCALCORRECTIONSCHECKSUM`; plus `length(ZAUTOCATEGORIZATIONLOCALCORRECTIONSASDATA) AS ZAUTOCATEGORIZATIONLOCALCORRECTIONSASDATA_LENGTH` if that column exists.
- Filters: `ZMARKEDFORDELETION = 0`, `Z_ENT = 3`, `ZNAME IS NOT NULL`, `ZNAME != ''`.
- Used by: `cmd_lists` (`remctl:4717`), `cmd_stats` (`remctl:5886`).

### 3. Smart lists — `q_smart_lists` (`remctl:501-505`)

```sql
SELECT {columns} FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND (Z_ENT = 4 OR ZSMARTLISTTYPE IS NOT NULL) ORDER BY COALESCE(ZNAME, ''), Z_PK
```

- Returns `[]` early if `ZSMARTLISTTYPE` column absent. `{columns}`: `Z_PK, ZNAME, ZCKIDENTIFIER, ZSMARTLISTTYPE, ZFILTERDATA, ZMINIMUMSUPPORTEDAPPVERSION, ZEFFECTIVEMINIMUMSUPPORTEDAPPVERSION` + optional `ZBADGEEMBLEM, ZCOLOR, ZISPINNEDBYCURRENTUSER, ZPINNEDDATE`.
- Filters: `ZMARKEDFORDELETION = 0` AND (`Z_ENT = 4` OR `ZSMARTLISTTYPE IS NOT NULL`).
- Used by: `cmd_smart_lists` (`remctl:4187`).

### 4. Custom smart-list exact-name count — `q_custom_smart_list_exact_name_count` (`remctl:508-512`)

```sql
SELECT COUNT(*) AS count FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND ZSMARTLISTTYPE = ? AND ZNAME = ?
```

- Params: `(CUSTOM_SMART_LIST_TYPE, name)`. Used by smart-list create/edit dedup paths (`cmd_smart_list_create`/`cmd_smart_list_edit`).

### 5. Custom smart-list delete matches — `q_custom_smart_list_delete_matches` (`remctl:517-527`)

Two forms:

```sql
SELECT Z_PK, ZNAME, ZCKIDENTIFIER, ZSMARTLISTTYPE, ZFILTERDATA FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND ZSMARTLISTTYPE = ? AND Z_PK = ?
```

```sql
SELECT Z_PK, ZNAME, ZCKIDENTIFIER, ZSMARTLISTTYPE, ZFILTERDATA FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND ZSMARTLISTTYPE = ? AND ZNAME = ? ORDER BY Z_PK
```

- Params: `(CUSTOM_SMART_LIST_TYPE, smart_list_id)` or `(CUSTOM_SMART_LIST_TYPE, name)`. Used by: `cmd_smart_list_delete`.

### 6. Templates list — `q_templates` (`remctl:570-577`)

```sql
SELECT {columns}, (SELECT COUNT(*) FROM ZREMCDSAVEDREMINDER sr WHERE sr.ZTEMPLATE = ZREMCDTEMPLATE.Z_PK AND sr.ZMARKEDFORDELETION = 0) AS item_count, (SELECT COUNT(*) FROM ZREMCDBASESECTION s WHERE s.ZTEMPLATE = ZREMCDTEMPLATE.Z_PK AND s.ZMARKEDFORDELETION = 0) AS section_count FROM ZREMCDTEMPLATE WHERE ZMARKEDFORDELETION = 0 AND ZNAME IS NOT NULL AND ZNAME != '' ORDER BY ZNAME, Z_PK
```

- Tables: `ZREMCDTEMPLATE` (main), correlated `ZREMCDSAVEDREMINDER sr` (alias) and `ZREMCDBASESECTION s` (alias). Aliases: `item_count`, `section_count`.
- `{columns}` from `template_select_columns` (`remctl:530-549`): `Z_PK, ZNAME, ZCKIDENTIFIER, ZCREATIONDATE, ZLASTMODIFIEDDATE, ZPUBLICLINKCREATIONDATE, ZPUBLICLINKEXPIRATIONDATE, ZPUBLICLINKLASTMODIFIEDDATE` + optional `ZBADGEEMBLEM, ZCOLOR, ZPUBLICLINKURLUUID, ZPUBLICLINKCONFIGURATIONDATA`.
- Filters: `ZMARKEDFORDELETION = 0`, `ZNAME IS NOT NULL`, `ZNAME != ''`. Used by: `cmd_templates` (`remctl:4213`).

### 7. Template exact-name count — `q_template_exact_name_count` (`remctl:581-585`)

```sql
SELECT COUNT(*) AS count FROM ZREMCDTEMPLATE WHERE ZMARKEDFORDELETION = 0 AND ZNAME = ?
```

- Used by: `cmd_template_create` dedup.

### 8. Template matches — `q_template_matches` (`remctl:589-605`)

Same select+subqueries as #6, with WHERE either:

```sql
... WHERE ZMARKEDFORDELETION = 0 AND Z_PK = ?
... WHERE ZMARKEDFORDELETION = 0 AND ZNAME = ? ORDER BY Z_PK
```

- Used by: `cmd_template_info`, `cmd_template_apply`, `cmd_template_delete`.

### 9. Template sections — `q_template_sections` (`remctl:614-619`)

```sql
SELECT {columns} FROM ZREMCDBASESECTION WHERE ZMARKEDFORDELETION = 0 AND ZTEMPLATE = ? ORDER BY Z_PK
```

- `{columns}` filtered-by-presence from `Z_PK, ZDISPLAYNAME, ZCKIDENTIFIER, ZCANONICALNAME, ZCREATIONDATE`. Returns `[]` if none present.
- Used by: `template_to_dict` when `include_items` (`remctl:1208`) → `cmd_template_info` etc.

### 10. Template saved reminders — `q_template_saved_reminders` (`remctl:626-630`)

```sql
SELECT {columns} FROM ZREMCDSAVEDREMINDER WHERE ZMARKEDFORDELETION = 0 AND ZTEMPLATE = ? ORDER BY Z_PK
```

- `{columns}` filtered-by-presence from `saved_reminder_select_columns` (`remctl:552-565`): `Z_PK, ZTITLE, ZCKIDENTIFIER, ZPARENTSAVEDREMINDERIDENTIFIER, ZPRIORITY, ZDISPLAYDATEISALLDAY, ZDISPLAYDATEDATE, ZCREATIONDATE, ZMETADATA`.
- Used by: `template_to_dict` (`remctl:1209`).

### 11. Resolve list by id — `resolve_list_ref` (`remctl:806-809`)

```sql
SELECT {list_select_columns} FROM ZREMCDBASELIST WHERE Z_PK = ? AND ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != ''
```

- Used by: list-resolution helper feeding `cmd_show`, add/edit list targeting, `resolve_list_pk`.

### 12. List CloudKit id — `q_list_ckid` (`remctl:959-963`)

```sql
SELECT ZCKIDENTIFIER FROM ZREMCDBASELIST WHERE Z_PK = ? AND ZMARKEDFORDELETION = 0 AND Z_ENT = 3
```

- Used by: list-targeting for bridge writes (e.g. list-edit/pin/rename/delete, add with list).

### 13. Smart-list CloudKit id — `q_smart_list_ckid` (`remctl:968-972`)

```sql
SELECT ZCKIDENTIFIER FROM ZREMCDBASELIST WHERE Z_PK = ? AND ZMARKEDFORDELETION = 0 AND (Z_ENT = 4 OR ZSMARTLISTTYPE IS NOT NULL)
```

- Used by: smart-list edit/delete bridge targeting.

### 14. List exact-name count — `q_list_exact_name_count` (`remctl:976-980`)

```sql
SELECT COUNT(*) AS count FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME = ?
```

- Used by: list create/rename collision checks.

### 15. List by PK — `q_list_by_pk` (`remctl:986-991`)

```sql
SELECT {list_select_columns} FROM ZREMCDBASELIST WHERE Z_PK = ? AND ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZNAME IS NOT NULL AND ZNAME != ''
```

- Used by: list lookup helpers (list-edit/show post-resolution).

### 16. List reminder count (for template) — `q_list_reminder_count_for_template` (`remctl:1003-1006`)

```sql
SELECT COUNT(*) AS count FROM ZREMCDREMINDER WHERE ZMARKEDFORDELETION = 0 AND ZLIST = ? AND ZACCOUNT IS NOT NULL [AND ZCOMPLETED = 0]
```

- `ZCOMPLETED = 0` appended unless `include_completed`. Wrapped in try/except `sqlite3.OperationalError`. Used by: template-create flow.

### 17. Core reminder column set — `rem_cols(db)` (`remctl:1260-1267`)

Not a standalone query — the SELECT-list fragment (including the 11 recurrence subqueries `_RECURRENCE_COLS`) embedded in queries #18–#27. See the alias table above. Always paired with `FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK`. The recurrence subqueries hit `ZREMCDOBJECT rr` with `rr.ZREMINDER4 = r.Z_PK AND rr.ZMARKEDFORDELETION = 0 AND rr.Z_ENT = 34 ORDER BY rr.Z_PK LIMIT 1`.

### 18. Reminders (generic listing) — `q_reminders` (`remctl:1275-1279`)

```sql
SELECT {rem_cols} FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE {conditions} ORDER BY r.Z_PK LIMIT ?
```

- Base conditions (`remctl:1270-1274`): `r.ZMARKEDFORDELETION = 0`, `r.ZACCOUNT IS NOT NULL`; `+ r.ZCOMPLETED = 0` unless `completed`; `+ r.ZLIST = ?` if `list_pk`; `+ r.ZPARENTREMINDER = ?` if `parent_pk`, else if `top_level`: `(r.ZPARENTREMINDER IS NULL OR r.ZPARENTREMINDER = 0)`. Default `limit=500` (export uses `10000`).
- Used by: `cmd_show` (`remctl:5084`,`5916`), `cmd_subtasks` (`remctl:5750`, parent_pk), `cmd_export` (`remctl:6301`, limit 10000, completed=True).

### 19. Single reminder by PK — `q_reminder` (`remctl:1282-1287`)

```sql
SELECT {rem_cols} FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE r.Z_PK = ? AND r.ZMARKEDFORDELETION = 0 AND r.ZACCOUNT IS NOT NULL
```

- Used by: `cmd_info`, `cmd_done`, `cmd_undone`, `cmd_delete`, `cmd_edit`, `cmd_flag`, `cmd_unflag`, `cmd_link`, `cmd_open`, `cmd_subtasks` (parent), `cmd_show` (per-id) — sites `remctl:5286,5311,5346,5379,5421,5746,5768,5826,5923,5940,5959,5995`.

### 20. Reminder by CloudKit identifier — `q_reminder_by_identifier` (`remctl:1292-1298`)

```sql
SELECT {rem_cols} FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE lower(r.ZCKIDENTIFIER) = lower(?) AND r.ZMARKEDFORDELETION = 0 AND r.ZACCOUNT IS NOT NULL ORDER BY r.Z_PK DESC LIMIT 1
```

- Used by: post-write reconciliation in edit/add (`remctl:2526,2541,5224`).

### 21. Subtask count — `q_subtask_count` (`remctl:1301-1304`)

```sql
SELECT COUNT(*) FROM ZREMCDREMINDER WHERE ZPARENTREMINDER = ? AND ZMARKEDFORDELETION = 0 AND ZCOMPLETED = 0
```

- Used by: serialization fallback `fallback_subtask_count` (`remctl:1879`), `_subtask_count_from_item` (`remctl:1748`). Note: matches `preload_extras` batch query in serialization (see #28).

### 22. Sections — `q_sections` (`remctl:1308-1316`)

With `list_pk`:

```sql
SELECT Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER FROM ZREMCDBASESECTION WHERE ZMARKEDFORDELETION = 0 AND ZLIST = ? ORDER BY Z_PK
```

Without:

```sql
SELECT s.Z_PK, s.ZDISPLAYNAME, s.ZLIST, s.ZCKIDENTIFIER, l.ZNAME as list_name FROM ZREMCDBASESECTION s LEFT JOIN ZREMCDBASELIST l ON s.ZLIST = l.Z_PK WHERE s.ZMARKEDFORDELETION = 0 ORDER BY l.ZNAME, s.Z_PK
```

- Aliases: `list_name`. Used by: `cmd_show` (`remctl:5087`), `cmd_sections` (`remctl:5852`), `cmd_stats` (`remctl:5887`), `cmd_lists` per-list (`remctl:4728`), section-name resolution (`remctl:2825`).

### 23. Section memberships — `q_section_memberships` (`remctl:1319-1337`)

```sql
SELECT ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA FROM ZREMCDBASELIST WHERE Z_PK = ?
```

then

```sql
SELECT ZCKIDENTIFIER, ZDISPLAYNAME FROM ZREMCDBASESECTION WHERE ZLIST = ? AND ZMARKEDFORDELETION = 0
```

- First query reads a JSON blob (`memberships[]` with `groupID`/`memberID`); builds `{memberID(reminder ZCKIDENTIFIER): sectionDisplayName}`. Used by: `cmd_show` (`remctl:5088`), `cmd_info` (`remctl:5779`), add section assignment (`remctl:2916`).

### 24. Section member counts — `q_section_member_counts` (`remctl:1340-1357`)

```sql
SELECT ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA FROM ZREMCDBASELIST WHERE Z_PK = ?
```

- Parses same JSON blob; counts non-`isObsolete` memberships per `groupID`. Used by: add/section flow (`remctl:2830`).

### 25. Attachments — `q_attachments` (`remctl:1361-1370`)

```sql
SELECT ZFILENAME, ZUTI, ZATTACHMENTTYPERAWVALUE FROM ZREMCDSAVEDATTACHMENT WHERE ZREMINDER = ? AND ZMARKEDFORDELETION = 0
UNION ALL
SELECT ZFILENAME, ZUTI, CASE WHEN ZWIDTH IS NOT NULL OR ZHEIGHT IS NOT NULL THEN 'image' ELSE 'file' END AS ZATTACHMENTTYPERAWVALUE FROM ZREMCDOBJECT WHERE ZREMINDER2 = ? AND ZFILENAME IS NOT NULL AND ZFILENAME != '' AND ZMARKEDFORDELETION = 0
ORDER BY ZFILENAME
```

- Two tables UNION'd: `ZREMCDSAVEDATTACHMENT` (FK `ZREMINDER`) and `ZREMCDOBJECT` (FK `ZREMINDER2`). Columns/aliases: `ZFILENAME`, `ZUTI`, `ZATTACHMENTTYPERAWVALUE` (synthesized in 2nd branch). Params: `(pk, pk)`. Used by: `cmd_info` (`remctl:5773`).

### 26. Alarms — `q_alarms` (`remctl:1373-1385`)

```sql
SELECT a.Z_PK AS alarm_id, a.ZTRIGGER AS trigger_id, t.Z_ENT AS trigger_entity, t.ZTIMEINTERVAL AS time_interval, t.ZDATECOMPONENTSDATA AS date_components, t.ZTITLE AS location_title, t.ZLATITUDE AS latitude, t.ZLONGITUDE AS longitude, t.ZRADIUS AS radius, t.ZADDRESS AS address, t.ZPROXIMITY AS proximity FROM ZREMCDOBJECT a LEFT JOIN ZREMCDOBJECT t ON a.ZTRIGGER = t.Z_PK WHERE a.ZREMINDER = ? AND a.Z_ENT = 15 AND a.ZMARKEDFORDELETION = 0 AND (t.Z_PK IS NULL OR t.ZMARKEDFORDELETION = 0) ORDER BY a.Z_PK
```

- Self-join on `ZREMCDOBJECT` (`a` = alarm Z_ENT 15, `t` = trigger via `a.ZTRIGGER = t.Z_PK`). Filters: alarm `Z_ENT = 15`, `ZMARKEDFORDELETION = 0`; trigger null-or-not-deleted. Aliases listed above. Used by: `cmd_info` (`remctl:5774`), and alarm display in edit/add reconciliation (`remctl:1537,1554,1569,2544`).

### 27. Rich links — `q_rich_links` (`remctl:1388-1392`)

```sql
SELECT ZURL FROM ZREMCDOBJECT WHERE ZREMINDER2 = ? AND ZURL IS NOT NULL AND ZURL != '' AND ZMARKEDFORDELETION = 0 ORDER BY Z_PK
```

- `q_rich_link` returns the first `ZURL`. Used by: serialization `rich_link_resolver` (`remctl:1878,1890`) when `ZICSURL` empty; `cmd_info` (`remctl:5776`).

### 28. Hashtags (single reminder) — `q_hashtags` (`remctl:1400-1402`)

```sql
SELECT h.ZNAME FROM ZREMCDOBJECT o JOIN ZREMCDHASHTAGLABEL h ON o.ZHASHTAGLABEL = h.Z_PK WHERE o.ZREMINDER3 = ?
```

- Join `ZREMCDOBJECT o` → `ZREMCDHASHTAGLABEL h` on `o.ZHASHTAGLABEL = h.Z_PK`, filtered by `o.ZREMINDER3 = ?` (reminder PK). Column: `h.ZNAME`. Used by: serialization fallback (`remctl:1880,1892`), `_tags_from_item` (`remctl:1757`), `cmd_info` (`remctl:5775`).

### 29. Search — `q_search` (`remctl:1574-1588`)

```sql
SELECT {rem_cols} FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE r.ZMARKEDFORDELETION = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND (r.ZTITLE LIKE ? ESCAPE '\' OR r.ZNOTES LIKE ? ESCAPE '\') [AND r.ZCOMPLETED = 0] ORDER BY r.Z_PK DESC LIMIT 100
```

- LIKE metacharacters in query escaped (`\`, `%`, `_`) with `ESCAPE '\'`; pattern `%{safe}%`. `ZCOMPLETED = 0` unless `completed`. Params `(pat, pat)`. Used by: `cmd_search` (`remctl:5644`).

### 30. Due today — `q_due_today` (`remctl:1597-1601`)

```sql
SELECT {rem_cols} FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND {window} ORDER BY r.ZDUEDATE
```

- `{window}` (`remctl:1593-1596`): if `include_overdue`: `r.ZDUEDATE < {to_ts(eod)} AND r.ZDUEDATE IS NOT NULL`; else `r.ZDUEDATE >= {to_ts(sod)} AND r.ZDUEDATE < {to_ts(eod)}`. `to_ts(...)` are literal Apple-epoch float bounds inlined into SQL (not bound params). Window from `due_today_window()`. Used by: `cmd_today` (`remctl:5663`).

### 31. Flagged — `q_flagged` (`remctl:1605-1608`)

```sql
SELECT {rem_cols} FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND r.ZFLAGGED = 1 ORDER BY r.ZDUEDATE NULLS LAST
```

- Used by: `cmd_flagged` (`remctl:5692`).

### 32. Urgent — `q_urgent` (`remctl:1613-1616`)

```sql
SELECT {rem_cols} FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND {urgent_where} ORDER BY r.ZDUEDATE NULLS LAST
```

- `{urgent_where}` (`urgent_where_clause`, `remctl:1242-1245`): `r.ZISURGENTSTATEENABLEDFORCURRENTUSER = 1` if column exists, else `0 = 1` (no-op match). Used by: `cmd_urgent` (`remctl:5711`).

### 33. Upcoming — `q_upcoming` (`remctl:1623-1629`)

```sql
SELECT {rem_cols} FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND r.ZDUEDATE IS NOT NULL AND r.ZDUEDATE >= {to_ts(sod)} AND r.ZDUEDATE < {to_ts(future)} ORDER BY r.ZDUEDATE
```

- Window from `upcoming_window(days)` (default 7; `sod .. sod+days+1`). Bounds inlined. Used by: `cmd_upcoming` (`remctl:6035`).

### 34. Overdue — `q_overdue` (`remctl:1635-1639`)

```sql
SELECT {rem_cols} FROM ZREMCDREMINDER r LEFT JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK WHERE r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND l.Z_PK IS NOT NULL AND r.ZDUEDATE IS NOT NULL AND r.ZDUEDATE < {to_ts(sod)} ORDER BY r.ZDUEDATE
```

- `sod = start_of_day()`. Used by: `cmd_overdue` (`remctl:6068`).

### 35. Section ckid resolution (add) — inline (`remctl:2815-2818`)

```sql
SELECT ZCKIDENTIFIER FROM ZREMCDBASESECTION WHERE ZLIST = ? AND ZMARKEDFORDELETION = 0 AND lower(ZCKIDENTIFIER) = lower(?)
```

- Params `(list_pk, section_id)`. Used by: add command section-by-id resolution.

### 36. List by ckid after template-apply — inline (`remctl:4362-4366`)

```sql
SELECT {list_select_columns} FROM ZREMCDBASELIST WHERE ZMARKEDFORDELETION = 0 AND Z_ENT = 3 AND ZCKIDENTIFIER = ?
```

- Opens a **fresh** `open_db()` connection (`remctl:4361`) to read the just-created list. Used by: `cmd_template_apply`.

### 37. Tags listing — `cmd_tags` inline (`remctl:5730-5732`)

```sql
SELECT ZNAME FROM ZREMCDHASHTAGLABEL WHERE ZNAME IS NOT NULL ORDER BY ZNAME
```

- Used by: `cmd_tags`.

### 38. Stats counts — `cmd_stats` inline (`remctl:5875-5885`)

```sql
SELECT COUNT(*) FROM ZREMCDREMINDER WHERE ZMARKEDFORDELETION = 0 AND ZACCOUNT IS NOT NULL                                              -- total
SELECT COUNT(*) FROM ZREMCDREMINDER WHERE ZMARKEDFORDELETION = 0 AND ZCOMPLETED = 0 AND ZACCOUNT IS NOT NULL                           -- active
SELECT COUNT(*) FROM ZREMCDREMINDER WHERE ZMARKEDFORDELETION = 0 AND ZCOMPLETED = 0 AND ZFLAGGED = 1 AND ZACCOUNT IS NOT NULL          -- flagged
SELECT COUNT(*) FROM ZREMCDREMINDER r WHERE r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND {urgent_where_clause}  -- urgent
SELECT COUNT(*) FROM ZREMCDREMINDER r WHERE r.ZMARKEDFORDELETION = 0 AND r.ZCOMPLETED = 0 AND r.ZACCOUNT IS NOT NULL AND r.ZDUEDATE IS NOT NULL AND r.ZDUEDATE < {to_ts(datetime.now())}  -- overdue
```

- `{urgent_where_clause}` as in #32; overdue bound `to_ts(datetime.now())` inlined. Also calls `q_lists`/`q_sections` for counts. Used by: `cmd_stats`.

### 39. PRAGMA introspection (not row data)

```sql
PRAGMA table_info(ZREMCDBASELIST)     -- list_select_columns / q_smart_lists / template/saved-reminder/section column probing (remctl:455)
PRAGMA table_info(ZREMCDTEMPLATE)     -- template_select_columns (remctl:541)
PRAGMA table_info(ZREMCDSAVEDREMINDER)-- saved_reminder_select_columns (remctl:564)
PRAGMA table_info(ZREMCDBASESECTION)  -- q_template_sections (remctl:610)
PRAGMA table_info(ZREMCDREMINDER)     -- reminder_has_column (remctl:1231)
```

- These drive the optional-column logic; the GRDB layer must do equivalent schema introspection (or pre-know which columns exist per OS version).

### 40. Serialization batch preloads — `preload_extras` (`remctl_serialization.py:143-164`)

Used by `serialize_reminders` (`remctl_serialization.py:259`) to avoid N+1 when rendering reminder lists (JSON output paths of `show`, `today`, `upcoming`, `overdue`, `flagged`, `urgent`, `search`, `export`, `subtasks`):

```sql
SELECT ZPARENTREMINDER, COUNT(*) FROM ZREMCDREMINDER WHERE ZPARENTREMINDER IN ({placeholders}) AND ZMARKEDFORDELETION = 0 AND ZCOMPLETED = 0 GROUP BY ZPARENTREMINDER
```

```sql
SELECT o.ZREMINDER3, h.ZNAME FROM ZREMCDOBJECT o JOIN ZREMCDHASHTAGLABEL h ON o.ZHASHTAGLABEL = h.Z_PK WHERE o.ZREMINDER3 IN ({placeholders})
```

- First: subtask counts keyed by `ZPARENTREMINDER` (matches #21 semantics, batched). Second: hashtags keyed by `ZREMINDER3` (matches #28, batched). `{placeholders}` = `?,?,...` for each reminder `Z_PK`.

---

## Entities/tables — consolidated

| Table                              | Role                                                                                                          | Key columns read                                                                                                                                                                                                                                                                                                                                                                                                                             | Filters commonly applied                                                                             | Queries                        |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------ |
| `ZREMCDREMINDER` (alias `r`)       | Reminders                                                                                                     | `Z_PK, ZTITLE, ZNOTES, ZCOMPLETED, ZFLAGGED, ZPRIORITY, ZISURGENTSTATEENABLEDFORCURRENTUSER, ZDUEDATEDELTAALERTSDATA, ZDUEDATE, ZDISPLAYDATEDATE, ZALLDAY, ZCOMPLETIONDATE, ZCREATIONDATE, ZPARENTREMINDER, ZLIST, ZICSURL, ZCKIDENTIFIER, ZACCOUNT`                                                                                                                                                                                         | `ZMARKEDFORDELETION=0`, `ZACCOUNT IS NOT NULL`, `ZCOMPLETED=0` (often), `ZLIST=?`, `ZPARENTREMINDER` | #16,18-21,29-34,38,40          |
| `ZREMCDBASELIST` (alias `l`)       | Lists & smart lists                                                                                           | `Z_PK, ZNAME, ZCKIDENTIFIER, ZCOLOR, ZSMARTLISTTYPE, ZFILTERDATA, ZBADGEEMBLEM, ZISPINNEDBYCURRENTUSER, ZPINNEDDATE, ZSHOULDCATEGORIZEGROCERYITEMS, ZSHOULDAUTOCATEGORIZEITEMS, ZSHOULDSUGGESTCONVERSIONTOGROCERYLIST, ZGROCERYLOCALEID, ZAUTOCATEGORIZATIONLOCALCORRECTIONSCHECKSUM, ZAUTOCATEGORIZATIONLOCALCORRECTIONSASDATA, ZMINIMUMSUPPORTEDAPPVERSION, ZEFFECTIVEMINIMUMSUPPORTEDAPPVERSION, ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA` | `ZMARKEDFORDELETION=0`, `Z_ENT=3` (lists) / `Z_ENT=4 OR ZSMARTLISTTYPE IS NOT NULL` (smart)          | #1-5,11-15,17(join),23,24,36   |
| `ZREMCDBASESECTION` (aliases `s`)  | Sections (lists & templates)                                                                                  | `Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER, ZCANONICALNAME, ZCREATIONDATE, ZTEMPLATE`                                                                                                                                                                                                                                                                                                                                                         | `ZMARKEDFORDELETION=0`, `ZLIST=?` / `ZTEMPLATE=?`                                                    | #6,8,9,22,23,35                |
| `ZREMCDOBJECT`                     | Polymorphic store: recurrence rules (Z_ENT 34), alarms (15), triggers, attachments, rich links, hashtag links | `Z_PK, Z_ENT, ZREMINDER2, ZREMINDER3, ZREMINDER4, ZREMINDER, ZTRIGGER, ZURL, ZFILENAME, ZUTI, ZWIDTH, ZHEIGHT, ZHASHTAGLABEL, ZTIMEINTERVAL, ZDATECOMPONENTSDATA, ZTITLE, ZLATITUDE, ZLONGITUDE, ZRADIUS, ZADDRESS, ZPROXIMITY` + recurrence cols `ZFREQUENCY, ZINTERVAL, ZOCCURRENCECOUNT, ZENDDATE, ZDAYSOFTHEWEEK, ZDAYSOFTHEMONTH, ZMONTHSOFTHEYEAR, ZDAYSOFTHEYEAR, ZWEEKSOFTHEYEAR, ZSETPOSITIONS`                                     | `ZMARKEDFORDELETION=0`, `Z_ENT IN {15,34}`, FK `ZREMINDER/ZREMINDER2/ZREMINDER3/ZREMINDER4`          | #17(recurrence),25,26,27,28,40 |
| `ZREMCDHASHTAGLABEL` (alias `h`)   | Hashtag labels                                                                                                | `Z_PK, ZNAME`                                                                                                                                                                                                                                                                                                                                                                                                                                | `ZNAME IS NOT NULL` (tags list)                                                                      | #28,37,40                      |
| `ZREMCDSAVEDATTACHMENT`            | First-class attachments                                                                                       | `ZFILENAME, ZUTI, ZATTACHMENTTYPERAWVALUE, ZREMINDER`                                                                                                                                                                                                                                                                                                                                                                                        | `ZREMINDER=?`, `ZMARKEDFORDELETION=0`                                                                | #25                            |
| `ZREMCDTEMPLATE`                   | Templates                                                                                                     | `Z_PK, ZNAME, ZCKIDENTIFIER, ZCREATIONDATE, ZLASTMODIFIEDDATE, ZPUBLICLINKCREATIONDATE, ZPUBLICLINKEXPIRATIONDATE, ZPUBLICLINKLASTMODIFIEDDATE, ZBADGEEMBLEM, ZCOLOR, ZPUBLICLINKURLUUID, ZPUBLICLINKCONFIGURATIONDATA`                                                                                                                                                                                                                      | `ZMARKEDFORDELETION=0`, `ZNAME IS NOT NULL`, `ZNAME != ''`                                           | #6,7,8                         |
| `ZREMCDSAVEDREMINDER` (alias `sr`) | Template items                                                                                                | `Z_PK, ZTITLE, ZCKIDENTIFIER, ZPARENTSAVEDREMINDERIDENTIFIER, ZPRIORITY, ZDISPLAYDATEISALLDAY, ZDISPLAYDATEDATE, ZCREATIONDATE, ZMETADATA, ZTEMPLATE`                                                                                                                                                                                                                                                                                        | `ZMARKEDFORDELETION=0`, `ZTEMPLATE=?`                                                                | #6,8,10                        |

**`ZREMCDDUEDATEDELTAALERT`: INSUFFICIENT DATA** — this table is **never queried** as a table. Early-Reminder ("due date delta") data is read only from the `ZREMCDREMINDER.ZDUEDATEDELTAALERTSDATA` JSON blob column (alias-passed through `rem_cols`, parsed in `due_date_delta_alerts_from_row`, `remctl_serialization.py:97-140`). No separate alert entity/table is accessed; if the GRDB layer needs the same data it must read the JSON blob column, not a join.

## Notable behaviors the GRDB layer must reproduce

- **All reads filter `ZMARKEDFORDELETION = 0`** (soft-delete tombstones) everywhere except PRAGMA introspection.
- **Reminder visibility requires `ZACCOUNT IS NOT NULL`** and (for list-scoped views) `l.Z_PK IS NOT NULL` (excludes reminders whose list join failed / orphaned).
- **`ZCOMPLETED = 0`** added unless completed explicitly requested.
- **Date filters inline literal Apple-epoch floats** computed from `to_ts(...)` directly into SQL (not bound params) in #30,33,34,38.
- **Column-existence probing**: `ZISURGENTSTATEENABLEDFORCURRENTUSER`, `ZDUEDATEDELTAALERTSDATA`, `ZDISPLAYDATEDATE`, and all `ZREMCDBASELIST`/`ZREMCDTEMPLATE`/`ZREMCDSAVEDREMINDER`/`ZREMCDBASESECTION` optional columns are conditionally included; absent urgent column degrades to literal `0`/`0=1`.
- **Polymorphic `ZREMCDOBJECT` FK columns** distinguish relationship type: `ZREMINDER` (alarms), `ZREMINDER2` (attachments/rich links), `ZREMINDER3` (hashtags), `ZREMINDER4` (recurrence rules). The GRDB layer must use the correct FK column per join.
- **Section membership** is not a join — it is a JSON blob on the list (`ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA`) mapping reminder `ZCKIDENTIFIER`→section `ZCKIDENTIFIER`.

Relevant source files: `/Users/orion/Developer/Playgrounds/remctl/remctl`, `/Users/orion/Developer/Playgrounds/remctl/remctl_serialization.py`, `/Users/orion/Developer/Playgrounds/remctl/remctl_runtime.py`, `/Users/orion/Developer/Playgrounds/remctl/remctl_smart_lists.py`.

## Shared modules

<!-- recon: modules (agent-a24ff1b4229b87779) -->

I have all three files. Producing the documentation now.

# RemCTL Module Reference (for Swift port)

## `remctl_runtime.py`

Module-level constants:

- `DEFAULT_STORE_SUBPATH` = `Path("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores")`
- `TRUTHY` = `{"1", "true", "yes", "on"}`

### `env_bool(name: str, default: bool = False) -> bool`

- Purpose: read an environment variable as a boolean.
- Inputs: `name` (env var name), `default` returned when var is unset (`None`).
- Output: `bool`.
- Logic the Swift port must preserve: returns `default` only when the var is literally absent (`os.environ.get` returns `None`). When present, value is `.strip().lower()` then tested for membership in `TRUTHY` (`"1","true","yes","on"`). Any other value (including empty string) yields `False`. Comparison is case-insensitive and whitespace-trimmed.

### `resolve_store_dir() -> Path`

- Purpose: locate the Reminders SQLite store directory.
- Inputs: none (reads env `REMCTL_STORE_DIR`).
- Output: `Path`.
- Logic: if `REMCTL_STORE_DIR` is set and truthy-non-empty, return `Path(override).expanduser()` (tilde expansion required). Otherwise `Path.home() / DEFAULT_STORE_SUBPATH`. Note the empty-string override is falsy and falls through to the default.

### `resolve_config_dir(app_name: str = "remctl") -> Path`

- Purpose: locate the config directory.
- Inputs: `app_name` (default `"remctl"`); reads env `REMCTL_CONFIG_DIR` and `XDG_CONFIG_HOME`.
- Output: `Path`.
- Logic/precedence the port must preserve: (1) `REMCTL_CONFIG_DIR` if set/non-empty → `expanduser()` returned directly (app_name NOT appended). (2) else base = `XDG_CONFIG_HOME` (expanduser) if set/non-empty, else `Path.home()/".config"`; return `base / app_name`. Empty strings are falsy and skipped.

### `ensure_private_dir(path: Path) -> None`

- Purpose: create a directory with private (0700) permissions.
- Inputs: `path`. Output: none.
- Logic: `mkdir(parents=True, exist_ok=True)` then `chmod(0o700)`; the chmod is wrapped in try/except `OSError` and silently ignored on failure (e.g. on filesystems without POSIX perms). Port must not throw if chmod fails.

### `write_private_text_file(path: Path, text: str) -> None`

- Purpose: atomically (truncating) write UTF-8 text to a file with 0600 perms, refusing symlinks.
- Inputs: `path`, `text`. Output: none.
- Logic the port must preserve:
    - Calls `ensure_private_dir(path.parent)` first.
    - Opens with `O_WRONLY | O_CREAT | O_TRUNC`, and `O_NOFOLLOW` added when available (symlink-refusal is a security control — Swift port should use `O_NOFOLLOW`).
    - File created with mode `0o600`.
    - Writes via UTF-8 encoded handle.
    - In `finally`, re-applies `chmod(0o600)` wrapped in try/except `OSError` (ignored). The chmod runs even if the write raised.

### `resolve_binary_path(script_path: str, binary_name: str, env_var: str) -> Path`

- Purpose: locate a helper binary.
- Inputs: `script_path` (caller's `__file__`), `binary_name`, `env_var` (override env name).
- Output: `Path`.
- Logic/precedence the port must preserve:
    1. If `env_var` is set/non-empty → `Path(override).expanduser()` returned (existence NOT checked).
    2. `script_dir = Path(script_path).resolve().parent`. Candidates checked in order via `.exists()`: `script_dir/binary_name`, `script_dir/"bin"/binary_name`, `~/bin/binary_name`, `~/.local/bin/binary_name`. First existing wins.
    3. Else `shutil.which(binary_name)` (PATH lookup); if found return `Path(discovered)`.
    4. Fallback: `script_dir / binary_name` (returned even though it does not exist).

### `start_of_day(now: datetime | None = None) -> datetime`

- Purpose: midnight of the given (or current local) day.
- Inputs: `now` optional; defaults to `datetime.now()` (local naive time).
- Output: `datetime` with `hour=minute=second=microsecond=0`.
- Date-window math: uses naive local time; Swift port should use the same local-timezone, start-of-day truncation.

### `due_today_window(now: datetime | None = None) -> tuple[datetime, datetime]`

- Purpose: half-open `[start, end)` window covering "today".
- Output: `(sod, sod + timedelta(days=1))` where `sod = start_of_day(now)`.
- Edge case the port must preserve: window is exactly 1 day, lower bound inclusive / upper bound exclusive (one day later at midnight).

### `upcoming_window(days: int = 7, now: datetime | None = None) -> tuple[datetime, datetime]`

- Purpose: window from today's midnight spanning `days` days.
- Output: `(sod, sod + timedelta(days=days + 1))`.
- Date-window math the port must preserve: the upper bound adds `days + 1` (NOT `days`). With default `days=7` this yields an 8-day span (today through the end of the 7th upcoming day). The `+1` is the load-bearing detail.

### `mask_secret(secret: str, visible_chars: int = 4) -> str`

- Purpose: obfuscate a secret for display.
- Inputs: `secret`, `visible_chars` (default 4).
- Output: masked `str`.
- Logic the port must preserve: if `len(secret) <= visible_chars * 2` (i.e. ≤ 8 by default) → return `"*" * len(secret)` (a run of asterisks equal to the secret length, leaking length only). Otherwise return `f"{secret[:visible_chars]}...{secret[-visible_chars:]}"` (first N + literal `...` + last N). Note the boundary is `<=`, so a length-8 secret is fully masked.

### `is_safe_remote_url(url: str) -> bool`

- Purpose: SSRF guard — validate an outbound URL is a public http/https endpoint.
- Inputs: `url`. Output: `bool` (True only if safe).
- URL safety rules the Swift port MUST preserve (security-critical):
    1. `urlparse(url)`; on `ValueError` → `False`.
    2. Scheme must be in `{"http", "https"}` (exact set) → else `False`.
    3. Reject if URL contains `username` or `password` (userinfo) → `False`.
    4. `hostname` must be present and must NOT end with `.local` → else `False`.
    5. DNS resolution via `getaddrinfo(hostname, port, type=SOCK_STREAM)` where port = `parsed.port or (443 if https else 80)`. On `socket.gaierror` (resolution failure) → `False`.
    6. For EVERY resolved address, build `ipaddress.ip_address(sockaddr[0])` and reject (`False`) if ANY of: `is_private`, `is_loopback`, `is_link_local`, `is_multicast`, `is_reserved`, `is_unspecified`. (All resolved IPs must be public; this blocks DNS-rebinding to internal ranges.)
    7. Only if all addresses pass → `True`.
    - Port note: this performs live DNS resolution and inspects all A/AAAA results. INSUFFICIENT DATA: behavior when `getaddrinfo` raises a non-`gaierror` exception (e.g. `UnicodeError` for malformed IDN host) is not handled here and would propagate.

### `is_safe_terminal_text(text: str) -> bool`

- Purpose: reject text containing terminal control characters (anti-injection for terminal output).
- Inputs: `text` (coerced via `str(text)`). Output: `bool`.
- Validation the port must preserve: returns `False` if ANY character has `ord(char) < 0x20` (C0 controls, includes tab/newline/CR) OR `0x7F <= ord(char) <= 0x9F` (DEL + C1 controls). Otherwise `True`. Note tabs and newlines are considered UNSAFE.

---

## `remctl_serialization.py`

Module-level constants:

- `RECURRENCE_FREQUENCIES` = `{0: "daily", 1: "weekly", 2: "monthly", 3: "yearly"}`
- `DUE_DATE_DELTA_UNITS` = `{0: ("minute","minutes"), 1: ("hour","hours"), 2: ("day","days"), 3: ("week","weeks"), 4: ("month","months")}`

Private helpers (`_row_has`, `_row_get`, `_json_blob`) are not public but their semantics are needed:

- `_row_get(row, key, default=None)`: works for dict OR sqlite3.Row-like objects (has callable `.keys()` and `[]` access). Returns `default` when key absent. Swift port's row abstraction must mimic "missing key → default" without throwing.
- `_json_blob(value)`: returns `None` for `value in (None, "")`; decodes `bytes` as UTF-8 with `"replace"` errors; `json.loads`; returns `None` on `TypeError`/`ValueError`. Used to safely parse embedded JSON blobs.

### `recurrence_from_row(row, *, ts=None) -> dict | None`

- Purpose: build a stable recurrence object from aliased `ZREMCDOBJECT` fields.
- Inputs: `row` (dict/Row with aliased keys below); keyword-only `ts` = a callback converting a Core Data timestamp to a `datetime` (only used for `endDate`).
- Output: recurrence dict, or `None`.
- Exact JSON keys produced (in this insertion order):
    - `"frequency"` (string from `RECURRENCE_FREQUENCIES`), `"interval"` (int).
    - `"daysOfWeekDetailed"` (raw list) and `"daysOfWeek"` (list of ints) — only when day-of-week blob non-empty.
    - `"daysOfMonth"`, `"monthsOfYear"`, `"daysOfYear"`, `"weeksOfYear"`, `"setPositions"` — each only when its blob is truthy.
    - `"count"` (int) — only when count truthy.
    - `"endDate"` (ISO 8601 string) — only when `recurrence_end_date` present AND `ts is not None`.
- Recurrence decoding rules the port must preserve:
    - Source aliases consumed: `recurrence_frequency`, `recurrence_interval`, `recurrence_days_of_week`, `recurrence_days_of_month`, `recurrence_months_of_year`, `recurrence_days_of_year`, `recurrence_weeks_of_year`, `recurrence_set_positions`, `recurrence_count`, `recurrence_end_date`.
    - If `recurrence_frequency` is `None` → return `None` (no recurrence).
    - `frequency` mapped via `int(frequency_raw)` into `RECURRENCE_FREQUENCIES`; any `KeyError/TypeError/ValueError` (unknown code or non-numeric) → return `None`.
    - `interval` = `recurrence_interval or 1` (falsy/0/None → 1), coerced `int`.
    - `daysOfWeek`: from `daysOfWeekDetailed`, take `int(item["dayOfTheWeek"])` for each dict item where `item.get("dayOfTheWeek")` is truthy. `daysOfWeekDetailed` keeps the raw decoded list verbatim.
    - The five list aliases are copied verbatim (no transformation) only when truthy.
    - `count` = `recurrence_count or 0`; emitted only if nonzero.
    - `endDate` emitted as `ts(end_date).isoformat()` only if both `end_date` and `ts` present.

### `due_date_delta_alerts_from_row(row, *, ts=None) -> list[dict]`

- Purpose: decode "Early Reminder" due-date delta alerts.
- Inputs: `row`; keyword-only `ts` (timestamp→datetime callback) used for `creationDate`.
- Output: list of alert dicts (possibly empty).
- Source: JSON blob in column `ZDUEDATEDELTAALERTSDATA`; must be a dict with list key `"dueDateDeltaAlerts"`; otherwise returns `[]`.
- Early-reminder decoding rules the port must preserve, per alert dict:
    - Must be a dict; read `dueDateDeltaUnit` and `dueDateDeltaCount`, both coerced via `int(...)`. On `TypeError/ValueError` → skip that alert.
    - `(singular, plural) = DUE_DATE_DELTA_UNITS.get(unit_raw, ("unknown","unknown"))` — unknown unit codes yield `"unknown"`.
    - `value = abs(count)`. `unit_name = singular if value == 1 else plural` (pluralization rule).
    - `direction = "before" if count < 0 else "after"` (note: count == 0 → "after").
    - `label = f"{value} {unit_name} {direction}"`.
- Exact JSON keys produced per item: `"unit"` (string), `"unitCode"` (int = raw unit code), `"count"` (signed int, original), `"value"` (abs int), `"direction"` (`"before"`/`"after"`), `"label"` (string). Optionally: `"identifier"` (only if truthy), `"creationDate"` (only if `creationDate` present AND `ts` not None; computed `ts(float(creation_date)).isoformat()`, swallowing `TypeError/ValueError`), `"minimumSupportedAppVersion"` (only if `alert.get("minimumSupportedAppVersion") is not None`).

### `preload_extras(db, pks) -> tuple[dict, dict]`

- Purpose: batch-load subtask counts and hashtags to avoid N+1 queries.
- Inputs: `db` (DB connection with `.execute`), `pks` (list of reminder `Z_PK` ints). Output: `(subtask_counts, hashtags)`.
- Returns `({}, {})` if `pks` is empty.
- Subtask query (rules the port must preserve): counts rows in `ZREMCDREMINDER` where `ZPARENTREMINDER IN (pks)` AND `ZMARKEDFORDELETION = 0` AND `ZCOMPLETED = 0`, grouped by parent. Result map: `{parent_pk: count}`. (Subtasks that are completed or marked-for-deletion are excluded.)
- Hashtag query: `SELECT o.ZREMINDER3, h.ZNAME FROM ZREMCDOBJECT o JOIN ZREMCDHASHTAGLABEL h ON o.ZHASHTAGLABEL = h.Z_PK WHERE o.ZREMINDER3 IN (pks)`. Result map: `{reminder_pk: [tag_name, ...]}` preserving query row order via `setdefault(...).append(...)`.
- `placeholders` built as comma-joined `?` of length `len(pks)`; parameters bound positionally. Port must parameterize, not interpolate, the pk values.

### `serialize_reminder(row, *, ts, priority_names, db=None, section=None, subtask_counts=None, hashtags=None, rich_link_resolver=None, fallback_subtask_count=None, fallback_hashtags=None) -> dict`

- Purpose: convert one reminder row into a JSON-serializable dict.
- Inputs (keyword-only after `row`):
    - `ts`: Core Data timestamp → datetime callback (used for all date fields).
    - `priority_names`: dict mapping priority int → name string.
    - `db`, `section`, `subtask_counts`, `hashtags`, `rich_link_resolver`, `fallback_subtask_count`, `fallback_hashtags`: optional fallbacks.
- Required source columns (accessed via `row["..."]`, will throw if missing): `Z_PK`, `ZTITLE`, `list_name` (aliased), `ZCOMPLETED`, `ZFLAGGED`, `ZPRIORITY`, `ZPARENTREMINDER`, `ZNOTES`, `ZICSURL`, `ZDUEDATE`, `ZCREATIONDATE`, `ZCOMPLETIONDATE`, `ZCKIDENTIFIER`. Optional (via `_row_get`): `ZISURGENTSTATEENABLEDFORCURRENTUSER`, `ZDISPLAYDATEDATE`, `ZALLDAY`, plus all recurrence/early-reminder aliases.
- Exact JSON keys produced (always present): `"id"` (=`Z_PK`), `"title"`, `"list"` (=`list_name`), `"completed"` (bool), `"flagged"` (bool), `"urgent"` (bool of `ZISURGENTSTATEENABLEDFORCURRENTUSER`, default `False`), `"priority"` (`priority_names.get(ZPRIORITY or 0, "none")`), `"subtaskCount"` (int), `"isSubtask"` (bool of `ZPARENTREMINDER`).
- Conditionally present keys and their rules:
    - `"section"` — only if `section` truthy.
    - `"notes"` — only if `ZNOTES` truthy.
    - `"url"` — `ZICSURL`; if falsy AND `db` and `rich_link_resolver` provided, calls `rich_link_resolver(db, Z_PK)`. Emitted only if resulting url truthy.
    - `"dueDate"` — `ts(ZDUEDATE).isoformat()` only if `ZDUEDATE` truthy.
    - `"displayDate"` — `ts(ZDISPLAYDATEDATE).isoformat()` only if `ZDISPLAYDATEDATE` truthy AND `!= ZDUEDATE` (suppressed when equal to due date).
    - `"allDay"` — `bool(ZALLDAY)` only if `ZALLDAY is not None` (note: presence test is `is not None`, so an explicit `0` still emits `false`).
    - `"createdDate"`, `"completionDate"` — ISO strings, only if respective columns truthy.
    - `"parentID"` — only if `ZPARENTREMINDER` truthy.
    - `"tags"` — only if tags list non-empty.
    - `"recurrence"` — from `recurrence_from_row(row, ts=ts)`, only if non-None.
    - `"earlyReminder"` (the FIRST alert) AND `"earlyReminders"` (full list) — both emitted together only if `due_date_delta_alerts_from_row` returns non-empty.
    - `"deepLink"` — only if `ZCKIDENTIFIER` truthy; format string `f"x-apple-reminderkit://REMCDReminder/{ZCKIDENTIFIER}"`.
- Subtask/tag fallback logic the port must preserve: `subtask_count = subtask_counts.get(Z_PK)`; if `None` and `db` + `fallback_subtask_count` provided → `fallback_subtask_count(db, Z_PK)`, else `0`. Same pattern for `tags` via `fallback_hashtags`, else `[]`.

### `serialize_reminders(rows, *, ts, priority_names, db=None, memberships=None, rich_link_resolver=None, fallback_subtask_count=None, fallback_hashtags=None) -> list[dict]`

- Purpose: serialize many rows with one shared `preload_extras` pass.
- Logic the port must preserve: if `db` is provided, call `preload_extras(db, [row["Z_PK"] for row in rows])` once; else `({}, {})`. `memberships` defaults to `{}`. For each row, calls `serialize_reminder(...)` passing `section=memberships.get(row["ZCKIDENTIFIER"])` (section keyed by CloudKit identifier, NOT pk) and the shared `subtask_counts`/`hashtags`. Output is a list in input row order.

---

## `remctl_smart_lists.py`

Module-level constants (quote exactly):

- `CUSTOM_SMART_LIST_TYPE = "com.apple.reminders.smartlist.custom"` — the type identifier the Swift port must write/recognize for custom smart lists. (Defined but not referenced elsewhere in this module; consumed by callers.)
- `SUPPORTED_PRIORITIES = {"low", "medium", "high"}`
- `SUPPORTED_MATCH_OPERATIONS = {"all": "and", "any": "or", "and": "and", "or": "or"}` — maps user-facing match words to stored operation values. Both user words (`all`/`any`) and raw operations (`and`/`or`) accepted; output is `"and"`/`"or"`.
- `SUPPORTED_TIME_FILTERS = {"morning", "afternoon", "evening", "night", "no-time", "noTime"}`
- `SUPPORTED_RELATIVE_DIRECTIONS = {"in-next":"inNext","innext":"inNext","inNext":"inNext","next":"inNext","in-past":"inPast","inpast":"inPast","inPast":"inPast","past":"inPast"}` — all normalize to `"inNext"`/`"inPast"`.
- `SUPPORTED_RELATIVE_UNITS = {"minute","hour","day","week","month","year"}`
- `SUPPORTED_VEHICLES = {"connected", "disconnected"}`
- `SUPPORTED_PROXIMITIES = {"enter":"enter","arrive":"enter","arriving":"enter","leave":"leave","leaving":"leave","exit":"leave"}` — normalize to `"enter"`/`"leave"`.

### `class SmartListFilterError(ValueError)`

- Purpose: raised when a requested smart list filter is unsupported/invalid. Subclasses `ValueError`.
- Distinct error messages the port must reproduce (each a separate raise site / case):
    1. `normalize_match_operation`: `"Smart list match must be all or any."`
    2. `normalize_priorities`: `"Unsupported smart list priority. Use low, medium, or high."`
    3. `normalize_filter_date` (empty): `"Smart list date cannot be empty."`
    4. `normalize_filter_date` (unparseable): `"Smart list dates must be YYYY-MM-DD or DD-MM-YYYY."`
    5. `normalize_relative_range` (string arity): `"Relative date range must be direction:magnitude:unit[:past-due]."`
    6. `normalize_relative_range` (direction): `"Relative date direction must be in-next or in-past."`
    7. `normalize_relative_range` (magnitude): `"Relative date magnitude must be a positive integer."`
    8. `normalize_relative_range` (unit): `"Relative date unit must be minute, hour, day, week, month, or year."`
    9. `build_supported_filter_payload` (no filters): `"Pass at least one smart list filter."`
    10. `_build_tag_filter` (conflict): `"Pass only one tag filter: --tags, --any-tag, or --untagged."`
    11. `_build_date_filter` (conflict): `"Pass only one date filter."`
    12. `_build_date_filter` (range arity): `"Date range must be START,END."`
    13. `_build_time_filter`: `"Time filter must be morning, afternoon, evening, night, or no-time."`
    14. `_build_location_filter` (both): `"Pass either --vehicle or a specific location, not both."`
    15. `_build_location_filter` (vehicle): `"Vehicle filter must be connected or disconnected."`
    16. `_build_location_filter` (missing keys): `"Specific location requires title, latitude, and longitude."`
    17. `_build_location_filter` (numbers): `"Specific location latitude, longitude, and radius must be numbers."`
    18. `_build_location_filter` (proximity): `"Specific location proximity must be enter or leave."`
    19. `_loads_json_bytes`: `"Smart list filter JSON must be an object"` (raised as plain `ValueError`, caught in decoder).
    20. `encode_supported_filter_payload`: `"Unsupported smart list filter shape."`

Private decode helpers (semantics required by port):

- `_uid_index(value)`: returns `value.data` for `plistlib.UID`, `value` for `int`, else `None`. Used to dereference NSKeyedArchiver UID pointers.
- `_loads_json_bytes(data)`: UTF-8 decode → `json.loads` → must be a `dict` else raises `ValueError("Smart list filter JSON must be an object")`.
- `_extract_keyed_archive_json(data)`: parses an NSKeyedArchiver plist. Requires top-level dict with list `$objects` and dict `$top`; follows `$top["root"]` UID → that object's `data` UID → returns the referenced object iff it is `bytes`, else `None`. Bounds-checks indices (`>= len(objects)` → None).

### `decode_smart_list_filter_blob(blob) -> dict`

- Purpose: decode a stored smart list filter blob into a structured result.
- Inputs: `blob` — `None`, empty bytes/str, raw bytes, or str.
- Output: always a dict with EXACT keys `"encoding"`, `"payload"`, `"summary"`, `"error"`.
- Decode rules the port must preserve:
    - Empty (`blob in (None, b"", "")`) → `{"encoding": None, "payload": None, "summary": None, "error": None}`.
    - str → encoded UTF-8; bytes coerced via `bytes(blob)`.
    - `stripped = raw.lstrip()`. If `stripped.startswith(b"{")` → treat as raw JSON (`encoding="json"`). The two recognized encodings: `"json"` (macOS 26 raw UTF-8 JSON) and `"keyed_archive_json"` (NSKeyedArchiver-wrapped JSON via `_extract_keyed_archive_json`).
    - On success: `{"encoding": <"json"|"keyed_archive_json">, "payload": <dict>, "summary": summarize_smart_list_filter(payload), "error": None}`.
    - Caught exceptions (`UnicodeDecodeError, json.JSONDecodeError, plistlib.InvalidFileException, ValueError`) → `{"encoding": None, "payload": None, "summary": None, "error": str(exc)}`.
    - Falls through (not JSON, not keyed archive) → `{"encoding": None, "payload": None, "summary": None, "error": "unsupported filter blob"}`.

### `summarize_smart_list_filter(payload) -> dict | None`

- Purpose: produce a human/structured summary of a decoded filter payload and decide `supported`.
- Inputs: `payload` (dict or None). Output: summary dict or `None`.
- Rules/exact keys the port must preserve:
    - `payload is None` → `None`.
    - `keys = sorted(str(key) for key in payload.keys())` (sorted string list, reused as `"keys"`).
    - Empty dict `{}` → `{"kind":"all","description":"All reminders","supported":True,"keys":[]}`.
    - `{"flagged": True}` exactly → `{"kind":"flagged","description":"Flagged reminders","supported":True,"keys":["flagged"]}`.
    - Pull `operation = payload.get("operation")`; build `payload_without_operation` (all keys except `"operation"`).
    - Priority-only special case: if `payload_without_operation` keys == `{"priorities"}` and it's a non-empty list of strings all in `SUPPORTED_PRIORITIES` → `{"kind":"priority","description":f"Priority: {label}","supported":True,"priorities":priorities,"keys":["priorities"] + (["operation"] if operation else [])}` where `label = ", ".join(priorities)`.
    - General case: for each non-operation key call `_summarize_filter_family(key,value)`; partition into `parts` (supported) / `unsupported`.
        - If `parts and not unsupported`: `match = {"and":"all","or":"any"}.get(operation,"all")`; `description = "; ".join(part["description"] ...)`; if `len(parts) > 1 or operation == "or"` prefix `f"Match {match}: "`. Result `{"kind": "compound" if len(parts)>1 else parts[0]["kind"], "description":..., "supported":True, "match":match, "filters":parts, "keys":keys}`.
        - Else → `{"kind":"unsupported","description":"Unsupported custom filter","supported":False,"materializes": False if any(part.get("materializes") is False for part in unsupported) else None, "filters": parts + unsupported, "keys":keys}`. Note `materializes` is `False` only if some unsupported part explicitly has `materializes is False`, otherwise `None`.

### `_summarize_filter_family(key, value) -> dict` (effectively internal but defines summary shapes)

- Per-family summary builder. Recognized families and their output `"kind"` values: `flagged`, `priority`, `tags`, `date` (delegates to `_summarize_date_filter`), `time`, `location`, `lists`. Unrecognized → `{"kind": str(key), "description": f"Unsupported {key} filter", "supported": False}`.
- Notable encode/decode rule the port must preserve: legacy `hashtags` of shape `{"hashtags": [..strings..]}` is decoded but marked `"supported": False, "materializes": False` (cannot be materialized). Modern shape `{"hashtags": {"operation": "and"|"or", "include": [...], "exclude": [...]}}` is supported; `match = "any" if op=="or" else "all"`. `{"any":""}` → "Any tag", `{"untagged":""}` → "Untagged only".

### `_summarize_date_filter(value) -> dict` (internal; defines date summary shapes)

- Recognizes: `{"any":""}`→`date:"any"`; `{"noDate":""}`→`date:"noDate"`; `{"today": bool}`→`date:"today"` with `"includePastDue"` = the bool; sole-key `onDate`/`beforeDate`/`afterDate` (string)→`date:<key>`,`"value"`; sole-key `dateRange` = list of exactly 2 strings→`date:"dateRange"`,`"range"`; `relativeRange` dict containing `{"direction","magnitude","units"}`→`date:"relativeRange"`, with `"includePastDue"` honored in description. Anything else → `{"kind":"date","description":"Unsupported date filter","supported":False}`.

### `normalize_match_operation(match) -> str`

- Purpose: normalize a match word to stored operation.
- Input: `match` (any; `None`→default). Output: `"and"` or `"or"`.
- Rules: `value = str(match or "all").strip()` (None/empty → `"all"`). If not in `SUPPORTED_MATCH_OPERATIONS` keys → raise `SmartListFilterError("Smart list match must be all or any.")`. Returns mapped value. NOTE: NOT lowercased — `"ALL"` would fail; case-sensitive match against keys `{"all","any","and","or"}`.

### `normalize_priorities(priorities) -> list[str]`

- Purpose: validate+dedupe priorities.
- Input: iterable or None. Output: list of canonical lowercase priority strings, order-preserving, deduped.
- Rules: each item `str(priority).strip().lower()`; must be in `SUPPORTED_PRIORITIES` else raise `SmartListFilterError("Unsupported smart list priority. Use low, medium, or high.")`. Duplicates skipped (first occurrence wins).

### `normalize_filter_date(value) -> str`

- Purpose: normalize a date to stored `DD-MM-YYYY` format.
- Input: `datetime` or string. Output: `"%d-%m-%Y"` string.
- Date math/parsing rules the port must preserve: `datetime` → `strftime("%d-%m-%Y")`. String stripped; empty → raise `"Smart list date cannot be empty."`. Try formats in order: `"%Y-%m-%d"`, `"%d-%m-%Y"`, `"%d/%m/%Y"`, `"%Y/%m/%d"`; first that parses → reformat to `"%d-%m-%Y"`. None parse → raise `"Smart list dates must be YYYY-MM-DD or DD-MM-YYYY."`. (Output format is always day-month-year, hyphen-separated, zero-padded.)

### `normalize_relative_range(value) -> dict`

- Purpose: normalize a relative date range.
- Input: dict (`direction`/`magnitude`/`units`/optional `includePastDue`) OR a string `"direction:magnitude:unit[:past-due]"`.
- Output JSON keys (insertion order matters): `"direction"`, `"magnitude"`, optionally `"includePastDue"` (`True`), then `"units"`. Note `magnitude` is stored as a STRING (not int) — `payload = {"direction": direction, "magnitude": magnitude}` where `magnitude` is the stripped string.
- Rules the port must preserve:
    - String form: split on `":"`, drop empties; arity must be 3 or 4 else raise `"Relative date range must be direction:magnitude:unit[:past-due]."`. 4th part enables `includePastDue` if in `{"past-due","include-past-due","includePastDue","true"}`.
    - Dict form: `includePastDue = bool(value.get("includePastDue", False))`.
    - `direction` mapped via `SUPPORTED_RELATIVE_DIRECTIONS` (stripped, case-sensitive on keys); falsy result → raise `"Relative date direction must be in-next or in-past."`.
    - `magnitude` stripped string; must be `.isdigit()` AND `int(magnitude) > 0` else raise `"Relative date magnitude must be a positive integer."`.
    - `units` stripped, lowercased; trailing `"s"` stripped (singularized); must be in `SUPPORTED_RELATIVE_UNITS` else raise `"Relative date unit must be minute, hour, day, week, month, or year."`.
    - `includePastDue` key only added when true.

### `build_supported_filter_payload(*, match="all", flagged=False, priorities=None, tags=None, tag_match="any", any_tag=False, untagged=False, date_any=False, date_today=False, date_today_include_past_due=False, date_no_date=False, date_on=None, date_before=None, date_after=None, date_range=None, date_relative=None, time_filter=None, include_list_ids=None, exclude_list_ids=None, list_match=None, vehicle=None, location=None) -> dict`

- Purpose: assemble a validated filter payload dict from keyword options.
- Output: the filter payload (a `dict`) ready for `encode_supported_filter_payload`.
- Assembly order (defines key insertion order in output) and rules the port must preserve:
    1. `flagged` → `("flagged", True)`.
    2. `normalize_priorities(priorities)` → `("priorities", [...])` if non-empty.
    3. `_build_tag_filter(...)` → `("hashtags", ...)` if non-None.
    4. `_build_date_filter(...)` → `("date", ...)` if non-None.
    5. `_build_time_filter(time_filter)` → `("time", ...)` if non-None.
    6. `_build_lists_filter(...)` → `("lists", ...)` if non-None.
    7. `_build_location_filter(...)` → `("location", ...)` if non-None.
    - If no filters collected → raise `SmartListFilterError("Pass at least one smart list filter.")`.
    - `operation = normalize_match_operation(match)`. `"operation"` key is added to payload FIRST (before filters) only if `len(filters) > 1 OR operation == "or"`. Then each `(key, value)` appended in collection order. (So `operation` precedes filter keys when present.)

### `encode_supported_filter_payload(payload) -> bytes`

- Purpose: validate and serialize a filter payload to the stored byte form.
- Output: UTF-8 bytes of compact JSON.
- Validate/encode rules the port must preserve: calls `summarize_smart_list_filter(payload)`; if summary falsy OR `not summary.get("supported")` OR `summary.get("kind") == "all"` → raise `SmartListFilterError("Unsupported smart list filter shape.")` (note: the empty `{}` "all" filter is explicitly rejected for encoding). Else `json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")` — compact separators (no spaces), non-ASCII preserved (not escaped). This matches the macOS 26 raw-JSON storage form decoded by `decode_smart_list_filter_blob`.

Internal builders' encode rules the Swift port must preserve:

### `_build_tag_filter(*, tags=None, tag_match="any", any_tag=False, untagged=False)`

- `tags` normalized: each `str(tag).lstrip("#").strip()`, dropping empties (leading `#` stripped). Mutually exclusive: `sum(bool(tags), any_tag, untagged) > 1` → raise conflict error. Returns: `{"any":""}` for `any_tag`; `{"untagged":""}` for `untagged`; for explicit tags `{"hashtags": {"operation": normalize_match_operation(tag_match), "include": tags, "exclude": []}}`; else `None`.

### `_build_date_filter(...)`

- At most one date option allowed (counts truthy among the eight; `today or today_include_past_due` counts as one) → raise `"Pass only one date filter."`. Outputs (exact shapes): `{"any":""}`; `{"today": bool(today_include_past_due)}` (so plain `today` → `{"today": False}`); `{"noDate":""}`; `{"onDate": normalize_filter_date(on)}`; `{"beforeDate": ...}`; `{"afterDate": ...}`; `{"dateRange": [start, end]}` (range string split on `","`, with `".."` first replaced by `","`; must yield exactly 2 parts else raise `"Date range must be START,END."`); `{"relativeRange": normalize_relative_range(relative)}`.

### `_build_time_filter(value)`

- `None` → None. Stripped value must be in `SUPPORTED_TIME_FILTERS` else raise time error. `"no-time"` converted to `"noTime"`. Returns `{<normalized>: ""}`.

### `_build_lists_filter(include_list_ids=None, exclude_list_ids=None, *, list_match=None)`

- Builds include/exclude string lists (stripped, empties dropped). If neither → None. Default operation when `list_match is None`: `"or"` if `len(include) > 1 and not exclude`, else `"and"`. If `list_match` given → `normalize_match_operation`. The `"operation"` key is added to the payload only if `operation == "or" OR len(include) > 1 OR exclude` (otherwise omitted). Payload base: `{"include": [...], "exclude": [...]}`.

### `_build_location_filter(*, vehicle=None, location=None)`

- Both set → raise `"Pass either --vehicle or a specific location, not both."`. Vehicle path: stripped value must be in `SUPPORTED_VEHICLES` → `{"vehicle": value}`. Location path: requires keys `{"title","latitude","longitude"}` (else raise); `latitude`/`longitude`/`radius` (default 100) coerced to `float` (TypeError/ValueError → raise numbers error); `proximity` (default `"enter"`) mapped via `SUPPORTED_PROXIMITIES` (else raise). Output key order: `{"location": {"title", "latitude", "radius", "longitude", "proximity"}}` (note `radius` precedes `longitude` in insertion order).

---

INSUFFICIENT DATA notes:

- The actual `ts` timestamp-conversion implementation (Core Data epoch offset, e.g. 978307200 seconds / 2001-01-01) is NOT in these files — it is injected by callers. The Swift port must source the exact epoch/conversion from the caller modules (not present here).
- `priority_names` mapping (int→string) is supplied by callers; not defined in `remctl_serialization.py`. The default fallback is the literal `"none"`.
- `rich_link_resolver`, `fallback_subtask_count`, `fallback_hashtags` are callbacks defined elsewhere; their bodies are not in these files.
- Day-of-week integer encoding semantics (what `dayOfTheWeek` ints mean, e.g. 1=Sunday) are not defined here; values are passed through verbatim.
- `CUSTOM_SMART_LIST_TYPE` is defined but not used within `remctl_smart_lists.py`; how/where it is written to the store is in caller code not provided.

Relevant files (absolute paths): `/Users/orion/Developer/Playgrounds/remctl/remctl_runtime.py`, `/Users/orion/Developer/Playgrounds/remctl/remctl_serialization.py`, `/Users/orion/Developer/Playgrounds/remctl/remctl_smart_lists.py`.

## Folded-in helpers (EventKit / private / AppKit)

<!-- recon: helpers (agent-aa98d58c7b10775f0) -->

I now have the complete picture of all three files. Here is the full documentation.

---

## remctl-bridge.swift (EventKit)

Reads a single JSON object on **stdin** (decoded into `Command`), takes **no argv flags**. Writes one JSON object on **stdout**. Dispatches on the `action` field. Caps stdin at 1 MiB. Errors emit `{"status":"error","message":...}` and `exit(1)`; success paths `exit(0)`.

**Shared input fields (`Command`):** `action`, `id`, `title`, `newTitle`, `list`, `due`, `priority`, `notes`, `url`, `flagged`, `recurrence` (`{frequency, interval, daysOfWeek[], daysOfMonth[], end}`), `alarm`, `clearAlarms`, `locationTitle`, `latitude`, `longitude`, `radius`, `proximity`, `color`.

**Shared mechanics for callers to port directly:**

- Access gate: every action except `authorize` first calls `requestAccess` → `store.requestFullAccessToReminders` (synchronous via semaphore). On error/denied → fail.
- Date parsing (`parseISO`): tries `ISO8601` with TZ → naive local `yyyy-MM-dd'T'HH:mm:ss` → `yyyy-MM-dd HH:mm` → date-only (`yyyy-MM-dd` interpreted as local midnight).
- `parseAlarm`: relative `-Nm`/`-Nh`/`-Nd` → `EKAlarm(relativeOffset:)`; otherwise absolute ISO → `EKAlarm(absoluteDate:)`.
- `applyFields` is shared by create/update and applies title, list (`findList`: matches `EKCalendar.title` across `calendars(for: .reminder)`), due (`dueDateComponents` y/mo/d/h/min/s **without** embedding `.timeZone`, plus `reminder.timeZone = .current` — load-bearing per the inline comment for CloudKit sync), priority (0–9), notes, url (appended to notes — `EKReminder.url` does NOT map to the displayed ZICSURL field), flagged (priority 1 proxy), recurrence, alarm/clearAlarms, location alarm.
- `findReminder`: `store.calendarItem(withIdentifier:)` cast to `EKReminder`.
- `colorForName`: maps red/orange/yellow/green/blue/purple/brown/cyan → `CGColor`.
- "due explicitly null" detection: re-parses raw JSON via `JSONSerialization` to distinguish JSON `null` from omitted; only `update` acts on it (clears `dueDateComponents`).

### authorize

- **Input:** `action:"authorize"`. **Does not** require prior access.
- **API:** `requestFullAccessToReminders`, then `calendars(for:.reminder).count`, `defaultCalendarForNewReminders()`.
- **Output:** `{status:"authorized", calendarCount:N, defaultList:"..."}`. exit 0.

### create

- **Input:** `title` (required, non-empty); optional `list` (defaults to `defaultCalendarForNewReminders()`), plus all `applyFields` fields.
- **API:** `EKReminder(eventStore:)`, `store.save(_, commit:true)`.
- **Output:** `{status:"created", id:<calendarItemIdentifier>, title}`. Failures: "title is required for create", "Save failed: …".

### update

- **Input:** `id` (required) + any `applyFields` fields; `due:null` clears the due date.
- **API:** `findReminder`, `applyFields`, `store.save(commit:true)`.
- **Output:** `{status:"updated", id}`.

### delete

- **Input:** `id`. **API:** `findReminder`, `store.remove(_, commit:true)`. **Output:** `{status:"deleted", id}`.

### complete

- **Input:** `id`. **API:** set `isCompleted=true`, `save`. **Output:** `{status:"completed", id}`.

### uncomplete

- **Input:** `id`. **API:** `isCompleted=false`, `completionDate=nil`, `save`. **Output:** `{status:"uncompleted", id}`.

### flag

- **Input:** `id`. **API:** if `priority==0` set `priority=1` (EventKit has no real flag API), `save`. **Output:** `{status:"flagged", id}`.

### unflag

- **Input:** `id`. **API:** if `priority==1` set `priority=0`, `save`. **Output:** `{status:"unflagged", id}`.

### create_list

- **Input:** `title` (required); optional `color`.
- **API:** `EKCalendar(for:.reminder, eventStore:)`; source = first `.calDAV` else first `.local` source; `cgColor` from `colorForName`; `store.saveCalendar(_, commit:true)`.
- **Output:** `{status:"created", id:<calendarIdentifier>, title}`. Fail if no suitable source.

### rename_list

- **Input:** `title` (current name, required), `newTitle` (required).
- **API:** `findList(title)`, set `.title=newTitle`, `saveCalendar`. **Output:** `{status:"renamed", id, title}`.

### delete_list

- **Input:** `title`. **API:** `findList`, `store.removeCalendar(_, commit:true)`. **Output:** `{status:"deleted", title}`.

### default / unknown

- Fails `"Unknown action: <action>"`, exit 1.

---

## remctl-permissions.swift (AppKit GUI)

A standalone Cocoa app (`NSApplication`, `.regular` activation policy). Configured **entirely via argv** (no stdin). Its job: guide the user to grant Full Disk Access and verify that the configured targets can read the Reminders SQLite store. **No JSON output** — output is shown in an in-window log `NSTextView`. Runs `app.run()` until the user quits; **no defined exit code contract** (terminates via "Done" → `NSApp.terminate`).

### argv flags (`parseOptions`)

- `--title <string>` — window header title (default "RemCTL Permissions").
- `--subtitle <string>` — header subtitle.
- `--target <title> <path> <subtitle>` — adds a `PermissionTarget` (consumes 3 args, repeatable). If none given, a default `/usr/bin/python3` target is injected.
- `--after <title> <command>` — adds an `AfterCommand` button that runs `command` via `/bin/zsh -lc` (consumes 2 args, repeatable).
- `--no-open` — suppress auto-opening System Settings on launch.
- Unrecognized args are skipped.

### Window behavior / AppKit surface

- On launch: `setActivationPolicy(.regular)`, sets app icon from sibling `remctl-permissions-icon.png` (resolved relative to `argv[0]`), builds a 600×560 `NSWindow` (`.titled,.closable,.miniaturizable`, centered, `makeKeyAndOrderFront`), `NSApp.activate(ignoringOtherApps:true)`.
- If `autoOpenSettings`: opens Full Disk Access pane trying URLs `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles` then `…com.apple.preference.security?Privacy_AllFiles` via `NSWorkspace.shared.open`.
- Copies the first target's path to the pasteboard (string + fileURL types).
- Header buttons: **Open Full Disk Access** (default key `\r`), **Check Access** (forces a verify pass + logs "Verified X of N…"), **Done** (terminates).
- Each target → `TargetRowView`: shows icon (Python icon special-cased via `pythonFrameworkRoot`/`.icns`, else `NSWorkspace.icon(forFile:)`), title/subtitle/path, **Copy Path** and **Reveal** (Finder) buttons, and a live status field. The row is an `NSDraggingSource` — `mouseDown` copies the path and begins a drag of the file URL (`.copy` op) so it can be dropped into the FDA list.
- A 2-second repeating `Timer` re-verifies all targets; statuses render as "Checking…", "✓ Access verified" (green), "Needs access" (orange).
- `--after` command buttons run async via `/bin/zsh -lc`, with a `PATH` prepended with `~/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`; stdout+stderr captured to the log; refreshes statuses after.

### Verification logic (the load-bearing part to port)

- `verifyPermissionTarget`: if target path is a Python executable (`isPythonExecutable`: basename starts "python" and is executable) → spawns that interpreter with `-c <script>` that globs `~/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/Data-*.sqlite` and checks `os.access(R_OK)` (exit 0 = verified). Otherwise → in-process `remindersStoreReadable()`: lists that Stores dir for a readable `Data-*.sqlite`.

INSUFFICIENT DATA: This helper never prints machine-readable output and has no explicit `exit()` calls other than via the AppKit run loop, so there is no scriptable success/failure exit code. Folding it in-process means the parent Swift CLI must invoke the GUI as a UI mode, not as a data-returning subcommand.

---

## remctl-private.m (private ReminderKit / Obj-C)

Reads one JSON object on **stdin** (`cmd`, an `NSDictionary`), **no argv flags**. Caps stdin at 1 MiB. Dispatches on `cmd[@"action"]` against a fixed allow-list (else fail "Unknown action"). Each op builds a `REMStore`, a `REMSaveRequest`, mutates change items, then `saveSynchronouslyWithError:`. Errors → `{"status":"error","message":...}` + `exit(1)`. Success → JSON dict + `return 0`.

**Object-ID URL scheme** (used by ID-based ops): `x-apple-reminderkit://REMCD{Reminder|ListSection|List|SmartList|Template}/<ckIdentifier>`, fed to `[REMObjectID objectIDWithURL:]`.

**Account resolution** (create-type ops): `fetchPrimaryActiveCloudKitAccountWithError:` → fallback `fetchDefaultAccountWithError:`.

**Color (`makeREMColor`):** named palette red/orange/yellow/green/blue/purple/brown/gray/cyan/teal → `REMColor initWithRed:green:blue:alpha:colorSpace:2 daSymbolicColorName:daHexString:ckSymbolicColorName:`; or `#RRGGBB` hex (regex `^#[0-9A-F]{6}$`) → custom. `cyan` symbolic name is remapped to hex `#5AC8FA` (ReminderKit rejects symbolic cyan).

**URL SSRF guard (`looksLikeWebURL`):** scheme must be http/https, host must resolve (via `getaddrinfo`) only to public addresses — rejects localhost, `.local`, and all RFC1918/loopback/link-local/CGNAT/multicast (IPv4 + IPv6 ULA/loopback/link-local).

**Shared appearance helper `applyListAppearance`** (used by create_list, create/update_smart_list, set_list_appearance): `color` via `setColor:` (on change or its `customContext`); `symbol` via `appearanceContext.setBadgeEmblem:` or `REMListBadge initWithEmblem:` → `setBadge:`; `emoji` via `REMListBadge initWithEmoji:` → `setBadge:`.

**Shared grocery helper `applyListGroceryMetadata`** (create_list, set_list_appearance): reads `shouldCategorizeGroceryItems` (bool) and `groceryLocaleID` (string) → `REMListGroceryContextChangeItem setShouldCategorizeGroceryItems:`/`setGroceryLocaleID:`.

The actions split into **two groups**: ID-less list/smart-list/template ops (each `return 0` early) and **reminder-scoped ops** that fall through to the bottom block requiring `cmd[@"id"]` (a reminder ckIdentifier) and emit a common tail with `urlsAdded/tagsAdded/imagesAdded/subtasksAdded`.

### create_list

- **Input:** `name` (required); optional `color`, `symbol`, `emoji`, `shouldCategorizeGroceryItems`, `groceryLocaleID`.
- **API:** resolve account → `updateAccount:` → `addListWithName:toAccountChangeItem:listObjectID:nil` → `setParentOwnerID:[account remObjectID]` → `addListChangeItem:` → `applyListAppearance` + `applyListGroceryMetadata` → save.
- **Output:** `{status:"created", action, name, color?, symbol?, emoji?, grocery…?, id:<uuid>, url}`.

### set_list_appearance

- **Input:** `listId` (required); optional `name`, `color`, `symbol`, `emoji`, grocery fields.
- **API:** `fetchListWithObjectID:` → `updateList:` → optional `setName:` → `applyListAppearance` + `applyListGroceryMetadata` → save.
- **Output:** `{status:"updated", action, listId, name?, color?, symbol?, emoji?, grocery…?}`.

### set_list_pinned

- **Input:** `listId`, `pinned` (bool, required). **API:** `fetchListWithObjectID:` → `updateList:` → `setIsPinned:` → save. **Output:** `{status:"updated", action, listId, pinned}`. Fails if change item lacks `setIsPinned:`.

### set_smart_list_pinned

- **Input:** `smartListId`, `pinned`. **API:** fetch via `fetchSmartListWithObjectID:` (if responds) else `fetchCustomSmartListWithObjectID:` → `updateSmartList:` → `setIsPinned:` → save. **Output:** `{status:"updated", action, smartListId, pinned}`.

### categorize_grocery_items

- **Input:** `listId`, `reminderIds` (string|array, ≥1). **API:** `fetchListWithObjectID:` → `updateList:` → `groceryContextChangeItem` → build reminder `REMObjectID` UUIDs → `categorizeGroceryItemsWithReminderIDs:` (wrapped in `@try`) → save. **Output:** `{status:"updated", action, listId, remindersCategorized:N}`.

### create_smart_list

- **Input:** `name` (required), `filterData` (base64, required, ≤64 KiB); optional `color`/`symbol`/`emoji`.
- **API:** resolve account → check `[[account capabilities] supportsCustomSmartLists]` → `updateAccount:` → `addCustomSmartListWithName:toAccountChangeItem:smartListObjectID:nil` → `setParentOwnerID:` → `addSmartListChangeItem:` → `customContext.setName:` → `setCustomSmartListSupportedVersion` (sets KVC `minimumSupportedVersion`/`effectiveMinimumSupportedVersion` = `20220430`) → `setSmartListType:@"com.apple.reminders.smartlist.custom"` → `setFilterData:` → `applyListAppearance` → save.
- **Output:** `{status:"created", action, name, …appearance, id:<uuid>, url}`.

### update_smart_list

- **Input:** `smartListId` (required); ≥1 of `filterData` (base64), `name`, or appearance (`color`/`symbol`/`emoji`).
- **API:** `fetchCustomSmartListWithObjectID:` → `updateSmartList:` → `setSmartListType:` → `setCustomSmartListSupportedVersion` → optional `setFilterData:`/`setName:` → `applyListAppearance` → save.
- **Output:** `{status:"updated", action, id, …appearance}`.

### delete_smart_list

- **Input:** `smartListId`. **API:** `fetchCustomSmartListWithObjectID:` → account (from `[smartList account]` else resolve) → `updateAccount:` → `updateSmartList:` → `removeFromParentWithAccountChangeItem:` → save. **Output:** `{status:"deleted", action, id}`.

### create_template

- **Input:** `name` (required), `listId` (required, source list), `includeCompleted` (bool, default false).
- **API:** `fetchListWithObjectID:` (validates source) → resolve account → `updateAccount:` → `REMTemplateConfiguration initWithSourceListID:shouldSaveCompleted:` → `addTemplateWithName:configuration:toAccountChangeItem:` → save.
- **Output:** `{status:"created", action, name, sourceListId, includeCompleted, id:<uuid>, url}`.

### apply_template

- **Input:** `templateId`. **API:** `fetchTemplateWithObjectID:` → resolve account → `updateAccount:` → `addListUsingTemplate:toAccountChangeItem:` → save. **Output:** `{status:"created", action, templateId, id:<new list uuid>, url}`.

### delete_template

- **Input:** `templateId`. **API:** `fetchTemplateWithObjectID:` → `updateTemplate:` → `removeFromParentAccount` → save. **Output:** `{status:"deleted", action, id}`.

---

The remaining actions are **reminder-scoped**: they require `cmd[@"id"]` (reminder ckIdentifier), do `fetchReminderWithObjectID:` → `updateReminder:` → mutate `REMReminderChangeItem` → save, and share the tail output `{status:"updated", id, action, urlsAdded, tagsAdded, imagesAdded, subtasksAdded, …per-action}`.

### add_private_metadata

- **Input:** `id`; `urls` (string|array) and/or `tags` (string|array) — ≥1 required between them. Also opportunistically applies `applyPrivateMetadataToChange`-style fields? — NO: this action uses the explicit tail blocks. URLs via `attachmentContext.addURLAttachmentWithURL:` (each validated by `looksLikeWebURL`); tags via `hashtagContext.addHashtagWithType:1 name:`.
- **Output tail** with `urlsAdded`/`tagsAdded`.
- Note: the standalone helper `applyPrivateMetadataToChange` (urls+tags+images+`flagged` via `flaggedContext`+`urgent` via `urgentAlarmContext`+location) is **defined but not invoked by any dispatched action** in `main`. INSUFFICIENT DATA: it appears to be dead/library code; the Swift port may want it as the consolidated path but no action currently calls it.

### add_url_attachments

- **Input:** `id`, `urls` (≥1). **API:** `attachmentContext.addURLAttachmentWithURL:` per URL (SSRF-validated). Output tail.

### add_tags

- **Input:** `id`, `tags` (≥1). **API:** `hashtagContext.addHashtagWithType:1 name:` per tag. Output tail.

### add_subtasks

- **Input:** `id`; either `subtasks` (array of objects, each requires `title`) or `titles` (string|array). At least one required.
- **API:** `change.subtaskContext` → per subtask `[save addReminderWithTitle:toReminderSubtaskContextChangeItem:]` → collect `remObjectID` uuid + urlRepresentation.
- **Output:** adds `subtaskURLs:[...]` and `subtasks:[{id,title,url}]`, plus `subtasksAdded`. INSUFFICIENT DATA: subtask object fields beyond `title` are accepted into the spec array but only `title` is consumed.

### assign_section

- **Input:** `id`, `sectionId`. **API:** `fetchListSectionWithObjectID:` → `updateList:[reminder list]` → `sectionsContextChangeItem` → build `REMMembership initWithMemberIdentifier:[reminder uuid] groupIdentifier:[section uuid] isObsolete:NO modifiedOn:now` → `REMMemberships` → `setUnsavedMembershipsOfRemindersInSections:`. Output adds `sectionId`.

### add_section_and_assign

- **Input:** `id`, `name` (new section name). **API:** `updateList:[reminder list]` → `sectionsContextChangeItem` → `addListSectionWithDisplayName:toListSectionContextChangeItem:` → membership wiring + `setUnsavedSectionIDsOrdering:[sectionObjectID]` + `setShouldUpdateSectionsOrdering:YES`. Output adds `sectionURL`.

### add_attachments

- **Input:** `id`, `images` (string|array, ≥1); optional `width`/`height` (default to intrinsic image size); `files` explicitly **rejected** ("Generic file/PDF attachments are not supported; use images only").
- **API:** per image: readability check, `NSImage` validity check, `attachmentContext.addImageAttachmentWithURL:width:height:error:`. Output tail (`imagesAdded`).

### set_flagged

- **Input:** `id`, `flagged` (bool). **API:** `flaggedContext.setFlagged:` (1/0). Output adds `flagged`.

### set_urgent

- **Input:** `id`, `urgent` (bool). **API:** `urgentAlarmContext.setIsUrgentStateEnabledForCurrentUser:`. Output adds `urgent`.

### set_early_reminder

- **Input:** `id`; optional `existingIdentifiers` (array of UUID strings to remove), `clear` (bool), or `unit`+`count`.
- **API:** `change.dueDateDeltaAlertContext`; if `existingIdentifiers` → `removeDueDateDeltaAlertsWithIdentifiers:`; always `removeAllFetchedDueDateDeltaAlerts`; if not `clear` → validate `unit` 0–4 and `count != 0` → `REMDueDateDeltaInterval initWithUnit:count:` → `addDueDateDeltaAlertWithDueDateDelta:`.
- **Output:** adds `earlyReminderRemoved?`, `earlyReminderCleared?`, or `earlyReminder:{unit,count}`. INSUFFICIENT DATA: the integer meaning of `unit` (0–4) is not documented in-file (likely minute/hour/day/week/month, unconfirmed).

### add_location_alarm

- **Input:** `id`; `latitude`, `longitude` (validated ±90/±180); optional `title` (default "Location"), `radius` (default 100), `proximity` (1=enter default, 2=leave; others coerced to 1), `address`.
- **API:** `REMStructuredLocation initWithTitle:locationUID:<UUID>:latitude:longitude:radius:address:routing:nil referenceFrameString:nil contactLabel:nil mapKitHandle:nil` → `REMAlarmLocationTrigger initWithStructuredLocation:proximity:` → `REMAlarm initWithTrigger:` → `change.addAlarm:`. Output adds `locationTitle`.

**Files:** `/Users/orion/Developer/Playgrounds/remctl/remctl-bridge.swift`, `/Users/orion/Developer/Playgrounds/remctl/remctl-permissions.swift`, `/Users/orion/Developer/Playgrounds/remctl/remctl-private.m`.

## Parity-critical test contract

<!-- recon: tests (agent-a99e1f8abac674ea5) -->

I now have the full picture of all four test files. Let me compile the parity-critical behavioral contract.

# RemCTL Swift Testing Port — Parity-Critical Behavioral Contract

Distilled from `tests/test_cli.py`, `tests/test_runtime.py`, `tests/test_smart_lists.py`, `tests/helpers.py`. Each bullet pins an OBSERVABLE contract (exact strings, JSON keys/values, exit codes, fixture/mock assumptions).

---

## Test harness & fixture conventions (cross-cutting)

- `helpers.load_module` loads `remctl` (the CLI script) by source path; the Swift port must expose the same set of callable units (`parse_*`, `cmd_*`, `private_*`, `bridge_*`, `resolve_*`, `q_*`, `apply_private_changes`, `to_dict`, `fmt`, etc.) as testable seams.
- Python tests stub via `mock.patch.object` against named module functions. The Swift design must allow injecting/overriding: `open_db`, `bridge_available`, `bridge_call`, `private_available`, `private_call`, `private_action`, `q_reminder`, `q_reminders`, `q_alarms`, `q_sections`, `q_section_memberships`, `q_rich_link`, `q_reminder_by_identifier`, `q_list_exact_name_count`, `resolve_list_or_die`, `resolve_required_list_target_or_die`, `osa_by_id_try`, `wait_for_grocery_section`, `preload_extras`, `apply_private_changes`.
- Mock DBs are in-memory SQLite with `sqlite3.Row` rows; column names exactly as listed in fixtures below (Core Data `Z*` schema). Swift port must read these exact column names.
- Human output assertions use substring matching after ANSI stripping (`_strip_ansi`). Color disabled via `C.enabled = False` in some tests.
- Error paths raise `SystemExit`; exit code asserted only where noted (else just "exits"). Error text written to stderr; success/data to stdout.

---

## parse\_\* helpers (value normalization)

- `parse_alarm("15m")` → `"-15m"`; `parse_alarm("2h")` → `"-2h"`; `parse_alarm("2026-04-15 14:00")` → `"2026-04-15T14:00:00"` (relative gets leading `-`; absolute → ISO `T`-joined, seconds appended).
- `parse_early_reminder("15 minutes")` → `{"unit": 0, "unitName": "minutes", "count": -15, "value": 15}`.
- `parse_early_reminder("1h before")` → `{"unit": 1, "unitName": "hour", "count": -1, "value": 1}`.
- `parse_early_reminder("clear")` → `{"clear": True}`.
- `parse_early_reminder("eventually")` → `None`.
- `parse_due("today at 3pm")` → not None, `(hour,minute)==(15,0)`.
- `parse_due("tomorrow 15:30")` → `(15,30)`; date is exactly 1 day after `today at 3pm` date.
- `parse_due("tonight at 11")` → `(23,0)`.
- `parse_due("Friday at 15:00")` → `(15,0)`.
- `parse_due("today at 25:00")` → `None` (invalid clock rejected).
- `parse_recurrence("weekly mon,wed")` → `{"frequency": "weekly", "interval": 1, "daysOfWeek": [2, 4]}` (mon=2, wed=4; ISO-ish weekday numbering where Sun=1).
- `parse_recurrence` returns `None` for: `"fortnightly"`, `"weekly funday"`, `"monthly 0,32"`.
- `parse_subtask_specs` accepts a JSON string spec. Output keys: `title`, `notes`, `due` (normalized to ISO `2026-04-15T14:00:00`), `urls` (list — `url` singular folded into `urls`), `tags` (list), `priority` (passthrough string `"high"`), `alarm` (normalized: `"15m"`→`"-15m"`), `flagged` (bool), `urgent` (bool), `proximity` (mapped string→int: `"arriving"`→`1`).
- `parse_subtask_specs` with a non-http(s) url (`file:///...`) → exits; stderr contains `"http or https"`.

---

## private_call / private_action / retry semantics

- `private_call(payload)` returns the `payload` field of `private_call_result` (i.e., the parsed JSON dict). Given result `{"returncode":1, ..., "payload":{"status":"error","message":"ReminderKit unavailable"}}`, returns `{"status":"error","message":"ReminderKit unavailable"}`.
- Transient-error sentinel string: `"Couldn’t communicate with a helper application."` (note the curly apostrophe `’`, U+2019). Detection of this exact message drives retry logic.
- `private_create_list_call(payload, name)`: on transient error, sleeps (`time.sleep`) and retries `private_call` once. Two-element side_effect `[transient, created]` → returns `created`; `private_call.call_count == 2`.
- `private_create_list_call` re-checks existence before retrying: if `q_list_exact_name_count` returns 1 after transient error, does NOT retry (`call_count == 1`), returns `{"status":"created", ..., "verifiedAfterTransientError": True}`.
- `private_action(payload)` for idempotent actions (e.g. `set_flagged`) retries transient error once: `[transient, updated]` → returns `updated`, `call_count == 2`.
- `private_action` does NOT retry additive metadata actions (`add_private_metadata`): on transient error, exits (`SystemExit`), `call_count == 1`.

---

## private_location_action — EventKit bridge preference

- When `bridge_available()` is True, `private_location_action({action:"add_location_alarm", id, title, latitude, longitude, radius, proximity})` calls `bridge_call` exactly once and does NOT call `private_call`.
- Bridge payload translates `title` → key `"locationTitle"` (value `"Apple Park"`).
- Returned result has `result["source"] == "eventkit_bridge"`.

---

## Helper path resolution & env overrides

- `current_bridge_path()` honors `REMCTL_BRIDGE_PATH` → `Path("/tmp/custom-bridge")`.
- `current_private_path()` honors `REMCTL_PRIVATE_PATH`.
- `current_permissions_path()` honors `REMCTL_PERMISSIONS_PATH`.
- (runtime) `resolve_binary_path(script, name, ENVVAR)`: env override wins → `Path(value)`. Else finds sibling binary next to script and returns `.resolve()`d absolute path.

---

## List resolution (`resolve_list_ref`)

Fixture `_list_db`: table `ZREMCDBASELIST` with columns `Z_PK, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION, Z_ENT, ZBADGEEMBLEM, ZCOLOR, ZISPINNEDBYCURRENTUSER, ZPINNEDDATE, ZSHOULDCATEGORIZEGROCERYITEMS, ZSHOULDAUTOCATEGORIZEITEMS, ZSHOULDSUGGESTCONVERSIONTOGROCERYLIST, ZGROCERYLOCALEID, ...`. Lists inserted with `Z_ENT=3`, `ZCKIDENTIFIER="CK-{idx}"`. Grocery lists: `ZSHOULDCATEGORIZEGROCERYITEMS=1` + `ZGROCERYLOCALEID` set.

- Name resolution is normalized (emoji/punctuation-insensitive): `resolve_list_ref(db, name="Weekly 513")` against `["🗓️ Weekly 513","Work"]` → `{"id":1, "title":"🗓️ Weekly 513", "method":"normalized"}`.
- Ambiguous normalized name (`["🗓️ Weekly 513","Weekly-513"]`) → `{"error":"ambiguous", "candidates":[...]}` where candidate `title`s sorted are `["Weekly-513","🗓️ Weekly 513"]`.
- By id: `resolve_list_ref(db, list_id=1)` → `{"id":1, "title":"Projects", "objectUUID":"CK-1", "method":"id", "isGroceries":False}`.

---

## list_to_dict — appearance fields

- Input row with `ZBADGEEMBLEM = '{"Emoji" : "\ud83d\udccc"}'` (JSON with surrogate-pair-escaped emoji) → `payload["badge"]["emoji"] == "📌"` (U+1F4CC).
- `ZCOLOR = b"not-a-color"` (undecodable) → `payload["color"]["hex"] == "#007AFF"` (default fallback color).

---

## cmd_lists

- JSON (`json=True`): array of list dicts. For a grocery list: `listType == "groceries"`, `isGroceries == True`, `grocery.locale == "en_US"`, `grocery.shouldCategorizeItems == True`, `grocery.shouldAutoCategorizeItems == False`. For a standard list: `listType == "standard"`, `isGroceries == False`, and key `"grocery"` ABSENT.
- Human (`json=False, format=None`): output contains the list name `"Groceries"` and the carrot emoji `"🥕"` marking grocery lists.

---

## cmd_show

Show-row fixture keys (per `_show_row`): `Z_PK, ZTITLE, ZNOTES, ZCOMPLETED, ZFLAGGED, ZPRIORITY, ZISURGENTSTATEENABLEDFORCURRENTUSER, ZDUEDATE, ZDISPLAYDATEDATE, ZALLDAY, ZCOMPLETIONDATE, ZCREATIONDATE, ZPARENTREMINDER, ZLIST, ZICSURL, ZCKIDENTIFIER, list_name, recurrence_* (all None), ZDUEDATEDELTAALERTSDATA`. Args: `list, list_id, completed, json, format, verbose`. Mocks: `resolve_required_list_target_or_die` → `{"id":1,"title":"Groceries","isGroceries":True}`; `q_reminders`, `q_sections`, `q_section_memberships`, `preload_extras` (returns `(section_counts_dict, hashtags_dict)`).

- Human grocery output: section headers rendered with a category-matched emoji prefix. HTML-entity in section names decoded (`"Dairy, Eggs &amp; Cheese"` → `"Dairy, Eggs & Cheese"`). Output contains literal `"[🥛 Dairy, Eggs & Cheese]"` and `"[🧻 Household Items]"`.
- JSON grocery output: each reminder has `section` (decoded, e.g. `"Dairy, Eggs & Cheese"`) and `sectionEmoji` (e.g. `"🥛"`).
- Section→emoji mapping is a fixed table the port must replicate (Dairy/Eggs/Cheese→🥛, Household Items→🧻).

---

## Templates

Fixture `_template_db` (extends `_list_db(["Source"])`): adds tables `ZREMCDTEMPLATE` (cols incl. `Z_PK, ZNAME, ZCKIDENTIFIER, ZMARKEDFORDELETION, ZCREATIONDATE, ZLASTMODIFIEDDATE, ZPUBLICLINK*DATE, ZBADGEEMBLEM, ZCOLOR, ZPUBLICLINKURLUUID (BLOB=UUID.bytes), ZPUBLICLINKCONFIGURATIONDATA`), `ZREMCDSAVEDREMINDER` (cols incl. `ZTITLE, ZPRIORITY, ZDISPLAYDATEISALLDAY, ZMETADATA (BLOB = b"\x01" + json), ZTEMPLATE`), and `ZREMCDBASESECTION` extended with `Z_ENT, ZCANONICALNAME, ZTEMPLATE, ZCREATIONDATE`. Template row: name `"Rome: Things To See"`, ckid `"TEMPLATE-1"`, UUID `3A6B9DE5-80A4-4180-8AFC-1D261121E344`. Saved reminder: `ZTITLE="Colosseum"`, `ZPRIORITY=1`, metadata `{title, flagged:1, priority:1, hashtags:[{name:"rome"}], recurrenceRules:[...]}`. Section: `ZDISPLAYNAME="Ancient Rome"`, `Z_ENT=8`.

- `cmd_templates(json=True)`: `payload[0]` has `name=="Rome: Things To See"`, `itemCount==1`, `sectionCount==1`, `publicLink.uuid=="3A6B9DE5-80A4-4180-8AFC-1D261121E344"`, `publicLink.url=="https://www.icloud.com/reminders/template/3A6B9DE5-80A4-4180-8AFC-1D261121E344#Rome:_Things_To_See"` (spaces→`_`, name appended after `#`).
- `cmd_template_info(name=..., json=True)`: `payload.sections[0].name=="Ancient Rome"`; `payload.items[0]`: `title=="Colosseum"`, `flagged==True`, `priority=="high"` (numeric 1 → label `"high"`), `tags==["rome"]`.
- `cmd_template_create`: if `private=False` → exits before calling `private_available`/`private_call`; stderr contains `"--private"`.
- `cmd_template_create(private=True, include_completed=True, from_list="Source")`: first positional arg to `private_call` exactly `{"action":"create_template", "name":"Packing Template", "listId":"CK-1", "includeCompleted":True}`.
- `cmd_template_apply(name="Rome: Things To See", private=True)`: `private_call` arg `{"action":"apply_template", "templateId":"TEMPLATE-1"}`.
- `cmd_template_delete(template_id=1, private=True, force=True)`: `private_call` arg `{"action":"delete_template", "templateId":"TEMPLATE-1"}`.

---

## list-symbols

- `cmd_list_symbols(json=True)`: `payload.count == 71`; `payload.note` contains `"approximate Unicode text fallback"`; `payload.symbols` names include `"education3"` and `"fitness"`.
- `cmd_list_symbols(json=False, html=None, preview=False)`: TUI output contains `"approximate text fallback"`, `"remctl list-symbols --preview"`, `"approx"`, `"education3"`.
- `build_list_symbols_html(rows, asset_map)`: HTML contains `"Official Reminders List Symbols"`, `"data:image/png;base64,ZmFrZQ=="` (base64 from asset_map), `"Preview official colors"`, `'data-color="#FF8D28"'` (the official color for `education3`), `"aria-pressed"`, `"education3"`, `"ListBadgeFitness"`. Rows have keys `name, asset, preview`.

---

## Argument parsing / main() dispatch

- Unknown command `remctl symbols`: exits with code `2`; stderr contains `"unknown command: 'symbols'"`, `"Did you mean: remctl list-symbols"`, `"Available commands:"`, `"  add,"` (commands listed, indented). Must NOT contain `"choose from"` (argparse default suppressed).
- `remctl show Work --format table`: dispatches handler `cmd_show` with `args.list=="Work"`, `args.format=="table"`, `args.json==False` (format flag accepted after subcommand).
- `remctl today --format json`: dispatches `cmd_today` with `args.format=="json"` and `args.json==True` (format=json implies json output).
- `remctl add --help`: exits code `0`; stdout contains `"--urgent"` and `"--early-reminder"`.
- `main()` calls `maybe_run_first_launch_onboarding` then `run_handler_with_fallback(args, handler)`.

---

## list create / edit / rename / delete / pin

- `cmd_list_create(name, color="blue", private=False, symbol=None, emoji=None)`: routes through bridge; `bridge_call` arg exactly `{"action":"create_list", "title":"Project X", "color":"blue"}`.
- `cmd_list_create` groceries (`groceries=True, private=True, grocery_locale="it_IT"`): `private_call` arg exactly `{"action":"create_list", "name":"Groceries", "shouldCategorizeGroceryItems":True, "groceryLocaleID":"it_IT"}`. Stdout JSON: `payload["private"]["status"]=="created"`. Mocks: `q_list_exact_name_count`→0.
- groceries create with `private_call` error result → exits; stderr contains `"ReminderKit unavailable"`.
- `cmd_list_create` with `symbol` but `private=False` → exits BEFORE calling `bridge_available`; stderr contains `"--private"`.
- `cmd_list_create` with unsupported symbol (`"sparkles"`, even with `private=True`) → exits before `bridge_available`; stderr contains `"unsupported list symbol"` and `"list-symbols"`.
- `cmd_list_edit(list_id=1, color="#123456", symbol="education3", private=True)`: `private_call` arg exactly `{"action":"set_list_appearance", "listId":"CK-1", "color":"#123456", "symbol":"education3"}`.
- `cmd_list_edit(groceries=True, private=True)` on grocery list (locale en_US): `private_call` arg keys/values `{"shouldCategorizeGroceryItems":True, "groceryLocaleID":"en_US", "action":"set_list_appearance", "listId":"CK-1"}`.
- `cmd_list_edit(standard=True, list_id=1, private=True)`: `private_call` arg `{"shouldCategorizeGroceryItems":False, "action":"set_list_appearance", "listId":"CK-1"}` (no `groceryLocaleID`).
- `cmd_list_pin(name, private=True)`: `private_call` arg `{"action":"set_list_pinned", "listId":"CK-1", "pinned":True}`.
- `cmd_list_unpin(list_id=1, private=True)`: `private_call` arg `{"action":"set_list_pinned", "listId":"CK-1", "pinned":False}`.
- `cmd_list_pin(private=False)` → exits before `private_available`/`private_call`; stderr contains `"--private"`.
- `cmd_list_rename(name="Old", new_name="New")`: `bridge_call` arg `{"action":"rename_list", "title":"Old", "newTitle":"New"}`.
- `cmd_list_delete(list_id=1, force=True)`: `bridge_call` arg `{"action":"delete_list", "title":"Old"}` (resolves id→title before bridge).

---

## Smart lists

Fixture `_smart_list_db`: `ZREMCDBASELIST` with extra cols `ZSMARTLISTTYPE, ZFILTERDATA (BLOB), ZMINIMUMSUPPORTEDAPPVERSION, ZEFFECTIVEMINIMUMSUPPORTEDAPPVERSION, ZISPINNEDBYCURRENTUSER, ZPINNEDDATE`. Rows: (1) built-in `Z_ENT=4`, ckid `"BUILTIN-1"`, `ZSMARTLISTTYPE="com.apple.reminders.smartlist.flagged"`, pinned (pinnedDate 123.0); (2) custom `Z_ENT=4`, ckid `"CUSTOM-1"`, name `"High Priority"`, `ZSMARTLISTTYPE == CUSTOM_SMART_LIST_TYPE`, `ZFILTERDATA=b'{"priorities":["high"]}'`, min/effective version 20220430, pinnedDate 456.0; (3) standard list `Z_ENT=3`, ckid `"LIST-1"`, name `"Reminders"`.

- `cmd_smart_lists(json=True)`: `payload[0]` (built-in) → `kind=="built-in"`, `name=="Flagged"` (type→display name), `filterLength==0`, `pinned==True`, `pinnedDate==123.0`. `payload[1]` (custom) → `kind=="custom"`, `pinned==True`, `pinnedDate==456.0`, `minimumSupportedVersion==20220430`, `effectiveMinimumSupportedVersion==20220430`, `filter.kind=="priority"`, `filterJSON=={"priorities":["high"]}`.
- `cmd_list_pin(name="Flagged", private=True)` for built-in smart list: `private_call` arg `{"action":"set_smart_list_pinned", "smartListId":"BUILTIN-1", "pinned":True}`; stdout JSON `kind=="smart-list"`.
- `cmd_list_unpin(smart_list_id=2, private=True)`: `private_call` arg `{"action":"set_smart_list_pinned", "smartListId":"CUSTOM-1", "pinned":False}`.
- `cmd_smart_list_create(private=False)` → exits before `private_available`/`private_call`; stderr contains `"requires --private"`.
- `cmd_smart_list_create(priority="none", private=True)` → exits before helper; stderr contains `"Unsupported smart list priority"`.
- `cmd_smart_list_create(name="Flagged Review", flagged=True, private=True)`: `private_call` arg has `action=="create_smart_list"`, `name=="Flagged Review"`, `filterData=="eyJmbGFnZ2VkIjp0cnVlfQ=="` (base64 of `{"flagged":true}`); stdout JSON `filter.kind=="flagged"`.
- `cmd_smart_list_create` with appearance (`color="red", emoji="📆"`): `private_call` arg includes `color=="red"`, `emoji=="📆"`.
- `cmd_smart_list_create` multi-filter (`match="any", priority="high,medium", date="today", include_list=["Reminders"]`): `filterData` base64-decodes to JSON `{"operation":"or", "priorities":["high","medium"], "date":{"today":False}, "lists":{"include":["LIST-1"], "exclude":[]}}` (note `today:False` is the official encoding, and list name resolves to object UUID `LIST-1`); stdout JSON `filter.match=="any"`.
- `cmd_smart_list_create` selected-tag (`match="all", tags="remctl", tag_match="any", date="today"`): decoded filterData `{"operation":"and", "hashtags":{"hashtags":{"operation":"or","include":["remctl"],"exclude":[]}}, "date":{"today":False}}`; stdout JSON `filter.filters[0].tagMatch=="any"`.
- `cmd_smart_list_create(include_list_id=[10])`: resolves PK 10 → object UUID; decoded filterData `{"lists":{"include":["LIST-1"], "exclude":[]}}`.
- `cmd_smart_list_create(include_list_id=[10,11])` (two included lists): exits before `private_call`; stderr contains `"only materializes one included-list"`.
- `cmd_smart_list_edit(name="High Priority", match="all", date="today", private=True)`: `private_call` arg `action=="update_smart_list"`, `smartListId=="CUSTOM-1"`, `filterData` decodes to `{"date":{"today":False}}`; stdout JSON `status=="updated"`.
- `cmd_smart_list_edit` appearance-only (`color="#123456", emoji="📆"`, no filter args): `private_call` arg exactly `{"action":"update_smart_list", "smartListId":"CUSTOM-1", "color":"#123456", "emoji":"📆"}`; stdout JSON does NOT contain key `"filter"`.
- `cmd_smart_list_delete(private=False)` → exits; stderr contains `"requires --private"`.
- `cmd_smart_list_delete(name="High Priority", private=True, force=True)`: `private_call` arg `{"action":"delete_smart_list", "smartListId":"CUSTOM-1"}`; stdout JSON `status=="deleted"`, `name=="High Priority"`.
- `cmd_smart_list_delete(name="Flagged")` (built-in) → exits, `private_call` not called; stderr contains `"custom smart list not found"`.

---

## Smart-list filter encode/decode (`remctl_smart_lists`)

Module symbols: `SmartListFilterError`, `build_supported_filter_payload`, `decode_smart_list_filter_blob`, `encode_supported_filter_payload`.

- `decode_smart_list_filter_blob(None)` → `{payload:None, summary:None, error:None}`.
- Decode NSKeyedArchiver-wrapped JSON (archive format per `archived_filter`: `$archiver=NSKeyedArchiver`, `$version=100000`, objects[2] = JSON bytes, class `ReminderKitInternal.REMCustomSmartListFilterDescriptor`): empty `{}` → `encoding=="keyed_archive_json"`, `payload=={}`, `summary.kind=="all"`.
- Raw-JSON blob `{"flagged":true}` → `payload=={"flagged":True}`, `summary.kind=="flagged"`, `summary.supported==True`.
- Priorities: `{"priorities":["high"]}` → `summary.priorities==["high"]`; `["low","medium","high"]` → preserved order.
- Official filter samples all decode with `summary.supported==True` — exact shapes to support (date format `DD-MM-YYYY`):
    - hashtags include/exclude with `operation`; `{"any":""}`; `{"untagged":""}`
    - `date.afterDate`, `date.dateRange:[d,d]`, `date.relativeRange:{direction,magnitude,includePastDue,units}`
    - `time.afternoon`, `time.noTime`
    - `location.vehicle:"connected"`, `location.location:{title,latitude,radius,longitude,proximity}`
    - `lists.include/exclude` (with optional `operation`)
    - top-level `operation` of `"and"`/`"or"`, multi-key combos
- Legacy short selected-tag `{"hashtags":{"hashtags":["remctl"]}}` (array form) → `summary.supported==False`, `summary.materializes==False`, `summary.kind=="unsupported"`.
- `build_supported_filter_payload` exact outputs:
    - `tags=["remctl","codex"]` → `{"hashtags":{"hashtags":{"operation":"or","include":["remctl","codex"],"exclude":[]}}}`
    - `tags=["remctl"], tag_match="all"` → `operation:"and"`
    - `tags=["#remctl"], tag_match="any"` → strips `#`: `include:["remctl"]`
    - `any_tag=True` → `{"hashtags":{"any":""}}`; `untagged=True` → `{"hashtags":{"untagged":""}}`
    - `date_on="2026-05-15"` → `{"date":{"onDate":"15-05-2026"}}` (ISO→`DD-MM-YYYY`)
    - `date_range="2026-05-15,2026-05-16"` → `{"date":{"dateRange":["15-05-2026","16-05-2026"]}}`
    - `date_relative="in-next:1:hour:past-due"` → `{"date":{"relativeRange":{"direction":"inNext","magnitude":"1","includePastDue":True,"units":"hour"}}}`
    - `time_filter="no-time"` → `{"time":{"noTime":""}}`
    - `vehicle="disconnected"` → `{"location":{"vehicle":"disconnected"}}`
    - combined (`match="any", tags=["remctl"], date_today=True, include_list_ids=["LIST-1"]`) → `{"operation":"or","hashtags":{...or...},"date":{"today":False},"lists":{"include":["LIST-1"],"exclude":[]}}`
    - `include_list_ids=["WORK","PROJECTS"]` (default) → `{"lists":{"include":[...],"exclude":[],"operation":"or"}}`; `list_match="all"` → `operation:"and"`
- `build_supported_filter_payload` raises `SmartListFilterError` for: no args at all; `priorities=["none"]`; conflicting `date_any=True` + `date_on=...`.
- `encode_supported_filter_payload(build_supported_filter_payload(priorities=["high"]))` → raw bytes `b'{"priorities":["high"]}'` (compact separators, NOT base64 — base64 happens at the CLI layer).

---

## cmd_add — guards & routing

Note: `--private` guards fire BEFORE any DB read (`open_db` not called) and BEFORE bridge (`bridge_call`/`bridge_available` not called). Many guards exit with code 2.

- Private-only options without `--private` (e.g. `section="Research"`): exits; `bridge_call` and `open_db` NOT called; stderr contains `"require --private"`.
- `--urgent` without `--private`: exits before bridge; stderr contains `"--private"`.
- `--early-reminder` without `--private`: exits before bridge; stderr contains `"--private"`.
- `--early-reminder` with `--private` but no `--due`: exits before bridge; stderr contains `"early_reminder_requires_due_date"`.
- `--grocery` without `--private`: exits before bridge; stderr contains `"--private"`.
- `--grocery` targeting a standard (non-grocery) list (private + bridge available): exits, `bridge_call` not called; stderr contains `"not a Groceries list"`.
- Unparseable `--due` (`"today at 25:00"`, json=False): exits code `2`; bridge not touched; stderr contains `"No reminder was created"` and the example `"today at 3pm"`.
- Unparseable `--due` (json=True, `"nonsense date"`): exits code `2`; stderr is JSON `{"code":"invalid_due_date", "field":"due", "input":"nonsense date", "examples":[...]}` (has `examples` key).
- Invalid `--priority` / `--recurrence` / `--alarm` (e.g. `"urgent"`/`"fortnightly"`/`"eventually"`): each exits before bridge; stderr contains the field name `"priority"` / `"recurrence"` / `"alarm"` respectively.
- Private invalid url (`file://localhost/...`): exits before bridge; stderr contains `"http or https"`.
- Private url to local/private host (`http://127.0.0.1:631/`): exits before bridge; stderr contains `"public http or https"`.
- Private url/tags/flag stay OUT of bridge payload: bridge payload has `title` but NO `url`, NO `flagged` keys; `apply_private_changes` called once as `apply_private_changes("ABC-123", args, db=fake_db, list_pk=7)`; stdout JSON `payload["private"][0]["status"]=="updated"`.
- JSON output includes `numericId` when `q_reminder_by_identifier` resolves (`{"Z_PK":17839}` → `payload["numericId"]==17839`).
- Bridge `list` field uses RESOLVED list title: with `resolve_list_or_die` returning `title="🗓️ Weekly 513"`, `bridge_call` arg `["list"]=="🗓️ Weekly 513"`; stdout `payload["resolvedList"]["title"]=="🗓️ Weekly 513"`, `["method"]=="normalized"`.

### cmd_add — grocery auto-categorization

- `wait_for_grocery_section` returns a section name (or None). With `bridge_available`+`private_available` True and section verified on first wait: `private_call` NOT called; stdout `payload["private"][0]["source"]=="reminders_auto"`, `payload["private"][0]["verifiedSections"][0]["section"]=="Dairy, Eggs & Cheese"`.
- Fallback: if first wait returns None, calls `private_call` with `{"action":"categorize_grocery_items", "listId":"CK-1", "reminderIds":["REM-1"]}`, then second wait returns the section; stdout `verifiedSections[0].section=="Dairy, Eggs & Cheese"`.
- `apply_private_grocery_categorization(db, list_pk, reminder_ids)`: if `private_call` returns the transient helper error but a section IS verified afterward → returns `{status:"updated", source:"reminders_auto", warning:<contains "helper application">, verifiedSections:[{section:"Dairy, Eggs & Cheese"}]}` (treats helper error as success).

---

## apply_private_changes

- Rich subtask (JSON subtask with notes/due/url/tags): first `private_action` call has `action=="add_subtasks"`, `subtasks[0].urls==["https://example.com/child"]`, `subtasks[0].tags==["childtag"]`. After helper returns child id `"CHILD-ID"`: second `private_action` call exactly `{"action":"add_private_metadata", "id":"CHILD-ID", "urls":["https://example.com/child"], "tags":["childtag"]}`; `bridge_call` for child exactly `{"action":"update", "id":"CHILD-ID", "notes":"Child notes", "due":"2026-04-15T14:00:00"}`. Result: `result[0]["bridgeUpdates"][0]["id"]=="CHILD-ID"`, `result[0]["childPrivateUpdates"][0]["id"]=="CHILD-ID"`.
- Early reminder delta (`early_reminder="15m"`): `private_action` arg `{"action":"set_early_reminder", "id":"PARENT-ID", "unit":0, "count":-15}`; result `result[0]["action"]=="set_early_reminder"`.
- Early reminder removes existing identifiers: with reminder row `ZDUEDATEDELTAALERTSDATA` containing existing alert `identifier="DELTA-1"` and `early_reminder="1h"`: `private_action` arg `{"action":"set_early_reminder", "id":"PARENT-ID", "existingIdentifiers":["DELTA-1"], "unit":1, "count":-1}`.

---

## Section resolution (`resolve_section_ckid`)

Fixture `_section_db`: `ZREMCDBASESECTION (Z_PK, ZDISPLAYNAME, ZLIST, ZCKIDENTIFIER, ZMARKEDFORDELETION)`; `ZREMCDBASELIST (Z_PK, ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA)` (JSON text `{"memberships":[{"groupID","memberID"}]}`).

- Duplicate section names where exactly one has members: returns the CKID of the non-empty section (`section_b`).
- Duplicate names, both empty (ambiguous): exits; stderr contains `"--section-id"` and BOTH section CKIDs.
- `section_id` given as `x-apple-reminderkit://REMCDListSection/<uuid>`: strips scheme, returns bare UUID.
- Passing both `section_name` and `section_id`: exits; stderr contains `"either --section or --section-id"`.

---

## cmd_import

- Reads JSON file array; each item → one `cmd_add` call. `{"title":"Buy milk","dueDate":"2026-05-01T12:00:00"}` → `cmd_add` called once with `args.due == "2026-05-01T12:00:00"` (maps `dueDate`→`due`).

---

## cmd_edit — guards & routing

- `--tags` without `--private`: exits before reading DB (`open_db` and `bridge_call` not called); stderr contains `"editing synced tags requires --private"`.
- Due-date edit is bridge-first: `bridge_call` once (osa not called); arg `action=="update"`, `due=="2026-04-20T09:00:00"`.
- Edit carries matching absolute alarm: when an existing alarm's date_components match the OLD due (and equal display date), editing due moves the alarm too. `q_alarms` row has `alarm_id, time_interval, latitude, longitude, date_components(JSON with timeZone)`. Result bridge payload: `due=="2026-05-26T16:00:00"` AND `alarm=="2026-05-26T16:00:00"`.
- If matching alarm must move but bridge unavailable: exits; bridge/osa not called; stderr contains `"requires remctl-bridge"`.
- Custom (non-matching) absolute alarm is NOT carried: bridge payload has NO `alarm` key.
- No-op due (due equals current) with custom alarm: `bridge_call.call_count==2` (double-tap), final payload `due=="2026-05-26T16:00:00"`, no `alarm` key.
- Due `"clear"`: bridge payload `due is None` and `clearAlarms == True`.
- Alarm `"clear"`: bridge payload `clearAlarms == True`, no `alarm` key.
- Alarm `"15m"`: bridge once, payload `alarm == "-15m"`.
- Move to list by name: calls `resolve_required_list_target_or_die(ANY, name="Projects", list_id=None)`, bridge once, payload `["list"]=="Projects"`; `private_available` and osa NOT called; stdout `payload["list"]=="Projects"`.
- Move by `list_id=9`: bridge payload `["list"]=="Projects"`; stdout `payload["resolvedList"]["id"]==9`, `["method"]=="id"`.
- Move + private section: `apply_private_changes(ckid, args, db=ANY, list_pk=9)` called once (section resolved against destination list PK).
- Both list name and `--list-id`: exits before bridge; stderr contains `"pass either a list name or --list-id"`.
- Double-tap when due equals current CoreData value: `bridge_call.call_count==2`; first ("nudge") payload `due=="2026-04-20T10:00:00"` (+1h), second `due=="2026-04-20T09:00:00"`. (Apple epoch offset = 978307200.)
- Unparseable due: exits, bridge not called.
- Bridge-unavailable fallback to AppleScript: osa called once; osa action (3rd positional arg) contains `"set due date of r to _rdt"`.

---

## Mutating-op routing (bridge vs AppleScript)

`_FAKE_REMINDER`: `{ZCKIDENTIFIER:"DEAD-BEEF-...", ZTITLE:"test", list_name:"Emails", ZLIST:7, ZDUEDATE:None}`. Helpers assert exactly one path fires.

- `cmd_done` bridge-first: `bridge_call` once, osa not called, payload `action=="complete"`.
- `cmd_undone` bridge-first: payload `action=="uncomplete"`.
- `cmd_delete` (force=True) bridge-first: payload `action=="delete"`.
- `cmd_flag` AppleScript-first: osa once, bridge not called, script contains `"set flagged of r to true"`.
- `cmd_unflag` AppleScript-first: script contains `"set flagged of r to false"`.
- Safety: `cmd_done`/`cmd_delete`/`cmd_flag`/`cmd_edit` with reminder having `ZCKIDENTIFIER=None` and bridge unavailable → exits; NONE of `bridge_call`/`osa_by_id_try`/`osa` called (refuses title-based fallback).

---

## run_handler_with_fallback

- Handler raising `RemindersDBUnavailable("db unavailable")` → exits (`SystemExit`); stderr contains `"db unavailable"`.

---

## Reminder formatting (fmt / reminders_to_table_data / to_dict)

- `fmt` and `reminders_to_table_data` accept raw `sqlite3.Row` (no `dict.get`). Minimal row (`Z_PK=42, ZTITLE, ZCOMPLETED, ZFLAGGED, ZPRIORITY, ZDUEDATE, list_name, ZNOTES, ZICSURL`): formatted contains `"Test reminder"`; table `id` (ANSI-stripped) `=="#42"`, `title=="Test reminder"`.
- Terminal-control sanitization: OSC sequences (`\033]52`, `\033]8`), BEL (`\a`), and `\033[31m` color codes from titles/notes/url stripped from both `fmt` output and table title; benign text (e.g. `"Clipboard"`) preserved.
- Flagged + urgent: `fmt` (ANSI-stripped) contains `"⏰"` and `"⚑"`; table title contains `"⏰ ⚑ Urgent flagged"`; `to_dict` → `urgent==True`, `flagged==True`. Driven by `ZISURGENTSTATEENABLEDFORCURRENTUSER` and `ZFLAGGED`.
- List color in id: when `get_list_colors` returns `{"Work":(1,2,3)}`, formatted id is `"\033[38;2;1;2;3m#42\033[0m"` (24-bit ANSI), table `id` identical. `fmt` accepts `_sc={42:0}` and `_ht={42:[]}` kwargs (section-count / hashtag preload caches).
- Recurrence: `recurrence_days_of_week` blob is JSON `[{"weekNumber":0,"dayOfTheWeek":2},...]`. With `recurrence_frequency=1, recurrence_interval=1`: formatted (stripped) contains `"weekly Mon, Wed"`; table `repeat=="weekly Mon, Wed"`; `to_dict.recurrence == {"frequency":"weekly", "interval":1, "daysOfWeekDetailed":[{weekNumber:0,dayOfTheWeek:2},{...4}], "daysOfWeek":[2,4]}`.
- Early reminder from `ZDUEDATEDELTAALERTSDATA` blob (JSON `{"dueDateDeltaAlerts":[{dueDateDeltaUnit:0, dueDateDeltaCount:-15, identifier:"DELTA-1", ...}]}`): formatted contains `"Early: 15 minutes before"`; `to_dict.earlyReminder == {label:"15 minutes before", unitCode:0, count:-15, ...}`; `to_dict.earlyReminders[0].identifier == "DELTA-1"`.

---

## cmd_info / to_dict

- `cmd_info(id, json=True)`: pulls `q_rich_link` → `payload["url"]` is the rich-link URL; `q_section_memberships` `{"ABC":"Playground"}` → `payload["section"]=="Playground"`. Mocks needed: `q_reminder, q_reminders, q_attachments, q_alarms, q_hashtags, q_section_memberships, q_rich_link, q_subtask_count`.
- `to_dict` keeps due vs display separate: `ZDUEDATE=801216000`→`dueDate=="2026-05-23T10:00:00"`; `ZDISPLAYDATEDATE=801215100`→`displayDate=="2026-05-23T09:45:00"`; `ZALLDAY=0`→`allDay==False`. (Confirms Apple-epoch→ISO conversion, local TZ assumption — see gap note.)
- `cmd_info` hydrates subtasks: subtask attachments and alarms surfaced — `payload["subtasks"][0]["attachments"][0]["filename"]=="child.png"`, `payload["subtasks"][0]["alarms"][0]["relativeOffset"]==-600`. Subtask fixture uses `ZREMCDOBJECT` polymorphic rows discriminated by `Z_ENT` (25=attachment, 15=alarm-link, 19=relative alarm trigger).

---

## Alarm serialization (`alarm_rows_to_json` / `q_alarms`)

`ZREMCDOBJECT` cols: `Z_PK, Z_ENT, ZREMINDER, ZTRIGGER, ZMARKEDFORDELETION, ZTIMEINTERVAL, ZDATECOMPONENTSDATA, ZTITLE, ZLATITUDE, ZLONGITUDE, ZRADIUS, ZADDRESS, ZPROXIMITY`. `Z_ENT` discriminates trigger type: 15=alarm record, 19=relative (`ZTIMEINTERVAL`), 17=absolute (`ZDATECOMPONENTSDATA`), 18=location.

- Relative alarm (`time_interval=-900`): `type=="relative"`, `relativeOffset==-900`, `relativeOffsetMinutes==-15`, `label=="15 minutes before due date"`.
- Absolute alarm (date_components JSON with `timeZone.identifier="Europe/Rome"`): `type=="absolute"`, `date=="2026-05-23T10:30:00"`, `timeZone=="Europe/Rome"`.
- Location alarm (`title="Apple Park", lat=37.3349, lon=-122.009, radius=200, address, proximity=1`): `type=="location"`, `location.title=="Apple Park"`, `location.proximity=="arriving"` (1→"arriving").

---

## q_attachments

`ZREMCDOBJECT (ZFILENAME, ZUTI, ZWIDTH, ZHEIGHT, ZREMINDER2, ZMARKEDFORDELETION)`; companion `ZREMCDSAVEDATTACHMENT (ZFILENAME, ZUTI, ZATTACHMENTTYPERAWVALUE, ZREMINDER, ZMARKEDFORDELETION)`.

- Returns only non-deleted image attachments (filename non-null, not `ZMARKEDFORDELETION=1`). For reminder 42: exactly `[{ZFILENAME:"first.png", ZUTI:"public.png", ZATTACHMENTTYPERAWVALUE:"image"}, {ZFILENAME:"second.png", ...}]` — excludes `deleted.png` (marked) and the null-filename `public.url` row; injects `ZATTACHMENTTYPERAWVALUE:"image"`.

---

## Setup / onboarding / doctor / permissions

- `resolve_setup_shell("auto")`: with `SHELL=/bin/tcsh` → `"skip"`; with `SHELL=/bin/zsh` → `"zsh"`.
- `cmd_setup(shell="skip", doctor=False, json=False)` with `CONFIG_DIR` overridden: stdout contains `"RemCTL setup"`, `"Shell completion: skipped"`, `"remctl onboard"`.
- `cmd_upcoming(days in {0,-1})`: exits before `open_db`; stderr contains `"between 1 and 3650"`.
- `bridge_access_check_for_onboarding`: with `current_bridge_path` pointing at an executable file, `os.access`→True, and `bridge_call_result` payload `{status:"authorized", calendarCount:3, defaultList:"Reminders"}` → `check["status"]=="ok"`, `detail` contains `"Reminders access granted"` and `"default: Reminders"`.
- `database_access_check_for_onboarding`: when `reminders_store_access_error` returns error, `find_main_db_path`→None, `full_disk_access_targets`→["Terminal.app","/tmp/python3"] → `status=="fail"`, `detail` contains `"db blocked"`, `fix` contains `"Terminal.app"`.
- `detect_terminal_app_name`: `TERM_PROGRAM="Apple_Terminal"` → `"Terminal.app"`.
- `full_disk_access_fix_text(rerun_command="remctl doctor", mention_onboard=True)` with targets+context `"Codex"`: text contains `"Terminal.app"`, `"/tmp/python3"`, `"remctl onboard"`, `"Current execution context: Codex"`, `"Terminal does not grant access"`, `"Command-Shift-G"`.
- `doctor_execution_context`: from process ancestry containing a `Codex` ancestor → `effective_context=="Codex"`, `host_app=="Codex.app"`, `parent_process["name"]=="python3"`.
- `cmd_doctor(json=True, for_agent=True)`: stdout JSON `ok==True`, `context.effective_context=="Codex"`, `agent_note` contains `"same context"`.
- `print_full_disk_access_guidance(settings_opened=True)`: copies resolved python path to clipboard (`copy_to_clipboard(resolved_path)`); stdout contains `"Copied path to clipboard: <path>"` and `"Command-Shift-G"`.
- `open_full_disk_access_settings`: tries modern URL first (`com.apple.settings.PrivacySecurity.extension`), then legacy (`com.apple.preference.security`) on failure; returns True when one succeeds.
- `print_check_report` indents multiline fixes: a fix `"First line\n  remctl permissions...\n  remctl doctor"` renders with `"      First line"` (6-space indent) and `"        remctl permissions full-disk-access"` / `"        remctl doctor"` (8-space).
- `cmd_onboard(json=False)`: when database check is `warn`/not-ready and helper launch fails, calls `open_full_disk_access_settings()` once, then `print_full_disk_access_guidance(settings_opened=True, rerun_command="remctl doctor")` once.
- `gather_onboarding_checks` order: `["open_reminders", "eventkit", "automation", "database"]`.
- `needs_full_disk_access_guidance` → False when database check detail is `"No local Reminders database found."` (missing-DB is not an FDA problem).
- `maybe_run_first_launch_onboarding` for interactive cmd (`today`): when `should_auto_onboard`→True, calls `run_onboarding(auto=True)` once and `print_check_report("RemCTL onboard", [])` once; returns the onboarding result.
- `should_auto_onboard` returns False for admin commands (`setup`) even on darwin/tty/no-state.
- `cmd_permissions(topic="full-disk-access", scope="cli", json=True)`: stdout JSON `available==True`, `targets==<full_disk_access_target_specs output>` (target dicts have `title, path, subtitle`).
- `launch_full_disk_access_helper(include_cli=True)`: Popen argv contains `"--target"`, `"/tmp/python3"`, `"Run Doctor"`; returns True.

---

## Runtime module (`remctl_runtime`)

- `resolve_store_dir`: `REMCTL_STORE_DIR` override → `Path(value)`.
- `resolve_config_dir`: `REMCTL_CONFIG_DIR` wins; else `XDG_CONFIG_HOME` → `Path("$XDG/remctl")`.
- `resolve_binary_path`: env override wins; else sibling binary `.resolve()`d.
- `mask_secret("abcdefgh12345678")` → `"abcd...5678"` (first4 + "..." + last4 when long); `mask_secret("short")` → `"*****"` (all-masked, same length as input, when ≤8 chars).
- `write_private_text_file(path, "secret\n")`: writes content verbatim; file mode `0o600`, parent dir mode `0o700` (creates parent).
- `due_today_window(datetime(2026,4,18,14,30))` → `(datetime(2026,4,18,0,0,0), datetime(2026,4,19,0,0,0))` (start-of-day to next start-of-day).
- `upcoming_window(7, datetime(2026,4,18,14,30))` → `(datetime(2026,4,18,0,0,0), datetime(2026,4,26,0,0,0))` (start-of-day, +7 days).
- `is_safe_remote_url`: True for public host (`93.184.216.34`). False for: localhost/`127.0.0.1`, private `10.0.0.8`, and `file://` scheme (rejected without DNS). Uses `socket.getaddrinfo` to resolve and check for private/loopback ranges.

---

## Gaps / underspecified items

- INSUFFICIENT DATA: Exact full set of `Available commands:` listed in the unknown-command error — only the prefix `"  add,"` is pinned; the complete ordered command list is not asserted.
- INSUFFICIENT DATA: The complete 71-symbol catalog (names, asset names, preview chars, official hex colors) — only `education3` (color `#FF8D28`), `fitness`, and count `71` are pinned. Port must source the full table from the original `remctl` script.
- INSUFFICIENT DATA: Full section-name→emoji mapping table — only Dairy/Eggs/Cheese→🥛 and Household Items→🧻 are pinned. The complete grocery-category emoji map must come from the source.
- INSUFFICIENT DATA: Timezone handling for Apple-epoch→ISO conversion in `to_dict` (`801216000`→`"2026-05-23T10:00:00"`). Whether conversion uses local TZ, a fixed TZ, or naive arithmetic is not isolated; the test runs in an unspecified TZ. Port must match whatever the reference uses (likely local time / `datetime.fromtimestamp`).
- INSUFFICIENT DATA: Smart-list built-in type→display-name map beyond `com.apple.reminders.smartlist.flagged`→`"Flagged"`. Full builtin map not enumerated.
- INSUFFICIENT DATA: Exact `mask_secret` boundary (e.g. behavior at exactly 8 vs 9 chars) — only one long and one short case pinned.
- INSUFFICIENT DATA: The full set of valid `priority` labels and `proximity`/`unit` enum mappings — only `priority 1→"high"`, `proximity 1→"arriving"`, `unit 0→minutes/1→hour` are pinned.
- INSUFFICIENT DATA: `CUSTOM_SMART_LIST_TYPE` constant value (referenced as `self.remctl.CUSTOM_SMART_LIST_TYPE` in fixtures but never asserted literally) — must be copied from source.
- INSUFFICIENT DATA: Recurrence weekday numbering is only confirmed for mon=2/wed=4; the full Sun..Sat mapping is implied (Sun=1) but not exhaustively pinned.

Relevant source files for filling gaps: `/Users/orion/Developer/Playgrounds/remctl/remctl` (main CLI), `/Users/orion/Developer/Playgrounds/remctl/remctl_runtime.py`, `/Users/orion/Developer/Playgrounds/remctl/remctl_smart_lists.py`.
