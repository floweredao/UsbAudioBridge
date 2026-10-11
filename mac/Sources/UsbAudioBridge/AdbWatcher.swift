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
    static let service = "\(package)/.BridgeService"

    private let lock = NSLock()
    private var _devices: [String: Device] = [:]
    private var forceSetup = false
    /// Set by the app delegate: true while the tablet app has at least one live audio socket.
    var isStreaming: () -> Bool = { false }
    private var idleSince: Date?
    private var lastRelaunch = Date.distantPast
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
                // This thread has no run loop, so drain Foundation objects (pipes, file handles) every poll.
                autoreleasepool { self.poll() }
                Thread.sleep(forTimeInterval: 2)
            }
        }
        t.name = "adb-watch"
        t.start()
    }

    /// AOA gate: true when the tablet app already holds our accessory default or permission (no prompt),
    /// or the tablet is unlocked so Android can show its one-time "open with" prompt. Switching a locked
    /// tablet that has neither makes Android drop accessory mode again, which also drops the adb lanes.
    func accessoryReady() -> Bool {
        guard let serial = devices.first(where: { $0.ready })?.serial else { return false }
        let usb = adb(["-s", serial, "shell", "dumpsys", "usb"]).1
        if let settings = usb.range(of: "profile_group_settings"), usb[settings.upperBound...].contains(Self.package) {
            return true
        }
        return adb(["-s", serial, "shell", "dumpsys", "trust"]).1.contains("deviceLocked=0")
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
                relaunchIfIdle(serial)
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
                let (code, out) = adb(["-s", serial, "install", "-r", apk.path], timeout: 180)
                if code != 0 { note = "App install failed"; Log.info("install failed: \(out)") }
            } else {
                note = "Android app not installed"
            }
        }
        _ = adb(["-s", serial, "shell", "pm", "grant", Self.package, "android.permission.RECORD_AUDIO"])
        let reversed = applyReverse(serial)
        if !launch(serial) { note = note ?? "Could not open the app" }
        Log.info("tablet \(serial) ready=\(reversed) \(note ?? "")")
        lock.lock()
        _devices[serial] = Device(serial: serial, model: model.isEmpty ? serial : model, ready: reversed, note: note)
        lock.unlock()
    }

    /// The app can die without the cable moving (update, force stop, low memory); bring it back.
    private func relaunchIfIdle(_ serial: String) {
        if isStreaming() {
            idleSince = nil
            return
        }
        let now = Date()
        guard let since = idleSince else {
            idleSince = now
            return
        }
        guard now.timeIntervalSince(since) > 10, now.timeIntervalSince(lastRelaunch) > 15 else { return }
        lastRelaunch = now
        Log.info("no audio from \(serial) for 10 s; relaunching the app")
        _ = adb(["-s", serial, "shell", "pm", "grant", Self.package, "android.permission.RECORD_AUDIO"])
        launch(serial)
    }

    /// Starts the bridge in the background. A foreground service started by the adb shell uid may use the mic
    /// on Android 11 even with the screen off, so the app screen never has to wake the tablet or come forward.
    /// App builds older than that exported service refuse the shell (SecurityException) or lack it, so only then
    /// fall back to the activity. Any other failure (e.g. the package is still being replaced) is left to the
    /// idle relaunch, which retries in 15 s, instead of opening the app over whatever the user is doing.
    @discardableResult
    private func launch(_ serial: String) -> Bool {
        let (code, out) = adb(["-s", serial, "shell", "am", "start-foreground-service", "-n", Self.service])
        if code == 0 && !out.contains("Error") && !out.contains("Exception") { return true }
        let reply = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reply.contains("SecurityException") || reply.contains("Not found") else {
            Log.info("am start-foreground-service: \(reply); retrying later")
            return false
        }
        Log.info("am start-foreground-service: \(reply); opening the app instead")
        let (launchCode, launchOut) = adb(["-s", serial, "shell", "am", "start", "-n", Self.activity])
        if launchCode != 0 || launchOut.contains("Error") { Log.info("am start: \(launchOut)"); return false }
        return true
    }

    @discardableResult
    private func applyReverse(_ serial: String) -> Bool {
        let a = adb(["-s", serial, "reverse", "tcp:\(Wire.micPort)", "tcp:\(Wire.micPort)"]).0
        let b = adb(["-s", serial, "reverse", "tcp:\(Wire.speakerPort)", "tcp:\(Wire.speakerPort)"]).0
        return a == 0 && b == 0
    }

    /// Runs adb with a deadline. When two adb server starts race, the losing `fork-server` can hang
    /// before it ever answers, and its client then waits forever; without a deadline that froze this
    /// whole watcher (no reverse re-apply, no relaunch) until someone killed the process by hand.
    private func adb(_ args: [String], timeout: TimeInterval = 15) -> (Int32, String) {
        guard let adbPath else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = args
        // Output goes to a temp file, not a pipe: a server forked by this client could inherit a pipe
        // and keep it open, so reading to EOF would block; a file needs no EOF.
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("uab-adb-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil),
              let out = try? FileHandle(forWritingTo: outURL) else { return (-1, "cannot create \(outURL.path)") }
        defer {
            try? out.close()
            try? FileManager.default.removeItem(at: outURL)
        }
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return (-1, "\(error)") }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            Log.info("adb \(args.joined(separator: " ")) timed out after \(Int(timeout)) s; killing it")
            kill(process.processIdentifier, SIGKILL)
            done.wait()
            return (-1, "timed out")
        }
        let data = (try? Data(contentsOf: outURL)) ?? Data()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
