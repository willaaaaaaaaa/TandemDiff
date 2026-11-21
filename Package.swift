// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TandemDiff",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TandemDiff", targets: ["TandemDiff"])],
    targets: [
        .target(name: "TandemDiffCore"),
        .executableTarget(name: "TandemDiff", dependencies: ["TandemDiffCore"]),
        .testTarget(name: "TandemDiffCoreTests", dependencies: ["TandemDiffCore"]),
        .testTarget(name: "TandemDiffAppTests", dependencies: ["TandemDiff", "TandemDiffCore"])
    ]
)
