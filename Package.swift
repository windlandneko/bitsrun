// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Bitsrun",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "bitsrun", targets: ["Bitsrun"])],
  targets: [
    .executableTarget(name: "Bitsrun", path: "Sources"),
    .testTarget(
      name: "BitsrunTests",
      dependencies: ["Bitsrun"],
      path: "tests",
      resources: [.copy("authentication.json")]
    ),
  ]
)
