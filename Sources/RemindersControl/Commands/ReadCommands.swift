import ArgumentParser
import Foundation
import GRDB
import Foundation

let readCommands: [ParsableCommand.Type] = [
    Today.self, Upcoming.self, Overdue.self, Search.self, Flagged.self, Urgent.self,
    Tags.self, Subtasks.self, Sections.self, Sharees.self, ListInfo.self, Stats.self,
    Show.self, Info.self,
]

struct Today: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "today", abstract: "List reminders due today.")
    @OptionGroup var opts: ReadDisplayOptions
    @Flag(name: .long, help: "Exclude overdue items") var noOverdue = false
    @Flag(name: .long, help: "Limited read-only EventKit fallback; no numeric ids or private metadata") var viaEventkit = false

    func run() async throws {
        if viaEventkit {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let dateStr = df.string(from: Date())
            await EventKitReadCLI.run(
                mode: "today", includeOverdue: !noOverdue, opts: opts,
                heading: "Due Today (\(dateStr)) (EventKit limited)",
                emptyMessage: "Nothing due today (\(dateStr)) via EventKit")
            return
        }
        Dispatch.runRead(json: opts.effectiveJSON) { store in
            let now = Date()
            let rows = store.dueToday(includeOverdue: !noOverdue, now: now)
            let pks = rows.compactMap { $0.int("Z_PK") }
            let (counts, tags) = store.preloadExtras(pks)
            let ansi = opts.ansi()

            if opts.effectiveJSON {
                Dispatch.printJSON(.array(serializeReminders(rows, store: store).map { .object($0) }), ensureAscii: true)
                return
            }
            if opts.useTable {
                print(fmtTable(remindersToTableData(rows, ansi: ansi, now: now), ansi: ansi))
                return
            }
            if rows.isEmpty {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                print("Nothing due today (\(fmt.string(from: now)))")
                return
            }
            let badges = store.preloadIndicators(pks)
            let sodTs = AppleEpoch.toTs(DateWindows.startOfDay(now))
            let overdue = rows.filter { (rowShownDate($0) ?? 0) < sodTs }
            let overduePKs = Set(overdue.compactMap { $0.int("Z_PK") })
            let due = rows.filter { !overduePKs.contains($0.int("Z_PK") ?? -1) }

            if !overdue.isEmpty {
                print(ansi.red("Overdue (\(overdue.count)):"))
                for r in overdue {
                    let pk = r.int("Z_PK") ?? 0
                    print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, indent: "  ", assigneeName: store.assignmentAssignee(pk: pk), badges: badges[pk] ?? ReminderBadges()))
                }
                print("")
            }
            if !due.isEmpty {
                print(ansi.bold("Due Today (\(due.count)):"))
                for r in due {
                    let pk = r.int("Z_PK") ?? 0
                    print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, indent: "  ", assigneeName: store.assignmentAssignee(pk: pk), badges: badges[pk] ?? ReminderBadges()))
                }
            }
            print("\n\(rows.count) total")
        }
    }
}

struct Upcoming: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upcoming", abstract: "List reminders due from today through N more days (default 7).")
    @OptionGroup var opts: ReadDisplayOptions
    @Argument(help: "Days to look ahead beyond today; the window always starts today (1 = today and tomorrow, 7 = today plus the next week)") var days: Int = 7
    @Flag(name: .long, help: "Limited read-only EventKit fallback; no numeric ids or private metadata") var viaEventkit = false

    func run() async throws {
        guard (1...3650).contains(days) else {
            let failure = CommandFailure("invalid_days", "upcoming days must be between 1 and 3650.")
            FileHandle.standardError.write(Data(failure.outcome(json: opts.effectiveJSON).stderr.utf8))
            throw ExitCode(1)
        }
        if viaEventkit {
            await EventKitReadCLI.run(
                mode: "upcoming", days: days, opts: opts,
                heading: "Upcoming (\(days) days) (EventKit limited)",
                emptyMessage: "Nothing due in the next \(days) days via EventKit",
                groupByDay: true)
            return
        }
        Dispatch.runRead(json: opts.effectiveJSON) { store in
            let now = Date()
            let rows = store.upcoming(days: days, now: now)
            let pks = rows.compactMap { $0.int("Z_PK") }
            let (counts, tags) = store.preloadExtras(pks)
            let ansi = opts.ansi()

            if opts.effectiveJSON {
                Dispatch.printJSON(.array(serializeReminders(rows, store: store).map { .object($0) }), ensureAscii: true)
                return
            }
            if opts.useTable {
                print(fmtTable(remindersToTableData(rows, ansi: ansi, now: now), ansi: ansi))
                return
            }
            if rows.isEmpty {
                print("Nothing due in the next \(days) days")
                return
            }
            print(ansi.bold("Upcoming (\(days) days):"))
            let badges = store.preloadIndicators(pks)

            let cal = Calendar.current
            let today = cal.startOfDay(for: now)
            let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

            // Group by local day string
            var keyOrder: [String] = []
            var groupMap: [String: (label: String, items: [ReminderRow])] = [:]

            for r in rows {
                guard let dueVal = rowShownDate(r), dueVal != 0 else { continue }
                let dt = Date(timeIntervalSince1970: dueVal + AppleEpoch.offset)
                let dtDay = cal.startOfDay(for: dt)
                let dayKey: String
                let comps = cal.dateComponents([.year, .month, .day], from: dtDay)
                dayKey = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
                if groupMap[dayKey] == nil {
                    let dayLabel: String
                    if dtDay == today { dayLabel = "Today" }
                    else if dtDay == tomorrow { dayLabel = "Tomorrow" }
                    else {
                        let lf = DateFormatter()
                        lf.dateFormat = "EEEE, MMM dd"
                        dayLabel = lf.string(from: dtDay)
                    }
                    groupMap[dayKey] = (label: dayLabel, items: [])
                    keyOrder.append(dayKey)
                }
                groupMap[dayKey]!.items.append(r)
            }

            for key in keyOrder.sorted() {
                guard let grp = groupMap[key] else { continue }
                print("\n  \(ansi.bold(grp.label)):")
                for r in grp.items {
                    let pk = r.int("Z_PK") ?? 0
                    print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, indent: "    ", assigneeName: store.assignmentAssignee(pk: pk), badges: badges[pk] ?? ReminderBadges()))
                }
            }
            print("\n\(rows.count) upcoming")
        }
    }
}

