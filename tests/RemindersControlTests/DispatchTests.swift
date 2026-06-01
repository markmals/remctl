import Testing
import Foundation
import ArgumentParser
@testable import RemindersControl

@Suite struct DispatchTests {
    // tiny throwaway command to exercise option parsing + resolution
    struct Probe: ParsableCommand {
        @OptionGroup var opts: ReadDisplayOptions
    }
    @Test func formatJSONForcesEffectiveJSON() throws {
        let p = try Probe.parse(["--format", "json"])
        #expect(p.opts.effectiveJSON == true)
        #expect(p.opts.useTable == false)
    }
    @Test func jsonFlagBeatsFormatTable() throws {
        let p = try Probe.parse(["--json", "--format", "table"])
        #expect(p.opts.effectiveJSON == true)
        #expect(p.opts.useTable == false)   // --json wins
    }
    @Test func formatTableWithoutJSON() throws {
        let p = try Probe.parse(["--format", "table"])
        #expect(p.opts.effectiveJSON == false)
        #expect(p.opts.useTable == true)
    }
    @Test func defaultsArePlain() throws {
        let p = try Probe.parse([])
        #expect(p.opts.effectiveJSON == false); #expect(p.opts.useTable == false)
    }
    // Black-box smoke: the built binary runs and --version works (validates CLIRunner end-to-end).
    @Test func cliVersionSmoke() throws {
        let r = try CLIRunner.run(["--version"])
        #expect(r.exit == 0)
        #expect(r.stdout.contains(remctlVersion))
    }
}
