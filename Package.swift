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
        .executable(name: "VirtualMacGuest", targets: ["VirtualMacGuest"]),
        .library(name: "BUUKit", targets: ["BUUKit"]),
    ],
    targets: [
        .target(
            name: "BUUKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Vendored from terminal-mac (MIT). Kept in Swift 5 mode: the VM and
        // guest helper use AppKit/Virtualization/ScreenCaptureKit APIs that the
        // upstream stack was written against.
        .target(
            name: "VirtualMacCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "VirtualMacKit",
            dependencies: ["VirtualMacCore"],
            exclude: ["ATTRIBUTION.md"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreServices"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        .executableTarget(
            name: "VirtualMacGuest",
            dependencies: ["VirtualMacKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreServices"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        .executableTarget(
            name: "BUU",
            dependencies: ["BUUKit", "VirtualMacKit", "VirtualMacCore"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreServices"),
                .linkedFramework("QuickLookUI"),
            ]
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
