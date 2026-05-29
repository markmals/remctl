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
                .unsafeFlags([
                    "-F", "/System/Library/PrivateFrameworks",
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
            ]
        ),
        // Thin executable: @main wrapper over the library root command.
        .executableTarget(
            name: "remctl",
            dependencies: ["RemindersControl"]
        ),
        .testTarget(
            name: "RemindersControlTests",
            dependencies: ["RemindersControl"]
        ),
    ]
)
