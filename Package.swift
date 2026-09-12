// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Notched",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "Notched",
      path: "Sources/Notched"
    )
  ]
)
