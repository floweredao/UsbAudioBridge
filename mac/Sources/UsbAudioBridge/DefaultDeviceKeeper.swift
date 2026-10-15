import CoreAudio
import Foundation

/// Keeps Tablet Audio as the Mac's default input and output once the user has chosen it.
///
/// macOS makes a device that has just connected the default on its own: a Bluetooth speaker that
/// wakes up after a long idle, or reconnects right after a reboot, takes over the default input and
/// system output, so apps quietly stop using the tablet. A change that follows a device appearing is
/// undone while the tablet is linked; a change with no new device behind it is the user's own choice
/// (or a remote-desktop app routing sound to itself) and is left alone, and the keeper stands down
/// until Tablet Audio is chosen again.
final class DefaultDeviceKeeper {
    enum Role: String, CaseIterable {
        case input, output, systemOutput

        var selector: AudioObjectPropertySelector {
            switch self {
            case .input: return kAudioHardwarePropertyDefaultInputDevice
            case .output: return kAudioHardwarePropertyDefaultOutputDevice
            case .systemOutput: return kAudioHardwarePropertyDefaultSystemOutputDevice
            }
        }

        var defaultsKey: String { "keepTabletAudio.\(rawValue)" }
    }

    private let tabletUID: String
    private let isLinked: () -> Bool
    private var policies: [Role: DefaultKeeperPolicy] = [:]
    private var knownDevices: Set<String> = []
    private var lastArrival = Date.distantPast

    init(tabletUID: String, isLinked: @escaping () -> Bool) {
        self.tabletUID = tabletUID
        self.isLinked = isLinked
    }

