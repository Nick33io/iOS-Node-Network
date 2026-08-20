// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "33write",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "WriteCore", targets: ["WriteCore"]),
    .library(name: "WriteCloud", targets: ["WriteCloud"]),
    .library(name: "WriteMesh", targets: ["WriteMesh"]),
    .executable(name: "write-smoke", targets: ["WriteSmoke"]),
    .executable(name: "write-dev", targets: ["WriteDev"]),
  ],
  targets: [
    // Pure Swift. No network, no MLX, no Foundation-heavy deps.
    // Everything privacy-critical lives here so it can be tested on the host.
    .target(name: "WriteCore"),
    // Cloud planner. The only target permitted to open a socket.
    .target(name: "WriteCloud", dependencies: ["WriteCore"]),
    // Runs the load-bearing invariants without XCTest, which ships only with
    // Xcode. Keeps the core verifiable on a Command Line Tools toolchain.
    .executableTarget(name: "WriteSmoke", dependencies: ["WriteCore"]),
    // Live end-to-end run on the Mac: real cloud planner, Ollama standing in
    // for the device writer under the same limits. Never ships.
    .executableTarget(name: "WriteDev", dependencies: ["WriteCore", "WriteCloud"]),
    // Portable multi-device coordination: task graph, versioned claim/lease
    // protocol, coordinator and worker actors. Transport is abstracted; the
    // MultipeerConnectivity adapter is Apple-only and lives outside this
    // portable core.
    .target(name: "WriteMesh", dependencies: ["WriteCore"]),
    .testTarget(name: "WriteCoreTests", dependencies: ["WriteCore"]),
    .testTarget(name: "WriteMeshTests", dependencies: ["WriteMesh", "WriteCore"]),
  ]
)
