// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppFeedbackKit",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "AppFeedbackKit", targets: ["AppFeedbackKit"]),
    ],
    targets: [
        .target(
            name: "AppFeedbackKit",
            path: "Sources/AppFeedbackKit",
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
            ]
        ),
    ]
)
