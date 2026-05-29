import ArgumentParser
import Foundation
import GRDB
import Foundation

let readCommands: [ParsableCommand.Type] = [
    Today.self, Upcoming.self, Overdue.self, Search.self, Flagged.self, Urgent.self,
    Tags.self, Subtasks.self, Sections.self, Stats.self, Show.self, Info.self,
]

struct Today: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "today", abstract: "List reminders due today.")
    @OptionGroup var opts: ReadDisplayOptions
    @Flag(name: .long, help: "Exclude overdue items") var noOverdue = false

    func run() throws {
        Dispatch.runRead { store in
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
            let sodTs = AppleEpoch.toTs(DateWindows.startOfDay(now))
            let overdue = rows.filter { ($0.double("ZDUEDATE") ?? 0) < sodTs }
            let overduePKs = Set(overdue.compactMap { $0.int("Z_PK") })
            let due = rows.filter { !overduePKs.contains($0.int("Z_PK") ?? -1) }

            if !overdue.isEmpty {
                print(ansi.red("Overdue (\(overdue.count)):"))
                for r in overdue {
                    let pk = r.int("Z_PK") ?? 0
                    print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, indent: "  "))
                }
                print("")
            }
            if !due.isEmpty {
                print(ansi.bold("Due Today (\(due.count)):"))
                for r in due {
                    let pk = r.int("Z_PK") ?? 0
                    print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, indent: "  "))
                }
            }
            print("\n\(rows.count) total")
        }
    }
}

struct Upcoming: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upcoming", abstract: "List upcoming reminders.")
    @OptionGroup var opts: ReadDisplayOptions
    @Argument(help: "Number of days to look ahead") var days: Int = 7

    func run() throws {
        guard (1...3650).contains(days) else {
            FileHandle.standardError.write(Data("Error: upcoming days must be between 1 and 3650.\n".utf8))
            throw ExitCode(1)
        }
        Dispatch.runRead { store in
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

            let cal = Calendar.current
            let today = cal.startOfDay(for: now)
            let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

            // Group by local day string
            var keyOrder: [String] = []
            var groupMap: [String: (label: String, items: [ReminderRow])] = [:]

            for r in rows {
                guard let dueVal = r.double("ZDUEDATE"), dueVal != 0 else { continue }
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
                    print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, indent: "    "))
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
        Dispatch.runRead { store in
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
            for r in rows {
                let pk = r.int("Z_PK") ?? 0
                print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, verbose: opts.verbose, indent: "  "))
            }
            print("\n\(rows.count) overdue")
        }
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Search reminders by text.")
    @OptionGroup var opts: ReadDisplayOptions
    @Argument(help: "Search query") var query: String
    @Flag(name: .long, help: "Include completed reminders") var completed = false

    func run() throws {
        Dispatch.runRead { store in
            let now = Date()
            let rows = store.search(query, completed: completed)
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
                print("No reminders matching '\(safeDisplay(query))'")
                return
            }
            print("Search: \(ansi.bold(safeDisplay(query)))")
            for r in rows {
                let pk = r.int("Z_PK") ?? 0
                print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, verbose: opts.verbose))
            }
            let n = rows.count
            print("\n\(n) result\(n == 1 ? "" : "s")")
        }
    }
}

