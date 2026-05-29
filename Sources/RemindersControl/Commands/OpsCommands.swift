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
