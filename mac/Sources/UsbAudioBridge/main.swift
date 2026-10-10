import AppKit
import AVFoundation

signal(SIGPIPE, SIG_IGN)
let arguments = CommandLine.arguments

if let i = arguments.firstIndex(of: "--loop-test") {
    // Runs from inside the app bundle so it shares the app's microphone permission.
    let seconds = arguments.count > i + 1 ? Double(arguments[i + 1]) ?? 8 : 8
    let report = LoopTest.run(seconds: seconds)
    let path = arguments.firstIndex(of: "--out").map { arguments[$0 + 1] }
    if let path { try? report.write(toFile: path, atomically: true, encoding: .utf8) }
    print(report)
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let bridge = Bridge()
    let adb = AdbWatcher()
    lazy var aoa = AoaTransport(canSwitch: { [adb] in adb.accessoryReady() }) { [bridge] conn in bridge.acceptAoa(conn) }
    var menu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = StatusMenu(bridge: bridge, adb: adb)
        adb.isStreaming = { [bridge] in
            let s = bridge.stats
            return s.micConnected || s.speakerConnected
        }
        Log.info("USB Audio Bridge helper starting")
        // Capturing the Tablet Audio bridge port counts as microphone access; ask once up front.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Log.info("microphone access granted=\(granted)")
            DispatchQueue.main.async { self.startBridge() }
        }
        if arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.menu?.showForSnapshot(seconds: 6) }
        }
    }

    private func startBridge() {
        do {
            try bridge.start()
            adb.start()
            // `defaults write <bundle id> aoa -bool false` keeps the tablet on adb only.
            if UserDefaults.standard.object(forKey: "aoa") as? Bool ?? true { aoa.start() }
        } catch {
            Log.info("start failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "USB Audio Bridge could not start"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
