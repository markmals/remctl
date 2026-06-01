# Installation and Onboarding

RemCTL is a single self-contained Swift binary — no helpers, no daemon, no service, no token. It reads your local Reminders database directly (read-only, via GRDB) for fast, detailed output, and writes through Apple's EventKit and ReminderKit frameworks **in-process**. It never writes the Reminders database directly.

## Requirements

- **macOS 14 (Sonoma) or later.**
- iCloud Reminders enabled.
- The two macOS permissions covered below: **Full Disk Access** (for the direct database reads) and **Reminders access** (for writes).

RemCTL installs from a prebuilt bottle (fast, ~3s) on Apple-Silicon macOS 15 (Sequoia) and 26 (Tahoe) when one is available; other configurations build from source, which needs Xcode or a Swift 6 toolchain. Because RemCTL links Apple's private ReminderKit framework, it is distributed as a Homebrew source/bottle install rather than a notarized App Store binary — but that is transparent to `brew install`.

## Install

```bash
brew install markmals/tap/remctl
remctl onboard                      # grant Reminders access (and Full Disk Access)
remctl doctor                       # confirm setup
remctl today
```

`brew install` is the only supported install path. If a bottle is not available for your platform, Homebrew builds RemCTL from source automatically; install Xcode (or a Swift 6 toolchain) first if the build reports a missing compiler.

The install does not grant macOS permissions — Apple requires those grants to happen interactively. Run `remctl onboard` next, then verify with `remctl doctor` so the first health report is meaningful.

## First Run

```bash
remctl onboard                      # triggers the Reminders prompt; guides Full Disk Access
remctl permissions full-disk-access # opens System Settings + prints the exact target
remctl doctor                       # verifies the current context
remctl today
```

`remctl onboard` runs the guided first-run flow: it triggers the native **Reminders access** prompt used by EventKit and ReminderKit writes, checks direct database access, and guides you to **Full Disk Access** when that read path is not yet authorized.

Private metadata writes do not need a separate first-run flow. Sections, subtasks, tags, attachments, urgent state, Early Reminders, list/smart-list appearance, Groceries metadata, and templates are first-class: the relevant flags just work, in-process, using the same Reminders grant as ordinary EventKit writes. See [private-metadata.md](private-metadata.md) for the supported fields and examples.

`remctl permissions full-disk-access` is safe to run even if direct reads already work — it opens System Settings to the right pane and prints the exact target path you need to add, which makes it the clearest first-run path before you run `doctor`.

## macOS Permissions

RemCTL needs two macOS permission grants:

- **Full Disk Access** — for the direct Reminders database reads. Grant it to the terminal, app, or agent-runner process that will run RemCTL.
- **Reminders access** — for EventKit and ReminderKit writes. Prompted on first write, or up front via `remctl onboard`.

### Granting Reminders access

`remctl onboard` triggers the native Reminders prompt; approve it. If you skip onboarding, the prompt appears the first time you run a write command (`add`, `edit`, `done`, a `list-*` command, etc.). You can confirm the result with the `eventkit` and `reminderkit` lines in `remctl doctor` (see below).

### Granting Full Disk Access

macOS does not provide a native Full Disk Access prompt for command-line tools, so this grant is manual.

```bash
remctl permissions full-disk-access
```

This opens **System Settings → Privacy & Security → Full Disk Access** and prints the exact target path to add. In the file picker:

1. Click `+`.
2. Press `Command-Shift-G`, paste the printed path, press Return, then click **Open**.
3. Run `remctl doctor` again to confirm the read path is now green.

`remctl permissions --json` reports `available: false` — there is no bundled GUI helper; the command degrades to opening System Settings and printing guidance.

### Full Disk Access is per process context

Full Disk Access is scoped to the **process context** that runs RemCTL. The same Mac can have:

- Terminal green: `remctl doctor` passes when run from Terminal.app.
- A different app or agent runner red: `remctl doctor` fails when run from that other context.

That is normal macOS TCC scoping, not a broken RemCTL install. A green `remctl doctor` in Terminal.app does **not** grant access to a different app or agent runner. Always run `remctl doctor` from the same context that will run RemCTL, and grant Full Disk Access to that exact process. For agent runners, use `remctl doctor --for-agent` (see [For Agents and CI](#for-agents-and-ci) below).

## Verifying with `doctor`

`remctl doctor` verifies the current execution context.

```bash
remctl doctor                       # human-readable report for the current context
remctl doctor --for-agent           # report framed for an agent/runner context
remctl doctor --json                # machine-readable; add --for-agent for agents
```

`doctor` reports these checks:

- `platform`, `macos` — OS and platform sanity.
- `store_dir`, `database` — the direct Reminders read path (Full Disk Access). These are the read checks that must pass.
- `cli` — RemCTL itself.
- `config_dir`, `completion` — configuration directory and shell completion.
- `eventkit` — EventKit authorization for writes. This is a **warning-level** check.
- `reminderkit` — ReminderKit availability for private-metadata writes. Also **warning-level**.

The checks that gate functionality are `platform`, `store_dir`, `database`, and `cli`; `eventkit` and `reminderkit` surface write-access state as warnings. Treat `remctl doctor --json` as the first setup check, and remember it must pass in the **same** context that will run your writes.

## Shell Completion

```bash
remctl setup
```

`remctl setup` installs shell completion. To load completion directly in the current shell:

```bash
eval "$(remctl completion zsh)"
eval "$(remctl completion bash)"
remctl completion fish | source
```

## For Agents and CI

Agent runners and CI processes run RemCTL from their own process context, which has its own Full Disk Access state. A green `remctl doctor` in your Terminal does **not** imply the agent's interpreter or runner is authorized.

```bash
remctl doctor --for-agent --json
```

To set up an agent or CI runner:

1. Run `remctl doctor --for-agent` from the runner (or as the runner's process). It prints the exact target — the interpreter or runner executable — to grant Full Disk Access.
2. Open **System Settings → Privacy & Security → Full Disk Access**, click `+`, press `Command-Shift-G`, paste that printed path, press Return, then click **Open**.
3. Relaunch the agent runner and re-run `remctl doctor --for-agent --json` until the read checks pass.
4. Grant **Reminders access** the same way as for interactive use — run a write (or `remctl onboard`) from the runner's context and approve the prompt.

The durable fix is granting Full Disk Access to the actual runner. Trust the context reported by `doctor --for-agent --json`: a green Terminal does not imply a green agent runner.

## Upgrading

```bash
brew upgrade remctl
remctl --version
remctl doctor
```

## Building from Source

If no bottle is available for your platform, Homebrew builds RemCTL from source automatically during `brew install`. This needs Xcode or a Swift 6 toolchain. The project source lives at `github.com/markmals/remctl`.