struct Flagged: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "flagged", abstract: "List flagged reminders.")
    @OptionGroup var opts: ReadDisplayOptions

    func run() throws {
        Dispatch.runRead { store in
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
            for r in rows {
                let pk = r.int("Z_PK") ?? 0
                print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, verbose: opts.verbose, indent: "  "))
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
        Dispatch.runRead { store in
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
            for r in rows {
                let pk = r.int("Z_PK") ?? 0
                print(fmt(r, tags: tags[pk] ?? [], subtaskCount: counts[pk] ?? 0, ansi: ansi, now: now, verbose: opts.verbose, indent: "  "))
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
        Dispatch.runRead { store in
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
        Dispatch.runRead { store in
            guard let parent = store.reminder(pk: id) else {
                FileHandle.standardError.write(Data("Error: #\(id) not found\n".utf8))
                Foundation.exit(1)
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
                    richLink: { store.richLink(pk: id) }
                )
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
                for s in subs {
                    let pk = s.int("Z_PK") ?? 0
                    print(fmt(s, tags: ht[pk] ?? [], subtaskCount: sc[pk] ?? 0, ansi: ansi, indent: "  "))
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
        Dispatch.runRead { store in
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

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stats", abstract: "Show reminder statistics.")
    @OptionGroup var opts: JSONOnlyOptions

    func run() throws {
        Dispatch.runRead { store in
            let ansi = opts.ansi()
            let now = Date()
            let total = store.statTotal()
            let active = store.statActive()
            let flagged = store.statFlagged()
            let urgent = store.statUrgent()
            let overdue = store.statOverdue(now: now)
            let lists = store.statListCount()
            let sections = store.statSectionCount()

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

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show reminders in a list.")
    @OptionGroup var opts: ReadDisplayOptions
    @Argument(help: "List name") var list: String?
    @Option(name: .long, help: "Show a list by stable numeric ID") var listId: Int?
    @Flag(name: .long, help: "Include completed reminders") var completed = false

    /// Extract the "section" string value from a serialized reminder, if present.
    private func sectionValue(_ obj: [(String, JSONValue)]) -> String? {
        for (k, v) in obj where k == "section" { if case let .string(s) = v { return s } }
        return nil
    }

    func run() throws {
        Dispatch.runRead { store in
            let target = try resolveRequiredListTarget(store: store, name: list, listId: listId)
            let pk = target.id
            let isGroceries = store.listIsGroceries(pk)
            let items = store.reminders(listPk: pk, completed: completed, topLevel: true)
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
            if opts.useTable {
                print(fmtTable(remindersToTableData(items, ansi: ansi), ansi: ansi))
                return
            }
            if items.isEmpty {
                print("No \(completed ? "" : "active ")reminders in '\(safeDisplay(target.title))'")
                return
            }
            let (sc, ht) = store.preloadExtras(items.compactMap { $0.int("Z_PK") })
            func line(_ r: Row, indent: String) -> String {
                let p = r.int("Z_PK") ?? 0
                return fmt(r, tags: ht[p] ?? [], subtaskCount: sc[p] ?? 0, ansi: ansi, verbose: opts.verbose, indent: indent)
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
private func infoDateString(_ appleSeconds: Double) -> String {
    let date = Date(timeIntervalSince1970: appleSeconds + AppleEpoch.offset)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MMM dd, yyyy 'at' hh:mm a"
    return f.string(from: date)
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show detailed reminder info.")
    @Argument(help: "Reminder ID") var id: Int
    @Flag(name: .long, help: "Output machine-readable JSON") var json = false
    @Flag(name: .long, help: "Disable ANSI color") var noColor = false

    func run() throws {
        Dispatch.runRead { store in
            guard let r = store.reminder(pk: id) else {
                FileHandle.standardError.write(Data("Error: #\(id) not found\n".utf8))
                Foundation.exit(1)
            }
            let subs = store.reminders(completed: true, parentPk: id)
            let tags = store.hashtags(pk: id)
            let richURL = store.richLink(pk: id)
            var sec: String? = nil
            if let listPk = r.int("ZLIST"), listPk != 0 {
                sec = r.string("ZCKIDENTIFIER").flatMap { store.sectionMemberships(listPk)[$0] }
            }

            if json {
                var d = serializeReminder(r, ts: { AppleEpoch.ts($0) }, priorityNames: Constants.priorityName,
                                          section: sec, subtaskCounts: [id: store.subtaskCount(pk: id)],
                                          hashtags: [id: tags], richLink: { store.richLink(pk: id) })
                let atts = attachmentRowsToJSON(store.attachments(pk: id))
                if !atts.isEmpty { d.append(("attachments", .array(atts))) }
                let alarms = alarmRowsToJSON(store.alarms(pk: id))
                if !alarms.isEmpty { d.append(("alarms", .array(alarms))) }
                if !subs.isEmpty {
                    var subObjs = serializeReminders(subs, store: store)
                    for i in subObjs.indices {
                        let spk = subs[i].int("Z_PK") ?? 0
                        let sa = attachmentRowsToJSON(store.attachments(pk: spk))
                        if !sa.isEmpty { subObjs[i].append(("attachments", .array(sa))) }
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
            if let due = r.double("ZDUEDATE"), due != 0 { print("  Due:       \(infoDateString(due))") }
            let early = dueDateDeltaAlertsFromRow(r, ts: { AppleEpoch.ts($0) })
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
                let (sc, ht) = store.preloadExtras(subs.compactMap { $0.int("Z_PK") })
                for s in subs {
                    let spk = s.int("Z_PK") ?? 0
                    print(fmt(s, tags: ht[spk] ?? [], subtaskCount: sc[spk] ?? 0, ansi: ansi, indent: "    "))
                }
            }
            let atts = store.attachments(pk: id)
            if !atts.isEmpty {
                print("  Attachments (\(atts.count)):")
                for a in atts {
                    let fn = a.string("ZFILENAME").flatMap { $0.isEmpty ? nil : $0 } ?? "untitled"
                    let ty = a.string("ZATTACHMENTTYPERAWVALUE").flatMap { $0.isEmpty ? nil : $0 } ?? "?"
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
}
