// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pane",
    platforms: [.macOS(.v15)],
    dependencies: [
        // In-app updates from GitHub Releases ("Check for Updates…").
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Detection, scanning and blur export. No UI, so it can be tested on its own.
        .target(
            name: "PaneKit",
            path: "Sources/PaneKit"
        ),
        .executableTarget(
            name: "Pane",
            dependencies: ["PaneKit", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Pane",
            linkerSettings: [
                // Embed Info.plist in the binary so camera/mic permission prompts work
                // even when running the bare executable (e.g. from Xcode).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Resources/Info.plist",
                    // Sparkle.framework is copied into Contents/Frameworks by build-app.sh.
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        // Developer tool: make sample videos, scan and export from the command line.
        .executableTarget(
            name: "pane-tool",
            dependencies: ["PaneKit"],
            path: "Sources/PaneTool"
        ),
        .testTarget(
            name: "PaneKitTests",
            dependencies: ["PaneKit"],
            path: "Tests/PaneKitTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