struct Overdue: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "overdue", abstract: "List overdue reminders.")
    @OptionGroup var opts: ReadDisplayOptions

    func run() throws {
        Dispatch.runRead(json: opts.effectiveJSON) { store in
            let now = Date()
            let rows = store.overdue(now: now)
            let pks = rows.compactMap { $0.int("Z_PK") }
            let (counts, tags) = store.preloadExtras(pks)
            let ansi = opts.ansi()

            if opts.effectiveJSON {
                Dispatch.printJSON(.array(serializeReminders(rows, store: store).map { .object($0) }), ensureAscii: true)
                return
            }
            if opts.useTable {
                print(fmtTable(remindersToTableData(rows, ansi: ansi, now: now), ansi: ansi))
                return
            }
            if rows.isEmpty {
                print("No overdue reminders")
                return
            }
            print(ansi.red(ansi.bold("Overdue (\(rows.count)):")))
            let badges = store.preloadIndicators(pks)
            for r in rows {
                let pk = r.int("Z_PK") ?? 0
                print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, verbose: opts.verbose, indent: "  ", assigneeName: store.assignmentAssignee(pk: pk), earlyFallback: store.earlyReminderAlerts, badges: badges[pk] ?? ReminderBadges()))
            }
            print("\n\(rows.count) overdue")
        }
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Search reminders by text.")
    @OptionGroup var opts: ReadDisplayOptions
    @Argument(help: "Search query") var query: String
    @Flag(name: .long, help: "Include completed reminders") var completed = false
    @Option(name: [.short, .long], help: "Only search one list, by name") var list: String?
    @Option(name: .long, help: "Only search one list, by stable numeric ID") var listId: Int?
    @Option(name: .long, help: "Matches per page, 1-\(RemindersStore.searchMaxLimit); \(RemindersStore.searchDefaultLimit) when omitted")
    var limit: Int?
    @Option(name: .long, help: "Matches to skip before this page; 0 when omitted") var offset: Int?
    @Flag(name: .long, help: "Limited read-only EventKit fallback; no numeric ids or private metadata") var viaEventkit = false

    /// Port of `search_page_args`: validated page bounds. `paged` means the caller asked for
    /// pages, which turns the `--json` array into the page object.
    private func pageArgs() throws -> (limit: Int, offset: Int, paged: Bool) {
        if let limit, !(1...RemindersStore.searchMaxLimit).contains(limit) {
            throw pagingFailure("invalid_limit", "--limit must be between 1 and \(RemindersStore.searchMaxLimit).")
        }
        if let offset, offset < 0 {
            throw pagingFailure("invalid_offset", "--offset must be 0 or more.")
        }
        return (limit ?? RemindersStore.searchDefaultLimit, offset ?? 0, limit != nil || offset != nil)
    }

    /// Paging bounds fail before the store is opened, so they report themselves.
    private func pagingFailure(_ code: String, _ message: String) -> ExitCode {
        let text: String
        if opts.effectiveJSON {
            let payload: JSONValue = .object([
                ("status", .string("error")),
                ("code", .string(code)),
                ("message", .string(message)),
            ])
            text = payload.serialized(indent: nil, ensureAscii: true) + "\n"
        } else {
            text = "Error: \(message)\n"
        }
        FileHandle.standardError.write(Data(text.utf8))
        return ExitCode(1)
    }

    private func pageJSON(items: [JSONValue], total: Int, limit: Int, offset: Int, nextOffset: Int?,
                          listRef: (id: Int, title: String)?) -> JSONValue
    {
        var pairs: [(String, JSONValue)] = [
            ("query", .string(query)),
            ("items", .array(items)),
            ("count", .int(items.count)),
            ("total", .int(total)),
            ("offset", .int(offset)),
            ("limit", .int(limit)),
            ("hasMore", .bool(nextOffset != nil)),
            ("nextOffset", nextOffset.map { JSONValue.int($0) } ?? .null),
        ]
        if let listRef {
            pairs.append(("list", .object([("id", .int(listRef.id)), ("title", .string(listRef.title))])))
        }
        return .object(pairs)
    }

    func run() async throws {
        if viaEventkit {
            await EventKitReadCLI.run(
                mode: "search", listId: listId, listName: list, query: query, completed: completed,
                pagingRequested: limit != nil || offset != nil, opts: opts,
                heading: "Search: \(safeDisplay(query)) (EventKit limited)",
                emptyMessage: "No reminders matching '\(safeDisplay(query))' via EventKit")
            return
        }
        let (limit, offset, paged) = try pageArgs()
        Dispatch.runRead(json: opts.effectiveJSON) { store in
            let now = Date()
            var listRef: (id: Int, title: String)?
            if list != nil || listId != nil {
                let target = try resolveRequiredListTarget(store: store, name: list, listId: listId)
                listRef = (target.id, target.title)
            }
            let rows = store.search(query, completed: completed, listPk: listRef?.id, limit: limit, offset: offset)
            let total = store.searchCount(query, completed: completed, listPk: listRef?.id)
            let nextOffset = offset + rows.count < total ? offset + rows.count : nil
            let pks = rows.compactMap { $0.int("Z_PK") }
            let (counts, tags) = store.preloadExtras(pks)
            let ansi = opts.ansi()

            if opts.effectiveJSON {
                let items = serializeReminders(rows, store: store).map { JSONValue.object($0) }
                if paged {
                    Dispatch.printJSON(pageJSON(items: items, total: total, limit: limit, offset: offset,
                                                nextOffset: nextOffset, listRef: listRef), ensureAscii: true)
                    return
                }
                // The bare array stays for existing scripts; stderr says when it is cut short.
                if let nextOffset {
                    FileHandle.standardError.write(Data(
                        ("Warning: showing \(rows.count) of \(total) matches. "
                         + "Pass --offset \(nextOffset) --limit \(limit) for the next page.\n").utf8))
                }
                Dispatch.printJSON(.array(items), ensureAscii: true)
                return
            }
            if opts.useTable {
                print(fmtTable(remindersToTableData(rows, ansi: ansi, now: now), ansi: ansi,
                               dateColumn: completed ? .completed : .due))
                if let nextOffset {
                    FileHandle.standardError.write(Data(
                        "Showing \(rows.count) of \(total) matches. Next page: --offset \(nextOffset)\n".utf8))
                }
                return
            }
            let scope = listRef.map { " in \(safeDisplay($0.title))" } ?? ""
            if rows.isEmpty {
                if total > 0 && offset > 0 {
                    print("No reminders matching '\(safeDisplay(query))'\(scope) past offset \(offset) (\(total) total)")
                } else {
                    print("No reminders matching '\(safeDisplay(query))'\(scope)")
                }
                return
            }
            print("Search: \(ansi.bold(safeDisplay(query)))\(scope)")
            let badges = store.preloadIndicators(pks)
            for r in rows {
                let pk = r.int("Z_PK") ?? 0
                print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, verbose: opts.verbose, assigneeName: store.assignmentAssignee(pk: pk), earlyFallback: store.earlyReminderAlerts, badges: badges[pk] ?? ReminderBadges()))
            }
            if rows.count == total {
                print("\n\(total) result\(total == 1 ? "" : "s")")
                return
            }
            print("\nShowing \(offset + 1)-\(offset + rows.count) of \(total) results")
            if let nextOffset { print("Next page: --offset \(nextOffset)") }
        }
    }
}

