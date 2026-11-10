// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ORB",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OrbCore", targets: ["OrbCore"]),
        .executable(name: "OrbApp", targets: ["OrbApp"]),
        .executable(name: "orb", targets: ["orb"]),
    ],
    targets: [
        .target(name: "OrbCore", path: "Sources/OrbCore"),
        .executableTarget(name: "OrbApp", dependencies: ["OrbCore"], path: "Sources/OrbApp"),
        .executableTarget(name: "orb", dependencies: ["OrbCore"], path: "Sources/orb"),
        .testTarget(
            name: "OrbCoreTests",
            dependencies: ["OrbCore"],
            path: "Tests/OrbCoreTests",
            swiftSettings: [
                .unsafeFlags([
                    "-Xfrontend", "-load-plugin-library",
                    "-Xfrontend", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
                ])
            ]
        ),
    ]
)
