// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClipCopy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClipCopy",
            path: "Sources/ClipCopy",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