struct Flagged: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "flagged", abstract: "List flagged reminders.")
    @OptionGroup var opts: ReadDisplayOptions

    func run() throws {
        Dispatch.runRead(json: opts.effectiveJSON) { store in
            let now = Date()
            let rows = store.flagged()
            let pks = rows.compactMap { $0.int("Z_PK") }
            let (counts, tags) = store.preloadExtras(pks)
            let ansi = opts.ansi()

            if opts.effectiveJSON {
                Dispatch.printJSON(.array(serializeReminders(rows, store: store).map { .object($0) }), ensureAscii: true)
                return
            }
            if opts.useTable {
                print(fmtTable(remindersToTableData(rows, ansi: ansi, now: now), ansi: ansi))
                return
            }
            if rows.isEmpty {
                print("No flagged reminders")
                return
            }
            print(ansi.bold("Flagged:"))
            let badges = store.preloadIndicators(pks)
            for r in rows {
                let pk = r.int("Z_PK") ?? 0
                print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, verbose: opts.verbose, indent: "  ", assigneeName: store.assignmentAssignee(pk: pk), earlyFallback: store.earlyReminderAlerts, badges: badges[pk] ?? ReminderBadges()))
            }
            let n = rows.count
            print("\n\(n) flagged")
        }
    }
}

struct Urgent: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "urgent", abstract: "List urgent reminders.")
    @OptionGroup var opts: ReadDisplayOptions

    func run() throws {
        Dispatch.runRead(json: opts.effectiveJSON) { store in
            let now = Date()
            let rows = store.urgent()
            let pks = rows.compactMap { $0.int("Z_PK") }
            let (counts, tags) = store.preloadExtras(pks)
            let ansi = opts.ansi()

            if opts.effectiveJSON {
                Dispatch.printJSON(.array(serializeReminders(rows, store: store).map { .object($0) }), ensureAscii: true)
                return
            }
            if opts.useTable {
                print(fmtTable(remindersToTableData(rows, ansi: ansi, now: now), ansi: ansi))
                return
            }
            if rows.isEmpty {
                print("No urgent reminders")
                return
            }
            print(ansi.bold("Urgent:"))
            let badges = store.preloadIndicators(pks)
            for r in rows {
                let pk = r.int("Z_PK") ?? 0
                print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, verbose: opts.verbose, indent: "  ", assigneeName: store.assignmentAssignee(pk: pk), earlyFallback: store.earlyReminderAlerts, badges: badges[pk] ?? ReminderBadges()))
            }
            let n = rows.count
            print("\n\(n) urgent")
        }
    }
}

struct Tags: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tags", abstract: "List tags / reminders by tag.")
    @OptionGroup var opts: JSONOnlyOptions

    func run() throws {
        Dispatch.runRead(json: opts.json) { store in
            let ansi = opts.ansi()
            let names = store.allTagNames()

            if opts.json {
                Dispatch.printJSON(.array(names.map { .object([("name", .string($0))]) }), ensureAscii: true)
                return
            }
            if names.isEmpty {
                print("No tags found")
                return
            }
            print(ansi.bold("Tags:"))
            for name in names {
                print("  \(ansi.magenta("#" + safeDisplay(name)))")
            }
            let n = names.count
            print("\n\(n) tag\(n == 1 ? "" : "s")")
        }
    }
}

