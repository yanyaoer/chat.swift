// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "chat.swift",
  platforms: [.macOS(.v15)],
  // dependencies: [
  // .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.1")
  // ],
  targets: [
    .executableTarget(
      name: "chat.swift",
      path: "Sources/ChatApp",
      swiftSettings: [
        // Workaround for a Swift 6.0.3 IRGen assertion while emitting
        // debug info for SwiftUI `Binding<String>` (seen on CI when
        // ChatHistory's `@AppStorage("selectedPrompt")` getter is
        // emitted). Same flag dev-asr/Package.swift already uses.
        .unsafeFlags(["-Xfrontend", "-disable-round-trip-debug-types"])
      ]
    )
  ]
)
