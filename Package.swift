// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BingDesk",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WallpaperCore", targets: ["WallpaperCore"]),
        .executable(name: "BingDesk", targets: ["BingDesk"])
    ],
    targets: [
        .target(name: "WallpaperCore"),
        .executableTarget(name: "BingDesk", dependencies: ["WallpaperCore"], path: "Sources/BingDesk"),
        .testTarget(name: "WallpaperCoreTests", dependencies: ["WallpaperCore"])
    ],
    swiftLanguageModes: [.v6]
)
