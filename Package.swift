// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "QuickDictate",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "QuickDictate",
            targets: ["QuickDictate"]
        )
    ],
    targets: [
        .executableTarget(
            name: "QuickDictate",
            path: "Sources/QuickDictate",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "QuickDictateTests",
            dependencies: ["QuickDictate"],
            path: "Tests/QuickDictateTests"
        )
    ]
)
