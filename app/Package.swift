// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EIApp",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "EIApp",
            path: "Sources/EIApp",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
