// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "XKit",
    platforms: [.iOS(.v18), .watchOS(.v11), .macOS(.v14)],
    products: [
        .library(name: "XKit", targets: ["XKit"]),
    ],
    targets: [
        .target(
            name: "XKit",
            resources: [.copy("Resources/endpoints.json")]
        ),
        .testTarget(
            name: "XKitTests",
            dependencies: ["XKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
