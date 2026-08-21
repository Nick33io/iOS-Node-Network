// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "33write",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "WriteCore", targets: ["WriteCore"]),
    .library(name: "WriteCloud", targets: ["WriteCloud"]),
    .library(name: "WriteLAN", targets: ["WriteLAN"]),
    .library(name: "WriteMesh", targets: ["WriteMesh"]),
    .library(name: "NodeKit", targets: ["NodeKit"]),
    .executable(name: "write-smoke", targets: ["WriteSmoke"]),
    .executable(name: "write-dev", targets: ["WriteDev"]),
    .executable(name: "NodeAgent", targets: ["NodeAgent"]),
  ],
  targets: [
    // Pure Swift. No network, no MLX, no Foundation-heavy deps.
    // Everything privacy-critical lives here so it can be tested on the host.
    .target(name: "WriteCore"),
    // Cloud planner. The only target permitted to open a socket.
    .target(name: "WriteCloud", dependencies: ["WriteCore"]),
    // Local-network model backends. Backs the dev runner on the Mac and the
    // app's simulator path, where MLX cannot run.
    .target(name: "WriteLAN", dependencies: ["WriteCore", "WriteCloud"]),
    // Runs the load-bearing invariants without XCTest, which ships only with
    // Xcode. Keeps the core verifiable on a Command Line Tools toolchain.
    .executableTarget(name: "WriteSmoke", dependencies: ["WriteCore"]),
    // Live end-to-end run on the Mac: real cloud planner, Ollama standing in
    // for the device writer under the same limits. Never ships.
    .executableTarget(name: "WriteDev", dependencies: ["WriteCore", "WriteCloud", "WriteLAN"]),
    // Portable multi-device coordination: task graph, versioned claim/lease
    // protocol, coordinator and worker actors. Transport is abstracted; the
    // MultipeerConnectivity adapter is Apple-only and lives outside this
    // portable core.
    .target(name: "WriteMesh", dependencies: ["WriteCore"]),
    // Everything it takes to *be* a node: the listener, the request boundary,
    // the bridge-fleet profile, the device profile, the benchmark. Shared so a
    // Mac and a phone answer the same contract from the same code rather than
    // from two implementations that drift. Apple-only — the sources are guarded
    // on `canImport(Darwin)`, so this compiles to an empty module on Linux and
    // the portable targets stay portable.
    .target(name: "NodeKit", dependencies: ["WriteCore"]),
    // A Mac as a first-class node rather than a special-cased Ollama endpoint:
    // same port, same routes, same limits enforced at the same boundary.
    .executableTarget(
      name: "NodeAgent",
      dependencies: ["NodeKit", "WriteCore", "WriteLAN"],
      path: "MacNode"
    ),
    .testTarget(name: "WriteCoreTests", dependencies: ["WriteCore"]),
    .testTarget(name: "WriteMeshTests", dependencies: ["WriteMesh", "WriteCore"]),
    .testTarget(name: "NodeKitTests", dependencies: ["NodeKit", "WriteCore"]),
  ]
)
