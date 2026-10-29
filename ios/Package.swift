// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LessonCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "LessonCore", targets: ["LessonCore"])],
    targets: [
        .target(name: "LessonCore", path: "LCRepeater/Core"),
        .testTarget(name: "LessonCoreTests", dependencies: ["LessonCore"], path: "LCRepeaterTests")
    ]
)
