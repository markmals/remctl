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
