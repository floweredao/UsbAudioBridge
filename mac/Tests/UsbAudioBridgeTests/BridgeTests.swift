import XCTest
@testable import UsbAudioBridge

/// The tablet mic path (jitter buffer and mono -> stereo) and PING/PONG handling. No audio device is opened.
final class BridgeTests: XCTestCase {
    private func feed(_ bridge: Bridge, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { bridge.micRing.write($0.baseAddress!, samples.count) }
    }

    private func feed(_ bridge: Bridge, _ count: Int, value: Float = 0.5) {
        feed(bridge, [Float](repeating: value, count: count))
    }

    /// One 128-frame device callback; returns the interleaved stereo it rendered.
    private func render(_ bridge: Bridge, frames: Int = 128) -> [Float] {
        var out = [Float](repeating: .nan, count: frames * 2)
        out.withUnsafeMutableBufferPointer { bridge.renderMic($0.baseAddress!, frames) }
        return out
    }

    func testSilentUntil15msIsQueued() {
        let bridge = Bridge()
        feed(bridge, 719)
        XCTAssertEqual(render(bridge), [Float](repeating: 0, count: 256))
        XCTAssertEqual(bridge.micRing.available, 719, "nothing is consumed before playback starts")
    }

    func testPlaysMonoOnBothChannelsInOrder() {
        let bridge = Bridge()
        let ramp = (0..<720).map { Float($0) / 1024 }
        feed(bridge, ramp)
        let out = render(bridge)
        for i in 0..<128 {
            XCTAssertEqual(out[2 * i], ramp[i])
            XCTAssertEqual(out[2 * i + 1], ramp[i])
        }
        XCTAssertEqual(bridge.micRing.available, 720 - 128)
    }

    func testAnUnderrunPadsWithSilenceAndWaitsTo15msAgain() {
        let bridge = Bridge()
        feed(bridge, 720)
        for _ in 0..<5 { _ = render(bridge) }
        let out = render(bridge) // 80 frames left
        XCTAssertEqual(Array(out[0..<160]), [Float](repeating: 0.5, count: 160))
        XCTAssertEqual(Array(out[160...]), [Float](repeating: 0, count: 96))
        feed(bridge, 600)
        XCTAssertEqual(render(bridge), [Float](repeating: 0, count: 256))
        feed(bridge, 120)
        XCTAssertEqual(render(bridge), [Float](repeating: 0.5, count: 256))
    }

    func testMoreThan45msQueuedIsCutBackTo15ms() {
        let bridge = Bridge()
        feed(bridge, 3000)
        XCTAssertEqual(render(bridge), [Float](repeating: 0.5, count: 256))
        XCTAssertEqual(bridge.micRing.available, 720 - 128)
    }

    func testASecondThatNeverDrainsIsTrimmedTo5ms() {
        let bridge = Bridge()
        feed(bridge, 1500)
        // The tablet delivers exactly what is played, so 1628 frames sit queued for a whole second.
        for _ in 0..<375 {
            feed(bridge, 128)
            XCTAssertEqual(render(bridge), [Float](repeating: 0.5, count: 256))
        }
        XCTAssertEqual(bridge.micRing.available, 240 - 128)
    }

    func testABurstAtTheEndOfTheTrimWindowDoesNotEmptyTheQueue() {
        let bridge = Bridge()
        feed(bridge, 1500)
        for _ in 0..<374 {
            feed(bridge, 128)
            _ = render(bridge)
        }
        // A late bunch of packets arrives just as the one-second window closes: the 45 ms cap cuts the queue
        // back to 15 ms, and the window trim must then work from that, not from what was there before.
        feed(bridge, 128 + 700)
        XCTAssertEqual(render(bridge), [Float](repeating: 0.5, count: 256), "the mic dropped out")
        XCTAssertEqual(bridge.micRing.available, 240 - 128)
    }

    func testPingIsAnsweredWithTheSamePayload() {
        let bridge = Bridge()
        let (mac, tablet) = connectionPair()
        defer { mac.close(); tablet.close() }
        let payload: [UInt8] = [0x00, 0x00, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC]
        bridge.handleControl(Wire.ping, payload, payload.count, mac)
        var buffer = [UInt8](repeating: 0, count: 16)
        let frame = tablet.readFrame(into: &buffer)
        XCTAssertEqual(frame?.type, Wire.pong)
        XCTAssertEqual(frame.map { Array(buffer[0..<$0.length]) }, payload)
    }

    /// The PING timestamp is the Mac's 64-bit uptime in nanoseconds, which passes 2^32 after 4.3 s; a
    /// 32-bit timestamp would give a nonsense round trip from then on.
    func testPongRoundTripUsesTheWhole64BitTimestamp() throws {
        let bridge = Bridge()
        let (mac, tablet) = connectionPair()
        defer { mac.close(); tablet.close() }
        let now = DispatchTime.now().uptimeNanoseconds
        try XCTSkipIf(now < (1 << 32) + 5_000_000, "uptime still below 2^32 ns")
        let sent = now - 5_000_000
        let payload = withUnsafeBytes(of: sent.bigEndian) { Array($0) }
        bridge.handleControl(Wire.pong, payload, payload.count, mac)
        let rtt = try XCTUnwrap(bridge.stats.rttMs)
        XCTAssertGreaterThanOrEqual(rtt, 5)
        XCTAssertLessThan(rtt, 1_000)
    }

    func testShortPongIsIgnored() {
        let bridge = Bridge()
        let (mac, tablet) = connectionPair()
        defer { mac.close(); tablet.close() }
        bridge.handleControl(Wire.pong, [1, 2, 3], 3, mac)
        XCTAssertNil(bridge.stats.rttMs)
    }

    /// A PONG echoes a PING timestamp, which is never ahead of the Mac's clock. One that is (garbage from
    /// the tablet) used to wrap the unsigned difference and show a round trip of about 585 years.
    func testPongWithATimestampAheadOfTheClockIsIgnored() {
        let bridge = Bridge()
        let (mac, tablet) = connectionPair()
        defer { mac.close(); tablet.close() }
        let ahead: UInt64 = DispatchTime.now().uptimeNanoseconds + 3_600_000_000_000
        let payload = withUnsafeBytes(of: ahead.bigEndian) { Array($0) }
        bridge.handleControl(Wire.pong, payload, payload.count, mac)
        XCTAssertNil(bridge.stats.rttMs)
    }
}