    func start() {
        knownDevices = Self.deviceUIDs()
        for role in Role.allCases {
            let keep = UserDefaults.standard.bool(forKey: role.defaultsKey)
            policies[role] = DefaultKeeperPolicy(tabletUID: tabletUID, keep: keep, lastSeen: Self.defaultUID(role))
        }
        let t = Thread { [unowned self] in
            while true {
                autoreleasepool { self.poll() }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        t.name = "default-keeper"
        t.start()
    }

    private func poll() {
        let now = Date()
        let devices = Self.deviceUIDs()
        if !devices.subtracting(knownDevices).isEmpty { lastArrival = now }
        knownDevices = devices
        let linked = isLinked()
        for role in Role.allCases {
            guard var policy = policies[role] else { continue }
            let current = Self.defaultUID(role)
            let action = policy.step(current: current, now: now, lastArrival: lastArrival, linked: linked)
            policies[role] = policy
            switch action {
            case .none:
                break
            case .kept:
                UserDefaults.standard.set(true, forKey: role.defaultsKey)
                Log.info("default \(role.rawValue) is Tablet Audio; keeping it there")
            case .released:
                UserDefaults.standard.set(false, forKey: role.defaultsKey)
                Log.info("default \(role.rawValue) changed to \(current ?? "none") by choice; no longer keeping Tablet Audio")
            case .automaticSwitch:
                Log.info("default \(role.rawValue) moved to \(current ?? "none") because a device connected")
            case .restore:
                if let device = AudioDevices.find(uid: tabletUID), Self.setDefault(role, device) {
                    Log.info("default \(role.rawValue) set back to Tablet Audio (was \(current ?? "none"))")
                } else {
                    Log.info("could not set default \(role.rawValue) back to Tablet Audio")
                }
            }
        }
    }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func uid(of device: AudioDeviceID) -> String? {
        var a = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    static func defaultUID(_ role: Role) -> String? {
        var a = address(role.selector)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return uid(of: device)
    }

    private static func setDefault(_ role: Role, _ device: AudioDeviceID) -> Bool {
        var a = address(role.selector)
        var id = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    private static func deviceUIDs() -> Set<String> {
        Set(AudioDevices.all().compactMap(uid(of:)))
    }
}

/// The keeper's decisions for one default (input, output or system output), free of CoreAudio so the
/// `--default-keeper-selftest` mode can drive it through recorded situations.
struct DefaultKeeperPolicy {
    enum Action: Equatable { case none, kept, released, automaticSwitch, restore }

    /// A switch counts as automatic when a device appeared this long before it, or shortly after.
    static let arrivalBefore: TimeInterval = 10
    static let arrivalAfter: TimeInterval = 3
    static let retryEvery: TimeInterval = 5

    let tabletUID: String
    private(set) var keep: Bool
    private var lastSeen: String?
    private var changedAt: Date?
    private var lastRestore = Date.distantPast

    init(tabletUID: String, keep: Bool, lastSeen: String?) {
        self.tabletUID = tabletUID
        self.keep = keep
        self.lastSeen = lastSeen
    }

    mutating func step(current: String?, now: Date, lastArrival: Date, linked: Bool) -> Action {
        if current == tabletUID {
            lastSeen = current
            changedAt = nil
            if keep { return .none }
            keep = true
            return .kept
        }
        if current != lastSeen {
            lastSeen = current
            changedAt = now
        }
        if let changed = changedAt {
            // Wait until a device that connects just after the switch would have shown up too.
            guard now.timeIntervalSince(changed) >= Self.arrivalAfter else { return .none }
            changedAt = nil
            guard keep else { return .none }
            let gap = changed.timeIntervalSince(lastArrival)
            if gap > Self.arrivalBefore || gap < -Self.arrivalAfter {
                keep = false
                return .released
            }
            return .automaticSwitch
        }
        guard keep, linked, now.timeIntervalSince(lastRestore) >= Self.retryEvery else { return .none }
        lastRestore = now
        return .restore
    }
}

enum DefaultKeeperSelfTest {
    static func run() -> String {
        let tablet = "UsbAudioBridge.TabletAudio"
        let speaker = "3C-39-E7-BF-F6-1D:output"
        let remote = "com.p5sys.jump.audio.driver_v001"
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            lines.append("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }

        // A Bluetooth speaker reconnects (it appears at 100 s) and macOS switches to it at 101 s.
        var p = DefaultKeeperPolicy(tabletUID: tablet, keep: true, lastSeen: tablet)
        _ = p.step(current: speaker, now: at(101), lastArrival: at(100), linked: true)
        let classified = p.step(current: speaker, now: at(104), lastArrival: at(100), linked: true)
        let restored = p.step(current: speaker, now: at(105), lastArrival: at(100), linked: true)
        check("bluetooth reconnect is an automatic switch", classified == .automaticSwitch)
        check("bluetooth reconnect is undone while linked", restored == .restore && p.keep)
        check("restoring Tablet Audio keeps quiet", p.step(current: tablet, now: at(106), lastArrival: at(100), linked: true) == .none)

        // The user picks the speaker in Sound settings: no device appeared around it.
        p = DefaultKeeperPolicy(tabletUID: tablet, keep: true, lastSeen: tablet)
        _ = p.step(current: speaker, now: at(500), lastArrival: at(100), linked: true)
        check("a manual change is respected", p.step(current: speaker, now: at(503), lastArrival: at(100), linked: true) == .released && !p.keep)
        check("after a manual change nothing is restored", p.step(current: speaker, now: at(600), lastArrival: at(100), linked: true) == .none)

        // A remote-desktop session routes output to its own (always present) device, then hands it back.
        p = DefaultKeeperPolicy(tabletUID: tablet, keep: true, lastSeen: tablet)
        _ = p.step(current: remote, now: at(700), lastArrival: at(100), linked: true)
        check("a remote-desktop switch is not fought", p.step(current: remote, now: at(703), lastArrival: at(100), linked: true) == .released)
        check("handing Tablet Audio back turns keeping on again", p.step(current: tablet, now: at(900), lastArrival: at(100), linked: true) == .kept && p.keep)

        // After a reboot the helper starts with the speaker already default; the stored choice was Tablet Audio.
        p = DefaultKeeperPolicy(tabletUID: tablet, keep: true, lastSeen: speaker)
        check("waits for the tablet before restoring", p.step(current: speaker, now: at(10), lastArrival: .distantPast, linked: false) == .none)
        check("restores once the tablet links", p.step(current: speaker, now: at(20), lastArrival: .distantPast, linked: true) == .restore)
        check("does not retry every second", p.step(current: speaker, now: at(21), lastArrival: .distantPast, linked: true) == .none)

        // Someone who never chose Tablet Audio is left alone, even when a device connects.
        p = DefaultKeeperPolicy(tabletUID: tablet, keep: false, lastSeen: speaker)
        _ = p.step(current: remote, now: at(101), lastArrival: at(100), linked: true)
        check("never chosen means never restored", p.step(current: remote, now: at(104), lastArrival: at(100), linked: true) == .none
              && p.step(current: remote, now: at(110), lastArrival: at(100), linked: true) == .none)

        lines.append(failures == 0 ? "default keeper self-test: all passed" : "default keeper self-test: \(failures) failed")
        return lines.joined(separator: "\n")
    }
}
