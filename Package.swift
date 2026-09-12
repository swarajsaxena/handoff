// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Handoff",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "Handoff",
      path: "Sources/Handoff"
    )
  ]
)
