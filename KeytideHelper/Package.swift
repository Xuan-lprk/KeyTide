// swift-tools-version:5.9
import PackageDescription

// Compile the same sources as the production Xcode helper target. This package
// does not install, sign, register, or launch the service.
let package = Package(
    name: "KeytideHelper",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KeytideHelper", targets: ["KeytideHelper"])
    ],
    targets: [
        .executableTarget(
            name: "KeytideHelper",
            path: ".",
            exclude: ["Assets.xcassets", "Info.plist", "KeytideHelper.entitlements", "README.md", "Tests"],
            sources: [
                "main.swift",
                "EventTapController.swift",
                "PayloadBuilder.swift",
                "HelperPayloadFields.swift",
                "ButtonRoleClassifier.swift",
                "SystemMediaKey.swift",
                "HelperProtocols.swift",
                "HelperLocations.swift",
                "HelperXPCListener.swift",
                "HelperIdleSupervisor.swift",
                "TrackpadRecording.swift",
                "InputEventSemantics.swift",
                "HelperTrackpadService.swift",
                "AppStats.swift",
                "AppActivityTracker.swift",
                "StatsModels.swift",
                "StatsManager.swift",
                "InteractionProfile.swift",
                "PhysicalKeyMapping.swift",
                "KeyboardLayout.swift",
                "KeyboardTrackingPeriod.swift",
                "KeyboardUsageProgress.swift",
                "CumulativeKeyboardSnapshot.swift",
                "GrowthKeyboardPresentation.swift",
                "KeyReplayStore.swift",
                "InputEventAggregator.swift",
                "HelperKeyReplayWriter.swift",
                "HelperInputService.swift"
            ],
            swiftSettings: [.define("KEYTIDE_HELPER")]
        ),
        .testTarget(
            name: "KeytideHelperTests",
            dependencies: ["KeytideHelper"],
            path: "Tests"
        )
    ]
)
