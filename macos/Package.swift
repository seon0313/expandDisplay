// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExpandDisplay",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "VirtualDisplayBridge",
            path: "Sources/VirtualDisplayBridge",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation"), .linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "ExpandDisplay",
            dependencies: ["VirtualDisplayBridge"],
            path: "Sources/ExpandDisplay",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
