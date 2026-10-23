// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "UsbAudioBridge",
    platforms: [.macOS(.v15)],
    targets: [
        // Echo canceller (speexdsp 1.2.1, BSD-3-Clause), vendored so the helper builds without Homebrew.
        .target(
            name: "CSpeexDSP",
            path: "Sources/CSpeexDSP",
            exclude: ["COPYING", "README.md"],
            publicHeadersPath: "include",
            cSettings: [
                .define("FLOATING_POINT"),
                .define("USE_KISS_FFT"),
                .define("EXPORT", to: ""),
            ]
        ),
        .executableTarget(
            name: "UsbAudioBridge",
            dependencies: ["CSpeexDSP"],
            path: "Sources/UsbAudioBridge",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        .testTarget(
            name: "UsbAudioBridgeTests",
            dependencies: ["UsbAudioBridge"],
            path: "Tests/UsbAudioBridgeTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
