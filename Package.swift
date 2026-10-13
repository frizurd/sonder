// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sonder",
    platforms: [.macOS(.v14)],
    dependencies: [
        // GitHub Flavored Markdown reference parser, used for Preview and export.
        .package(url: "https://github.com/swiftlang/swift-cmark", .upToNextMinor(from: "0.9.0")),
        // Updates: checks the release feed, then downloads, verifies and installs new versions.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Sonder",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Sonder",
            linkerSettings: [
                // SwiftPM records the deployment target as the SDK version, which makes macOS run the app
                // in its compatibility look. Declaring the macOS 26 SDK opts into Liquid Glass while
                // still running on macOS 14.
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.0"]),
                // Sparkle.framework is copied into the app's Frameworks folder by scripts/build-app.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "SonderTests",
            dependencies: ["Sonder"],
            path: "Tests/SonderTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
