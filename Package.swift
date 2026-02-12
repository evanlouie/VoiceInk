// swift-tools-version: 5.10
// This Package.swift exists solely for SourceKit-LSP editor support in VS Code.
// The actual build is done via the Xcode project. Do NOT use `swift build`.

import PackageDescription

let package = Package(
    name: "VoiceInk",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VoiceInk", targets: ["VoiceInk"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.2.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", branch: "main"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
        .package(url: "https://github.com/ejbills/mediaremote-adapter", branch: "master"),
        .package(url: "https://github.com/marmelroy/Zip", from: "2.1.2"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", branch: "main"),
        .package(url: "https://github.com/tisfeng/SelectedTextKit", from: "2.6.2"),
    ],
    targets: [
        .target(
            name: "VoiceInk",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                "Sparkle",
                .product(name: "MediaRemoteAdapter", package: "mediaremote-adapter"),
                "Zip",
                .product(name: "Atomics", package: "swift-atomics"),
                "FluidAudio",
                "SelectedTextKit",
                "whisper",
            ],
            path: "VoiceInk",
            exclude: [
                "Info.plist",
                "VoiceInk.entitlements",
                "VoiceInk.local.entitlements",
                "Assets.xcassets",
                "Preview Content",
                "Resources/models",
                "Resources/arcURL.scpt",
                "Resources/braveURL.scpt",
                "Resources/chromeURL.scpt",
                "Resources/edgeURL.scpt",
                "Resources/firefoxURL.scpt",
                "Resources/operaURL.scpt",
                "Resources/orionURL.scpt",
                "Resources/safariURL.scpt",
                "Resources/vivaldiURL.scpt",
                "Resources/yandexURL.scpt",
                "Resources/zenURL.scpt",
            ],
            swiftSettings: [
                .unsafeFlags(["-swift-version", "5"])
            ]
        ),
        .binaryTarget(
            name: "whisper",
            path: "whisper.xcframework"
        ),
    ]
)
