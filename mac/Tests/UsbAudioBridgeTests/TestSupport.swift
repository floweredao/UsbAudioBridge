import Darwin
import Foundation
@testable import UsbAudioBridge

/// Two connected sockets: `mac` plays the helper's end, `tablet` the Android app's end.
func connectionPair() -> (mac: Connection, tablet: Connection) {
    var fds: [Int32] = [0, 0]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socketpair failed: \(errno)")
    var one: Int32 = 1
    for fd in fds { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }
    return (Connection(fd: fds[0]), Connection(fd: fds[1]))
}

func writeRaw(_ fd: Int32, _ bytes: [UInt8]) {
    bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
            precondition(n > 0, "write failed: \(errno)")
            offset += n
        }
    }
}

func readRaw(_ fd: Int32, _ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
        let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
        if n <= 0 { break }
        offset += n
    }
    return Array(bytes[0..<offset])
}

/// True once any of the connections reads end-of-file (the other end closed it) within `timeout`.
/// Only for connections with nothing left to read: pending data would also count as readable.
func peerClosedAny(_ connections: [Connection], timeout: TimeInterval = 2) -> Bool {
    var fds = connections.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
    guard poll(&fds, nfds_t(fds.count), Int32(timeout * 1000)) > 0 else { return false }
    for (i, p) in fds.enumerated() where p.revents != 0 {
        var byte: UInt8 = 0
        if Darwin.read(connections[i].fd, &byte, 1) == 0 { return true }
    }
    return false
}

func peerClosed(_ connection: Connection, timeout: TimeInterval = 2) -> Bool {
    peerClosedAny([connection], timeout: timeout)
}

/// Thread-safe log of the groups a LaneJoiner hands over.
final class GroupLog {
    private let lock = NSLock()
    private var entries: [(group: LaneGroup, first: (type: UInt8, payload: [UInt8])?)] = []

    func append(_ group: LaneGroup, _ first: (type: UInt8, payload: [UInt8])?) {
        lock.lock(); defer { lock.unlock() }
        entries.append((group, first))
    }

    var all: [(group: LaneGroup, first: (type: UInt8, payload: [UInt8])?)] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}
