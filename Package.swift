// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeedbackKit",
    // iOS 17 rather than something newer: this has to drop into existing apps
    // without forcing their deployment target up. Nothing here needs a later SDK.
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "FeedbackKit", targets: ["FeedbackKit"])
    ],
    targets: [
        .target(
            name: "FeedbackKit",
            // A package carries its own privacy manifest, and SwiftPM will not
            // pick it up implicitly — it has to be declared as a resource.
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FeedbackKitTests",
            dependencies: ["FeedbackKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ],
    swiftLanguageModes: [.v6]
)
