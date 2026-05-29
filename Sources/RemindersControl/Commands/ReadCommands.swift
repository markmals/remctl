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
