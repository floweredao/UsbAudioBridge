import Darwin
import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

/// Carries the tablet link over USB accessory mode (Android Open Accessory) instead of adb.
///
/// An Android device that shows an adb interface is asked to switch to accessory mode; it then
/// re-enumerates as 18d1:2d00 (or 2d01 with adb still on). Its accessory interface has one bulk pipe
/// per direction, bridged here to a socketpair so the Bridge sees an ordinary `Connection` carrying
/// mic AUDIO, speaker AUDIO and PING/PONG together. The link is handed over only after the first
/// packet from the tablet, so a tablet whose app never opened the accessory stays on adb.
final class AoaTransport {
    private static let googleVendor = 0x18D1
    private static let accessoryProducts: Set<Int> = [0x2D00, 0x2D01]
    private static let strings = ["floweredao", "UsbAudioBridge", "USB Audio Bridge", "1.0",
                                  "https://github.com/floweredao/UsbAudioBridge", "UsbAudioBridge"]

    private let onLink: (Connection) -> Void
    /// Asked before every switch: true when the tablet app can take the accessory without a prompt,
    /// or the tablet is unlocked so Android can show its "open with" prompt.
    private let canSwitch: () -> Bool
    private let lock = NSLock()
    private var linkActive = false
    private var lastAttempt = Date.distantPast
    private var everLinked = false
    private var failedRelinks = 0
    /// A switch that never links makes Android drop accessory mode and re-enumerate, which also drops
    /// the adb lanes; so until a link has worked, or after three relinks in a row failed, wait this long.
    private static let retryAfterFailure: TimeInterval = 600
    private static let retryAfterSuccess: TimeInterval = 5

    init(canSwitch: @escaping () -> Bool, onLink: @escaping (Connection) -> Void) {
        self.canSwitch = canSwitch
        self.onLink = onLink
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return linkActive
    }

    func start() {
        let t = Thread { [unowned self] in
            while true {
                autoreleasepool { self.poll() }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        t.name = "aoa-watch"
        t.start()
    }

    private func poll() {
        guard !isActive else { return }
        if let accessory = Self.findAccessoryInterface() {
            lock.lock(); linkActive = true; lock.unlock()
            let t = Thread { [unowned self] in
                if self.run(interface: accessory) {
                    self.everLinked = true
                    self.failedRelinks = 0
                } else if self.everLinked {
                    self.failedRelinks += 1
                }
                lock.lock(); linkActive = false; lock.unlock()
            }
            t.name = "aoa-link"
            t.qualityOfService = .userInteractive
            t.start()
            return
        }
        let devices = Self.androidDevices()
        defer { devices.forEach { IOObjectRelease($0) } }
        guard let device = devices.first else { return }
        let wait = everLinked && failedRelinks < 3 ? Self.retryAfterSuccess : Self.retryAfterFailure
        guard Date().timeIntervalSince(lastAttempt) > wait, canSwitch() else { return }
        lastAttempt = Date()
        switchToAccessory(device)
    }

    private func switchToAccessory(_ service: io_service_t) {
        do {
            let device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
            defer { device.destroy() }
            let version = NSMutableData(length: 2)!
            try Self.control(device, type: 0xC0, request: 51, data: version)
            let protocolVersion = version.bytes.load(as: UInt16.self)
            guard protocolVersion >= 1 else {
                Log.info("aoa: device does not support accessory mode")
                return
            }
            for (index, string) in Self.strings.enumerated() {
                try Self.control(device, type: 0x40, request: 52, index: UInt16(index),
                                 data: NSMutableData(data: Data((string + "\0").utf8)))
            }
            try Self.control(device, type: 0x40, request: 53, data: nil)
            Log.info("aoa: asked the tablet to switch to accessory mode (protocol \(protocolVersion))")
        } catch {
            Log.info("aoa: switch failed: \(error.localizedDescription); staying on adb")
        }
    }

    /// Returns true when the tablet linked. A link that ends is not reset here: the next poll reopens the
    /// same accessory and gives the app 30 s (enough for an `adb install` and its dex2oat) to answer.
    /// Only a session nobody answers is reset, because Android cannot reopen a closed accessory session
    /// until the USB device re-enumerates; the tablet then comes back on adb and, if it linked before,
    /// is switched again a few seconds later.
    private func run(interface service: io_service_t) -> Bool {
        defer { IOObjectRelease(service) }
        let interface: IOUSBHostInterface
        let input: IOUSBHostPipe
        let output: IOUSBHostPipe
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
            guard let (inAddress, outAddress) = Self.bulkEndpoints(interface) else {
                Log.info("aoa: accessory interface has no bulk pipes")
                interface.destroy()
                Self.reset(interfaceService: service)
                return false
            }
            input = try interface.copyPipe(withAddress: Int(inAddress))
            output = try interface.copyPipe(withAddress: Int(outAddress))
        } catch {
            Log.info("aoa: cannot open accessory interface: \(error.localizedDescription)")
            Self.reset(interfaceService: service)
            Thread.sleep(forTimeInterval: 2)
            return false
        }

        let packet = NSMutableData(length: 16384)!
        var received = 0
        // Wait for the tablet app to open the accessory: it pings every second once it does.
        do {
            try input.__sendIORequest(with: packet, bytesTransferred: &received, completionTimeout: 30)
        } catch {
            Log.info("aoa: the tablet app did not answer over the accessory; back to adb")
            interface.destroy()
            Self.reset(interfaceService: service)
            return false
        }
        defer { interface.destroy() }

        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return false }
        var one: Int32 = 1
        setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // If the tablet stops draining the accessory, the speaker sender must fail fast instead of blocking.
        var sendTimeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fds[0], SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        let bridgeSide = Connection(fd: fds[0])
        let usbSide = fds[1]
        Log.info("aoa: tablet linked over USB accessory")
        onLink(bridgeSide)

        let writer = Thread {
            let chunk = NSMutableData(length: 16384)!
            while true {
                let n = Darwin.read(usbSide, chunk.mutableBytes, chunk.length)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                let data = NSMutableData(bytes: chunk.bytes, length: n)
                var sent = 0
                do {
                    try output.__sendIORequest(with: data, bytesTransferred: &sent, completionTimeout: 2)
                } catch {
                    Log.info("aoa: write failed: \(error.localizedDescription)")
                    break
                }
            }
            Darwin.shutdown(usbSide, SHUT_RDWR)
            try? input.__abort(with: .asynchronous)
        }
        writer.name = "aoa-out"
        writer.qualityOfService = .userInteractive
        writer.start()

        while received >= 0 {
            if received > 0 {
                var offset = 0
                while offset < received {
                    let n = Darwin.write(usbSide, packet.bytes + offset, received - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { received = -1; break }
                    offset += n
                }
                if received < 0 { break }
            }
            do {
                // The app pings every second, so 3 s of silence means it died (e.g. an update) while the
                // accessory stays configured; dropping the link lets the adb watchdog relaunch it.
                try input.__sendIORequest(with: packet, bytesTransferred: &received, completionTimeout: 3)
            } catch {
                Log.info("aoa: no data from the tablet app for 3 s")
                break
            }
        }
        Darwin.shutdown(usbSide, SHUT_RDWR)
        bridgeSide.close()
        try? output.__abort(with: .asynchronous)
        while !writer.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        Darwin.close(usbSide)
        Log.info("aoa: accessory link closed")
        return true
    }

    // MARK: IOKit helpers

    private static func reset(interfaceService: io_service_t) {
        guard let deviceService = parent(interfaceService) else { return }
        defer { IOObjectRelease(deviceService) }
        do {
            let device = try IOUSBHostDevice(__ioService: deviceService, options: [], queue: nil, interestHandler: nil)
            defer { device.destroy() }
            try device.reset()
            Log.info("aoa: reset the tablet's USB connection")
        } catch {
            Log.info("aoa: reset failed: \(error.localizedDescription)")
        }
    }

    private static func control(_ device: IOUSBHostDevice, type: UInt8, request: UInt8, index: UInt16 = 0, data: NSMutableData?) throws {
        var r = IOUSBDeviceRequest()
        r.bmRequestType = type
        r.bRequest = request
        r.wValue = 0
        r.wIndex = index
        r.wLength = UInt16(data?.length ?? 0)
        var done = 0
        try device.__send(r, data: data, bytesTransferred: &done, completionTimeout: 2)
    }

    private static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
    }

