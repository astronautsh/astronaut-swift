// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Astronaut",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "Astronaut",
            targets: ["Astronaut"]
        ),
    ],
    targets: [
        .target(
            name: "Astronaut"
        ),
        .testTarget(
            name: "AstronautTests",
            dependencies: ["Astronaut"]
        ),
    ]
)
