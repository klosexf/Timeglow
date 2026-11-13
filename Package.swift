// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TimeglowMonitoring",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MonitoringCore", targets: ["MonitoringCore"])],
    targets: [
        .target(name: "MonitoringCore", path: "Timeglow/MonitoringCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "MonitoringCoreTests", dependencies: ["MonitoringCore"], path: "Tests/MonitoringCoreTests")
    ]
)
