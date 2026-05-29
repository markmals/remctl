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
