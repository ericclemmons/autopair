// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoPair",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AutoPair",
            path: "Sources/AutoPair",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ]),
            ]
        ),
    ]
)