struct Subtasks: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "subtasks", abstract: "Show a reminder's subtasks.")
    @Argument(help: "Reminder ID") var id: Int
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false
    @Flag(name: [.short, .long], help: "Verbose output (accepted, no-op)") var verbose = false

    func run() throws {
        Dispatch.runRead(json: json) { store in
            guard let parent = store.reminder(pk: id) else {
                throw CLIError("#\(id) not found", code: "not_found", context: [("id", .int(id))])
            }
            let subs = store.reminders(completed: true, parentPk: id)
            let subPks = subs.compactMap { $0.int("Z_PK") }
            let (sc, ht) = store.preloadExtras(subPks)

            if json {
                var d = serializeReminder(
                    parent,
                    ts: { AppleEpoch.ts($0) },
                    priorityNames: Constants.priorityName,
                    subtaskCounts: [id: store.subtaskCount(pk: id)],
                    hashtags: [id: store.hashtags(pk: id)],
                    attachments: attachmentJSONByReminder(store.preloadAttachments([id]),
                                                          resolve: store.resolveAttachmentPath),
                    richLink: { store.richLink(pk: id) }
                )
                if let assignment = assignmentToDict(store.assignment(reminderPk: id)) {
                    d.append(("assignment", assignment))
                }
                let childObjs = serializeReminders(subs, store: store)
                d.append(("subtasks", .array(childObjs.map { .object($0) })))
                Dispatch.printJSON(.object(d), ensureAscii: true)
                return
            }
            print("Parent: \(safeDisplay(parent.string("ZTITLE")))")
            if subs.isEmpty {
                print("  No subtasks")
            } else {
                let ansi = Ansi.resolve(noColorFlag: false)
                let badges = store.preloadIndicators(subPks)
                for s in subs {
                    let pk = s.int("Z_PK") ?? 0
                    print(fmt(s, tags: ht[pk] ?? [], subtaskCount: sc[pk] ?? 0, ansi: ansi, indent: "  ", assigneeName: store.assignmentAssignee(pk: pk), badges: badges[pk] ?? ReminderBadges()))
                }
                let n = subs.count
                print("\n\(n) subtask\(n == 1 ? "" : "s")")
            }
        }
    }
}

struct Sections: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sections", abstract: "Show list sections.")
    @OptionGroup var opts: JSONOnlyOptions

    func run() throws {
        Dispatch.runRead(json: opts.json) { store in
            let ansi = opts.ansi()
            let rows = store.sectionsAll()

            if opts.json {
                // Build ordered object: keys are list names in first-seen order
                var keyOrder: [String] = []
                var groupMap: [String: [JSONValue]] = [:]
                for r in rows {
                    let ln = r.string("list_name") ?? "?"
                    if groupMap[ln] == nil {
                        keyOrder.append(ln)
                        groupMap[ln] = []
                    }
                    let dn = r.string("ZDISPLAYNAME")
                    groupMap[ln]!.append(dn.map { .string($0) } ?? .null)
                }
                let pairs: [(String, JSONValue)] = keyOrder.map { ln in
                    (ln, .array(groupMap[ln] ?? []))
                }
                Dispatch.printJSON(.object(pairs), ensureAscii: true)
                return
            }
            if rows.isEmpty {
                print("No sections found")
                return
            }
            var cur: String? = nil
            for r in rows {
                let ln = r.string("list_name") ?? "?"
                if ln != cur {
                    if cur != nil { print("") }
                    print("\(ansi.bold(colorListName(ln, ansi: ansi))):")
                    cur = ln
                }
                print("  - \(safeDisplay(r.string("ZDISPLAYNAME")))")
            }
            let n = rows.count
            print("\n\(n) section\(n == 1 ? "" : "s")")
        }
    }
}

