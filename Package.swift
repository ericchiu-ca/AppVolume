// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppVolume",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "AppVolume", targets: ["AppVolume"])],
    targets: [
        .target(name: "AudioBackend", path: "Sources/AudioBackend", publicHeadersPath: "include", linkerSettings: [
            .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"), .linkedFramework("AppKit")
        ]),
        .executableTarget(name: "AppVolume", dependencies: ["AudioBackend"], path: "Sources/AppVolume"),
        .testTarget(name: "AppVolumeTests", dependencies: ["AppVolume"], path: "Tests/AppVolumeTests")
    ],
    swiftLanguageModes: [.v5]
)
