// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "TaskDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TaskDesk", targets: ["TaskDesk"]), .executable(name: "taskctl", targets: ["taskctl"])],
    targets: [
        .target(name: "TaskCore"),
        .executableTarget(name: "TaskDesk", dependencies: ["TaskCore"]),
        .executableTarget(name: "taskctl", dependencies: ["TaskCore"]),
        .testTarget(name: "TaskCoreTests", dependencies: ["TaskCore"]),
        .testTarget(name: "TaskDeskTests", dependencies: ["TaskDesk", "TaskCore"])
    ]
)
