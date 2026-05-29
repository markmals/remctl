import ArgumentParser

let writeCommands: [ParsableCommand.Type] = [
    Add.self, Edit.self, Done.self, Undone.self, Delete.self,
    FlagCmd.self, Unflag.self, Link.self, Open.self,
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

struct FlagCmd: ParsableCommand {
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
