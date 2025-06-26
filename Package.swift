// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "chat.swift",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0") // Updated version
  ],
  targets: [
    .executableTarget(
      name: "chat.swift",
      dependencies: [
        .product(name: "MCP", package: "swift-sdk") // Updated product name
      ],
      path: "Sources/ChatApp"
    )
  ]
)
