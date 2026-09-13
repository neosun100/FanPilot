// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FanPilotMenu",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "FanPilotMenu", path: "Sources/FanPilotMenu")
    ]
)
