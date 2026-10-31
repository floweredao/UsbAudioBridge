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
    static let join: UInt8 = 5  // tablet -> Mac after HELLO: [session u32][lane u8][lane count u8]
    static let maxPayload = 1 << 16
    static let helloMagic: [UInt8] = Array("UAB1".utf8)
}

/// One accepted TCP connection. Writes are serialized; close() unblocks a reader and a writer.
final class Connection {
    let fd: Int32
    private let lock = NSLock()
    /// Held for a whole frame write. Separate from `lock` so close() never waits behind a write blocked on a full socket.
    private let writeLock = NSLock()
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
        writeLock.lock(); defer { writeLock.unlock() }
        if closed { return false }
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

    /// Bytes written but not yet taken by the peer (SO_NWRITE).
    var unsentBytes: Int {
        var value: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_NWRITE, &value, &size) == 0 ? Int(value) : 0
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
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        lock.unlock()
        // shutdown() makes a blocked read or write return at once; the descriptor is released only after
        // that write has let go of it, so it is never reused under a writer.
        Darwin.shutdown(fd, SHUT_RDWR)
        writeLock.lock()
        Darwin.close(fd)
        writeLock.unlock()
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

/// One tablet stream carried over several TCP connections.
///
/// `adb` keeps only one unacknowledged packet in flight per socket, so a single socket delivers audio
/// in 20-40 ms bunches (one bunch per USB round trip). Spreading frames round-robin over several sockets
/// keeps several packets in flight. Lane 0 carries only PING/PONG; lanes 1... carry AUDIO in strict
/// round-robin order, so the receiver restores the order by reading them in the same rotation.
/// A legacy tablet app (no JOIN) is a group of one connection that carries everything.
final class LaneGroup {
    let lanes: [Connection]

    init(_ lanes: [Connection]) {
        self.lanes = lanes
    }

    var control: Connection { lanes[0] }
    var audio: ArraySlice<Connection> { lanes.count == 1 ? lanes[...] : lanes[1...] }

    func close() {
        lanes.forEach { $0.close() }
    }
}

/// Greets each accepted connection and groups the ones that announce the same JOIN session.
final class LaneJoiner {
    typealias OnGroup = (_ group: LaneGroup, _ firstFrame: (type: UInt8, payload: [UInt8])?) -> Void
    private let lock = NSLock()
    private var pending: [UInt32: [Int: Connection]] = [:]
    private static let maxPendingSessions = 4
    private let onGroup: OnGroup

    init(onGroup: @escaping OnGroup) {
        self.onGroup = onGroup
    }

    func accept(_ conn: Connection) {
        conn.send(Wire.hello, bytes: Wire.helloMagic)
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 256)
            guard let frame = conn.readFrame(into: &buffer) else {
                conn.close()
                return
            }
            guard frame.type == Wire.join else {
                // Legacy app: the first frame is already audio or a ping; hand it over unprocessed.
                onGroup(LaneGroup([conn]), (frame.type, Array(buffer[0..<frame.length])))
                return
            }
            // A JOIN too short to name its session and lane is not a legacy app; it must not replace the link.
            guard frame.length >= 6 else {
                conn.close()
                return
            }
            let session = buffer[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let lane = Int(buffer[4])
            let count = Int(buffer[5])
            guard count >= 2, count <= 16, lane < count else {
                conn.close()
                return
            }
            lock.lock()
            // Every attempt that never gets all its lanes open leaves a half-joined session behind, and only
            // a complete session cleared them, so their sockets piled up; past a few, drop the older ones.
            var evicted: [Connection] = []
            if pending[session] == nil && pending.count >= Self.maxPendingSessions {
                evicted = pending.values.flatMap { $0.values }
                pending.removeAll()
            }
            var lanes = pending[session] ?? [:]
            let replaced = lanes[lane]
            lanes[lane] = conn
            // Lanes that announced a different count must not complete the group (it would miss a lane).
            guard lanes.count == count, lanes.keys.allSatisfy({ $0 < count }) else {
                pending[session] = lanes
                lock.unlock()
                replaced?.close()
                evicted.forEach { $0.close() }
                return
            }
            // A complete session supersedes any half-joined older one (its tablet side already gave up).
            pending[session] = nil
            let stale = pending.values.flatMap { $0.values }
            pending.removeAll()
            lock.unlock()
            replaced?.close()
            evicted.forEach { $0.close() }
            stale.forEach { $0.close() }
            onGroup(LaneGroup((0..<count).map { lanes[$0]! }), nil)
        }
        thread.name = "join"
        thread.start()
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
            throw BridgeError.portBusy(port, errno)
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
    case portBusy(UInt16, Int32)
    case audio(String)

    var description: String {
        switch self {
        case .socket(let m), .audio(let m): return m
        case .portBusy(let port, let code): return "port \(port) is busy (errno \(code)); is another copy running?"
        }
    }
}
