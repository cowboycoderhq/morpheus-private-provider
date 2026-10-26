// swift-tools-version:5.9
// Sealed engine v2 for the Splash child (P9/P10 prototype).
//
// The engine is the only process that sees a consumer's prompt in plain text
// besides the pinned, sandboxed Splash child: it attests itself with App Attest
// (CD-hash opt-in), opens the consumer's envelope, renders the chat template
// and tokenizes in-process (the tokenizer bytes are hashed and bound into every
// session), and talks to the child over the sealed socketpair. It runs no model
// and uses no Metal itself.
//
// Package pins match the v1 engine (swift-transformers 1.3.4).
import PackageDescription

let package = Package(
  name: "SealedEngineV2",
  platforms: [.macOS("27.0")],   // the App Attest CD-hash extension needs a macOS 27 deployment target (measured 2026-10-20)
  dependencies: [
    .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
  ],
  targets: [
    // Staged spawn module (S-5 gate + A-13 canary) and the R1 guard, in C.
    .target(
      name: "SealedSpawnC",
      path: "Sources/SealedSpawnC",
      cSettings: [.unsafeFlags(["-std=c17", "-Wall", "-Wextra"])]
    ),
    .executableTarget(
      name: "SealedEngineV2",
      dependencies: [
        "SealedSpawnC",
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "Hub", package: "swift-transformers"),
      ],
      path: "Sources/SealedEngineV2",
      linkerSettings: [.linkedFramework("DeviceCheck"), .linkedFramework("CoreServices")]
    ),
  ]
)
