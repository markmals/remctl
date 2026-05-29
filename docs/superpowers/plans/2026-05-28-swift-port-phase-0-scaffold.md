# RemCTL Swift Port — Phase 0 (Scaffold) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the `RemindersControl` SwiftPM package — a single `remctl` binary — that builds and tests cleanly, links its two third-party deps and the private-framework Obj-C target, and exposes a stub command tree for all 45 subcommands. No reminder logic yet; this is the foundation Phases 1–5 build on.

**Architecture:** A library target `RemindersControl` holds all Swift Argument Parser commands (so they are unit-testable); a thin `remctl` executable target is just an `@main` wrapper that calls the library's root command. An Obj-C target `ReminderKitPrivate` links the private ReminderKit framework and exposes a tiny probe function — proving the riskiest link path compiles before any private logic is ported. Tests use Swift Testing.

**Tech Stack:** Swift 6 / SwiftPM, [swift-argument-parser](https://github.com/apple/swift-argument-parser), [GRDB.swift](https://github.com/groue/GRDB.swift), Swift Testing, Objective-C (private framework target), GitHub Actions (macOS).

**Context:** This is Phase 0 of 6 (see `docs/superpowers/specs/2026-05-28-reminders-swift-port-design.md` §8). The Swift package lives at the repo root alongside the existing Python (which stays until Phase 5 for parity verification). SwiftPM only compiles sources under `Sources/`, so the root-level `remctl`, `*.py`, `remctl-*.swift`, and `remctl-private.m` are untouched by the build. Work happens on branch `swift-port`; the push remote is `fork` (`github.com/markmals/remctl`).

**Conventions used by every task:**
- Run all `swift` commands from the repo root `/Users/orion/Developer/Playgrounds/remctl`.
- Commit messages end with the trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- The 45 subcommands (authoritative list): `add, edit, done, undone, delete, flag, unflag, link, open, search, today, flagged, urgent, tags, subtasks, info, sections, stats, show, upcoming, overdue, export, import, lists, list-create, list-edit, list-pin, list-unpin, list-rename, list-delete, list-symbols, smart-lists, smart-list-create, smart-list-edit, smart-list-delete, templates, template-info, template-create, template-apply, template-delete, completion, doctor, onboard, permissions, setup`.

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `Package.swift` | Package manifest: deps, three targets, linker settings. |
| `.gitignore` | Append `.build/` (and `.swiftpm/`). |
| `Sources/RemindersControl/RemCTL.swift` | `public` root `AsyncParsableCommand`; wires the subcommand list. |
| `Sources/RemindersControl/GlobalOptions.swift` | `JSONOptions` shared option group, `remctlVersion`, `NotImplemented` error. |
| `Sources/RemindersControl/Commands/ReadCommands.swift` | 12 read/inspect command stubs. |
| `Sources/RemindersControl/Commands/WriteCommands.swift` | 9 reminder-mutation command stubs. |
| `Sources/RemindersControl/Commands/ListCommands.swift` | 8 list-management command stubs. |
| `Sources/RemindersControl/Commands/SmartListCommands.swift` | 4 smart-list command stubs. |
| `Sources/RemindersControl/Commands/TemplateCommands.swift` | 5 template command stubs. |
| `Sources/RemindersControl/Commands/OpsCommands.swift` | 7 IO/ops command stubs. |
| `Sources/remctl/Entry.swift` | `@main` thin executable wrapper. |
| `Sources/ReminderKitPrivate/include/ReminderKitPrivate.h` | Obj-C umbrella header (public C API). |
| `Sources/ReminderKitPrivate/ReminderKitPrivate.m` | Phase-0 probe implementation. |
| `Tests/RemindersControlTests/PrivateLinkTests.swift` | Proves the private-framework target links and loads. |
| `Tests/RemindersControlTests/CommandTreeTests.swift` | Asserts the 45-command tree + version. |
| `.github/workflows/ci.yml` | Build + test on macOS runners. |

---

## Task 1: Package manifest, gitignore, dependency resolution

**Files:**
- Create: `Package.swift`
- Modify: `.gitignore`

- [ ] **Step 1: Write `Package.swift`**

Create `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemindersControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "remctl", targets: ["remctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.0.0")),
    ],
    targets: [
        // Obj-C target that links the private ReminderKit framework.
        .target(
            name: "ReminderKitPrivate",
            path: "Sources/ReminderKitPrivate",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/System/Library/PrivateFrameworks",
                    "-framework", "ReminderKit",
                ]),
            ]
        ),
        // Library holding all the CLI commands (unit-testable).
        .target(
            name: "RemindersControl",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
                "ReminderKitPrivate",
            ],
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        // Thin executable: @main wrapper over the library root command.
        .executableTarget(
            name: "remctl",
            dependencies: ["RemindersControl"]
        ),
        .testTarget(
            name: "RemindersControlTests",
            dependencies: ["RemindersControl"]
        ),
    ]
)
```

- [ ] **Step 2: Append build artifacts to `.gitignore`**

Append these two lines to the existing `.gitignore`:

```gitignore
.build/
.swiftpm/
```

- [ ] **Step 3: Resolve dependencies (de-risk versions)**

Run: `swift package resolve`
Expected: exits 0; prints resolved versions for `swift-argument-parser` and `GRDB.swift`; creates `Package.resolved`.
If a version range fails to resolve, widen the lower bound to the latest tag SwiftPM reports and re-run. Record the resolved versions — they get vendored at release (spec §7).

- [ ] **Step 4: Confirm the manifest is well-formed**

Run: `swift package describe --type json | head -c 200`
Expected: valid JSON beginning with the package name `RemindersControl`. (The build will fail until Tasks 2–3 add sources — that is expected here; this step only validates the manifest parses.)

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved .gitignore
git commit -m "Phase 0: SwiftPM manifest (ArgumentParser + GRDB + ReminderKitPrivate)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: ReminderKitPrivate Obj-C target (private-framework link de-risk)

This proves the single hardest build risk — linking `/System/Library/PrivateFrameworks/ReminderKit` into the binary — before any private logic is ported (that is Phase 3).

**Files:**
- Create: `Sources/ReminderKitPrivate/include/ReminderKitPrivate.h`
- Create: `Sources/ReminderKitPrivate/ReminderKitPrivate.m`
- Test: `Tests/RemindersControlTests/PrivateLinkTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/RemindersControlTests/PrivateLinkTests.swift`:

```swift
import Testing
import ReminderKitPrivate

@Test("ReminderKitPrivate links and the private framework loads")
func privateFrameworkProbe() {
    // RKPProbe() returns "reminderkit-ok" when the private REMStore class
    // resolves at runtime, proving both link-time and runtime availability.
    #expect(String(cString: RKPProbe()) == "reminderkit-ok")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter privateFrameworkProbe`
Expected: FAIL — compilation error, `no such module 'ReminderKitPrivate'` / `RKPProbe` undefined (sources not created yet).

- [ ] **Step 3: Write the umbrella header**

Create `Sources/ReminderKitPrivate/include/ReminderKitPrivate.h`:

```objc
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Phase-0 probe. Returns a C string: "reminderkit-ok" when the private
/// ReminderKit framework's REMStore class resolves at runtime, otherwise
/// "reminderkit-missing". Performs no writes. Replaced by the real private
/// API surface in Phase 3.
const char *RKPProbe(void);

NS_ASSUME_NONNULL_END
```

- [ ] **Step 4: Write the probe implementation**

Create `Sources/ReminderKitPrivate/ReminderKitPrivate.m`:

```objc
#import "ReminderKitPrivate.h"

const char *RKPProbe(void) {
    // Linking with -framework ReminderKit validates the link path at build
    // time; NSClassFromString validates the framework loads at runtime
    // without instantiating anything.
    Class store = NSClassFromString(@"REMStore");
    return store != nil ? "reminderkit-ok" : "reminderkit-missing";
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter privateFrameworkProbe`
Expected: PASS. (If it reports `reminderkit-missing`, the framework did not load — stop and investigate the `-F`/`-framework` flags before continuing.)

- [ ] **Step 6: Commit**

```bash
git add Sources/ReminderKitPrivate Tests/RemindersControlTests/PrivateLinkTests.swift
git commit -m "Phase 0: ReminderKitPrivate Obj-C target with private-framework link probe

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Library root command, global options, executable entry point

**Files:**
- Create: `Sources/RemindersControl/GlobalOptions.swift`
- Create: `Sources/RemindersControl/RemCTL.swift`
- Create: `Sources/remctl/Entry.swift`
- Test: `Tests/RemindersControlTests/CommandTreeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/RemindersControlTests/CommandTreeTests.swift`:

```swift
import Testing
import ArgumentParser
@testable import RemindersControl

@Test("Root command reports the package version")
func rootHasVersion() {
    #expect(RemCTL.configuration.version == remctlVersion)
    #expect(RemCTL.configuration.commandName == "remctl")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter rootHasVersion`
Expected: FAIL — `RemCTL` / `remctlVersion` undefined.

- [ ] **Step 3: Write `GlobalOptions.swift`**

Create `Sources/RemindersControl/GlobalOptions.swift`:

```swift
import ArgumentParser

/// The version string surfaced by `remctl --version`. The Swift rewrite is a
/// major version (spec §7); bump here on release.
public let remctlVersion = "2.0.0"

/// Shared output options included by every subcommand. Parity note: the Python
/// CLI adds `--json` per-subcommand (via `js(c)`), not as a root-level flag, so
/// it lives in an option group each command embeds rather than on the root.
public struct JSONOptions: ParsableArguments {
    public init() {}

    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.")
    public var json = false
}

/// Thrown by Phase-0 stubs. The real implementations land in later phases.
struct NotImplemented: Error, CustomStringConvertible {
    let command: String
    init(_ command: String) { self.command = command }
    var description: String { "`\(command)` is not implemented yet (Phase 0 stub)." }
}
```

- [ ] **Step 4: Write `RemCTL.swift` with an empty subcommand list**

Create `Sources/RemindersControl/RemCTL.swift`:

```swift
import ArgumentParser

/// Root command for the `remctl` CLI. Subcommand groups are assembled in
/// `allSubcommands`; each group lives in its own file under `Commands/`.
public struct RemCTL: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "remctl",
        abstract: "Power-user CLI for Apple Reminders.",
        version: remctlVersion,
        subcommands: allSubcommands
    )
}

/// Every subcommand type, assembled from the per-group arrays. Populated across
/// Tasks 4–9; starts empty so the package builds after Task 3.
let allSubcommands: [ParsableCommand.Type] = []
```

- [ ] **Step 5: Write the executable entry point**

Create `Sources/remctl/Entry.swift`:

```swift
import RemindersControl

@main
struct RemctlMain {
    static func main() async {
        await RemCTL.main()
    }
}
```

- [ ] **Step 6: Run the test to verify it passes, and confirm the binary builds**

Run: `swift test --filter rootHasVersion`
Expected: PASS.
Run: `swift run remctl --version`
Expected: prints `2.0.0`.

- [ ] **Step 7: Commit**

```bash
git add Sources/RemindersControl/GlobalOptions.swift Sources/RemindersControl/RemCTL.swift Sources/remctl/Entry.swift Tests/RemindersControlTests/CommandTreeTests.swift
git commit -m "Phase 0: library root command, global options, executable entry

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Read & inspect command stubs (12)

**Files:**
- Create: `Sources/RemindersControl/Commands/ReadCommands.swift`
- Modify: `Sources/RemindersControl/RemCTL.swift` (extend `allSubcommands`)
- Test: `Tests/RemindersControlTests/CommandTreeTests.swift` (add a case)

- [ ] **Step 1: Add the failing test case**

Append to `Tests/RemindersControlTests/CommandTreeTests.swift`:

```swift
@Test("Read commands are registered")
func readCommandsRegistered() {
    let names = Set(RemCTL.configuration.subcommands.compactMap { $0.configuration.commandName })
    for expected in ["today", "upcoming", "overdue", "search", "flagged", "urgent",
                     "tags", "subtasks", "sections", "stats", "show", "info"] {
        #expect(names.contains(expected), "missing \(expected)")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter readCommandsRegistered`
Expected: FAIL — names set is empty, expectations fail.

- [ ] **Step 3: Create `ReadCommands.swift`**

Create `Sources/RemindersControl/Commands/ReadCommands.swift`:

```swift
import ArgumentParser

let readCommands: [ParsableCommand.Type] = [
    Today.self, Upcoming.self, Overdue.self, Search.self, Flagged.self, Urgent.self,
    Tags.self, Subtasks.self, Sections.self, Stats.self, Show.self, Info.self,
]

struct Today: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "today", abstract: "List reminders due today.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("today") }
}

struct Upcoming: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upcoming", abstract: "List upcoming reminders.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("upcoming") }
}

struct Overdue: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "overdue", abstract: "List overdue reminders.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("overdue") }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Search reminders by text.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("search") }
}

struct Flagged: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "flagged", abstract: "List flagged reminders.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("flagged") }
}

struct Urgent: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "urgent", abstract: "List urgent reminders.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("urgent") }
}

struct Tags: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tags", abstract: "List tags / reminders by tag.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("tags") }
}

struct Subtasks: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "subtasks", abstract: "Show a reminder's subtasks.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("subtasks") }
}

struct Sections: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sections", abstract: "Show list sections.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("sections") }
}

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stats", abstract: "Show reminder statistics.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("stats") }
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show a single reminder.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("show") }
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show detailed reminder info.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("info") }
}
```

- [ ] **Step 4: Wire the group into `allSubcommands`**

In `Sources/RemindersControl/RemCTL.swift`, replace the line:

```swift
let allSubcommands: [ParsableCommand.Type] = []
```

with:

```swift
let allSubcommands: [ParsableCommand.Type] =
    readCommands
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter readCommandsRegistered`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/RemindersControl/Commands/ReadCommands.swift Sources/RemindersControl/RemCTL.swift Tests/RemindersControlTests/CommandTreeTests.swift
git commit -m "Phase 0: read/inspect command stubs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Reminder-mutation command stubs (9)

**Files:**
- Create: `Sources/RemindersControl/Commands/WriteCommands.swift`
- Modify: `Sources/RemindersControl/RemCTL.swift`
- Test: `Tests/RemindersControlTests/CommandTreeTests.swift`

- [ ] **Step 1: Add the failing test case**

Append to `CommandTreeTests.swift`:

```swift
@Test("Write commands are registered")
func writeCommandsRegistered() {
    let names = Set(RemCTL.configuration.subcommands.compactMap { $0.configuration.commandName })
    for expected in ["add", "edit", "done", "undone", "delete", "flag", "unflag", "link", "open"] {
        #expect(names.contains(expected), "missing \(expected)")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter writeCommandsRegistered`
Expected: FAIL — names missing.

- [ ] **Step 3: Create `WriteCommands.swift`**

Create `Sources/RemindersControl/Commands/WriteCommands.swift`:

```swift
import ArgumentParser

let writeCommands: [ParsableCommand.Type] = [
    Add.self, Edit.self, Done.self, Undone.self, Delete.self,
    Flag.self, Unflag.self, Link.self, Open.self,
]

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a reminder.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("add") }
}

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Edit a reminder.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("edit") }
}

struct Done: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "done", abstract: "Mark reminders complete.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("done") }
}

struct Undone: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "undone", abstract: "Mark reminders incomplete.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("undone") }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete reminders.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("delete") }
}

struct Flag: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "flag", abstract: "Flag a reminder.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("flag") }
}

struct Unflag: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unflag", abstract: "Unflag a reminder.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("unflag") }
}

struct Link: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "link", abstract: "Print a reminder's deep link.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("link") }
}

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open a reminder in Reminders.app.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("open") }
}
```

- [ ] **Step 4: Extend `allSubcommands`**

In `RemCTL.swift`, replace:

```swift
let allSubcommands: [ParsableCommand.Type] =
    readCommands
```

with:

```swift
let allSubcommands: [ParsableCommand.Type] =
    readCommands
    + writeCommands
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter writeCommandsRegistered`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/RemindersControl/Commands/WriteCommands.swift Sources/RemindersControl/RemCTL.swift Tests/RemindersControlTests/CommandTreeTests.swift
git commit -m "Phase 0: reminder-mutation command stubs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: List-management command stubs (8)

**Files:**
- Create: `Sources/RemindersControl/Commands/ListCommands.swift`
- Modify: `Sources/RemindersControl/RemCTL.swift`
- Test: `Tests/RemindersControlTests/CommandTreeTests.swift`

- [ ] **Step 1: Add the failing test case**

Append to `CommandTreeTests.swift`:

```swift
@Test("List commands are registered")
func listCommandsRegistered() {
    let names = Set(RemCTL.configuration.subcommands.compactMap { $0.configuration.commandName })
    for expected in ["lists", "list-create", "list-edit", "list-pin", "list-unpin",
                     "list-rename", "list-delete", "list-symbols"] {
        #expect(names.contains(expected), "missing \(expected)")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter listCommandsRegistered`
Expected: FAIL.

- [ ] **Step 3: Create `ListCommands.swift`**

Create `Sources/RemindersControl/Commands/ListCommands.swift`:

```swift
import ArgumentParser

let listCommands: [ParsableCommand.Type] = [
    Lists.self, ListCreate.self, ListEdit.self, ListPin.self, ListUnpin.self,
    ListRename.self, ListDelete.self, ListSymbols.self,
]

struct Lists: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lists", abstract: "List all lists.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("lists") }
}

struct ListCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-create", abstract: "Create a list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("list-create") }
}

struct ListEdit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-edit", abstract: "Edit a list's appearance.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("list-edit") }
}

struct ListPin: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-pin", abstract: "Pin a list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("list-pin") }
}

struct ListUnpin: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-unpin", abstract: "Unpin a list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("list-unpin") }
}

struct ListRename: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-rename", abstract: "Rename a list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("list-rename") }
}

struct ListDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-delete", abstract: "Delete a list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("list-delete") }
}

struct ListSymbols: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-symbols", abstract: "List badge symbols.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("list-symbols") }
}
```

- [ ] **Step 4: Extend `allSubcommands`**

In `RemCTL.swift`, replace the assignment with:

```swift
let allSubcommands: [ParsableCommand.Type] =
    readCommands
    + writeCommands
    + listCommands
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter listCommandsRegistered`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/RemindersControl/Commands/ListCommands.swift Sources/RemindersControl/RemCTL.swift Tests/RemindersControlTests/CommandTreeTests.swift
git commit -m "Phase 0: list-management command stubs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Smart-list command stubs (4)

**Files:**
- Create: `Sources/RemindersControl/Commands/SmartListCommands.swift`
- Modify: `Sources/RemindersControl/RemCTL.swift`
- Test: `Tests/RemindersControlTests/CommandTreeTests.swift`

- [ ] **Step 1: Add the failing test case**

Append to `CommandTreeTests.swift`:

```swift
@Test("Smart-list commands are registered")
func smartListCommandsRegistered() {
    let names = Set(RemCTL.configuration.subcommands.compactMap { $0.configuration.commandName })
    for expected in ["smart-lists", "smart-list-create", "smart-list-edit", "smart-list-delete"] {
        #expect(names.contains(expected), "missing \(expected)")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter smartListCommandsRegistered`
Expected: FAIL.

- [ ] **Step 3: Create `SmartListCommands.swift`**

Create `Sources/RemindersControl/Commands/SmartListCommands.swift`:

```swift
import ArgumentParser

let smartListCommands: [ParsableCommand.Type] = [
    SmartLists.self, SmartListCreate.self, SmartListEdit.self, SmartListDelete.self,
]

struct SmartLists: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-lists", abstract: "List smart lists.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("smart-lists") }
}

struct SmartListCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-list-create", abstract: "Create a smart list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("smart-list-create") }
}

struct SmartListEdit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-list-edit", abstract: "Edit a smart list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("smart-list-edit") }
}

struct SmartListDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart-list-delete", abstract: "Delete a smart list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("smart-list-delete") }
}
```

- [ ] **Step 4: Extend `allSubcommands`**

In `RemCTL.swift`, replace the assignment with:

```swift
let allSubcommands: [ParsableCommand.Type] =
    readCommands
    + writeCommands
    + listCommands
    + smartListCommands
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter smartListCommandsRegistered`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/RemindersControl/Commands/SmartListCommands.swift Sources/RemindersControl/RemCTL.swift Tests/RemindersControlTests/CommandTreeTests.swift
git commit -m "Phase 0: smart-list command stubs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Template command stubs (5)

**Files:**
- Create: `Sources/RemindersControl/Commands/TemplateCommands.swift`
- Modify: `Sources/RemindersControl/RemCTL.swift`
- Test: `Tests/RemindersControlTests/CommandTreeTests.swift`

- [ ] **Step 1: Add the failing test case**

Append to `CommandTreeTests.swift`:

```swift
@Test("Template commands are registered")
func templateCommandsRegistered() {
    let names = Set(RemCTL.configuration.subcommands.compactMap { $0.configuration.commandName })
    for expected in ["templates", "template-info", "template-create", "template-apply", "template-delete"] {
        #expect(names.contains(expected), "missing \(expected)")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter templateCommandsRegistered`
Expected: FAIL.

- [ ] **Step 3: Create `TemplateCommands.swift`**

Create `Sources/RemindersControl/Commands/TemplateCommands.swift`:

```swift
import ArgumentParser

let templateCommands: [ParsableCommand.Type] = [
    Templates.self, TemplateInfo.self, TemplateCreate.self, TemplateApply.self, TemplateDelete.self,
]

struct Templates: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "templates", abstract: "List templates.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("templates") }
}

struct TemplateInfo: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-info", abstract: "Show template details.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("template-info") }
}

struct TemplateCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-create", abstract: "Create a template from a list.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("template-create") }
}

struct TemplateApply: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-apply", abstract: "Create a list from a template.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("template-apply") }
}

struct TemplateDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-delete", abstract: "Delete a template.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("template-delete") }
}
```

- [ ] **Step 4: Extend `allSubcommands`**

In `RemCTL.swift`, replace the assignment with:

```swift
let allSubcommands: [ParsableCommand.Type] =
    readCommands
    + writeCommands
    + listCommands
    + smartListCommands
    + templateCommands
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter templateCommandsRegistered`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/RemindersControl/Commands/TemplateCommands.swift Sources/RemindersControl/RemCTL.swift Tests/RemindersControlTests/CommandTreeTests.swift
git commit -m "Phase 0: template command stubs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: IO/ops command stubs (7) and full-tree assertion

**Files:**
- Create: `Sources/RemindersControl/Commands/OpsCommands.swift`
- Modify: `Sources/RemindersControl/RemCTL.swift`
- Test: `Tests/RemindersControlTests/CommandTreeTests.swift`

- [ ] **Step 1: Add the failing test cases**

Append to `CommandTreeTests.swift`:

```swift
@Test("Ops commands are registered")
func opsCommandsRegistered() {
    let names = Set(RemCTL.configuration.subcommands.compactMap { $0.configuration.commandName })
    for expected in ["export", "import", "completion", "doctor", "onboard", "permissions", "setup"] {
        #expect(names.contains(expected), "missing \(expected)")
    }
}

@Test("Exactly 45 unique subcommands are registered")
func allFortyFiveRegistered() {
    let names = RemCTL.configuration.subcommands.compactMap { $0.configuration.commandName }
    #expect(names.count == 45)
    #expect(Set(names).count == 45, "duplicate command names: \(names)")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "opsCommandsRegistered|allFortyFiveRegistered"`
Expected: FAIL — ops names missing; count is 38, not 45.

- [ ] **Step 3: Create `OpsCommands.swift`**

Create `Sources/RemindersControl/Commands/OpsCommands.swift`:

```swift
import ArgumentParser

let opsCommands: [ParsableCommand.Type] = [
    Export.self, Import.self, Completion.self, Doctor.self, Onboard.self, Permissions.self, Setup.self,
]

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export reminders.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("export") }
}

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import", abstract: "Import reminders.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("import") }
}

struct Completion: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "completion", abstract: "Print a shell completion script.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("completion") }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Diagnose setup and permissions.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("doctor") }
}

struct Onboard: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "onboard", abstract: "First-run onboarding.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("onboard") }
}

struct Permissions: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "permissions", abstract: "Guided Full Disk Access setup.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("permissions") }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup", abstract: "Install shell completions/config.")
    @OptionGroup var output: JSONOptions
    func run() throws { throw NotImplemented("setup") }
}
```

- [ ] **Step 4: Extend `allSubcommands` (final form)**

In `RemCTL.swift`, replace the assignment with:

```swift
let allSubcommands: [ParsableCommand.Type] =
    readCommands
    + writeCommands
    + listCommands
    + smartListCommands
    + templateCommands
    + opsCommands
```

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --filter "opsCommandsRegistered|allFortyFiveRegistered"`
Expected: PASS.

- [ ] **Step 6: Run the whole suite and smoke-test help**

Run: `swift test`
Expected: PASS (all command-tree tests + the private-link test).
Run: `swift run remctl --help`
Expected: usage text listing all 45 subcommands under SUBCOMMANDS.
Run: `swift run remctl today`
Expected: stderr `Error: `today` is not implemented yet (Phase 0 stub).`; non-zero exit.

- [ ] **Step 7: Commit**

```bash
git add Sources/RemindersControl/Commands/OpsCommands.swift Sources/RemindersControl/RemCTL.swift Tests/RemindersControlTests/CommandTreeTests.swift
git commit -m "Phase 0: ops command stubs; full 45-command tree

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: CI workflow (build + test on macOS)

This lives in the RemCTL repo (the `fork`). It is independent of the tap's bottle CI; this just keeps `swift build`/`swift test` green on every push and PR. Network is available here (unlike the Homebrew bottle sandbox), so SwiftPM fetches deps normally.

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Create the workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main, swift-port]
  pull_request:

jobs:
  build-test:
    strategy:
      matrix:
        os: [macos-15, macos-26]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: Show Swift version
        run: swift --version
      - name: Build
        run: swift build
      - name: Test
        run: swift test
```

- [ ] **Step 2: Validate the YAML locally**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('ci.yml OK')"`
Expected: `ci.yml OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Phase 0: CI — swift build + test on macOS runners

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: (Optional) Push the branch to the fork to exercise CI**

Only with the user's go-ahead (this publishes the branch):

```bash
git push -u fork swift-port
```

Expected: branch pushed; the CI workflow runs on `github.com/markmals/remctl`. Confirm both matrix jobs go green.

---

## Self-Review (completed during authoring)

**Spec coverage (design §8, Phase 0 row):**
- "Package.swift (ArgumentParser + GRDB)" → Task 1. ✓
- "command skeleton with all 45 subcommand stubs" → Tasks 4–9 (12+9+8+4+5+7 = 45), asserted by `allFortyFiveRegistered`. ✓
- "`--version` global" → Task 3 (`version: remctlVersion`), asserted by `rootHasVersion`; verified via `remctl --version`. ✓
- "`--json` as a shared per-subcommand option" → `JSONOptions` (Task 3), embedded in every stub via `@OptionGroup` (Tasks 4–9). ✓
- "no global `--json`/`--store`/`--config`" → none defined on the root. ✓
- "color via `NO_COLOR`" → no color in Phase 0 output; honoring `NO_COLOR` is deferred to the `Output` unit in Phase 1 (no Phase-0 task needed). Noted, not a gap.
- "fold the 3 helpers in as targets" → `ReminderKitPrivate` Obj-C target established and link-proven (Task 2). The EventKit and AppKit/permissions Swift helpers are refactored from standalone executables into library code in Phases 2 and 4 respectively (their `main`/top-level code must be removed first); EventKit and AppKit are already linked by the library target (Task 1) so those phases only add source. Scope-correct for Phase 0.
- "CI green" → Task 10. ✓
- Acceptance ("`swift build` + `swift test` run; `remctl --help` lists all commands") → verified in Task 9 Step 6. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete file content; every command step states the exact command and expected output. ✓

**Type/name consistency:** `RemCTL`, `remctlVersion`, `JSONOptions`, `NotImplemented`, and the six group arrays (`readCommands`, `writeCommands`, `listCommands`, `smartListCommands`, `templateCommands`, `opsCommands`) are defined once and referenced consistently in `allSubcommands`. Command struct names are unique across files (verified against the 45-name list). ✓

**Known risk flagged for the executor:** exact resolvable versions of `swift-argument-parser` and `GRDB.swift` are pinned as lower bounds in Task 1; if SwiftPM cannot resolve, bump to the latest tag and record it (these versions get vendored at release, spec §7). The `ReminderKitPrivate` link is de-risked first (Task 2) precisely because it is the least standard part of the build.
