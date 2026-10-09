// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "UsbAudioBridge",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "UsbAudioBridge",
            path: "Sources/UsbAudioBridge",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
