import Foundation

/// Polls `adb devices`; for each attached tablet it installs/updates the app if needed,
/// grants the mic permission, sets up `adb reverse` for both ports and launches the app.
final class AdbWatcher {
    struct Device {
        let serial: String
        var model: String
        var ready: Bool
        var note: String?
    }

    static let package = "com.floweredao.usbaudiobridge"
    static let activity = "\(package)/.MainActivity"

    private let lock = NSLock()
    private var _devices: [String: Device] = [:]
    private var forceSetup = false
    let adbPath: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "\(home)/Library/Android/sdk/platform-tools/adb",
                "/opt/homebrew/share/android-commandlinetools/platform-tools/adb"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    var devices: [Device] {
        lock.lock(); defer { lock.unlock() }
        return _devices.values.sorted { $0.serial < $1.serial }
    }

    func start() {
        guard adbPath != nil else {
            Log.info("adb not found; install it with: brew install --cask android-platform-tools")
            return
        }
        let t = Thread { [unowned self] in
            while true {
                self.poll()
                Thread.sleep(forTimeInterval: 2)
            }
        }
        t.name = "adb-watch"
        t.start()
    }

    /// Re-runs the full setup (reverse + launch) on the next poll.
    func reconnect() {
        lock.lock(); forceSetup = true; lock.unlock()
    }

    private func poll() {
        let (code, out) = adb(["devices"])
        guard code == 0 else { return }
        let attached = out.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "\t")
            return parts.count == 2 && parts[1] == "device" ? String(parts[0]) : nil
        }
        lock.lock()
        let force = forceSetup
        forceSetup = false
        for serial in _devices.keys where !attached.contains(serial) {
            Log.info("tablet \(serial) detached")
            _devices[serial] = nil
        }
        let known = _devices
        lock.unlock()

        for serial in attached {
            if let device = known[serial], device.ready, !force {
                // adb server restarts drop reverse rules; re-apply them quietly.
                let (_, list) = adb(["-s", serial, "reverse", "--list"])
                if !list.contains("tcp:\(Wire.micPort)") || !list.contains("tcp:\(Wire.speakerPort)") {
                    Log.info("reverse rules missing on \(serial); re-applying")
                    applyReverse(serial)
                }
                continue
            }
            setup(serial)
        }
    }

    private func setup(_ serial: String) {
        let model = adb(["-s", serial, "shell", "getprop", "ro.product.model"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.info("tablet \(serial) (\(model)) attached; setting up")
        var note: String?
        let installed = adb(["-s", serial, "shell", "pm", "path", Self.package]).1.contains("package:")
        if !installed {
            if let apk = Bundle.main.url(forResource: "UsbAudioBridge", withExtension: "apk") {
                Log.info("installing app on \(serial)")
                let (code, out) = adb(["-s", serial, "install", "-r", apk.path])
                if code != 0 { note = "App install failed"; Log.info("install failed: \(out)") }
            } else {
                note = "Android app not installed"
            }
        }
        _ = adb(["-s", serial, "shell", "pm", "grant", Self.package, "android.permission.RECORD_AUDIO"])
        let reversed = applyReverse(serial)
        let (launchCode, launchOut) = adb(["-s", serial, "shell", "am", "start", "-n", Self.activity])
        if launchCode != 0 || launchOut.contains("Error") { note = note ?? "Could not open the app"; Log.info("am start: \(launchOut)") }
        Log.info("tablet \(serial) ready=\(reversed) \(note ?? "")")
        lock.lock()
        _devices[serial] = Device(serial: serial, model: model.isEmpty ? serial : model, ready: reversed, note: note)
        lock.unlock()
    }

    @discardableResult
    private func applyReverse(_ serial: String) -> Bool {
        let a = adb(["-s", serial, "reverse", "tcp:\(Wire.micPort)", "tcp:\(Wire.micPort)"]).0
        let b = adb(["-s", serial, "reverse", "tcp:\(Wire.speakerPort)", "tcp:\(Wire.speakerPort)"]).0
        return a == 0 && b == 0
    }

    private func adb(_ args: [String]) -> (Int32, String) {
        guard let adbPath else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
