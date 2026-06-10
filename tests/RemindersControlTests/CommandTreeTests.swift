import Testing
import ArgumentParser
@testable import RemindersControl

@Test("Root command reports the package version")
func rootHasVersion() {
    #expect(RemindersControl.configuration.version == remctlVersion)
    #expect(RemindersControl.configuration.commandName == "remctl")
}

@Test("Read commands are registered")
func readCommandsRegistered() {
    let names = Set(RemindersControl.configuration.subcommands.compactMap { $0.configuration.commandName })
    for expected in ["today", "upcoming", "overdue", "search", "flagged", "urgent",
                     "tags", "subtasks", "sections", "stats", "show", "info"] {
        #expect(names.contains(expected), "missing \(expected)")
    }
}

@Test("Write commands are registered")
func writeCommandsRegistered() {
    let names = Set(RemindersControl.configuration.subcommands.compactMap { $0.configuration.commandName })
    for expected in ["add", "edit", "done", "undone", "delete", "flag", "unflag", "link", "open"] {
        #expect(names.contains(expected), "missing \(expected)")
    }
}

@Test("List commands are registered")
func listCommandsRegistered() {
    let names = Set(RemindersControl.configuration.subcommands.compactMap { $0.configuration.commandName })
    for expected in ["lists", "list-create", "list-edit", "list-pin", "list-unpin",
                     "list-rename", "list-delete", "list-symbols"] {
        #expect(names.contains(expected), "missing \(expected)")
    }
}

@Test("Smart-list commands are registered")
func smartListCommandsRegistered() {
    let names = Set(RemindersControl.configuration.subcommands.compactMap { $0.configuration.commandName })
    for expected in ["smart-lists", "smart-list-create", "smart-list-edit", "smart-list-delete"] {
        #expect(names.contains(expected), "missing \(expected)")
    }
}

@Test("Template commands are registered")
func templateCommandsRegistered() {
    let names = Set(RemindersControl.configuration.subcommands.compactMap { $0.configuration.commandName })
    for expected in ["templates", "template-info", "template-create", "template-apply", "template-delete"] {
        #expect(names.contains(expected), "missing \(expected)")
    }
}

@Test("Ops commands are registered")
func opsCommandsRegistered() {
    let names = Set(RemindersControl.configuration.subcommands.compactMap { $0.configuration.commandName })
    for expected in ["export", "import", "completion", "doctor", "onboard", "permissions", "setup"] {
        #expect(names.contains(expected), "missing \(expected)")
    }
}

@Test("Exactly 46 unique subcommands are registered")
func allFortySixRegistered() {
    let names = RemindersControl.configuration.subcommands.compactMap { $0.configuration.commandName }
    #expect(names.count == 46)
    #expect(Set(names).count == 46, "duplicate command names: \(names)")
}