    private static func services(_ className: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [io_service_t] = []
        while case let s = IOIteratorNext(iterator), s != 0 { result.append(s) }
        return result
    }

    private static func parent(_ entry: io_registry_entry_t) -> io_registry_entry_t? {
        var p: io_registry_entry_t = 0
        return IORegistryEntryGetParentEntry(entry, kIOServicePlane, &p) == KERN_SUCCESS ? p : nil
    }

    /// Android devices (not yet in accessory mode) identified by their adb interface.
    private static func androidDevices() -> [io_service_t] {
        var result: [io_service_t] = []
        for iface in services("IOUSBHostInterface") {
            defer { IOObjectRelease(iface) }
            guard intProperty(iface, "bInterfaceClass") == 0xFF, intProperty(iface, "bInterfaceSubClass") == 0x42,
                  intProperty(iface, "bInterfaceProtocol") == 0x01, let device = parent(iface) else { continue }
            if intProperty(device, "idVendor") == googleVendor, accessoryProducts.contains(intProperty(device, "idProduct") ?? 0) {
                IOObjectRelease(device)
                continue
            }
            result.append(device)
        }
        return result
    }

    /// The vendor-specific, non-adb interface of a device that is already in accessory mode.
    private static func findAccessoryInterface() -> io_service_t? {
        var found: io_service_t?
        for iface in services("IOUSBHostInterface") {
            guard found == nil, intProperty(iface, "bInterfaceClass") == 0xFF, intProperty(iface, "bInterfaceSubClass") != 0x42,
                  let device = parent(iface) else {
                IOObjectRelease(iface)
                continue
            }
            let isAccessory = intProperty(device, "idVendor") == googleVendor
                && accessoryProducts.contains(intProperty(device, "idProduct") ?? 0)
            IOObjectRelease(device)
            if isAccessory { found = iface } else { IOObjectRelease(iface) }
        }
        return found
    }

    private static func bulkEndpoints(_ interface: IOUSBHostInterface) -> (UInt8, UInt8)? {
        let configuration = interface.configurationDescriptor
        let interfaceDescriptor = interface.interfaceDescriptor
        var inAddress: UInt8?
        var outAddress: UInt8?
        var current = UnsafePointer<IOUSBDescriptorHeader>(OpaquePointer(interfaceDescriptor))
        while let endpoint = IOUSBGetNextEndpointDescriptor(configuration, interfaceDescriptor, current) {
            if endpoint.pointee.bmAttributes & 0x03 == 0x02 {
                if endpoint.pointee.bEndpointAddress & 0x80 != 0 { inAddress = inAddress ?? endpoint.pointee.bEndpointAddress }
                else { outAddress = outAddress ?? endpoint.pointee.bEndpointAddress }
            }
            current = UnsafePointer<IOUSBDescriptorHeader>(OpaquePointer(endpoint))
        }
        guard let inAddress, let outAddress else { return nil }
        return (inAddress, outAddress)
    }
}
