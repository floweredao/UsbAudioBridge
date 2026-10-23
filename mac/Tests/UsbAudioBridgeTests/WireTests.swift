import XCTest
@testable import UsbAudioBridge

/// Framing shared with android/.../audio/Protocol.kt: [type: u8][length: u32 big-endian][payload].
final class WireTests: XCTestCase {
    func testSendWritesTypeThenBigEndianLengthThenPayload() {
        let (mac, tablet) = connectionPair()
        defer { mac.close(); tablet.close() }
        let payload = (0..<300).map { UInt8($0 % 251) }
        XCTAssertTrue(mac.send(Wire.audio, bytes: payload))
        XCTAssertEqual(readRaw(tablet.fd, 5), [Wire.audio, 0x00, 0x00, 0x01, 0x2C])
        XCTAssertEqual(readRaw(tablet.fd, 300), payload)
    }

    func testReadFrameDecodesWhatSendEncodes() {
        let (mac, tablet) = connectionPair()
        defer { mac.close(); tablet.close() }
        XCTAssertTrue(tablet.send(Wire.ping, bytes: [1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertTrue(tablet.send(Wire.pong, bytes: []))
        var buffer = [UInt8](repeating: 0, count: 4)
        let ping = mac.readFrame(into: &buffer)
        XCTAssertEqual(ping?.type, Wire.ping)
        XCTAssertEqual(ping?.length, 8)
        XCTAssertEqual(Array(buffer[0..<8]), [1, 2, 3, 4, 5, 6, 7, 8], "the buffer grows to fit the payload")
        let empty = mac.readFrame(into: &buffer)
        XCTAssertEqual(empty?.type, Wire.pong)
        XCTAssertEqual(empty?.length, 0)
    }

    func testLargestAllowedPayloadRoundTrips() {
        let (mac, tablet) = connectionPair()
        defer { mac.close(); tablet.close() }
        let payload = (0..<Wire.maxPayload).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 8) }
        // The socket buffer is smaller than the frame, so the writer needs its own thread.
        let sent = expectation(description: "sent")
        DispatchQueue.global().async {
            if tablet.send(Wire.audio, bytes: payload) { sent.fulfill() }
        }
        var buffer = [UInt8](repeating: 0, count: 16)
        let frame = mac.readFrame(into: &buffer)
        XCTAssertEqual(frame?.type, Wire.audio)
        XCTAssertEqual(frame?.length, Wire.maxPayload)
        XCTAssertTrue(buffer.prefix(Wire.maxPayload).elementsEqual(payload))
        wait(for: [sent], timeout: 5)
    }

    func testOversizedLengthIsRefused() {
        let (mac, tablet) = connectionPair()
        defer { mac.close(); tablet.close() }
        writeRaw(tablet.fd, [Wire.audio, 0x00, 0x01, 0x00, 0x01]) // maxPayload + 1
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertNil(mac.readFrame(into: &buffer))
    }

    func testLengthWithTheTopBitSetIsRefusedNotNegative() {
        // A Java int length that went negative arrives as 0x80000000 or more.
        let (mac, tablet) = connectionPair()
        defer { mac.close(); tablet.close() }
        writeRaw(tablet.fd, [Wire.audio, 0x80, 0x00, 0x00, 0x00])
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertNil(mac.readFrame(into: &buffer))
    }

    func testEndOfStreamInsideAFrameIsNotAFrame() {
        let (mac, tablet) = connectionPair()
        defer { mac.close() }
        writeRaw(tablet.fd, [Wire.audio, 0x00, 0x00, 0x00, 0x04, 0x11, 0x22])
        tablet.close()
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertNil(mac.readFrame(into: &buffer))

        let (mac2, tablet2) = connectionPair()
        defer { mac2.close() }
        writeRaw(tablet2.fd, [Wire.audio, 0x00])
        tablet2.close()
        XCTAssertNil(mac2.readFrame(into: &buffer))
    }

    func testSendAfterCloseFails() {
        let (mac, tablet) = connectionPair()
        defer { tablet.close() }
        mac.close()
        XCTAssertTrue(mac.closed)
        XCTAssertFalse(mac.send(Wire.ping, bytes: [0]))
        mac.close() // closing twice is harmless
    }

    func testAudioLanesSkipTheControlLaneOnlyWhenThereIsOne() {
        let pairs = (0..<3).map { _ in connectionPair() }
        defer { pairs.forEach { $0.mac.close(); $0.tablet.close() } }

        let legacy = LaneGroup([pairs[0].mac])
        XCTAssertTrue(legacy.control === pairs[0].mac)
        XCTAssertEqual(legacy.audio.map { ObjectIdentifier($0) }, [ObjectIdentifier(pairs[0].mac)])

        let joined = LaneGroup(pairs.map { $0.mac })
        XCTAssertTrue(joined.control === pairs[0].mac)
        XCTAssertEqual(joined.audio.map { ObjectIdentifier($0) }, pairs[1...].map { ObjectIdentifier($0.mac) })
    }
}
