// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacSpaceFinder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MacSpaceFinder", path: "Sources/MacSpaceFinder"),
        .testTarget(name: "MacSpaceFinderTests", dependencies: ["MacSpaceFinder"], path: "Tests/MacSpaceFinderTests"),
    ]
)
