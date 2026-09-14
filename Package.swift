// swift-tools-version: 5.10
// Brownie — the overnight Mac app.
//
// One package, strictly layered targets. SwiftPM enforces the dependency rule: a target can only
// import what it declares. Domain sits at the centre and depends on nothing.
//
//   BrownieApp ─► everything
//   Ingest, Proactive ─► Domain, Privacy, Knowledge (+ Brain / Inference via protocols only)
//   Sources, Inference, Brain, Agent, Scheduling, Knowledge ─► Domain, Platform, Support
//   Platform ─► Domain, Support
//   Domain ─► Support
//   Support ─► nothing

import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .enableExperimentalFeature("StrictConcurrency=complete"),
]

let package = Package(
    name: "Brownie",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Brownie", targets: ["BrownieApp"]),
        .executable(name: "browniectl", targets: ["BrownieCLI"]),
    ],
    dependencies: [
        .package(path: "Vendor/LiteRTLM"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // ── Foundation layers ────────────────────────────────────────────────────────────
        .target(name: "Support", swiftSettings: strict),
        .target(name: "Domain", dependencies: ["Support"], swiftSettings: strict),
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .systemLibrary(name: "CTDJson", path: "Sources/CTDJson"),
        .target(name: "Platform", dependencies: ["Domain", "Support", "CSQLite"], swiftSettings: strict),

        // ── Capabilities (each implements Domain protocols; none import each other) ─────
        .target(name: "Privacy", dependencies: ["Domain", "Support"], swiftSettings: strict),
        .target(name: "LocalSources", dependencies: ["Domain", "Platform", "Support"], swiftSettings: strict),
        .target(name: "CloudSources", dependencies: ["Domain", "Platform", "LocalSources", "Support"], swiftSettings: strict),
        .target(name: "TelegramSource", dependencies: ["Domain", "Platform", "LocalSources", "Support", "CTDJson"],
                swiftSettings: strict + [.unsafeFlags(["-I", "Vendor/tdlib/include"])],
                linkerSettings: [.unsafeFlags(["-L", "Vendor/tdlib/lib", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "Vendor/tdlib/lib"])]),
        .target(
            name: "Inference",
            dependencies: ["Domain", "Support", .product(name: "LiteRTLM", package: "LiteRTLM")],
            swiftSettings: strict
        ),
        .target(name: "Brain", dependencies: ["Domain", "Platform", "Support"], swiftSettings: strict),
        .target(name: "Knowledge", dependencies: ["Domain", "Platform", "Support"], resources: [.copy("Prompts")], swiftSettings: strict),
        .target(
            name: "Ingest",
            dependencies: ["Domain", "Platform", "Privacy", "Support"],
            resources: [.copy("Prompts")],
            swiftSettings: strict
        ),
        .target(name: "Proactive", dependencies: ["Domain", "Platform", "Knowledge", "Support"], resources: [.copy("Prompts")], swiftSettings: strict),
        .target(name: "Pipeline", dependencies: ["Domain", "Platform", "Ingest", "Knowledge", "Proactive", "Support"], swiftSettings: strict),
        .target(name: "Agent", dependencies: ["Domain", "Platform", "Support"], swiftSettings: strict),
        .target(name: "Scheduling", dependencies: ["Domain", "Platform", "Support"], swiftSettings: strict),

        // ── Consumers ───────────────────────────────────────────────────────────────────
        .executableTarget(
            name: "BrownieApp",
            dependencies: [
                "Domain", "Platform", "Privacy", "LocalSources", "CloudSources", "TelegramSource", "Inference", "Brain",
                "Knowledge", "Ingest", "Proactive", "Pipeline", "Agent", "Scheduling", "Support",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.copy("Resources")],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "BrownieCLI",
            dependencies: ["Domain", "Platform", "Privacy", "LocalSources", "Inference", "Brain", "Knowledge", "Ingest", "Proactive", "Pipeline", "Support"],
            swiftSettings: strict
        ),

        // ── Tests ───────────────────────────────────────────────────────────────────────
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "PrivacyTests", dependencies: ["Privacy"]),
        .testTarget(name: "IngestTests", dependencies: ["Ingest", "Domain", "Platform"]),
        .testTarget(name: "LocalSourcesTests", dependencies: ["LocalSources", "Platform"]),
        .testTarget(name: "CloudSourcesTests", dependencies: ["CloudSources", "LocalSources", "Domain", "Platform"]),
        .testTarget(name: "ProactiveTests", dependencies: ["Proactive", "Domain"]),
        .testTarget(name: "AgentTests", dependencies: ["Agent", "Domain"]),
        .testTarget(name: "KnowledgeTests", dependencies: ["Knowledge", "Domain", "Platform"]),
        .testTarget(name: "BrainTests", dependencies: ["Brain", "Domain"]),
        .testTarget(name: "SchedulingTests", dependencies: ["Scheduling"]),
        .testTarget(name: "Eval", dependencies: ["Domain", "Inference", "Ingest", "Privacy"], path: "Tests/Eval", resources: [.copy("Corpus")]),
    ]
)
