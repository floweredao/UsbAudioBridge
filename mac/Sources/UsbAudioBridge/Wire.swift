import Darwin
import Foundation

/// Wire format shared with the Android app (android/.../audio/Protocol.kt).
/// Every message is [type: u8][length: u32 big-endian][payload].
enum Wire {
    static let micPort: UInt16 = 47123      // tablet mic -> Mac, s16le mono 48 kHz
    static let speakerPort: UInt16 = 47124  // Mac -> tablet speaker, s16le stereo 48 kHz
    static let sampleRate = 48_000.0

    static let audio: UInt8 = 1
    static let ping: UInt8 = 2
    static let pong: UInt8 = 3
    static let hello: UInt8 = 4
    static let maxPayload = 1 << 16
    static let helloMagic: [UInt8] = Array("UAB1".utf8)
}

/// One accepted TCP connection. Writes are serialized; close() unblocks a reader.
final class Connection {
    let fd: Int32
    private let lock = NSLock()
    private var isClosed = false

    init(fd: Int32) {
        self.fd = fd
    }

    var closed: Bool {
        lock.lock(); defer { lock.unlock() }
        return isClosed
    }

    @discardableResult
    func send(_ type: UInt8, _ payload: UnsafeRawBufferPointer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isClosed { return false }
        var header = [UInt8](repeating: 0, count: 5)
        header[0] = type
        let length = UInt32(payload.count)
        header[1] = UInt8(length >> 24 & 0xff)
        header[2] = UInt8(length >> 16 & 0xff)
        header[3] = UInt8(length >> 8 & 0xff)
        header[4] = UInt8(length & 0xff)
        let ok = header.withUnsafeBytes { writeAll($0) } && writeAll(payload)
        return ok
    }

    @discardableResult
    func send(_ type: UInt8, bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { send(type, $0) }
    }

    /// Blocks until a full frame arrives. Returns nil on EOF or error.
    func readFrame(into buffer: inout [UInt8]) -> (type: UInt8, length: Int)? {
        var header = [UInt8](repeating: 0, count: 5)
        guard header.withUnsafeMutableBytes({ readAll($0) }) else { return nil }
        let length = Int(header[1]) << 24 | Int(header[2]) << 16 | Int(header[3]) << 8 | Int(header[4])
        guard length <= Wire.maxPayload else { return nil }
        if buffer.count < length { buffer = [UInt8](repeating: 0, count: length) }
        guard buffer.withUnsafeMutableBytes({ readAll(UnsafeMutableRawBufferPointer(rebasing: $0[0..<length])) }) else { return nil }
        return (header[0], length)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private func writeAll(_ buffer: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private func readAll(_ buffer: UnsafeMutableRawBufferPointer) -> Bool {
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.read(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

/// Loopback-only TCP listener; `adb reverse` forwards the tablet's 127.0.0.1:port here.
final class Server {
    let port: UInt16
    private let onAccept: (Connection) -> Void

    init(port: UInt16, onAccept: @escaping (Connection) -> Void) {
        self.port = port
        self.onAccept = onAccept
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.socket("socket() failed: \(errno)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw BridgeError.socket("port \(port) is busy (errno \(errno)); is another copy running?")
        }
        guard listen(fd, 4) == 0 else { throw BridgeError.socket("listen() failed: \(errno)") }
        let thread = Thread { [onAccept] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                var one: Int32 = 1
                setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                onAccept(Connection(fd: client))
            }
        }
        thread.name = "accept-\(port)"
        thread.start()
    }
}

enum BridgeError: Error, CustomStringConvertible {
    case socket(String)
    case audio(String)

    var description: String {
        switch self {
        case .socket(let m), .audio(let m): return m
        }
    }
}
