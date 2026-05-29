import Testing
import ArgumentParser
@testable import RemindersControl

@Test("Root command reports the package version")
func rootHasVersion() {
    #expect(RemCTL.configuration.version == remctlVersion)
    #expect(RemCTL.configuration.commandName == "remctl")
}