/// Port of `cmd_sharees` (upstream 683c362): show the people available for assignment
/// in a shared list. Read-only; assignment writes live on add/edit (--assign).
struct Sharees: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sharees", abstract: "Show people available for assignment in a shared list.")
    @OptionGroup var opts: JSONOnlyOptions
    @Argument(help: "List name") var list: String?
    @Option(name: .long, help: "Shared list by stable numeric ID") var listId: Int?

    func run() throws {
        Dispatch.runRead(json: opts.json) { store in
            let target = try resolveRequiredListTarget(store: store, name: list, listId: listId)
            let currentUserCkid = store.listSharedOwnerCkid(listPk: target.id)
            let rows = store.sharees(listPk: target.id)
            let shareeObjs = rows.map { shareeToDict($0, currentUserCkid: currentUserCkid) }

            if opts.json {
                // payload["list"] is the full list_ref_payload (id/title/objectUUID/
                // requested/method/isGroceries), like every other list-ref JSON.
                let requested = listId != nil ? String(listId!) : (list ?? "")
                let method = store.resolveListRefWithMethod(name: list, listId: listId).method
                let listRef: JSONValue
                if let fullRow = store.listRowByPkFull(target.id) {
                    listRef = .object(listRefPayload(fullRow, requested: requested, method: method))
                } else {
                    listRef = .object([
                        ("id", .int(target.id)), ("title", .string(target.title)),
                        ("objectUUID", target.objectUUID.map(JSONValue.string) ?? .null),
                        ("requested", .string(requested)), ("method", .string(method)),
                        ("isGroceries", .bool(false)),
                    ])
                }
                let payload: JSONValue = .object([
                    ("list", listRef),
                    ("currentUserSharee", currentUserCkid.map(JSONValue.string) ?? .null),
                    ("sharees", .array(shareeObjs.map { .object($0) })),
                ])
                Dispatch.printJSON(payload, ensureAscii: false)
                return
            }

            let ansi = opts.ansi()
            print(ansi.bold("Sharees for \(safeDisplay(target.title)):"))
            if rows.isEmpty {
                print("  No sharees")
                return
            }
            for obj in shareeObjs {
                func str(_ key: String) -> String? {
                    for (k, v) in obj where k == key { if case let .string(s) = v { return s } }
                    return nil
                }
                func intval(_ key: String) -> Int? {
                    for (k, v) in obj where k == key { if case let .int(i) = v { return i } }
                    return nil
                }
                let isMe = obj.contains { $0.0 == "currentUser" && $0.1 == .bool(true) }
                let current = isMe ? ansi.dim(" (me)") : ""
                let address = str("address").map { " \(ansi.dim($0))" } ?? ""
                let idText = ansi.dim("(id: \(intval("id").map(String.init) ?? "?"))")
                print("  - \(safeDisplay(str("name") ?? ""))\(current)\(address) \(idText)")
            }
            let n = rows.count
            print("\n\(n) sharee\(n == 1 ? "" : "s")")
        }
    }
}

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stats", abstract: "Show reminder statistics.")
    @OptionGroup var opts: JSONOnlyOptions

    func run() throws {
        Dispatch.runRead(json: opts.json) { store in
            let ansi = opts.ansi()
            let counts = store.reminderStats()
            let total = counts.total
            let active = counts.active
            let flagged = counts.flagged
            let urgent = counts.urgent
            let overdue = counts.overdue
            let lists = store.statListCount()
            let sections = store.liveSectionCount()
            if opts.json {
                let pairs: [(String, JSONValue)] = [
                    ("total", .int(total)),
                    ("active", .int(active)),
                    ("completed", .int(total - active)),
                    ("overdue", .int(overdue)),
                    ("flagged", .int(flagged)),
                    ("urgent", .int(urgent)),
                    ("lists", .int(lists)),
                    ("sections", .int(sections)),
                ]
                Dispatch.printJSON(.object(pairs), ensureAscii: true)
                return
            }
            print(ansi.bold("Reminders Stats"))
            print("  Total:      \(total)")
            print("  Active:     \(ansi.green(String(active)))")
            print("  Completed:  \(ansi.dim(String(total - active)))")
            print("  Overdue:    \(overdue != 0 ? ansi.red(String(overdue)) : "0")")
            print("  Flagged:    \(flagged != 0 ? ansi.yellow(String(flagged)) : "0")")
            print("  Urgent:     \(urgent != 0 ? ansi.red(String(urgent)) : "0")")
            print("  Lists:      \(lists)")
            print("  Sections:   \(sections)")
        }
    }
}

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show reminders in a list.")
    @OptionGroup var opts: ReadDisplayOptions
    @Argument(help: "List name") var list: String?
    @Option(name: .long, help: "Show a list by stable numeric ID") var listId: Int?
    @Flag(name: .long, help: "Include completed reminders") var completed = false
    @Flag(name: .long, help: "Limited read-only EventKit fallback; no numeric ids or private metadata") var viaEventkit = false

    /// Extract the "section" string value from a serialized reminder, if present.
    private func sectionValue(_ obj: [(String, JSONValue)]) -> String? {
        for (k, v) in obj where k == "section" { if case let .string(s) = v { return s } }
        return nil
    }

    /// Port of `cmd_show_group`: the reminders of every child list of a group, grouped by child
    /// list and printed in each list's own manual display order.
    private func showGroup(store: RemindersStore, id: Int, title: String, objectUUID: String?) {
        let children = store.childLists(groupPk: id)
        if children.isEmpty {
            if opts.effectiveJSON {
                Dispatch.printJSON(.array([]), ensureAscii: false)
            } else {
                print("No child lists in group '\(safeDisplay(title))'")
            }
            return
        }
        var sectionsByList: [Int: [Row]] = [:]
        var membershipsByList: [Int: [String: String]] = [:]
        for pk in children.compactMap({ $0.int("Z_PK") }) {
            let secs = store.sectionsForList(pk)
            sectionsByList[pk] = secs
            membershipsByList[pk] = secs.isEmpty ? [:] : store.sectionMemberships(pk)
        }
        let items = store.reminders(listPks: children.compactMap { $0.int("Z_PK") },
                                    completed: completed, topLevel: true, manualOrder: true)
        if opts.effectiveJSON {
            printGroupJSON(store: store, id: id, title: title, objectUUID: objectUUID,
                           children: children, items: items, membershipsByList: membershipsByList)
            return
        }
        if items.isEmpty {
            print("No \(completed ? "" : "active ")reminders in group '\(safeDisplay(title))'")
            return
        }
        printGroupReminders(store: store, title: title, children: children, items: items,
                            sectionsByList: sectionsByList, membershipsByList: membershipsByList)
    }

    /// `show <group> --json`: the child list's stub replaces each reminder's plain list name, and
    /// the group it came through is appended.
    private func printGroupJSON(store: RemindersStore, id: Int, title: String, objectUUID: String?,
                                children: [Row], items: [Row],
                                membershipsByList: [Int: [String: String]])
    {
        var childById: [Int: Row] = [:]
        for child in children { if let pk = child.int("Z_PK") { childById[pk] = child } }
        // Reminder identifiers are unique across lists, so one lookup covers every child.
        let memberships = membershipsByList.values.reduce(into: [String: String]()) { $0.merge($1) { a, _ in a } }
        var groupStub: [(String, JSONValue)] = [("id", .int(id)), ("title", .string(title))]
        if let objectUUID, !objectUUID.isEmpty { groupStub.append(("objectUUID", .string(objectUUID))) }
        let payload = zip(items, serializeReminders(items, store: store, memberships: memberships))
            .map { item, obj -> JSONValue in
                guard let child = item.int("ZLIST").flatMap({ childById[$0] }) else { return .object(obj) }
                var out = obj.map { key, value in key == "list" ? (key, JSONValue.object(listGroupStub(child))) : (key, value) }
                out.append(("group", .object(groupStub)))
                return .object(out)
            }
        Dispatch.printJSON(.array(payload), ensureAscii: false)
    }

    /// The human and table renderings of a group: one heading (and, in table mode, one table) per
    /// child list and per section within it.
    private func printGroupReminders(store: RemindersStore, title: String, children: [Row], items: [Row],
                                     sectionsByList: [Int: [Row]], membershipsByList: [Int: [String: String]])
    {
        let ansi = opts.ansi()
        let pks = items.compactMap { $0.int("Z_PK") }
        let (sc, ht) = store.preloadExtras(pks)
        let badges: [Int: ReminderBadges] = opts.useTable ? [:] : store.preloadIndicators(pks)
        func render(_ rows: [Row]) {
            if rows.isEmpty { return }
            if opts.useTable {
                print(fmtTable(remindersToTableData(rows, ansi: ansi), ansi: ansi,
                               dateColumn: completed ? .completed : .due, includeList: false))
                return
            }
            for r in rows {
                let p = r.int("Z_PK") ?? 0
                print(fmt(r, tags: ht[p] ?? [], subtaskCount: sc[p] ?? 0, ansi: ansi, verbose: opts.verbose,
                          indent: "    ", assigneeName: store.assignmentAssignee(pk: p), badges: badges[p] ?? ReminderBadges()))
            }
        }
        print("\(ansi.bold(colorListName(title, ansi: ansi))) \(ansi.dim("(group)")):")
        for child in children {
            guard let pk = child.int("Z_PK") else { continue }
            let childItems = items.filter { $0.int("ZLIST") == pk }
            if childItems.isEmpty { continue }
            let isGroceries = isGroceryListRow(child)
            var heading = colorListName(child.string("ZNAME"), ansi: ansi)
            if isGroceries { heading += " \(Constants.groceryListMarker)" }
            print("\n  \(ansi.bold(heading)):")
            let secs = sectionsByList[pk] ?? []
            guard !secs.isEmpty else {
                render(childItems)
                continue
            }
            let memberships = membershipsByList[pk] ?? [:]
            var sectionItems: [String: [Row]] = [:]
            var unsectioned: [Row] = []
            for item in childItems {
                if let name = item.string("ZCKIDENTIFIER").flatMap({ memberships[$0] }) {
                    sectionItems[name, default: []].append(item)
                } else {
                    unsectioned.append(item)
                }
            }
            render(unsectioned)
            for name in secs.map({ $0.string("ZDISPLAYNAME") ?? "" }) {
                guard let sectioned = sectionItems[name] else { continue }
                print("\n    \(ansi.bold("[\(safeDisplay(formatGrocerySectionName(name, isGroceries: isGroceries)))]"))")
                render(sectioned)
            }
        }
        let n = items.count
        print("\n\(n) reminder\(n == 1 ? "" : "s")")
    }

    func run() async throws {
        if viaEventkit {
            await EventKitReadCLI.run(
                mode: "show", listId: listId, listName: list, requiresListName: true,
                completed: completed, opts: opts,
                heading: "\(safeDisplay(list?.isEmpty == false ? list! : "Reminders")) (EventKit limited)",
                emptyMessage: "No \(completed ? "" : "active ")reminders found via EventKit")
            return
        }
        Dispatch.runRead(json: opts.effectiveJSON) { store in
            // A group holds lists, not reminders, so `show` reads through to its child lists.
            let target = try resolveRequiredListTarget(store: store, name: list, listId: listId, allowGroups: true)
            if target.isGroup {
                showGroup(store: store, id: target.id, title: target.title, objectUUID: target.objectUUID)
                return
            }
            let pk = target.id
            let isGroceries = store.listIsGroceries(pk)
            let items = store.reminders(listPk: pk, completed: completed, topLevel: true, manualOrder: true)
            let secs = store.sectionsForList(pk)
            let memberships = secs.isEmpty ? [:] : store.sectionMemberships(pk)
            let ansi = opts.ansi()

            if opts.effectiveJSON {
                var objs = serializeReminders(items, store: store, memberships: memberships)
                if isGroceries {
                    objs = objs.map { obj in
                        if let section = sectionValue(obj), let emoji = groceryCategoryEmoji(section) {
                            return obj + [("sectionEmoji", .string(emoji))]
                        }
                        return obj
                    }
                }
                Dispatch.printJSON(.array(objs.map { .object($0) }), ensureAscii: false)
                return
            }
            if items.isEmpty {
                print("No \(completed ? "" : "active ")reminders in '\(safeDisplay(target.title))'")
                return
            }
            if opts.useTable {
                print(fmtTable(remindersToTableData(items, ansi: ansi), ansi: ansi,
                               dateColumn: completed ? .completed : .due))
                return
            }
            let pks = items.compactMap { $0.int("Z_PK") }
            let (sc, ht) = store.preloadExtras(pks)
            let badges = store.preloadIndicators(pks)
            func line(_ r: Row, indent: String) -> String {
                let p = r.int("Z_PK") ?? 0
                return fmt(r, tags: ht[p] ?? [], subtaskCount: sc[p] ?? 0, ansi: ansi, verbose: opts.verbose, indent: indent, assigneeName: store.assignmentAssignee(pk: p), badges: badges[p] ?? ReminderBadges())
            }
            var heading = colorListName(target.title, ansi: ansi)
            if isGroceries { heading += " \(Constants.groceryListMarker)" }
            print("\(ansi.bold(heading)):")
            if !secs.isEmpty {
                var secItems: [String: [Row]] = [:]
                var unsectioned: [Row] = []
                for item in items {
                    if let sn = item.string("ZCKIDENTIFIER").flatMap({ memberships[$0] }) {
                        secItems[sn, default: []].append(item)
                    } else {
                        unsectioned.append(item)
                    }
                }
                for item in unsectioned { print(line(item, indent: "")) }
                for sn in secs.map({ $0.string("ZDISPLAYNAME") ?? "" }) {
                    guard let group = secItems[sn] else { continue }
                    let h = safeDisplay(formatGrocerySectionName(sn, isGroceries: isGroceries))
                    print("\n  \(ansi.bold("[\(h)]"))")
                    for item in group { print(line(item, indent: "  ")) }
                }
            } else {
                for item in items { print(line(item, indent: "")) }
            }
            let n = items.count
            print("\n\(n) reminder\(n == 1 ? "" : "s")")
        }
    }
}

