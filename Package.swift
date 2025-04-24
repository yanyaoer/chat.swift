// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "chat.swift",
  platforms: [.macOS(.v14)],
  // dependencies: [
  // .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.1")
  // ],
  targets: [
    .executableTarget(
      name: "chat.swift",
      path: "Sources/ChatApp"
    )
  ]
)
