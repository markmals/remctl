// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemindersControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "remctl", targets: ["remctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.0.0")),
    ],
    targets: [
        // Obj-C target that links the private ReminderKit framework.
        .target(
            name: "ReminderKitPrivate",
            path: "Sources/ReminderKitPrivate",
            publicHeadersPath: "include",
            linkerSettings: [
                // ReminderKitPrivate.m imports AppKit (NSImage, used to validate
                // image attachments) on top of Foundation + the private
                // ReminderKit framework.
                .unsafeFlags([
                    "-F", "/System/Library/PrivateFrameworks",
                    "-framework", "Foundation",
                    "-framework", "AppKit",
                    "-framework", "ReminderKit",
                ]),
            ]
        ),
        // Library holding all the CLI commands (unit-testable).
        .target(
            name: "RemindersControl",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
                "ReminderKitPrivate",
            ],
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreLocation"),
            ]
        ),
        // Thin executable: @main wrapper over the library root command.
        .executableTarget(
            name: "remctl",
            dependencies: ["RemindersControl"]
        ),
        .testTarget(
            name: "RemindersControlTests",
            // ReminderKitPrivate is listed explicitly because PrivateLinkTests
            // imports it directly; relying on the transitive edge through
            // RemindersControl would break if that edge ever changes.
            dependencies: ["RemindersControl", "ReminderKitPrivate"],
            // Explicit lowercase path. The repo still carries the old Python
            // suite in `tests/`, so the default `Tests/` lookup is ambiguous on
            // case-insensitive macOS and would not resolve on a case-sensitive
            // filesystem (the files are git-tracked under lowercase `tests/`).
            // Pinning the real path keeps the build deterministic everywhere.
            // Phase 5 removes the Python suite and can restore the `Tests/` norm.
            path: "tests/RemindersControlTests"
        ),
    ]
)
