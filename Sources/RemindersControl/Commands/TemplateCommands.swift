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
