// swift-tools-version: 6.0
import PackageDescription

// The app target is macOS-only (SwiftUI). BUUKit is platform independent so the
// wire-format / parsing / persistence logic can be unit tested anywhere.
#if canImport(SwiftUI)

let package = Package(
    name: "BUU",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BUU", targets: ["BUU"]),
        .library(name: "BUUKit", targets: ["BUUKit"]),
    ],
    targets: [
        .target(
            name: "BUUKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "BUU",
            dependencies: ["BUUKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BUUKitTests",
            dependencies: ["BUUKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

#else

let package = Package(
    name: "BUUKit",
    products: [
        .library(name: "BUUKit", targets: ["BUUKit"]),
    ],
    targets: [
        .target(
            name: "BUUKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BUUKitTests",
            dependencies: ["BUUKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

#endif