/// Human date format for `info`: "%b %d, %Y at %I:%M %p" -> e.g. "May 23, 2026 at 10:00 AM".
/// `dateOnly` drops the time component for all-day reminders -> "May 23, 2026".
private func infoDateString(_ appleSeconds: Double, dateOnly: Bool = false) -> String {
    let date = Date(timeIntervalSince1970: appleSeconds + AppleEpoch.offset)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = dateOnly ? "MMM dd, yyyy" : "MMM dd, yyyy 'at' hh:mm a"
    return f.string(from: date)
}

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show detailed reminder info.")
    @Argument(help: "Reminder ID") var id: Int
    @Flag(name: .long, help: "Also look in Recently Deleted; deleted details omit unavailable private metadata")
    var includeDeleted = false
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false
    @Flag(name: .long, help: "Disable ANSI color") var noColor = false

    func run() async throws {
        if includeDeleted, let outcome = await Self.includeDeletedOutcome(id: id, json: json) {
            WriteDispatch.emit(outcome)
        }
        Dispatch.runRead(json: json) { store in
            guard let r = store.reminder(pk: id) else {
                throw CLIError("#\(id) not found", code: "not_found", context: [("id", .int(id))])
            }
            let subs = store.reminders(completed: true, parentPk: id)
            let tags = store.hashtags(pk: id)
            let richURL = store.richLink(pk: id)
            var sec: String? = nil
            if let listPk = r.int("ZLIST"), listPk != 0 {
                sec = r.string("ZCKIDENTIFIER").flatMap { store.sectionMemberships(listPk)[$0] }
            }

            if json {
                let attachments = attachmentJSONByReminder(store.preloadAttachments([id]),
                                                           resolve: store.resolveAttachmentPath)
                var d = serializeReminder(r, ts: { AppleEpoch.ts($0) }, priorityNames: Constants.priorityName,
                                          section: sec, subtaskCounts: [id: store.subtaskCount(pk: id)],
                                          hashtags: [id: tags], attachments: attachments,
                                          richLink: { store.richLink(pk: id) },
                                          hasAbsoluteAlarm: { store.hasAbsoluteAlarm(pk: id) },
                                          earlyFallback: store.earlyReminderAlerts)
                if let assignment = assignmentToDict(store.assignment(reminderPk: id)) {
                    d.append(("assignment", assignment))
                }
                let alarms = alarmRowsToJSON(store.alarms(pk: id))
                if !alarms.isEmpty { d.append(("alarms", .array(alarms))) }
                if !subs.isEmpty {
                    // serializeReminders already carries each subtask's attachments.
                    var subObjs = serializeReminders(subs, store: store)
                    for i in subObjs.indices {
                        let spk = subs[i].int("Z_PK") ?? 0
                        let sal = alarmRowsToJSON(store.alarms(pk: spk))
                        if !sal.isEmpty { subObjs[i].append(("alarms", .array(sal))) }
                    }
                    d.append(("subtasks", .array(subObjs.map { .object($0) })))
                }
                Dispatch.printJSON(.object(d), ensureAscii: true)
                return
            }

            let ansi = Ansi.resolve(noColorFlag: noColor)
            let listName = r.string("list_name")
            print("\(ansi.bold("Reminder")) \(colorByList("#\(id)", listName: listName, ansi: ansi))")
            print("  Title:     \(safeDisplay(r.string("ZTITLE")))")
            print("  List:      \(colorListName(listName, ansi: ansi))")
            if let sec, !sec.isEmpty { print("  Section:   \(ansi.bold(safeDisplay(sec)))") }
            let completed = (r.int("ZCOMPLETED") ?? 0) != 0
            print("  Status:    \(completed ? ansi.green("Completed") : ansi.yellow("Active"))")
            let pri = r.int("ZPRIORITY") ?? 0
            var priDisplay = Constants.priorityName[pri] ?? "none"
            if pri == 1 { priDisplay = ansi.red(priDisplay) }
            else if pri == 5 { priDisplay = ansi.yellow(priDisplay) }
            else if pri == 9 { priDisplay = ansi.green(priDisplay) }
            print("  Priority:  \(priDisplay)")
            print("  Flagged:   \((r.int("ZFLAGGED") ?? 0) != 0 ? ansi.yellow("Yes") : "No")")
            print("  Urgent:    \((r.int("ZISURGENTSTATEENABLEDFORCURRENTUSER") ?? 0) != 0 ? ansi.red("Yes") : "No")")
            if let assignment = assignmentToDict(store.assignment(reminderPk: id)) {
                let assignee = assignmentPersonLabel(assignment, key: "assignee")
                let originator = assignmentPersonLabel(assignment, key: "originator")
                print("  Assigned:  \(ansi.cyan(safeDisplay(assignee ?? "Unknown")))")
                if let originator { print("  By:        \(safeDisplay(originator))") }
            }
            if let due = r.double("ZDUEDATE"), due != 0 {
                let effective = rowEffectiveDue(r, hasAbsoluteAlarm: { store.hasAbsoluteAlarm(pk: id) }) ?? due
                if itemIsAllDay(r) {
                    print("  Due:       \(infoDateString(effective, dateOnly: true)) (all-day)")
                } else {
                    print("  Due:       \(infoDateString(effective))")
                    // Reminders lists a timed reminder at its absolute alarm when that sits
                    // at another time than the due date (upstream f9b6411).
                    if let shown = rowShownDate(r), Int(shown) != Int(effective) {
                        print("  Shown at:  \(infoDateString(shown)) \(ansi.dim("(Reminders lists it here)"))")
                    }
                }
            }
            var early = dueDateDeltaAlertsFromRow(r, ts: { AppleEpoch.ts($0) })
            if early.isEmpty, let ck = r.string("ZCKIDENTIFIER"), !ck.isEmpty {
                early = store.earlyReminderAlerts(ck)
            }
            if !early.isEmpty {
                let labels = early.compactMap { pairs -> String? in
                    for (k, v) in pairs where k == "label" { if case let .string(s) = v { return s } }; return nil
                }.joined(separator: ", ")
                print("  Early:     \(ansi.cyan(labels))")
            }
            if let rec = recurrenceFromRow(r, ts: { AppleEpoch.ts($0) }) {
                let summary = recurrenceSummary(rec)
                if !summary.isEmpty { print("  Repeats:   \(ansi.magenta(summary))") }
            }
            if let c = r.double("ZCREATIONDATE"), c != 0 { print("  Created:   \(infoDateString(c))") }
            if let cd = r.double("ZCOMPLETIONDATE"), cd != 0 { print("  Completed: \(infoDateString(cd))") }
            if let notes = r.string("ZNOTES"), !notes.isEmpty { print("  Notes:     \(safeDisplay(notes))") }
            let url = r.string("ZICSURL").flatMap { $0.isEmpty ? nil : $0 } ?? richURL
            if let url, !url.isEmpty { print("  URL:       \(safeDisplay(url))") }
            if !tags.isEmpty {
                let tagStr = tags.map { ansi.magenta("#" + safeDisplay($0)) }.joined(separator: ", ")
                print("  Tags:      \(tagStr)")
            }
            if let pp = r.int("ZPARENTREMINDER"), pp != 0 {
                let p = store.reminder(pk: pp)
                let suffix = p.map { " (\(safeDisplay($0.string("ZTITLE"))))" } ?? ""
                print("  Parent:    #\(pp)\(suffix)")
            }
            if !subs.isEmpty {
                print("  Subtasks (\(subs.count)):")
                let subPks = subs.compactMap { $0.int("Z_PK") }
                let (sc, ht) = store.preloadExtras(subPks)
                let badges = store.preloadIndicators(subPks)
                for s in subs {
                    let spk = s.int("Z_PK") ?? 0
                    print(fmt(s, tags: ht[spk] ?? [], subtaskCount: sc[spk] ?? 0, ansi: ansi, indent: "    ", assigneeName: store.assignmentAssignee(pk: spk), badges: badges[spk] ?? ReminderBadges()))
                }
            }
            let atts = store.attachments(pk: id)
            if !atts.isEmpty {
                print("  Attachments (\(atts.count)):")
                for a in atts {
                    let fn = a.filename.flatMap { $0.isEmpty ? nil : $0 } ?? "untitled"
                    let ty = a.type.flatMap { $0.isEmpty ? nil : $0 } ?? "?"
                    print("    - \(safeDisplay(fn)) (\(safeDisplay(ty)))")
                }
            }
            let alarms = alarmRowsToJSON(store.alarms(pk: id))
            if !alarms.isEmpty {
                print("  Alarms (\(alarms.count)):")
                for alarm in alarms { print("    - \(safeDisplay(alarmHumanLabel(alarm)))") }
            }
            if let ck = r.string("ZCKIDENTIFIER"), !ck.isEmpty {
                print("  Deep link: \(ansi.dim(Constants.deepLinkReminderPrefix + ck))")
            }
        }
    }

    /// Opens the store and the private boundary for the Recently Deleted branch. A store that
    /// cannot be opened yields nil: the regular read below reports that failure itself.
    private static func includeDeletedOutcome(id: Int, json: Bool) async -> WriteOutcome? {
        guard let store = try? RemindersStore.open() else { return nil }
        return await deletedDetails(id: id, json: json, store: store, private: PrivateWriterFactory.make())
    }

    /// Port of `cmd_info`'s Recently Deleted branch (upstream a413c19): an id with no live
    /// reminder may still be recoverable. Returns what to emit — the deleted details, or the
    /// structured recovery failure — and nil when the id is live or absent from the recovery
    /// view, so `info` carries on with the regular read.
    static func deletedDetails(id: Int, json: Bool, store: RemindersStore,
                               private priv: PrivateWriter) async -> WriteOutcome? {
        guard store.reminder(pk: id) == nil else { return nil }
        do {
            let items = try await RecentlyDeleted.read(store: store, private: priv)
            guard let item = RecentlyDeleted.find(items, id: id) else { return nil }
            if json { return .ok(JSONValue.object(item.payload).serialized(indent: 2, ensureAscii: true) + "\n") }
            return .ok("Recently deleted: #\(id) \(safeDisplay(item.title))\n"
                       + "Restore with: \(CLIName.current) restore \(item.restoreId) --list LIST\n")
        } catch let failure as CommandFailure {
            return failure.outcome(json: json)
        } catch {
            return CommandFailure("command_failed", "\(error)").outcome(json: json)
        }
    }
}
