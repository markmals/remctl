import Foundation

/// Runs the built `remctl` debug binary as a subprocess for black-box parity tests.
enum CLIRunner {
    /// Package root = four directories up from this file (.../tests/RemindersControlTests/Support/CLIRunner.swift).
    static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // RemindersControlTests
            .deletingLastPathComponent()  // tests
            .deletingLastPathComponent()  // <root>
    }
    static func binaryURL() -> URL {
        packageRoot().appendingPathComponent(".build/debug/remctl")
    }
    /// Build the remctl product once if the binary is missing (swift test does not build executables by default).
    static func ensureBuilt() throws {
        let bin = binaryURL()
        if FileManager.default.isExecutableFile(atPath: bin.path) { return }
        let p = Process()
        p.currentDirectoryURL = packageRoot()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swift", "build", "--product", "remctl"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
    }

    struct Result { let stdout: String; let stderr: String; let exit: Int32 }

    static func run(_ args: [String], storeDir: URL? = nil, extraEnv: [String: String] = [:]) throws -> Result {
        try ensureBuilt()
        let p = Process()
        p.executableURL = binaryURL()
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let storeDir { env["REMCTL_STORE_DIR"] = storeDir.path }
        env["NO_COLOR"] = "1"
        extraEnv.forEach { env[$0] = $1 }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run(); p.waitUntilExit()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(stdout: o, stderr: e, exit: p.terminationStatus)
    }
}
