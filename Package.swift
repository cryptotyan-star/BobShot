// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BobShot",
    platforms: [
        .macOS(.v14) // ScreenCaptureKit SCScreenshotManager требует macOS 14+
    ],
    targets: [
        .executableTarget(
            name: "BobShot",
            path: "Sources/BobShot"
        )
    ]
)
