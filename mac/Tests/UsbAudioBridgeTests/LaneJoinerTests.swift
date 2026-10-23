import XCTest
@testable import UsbAudioBridge

final class LaneJoinerTests: XCTestCase {
    /// Opens one lane the way Protocol.kt's openLanes does: wait for HELLO, then send JOIN.
    private func join(_ joiner: LaneJoiner, session: UInt32, lane: Int, count: Int) -> (mac: Connection, tablet: Connection) {
        let pair = connectionPair()
        joiner.accept(pair.mac)
        var buffer = [UInt8](repeating: 0, count: 16)
        let hello = pair.tablet.readFrame(into: &buffer)
        XCTAssertEqual(hello?.type, Wire.hello)
        XCTAssertEqual(hello.map { Array(buffer[0..<$0.length]) }, Wire.helloMagic)
        let sessionBytes = withUnsafeBytes(of: session.bigEndian) { Array($0) }
        XCTAssertTrue(pair.tablet.send(Wire.join, bytes: sessionBytes + [UInt8(lane), UInt8(count)]))
        return pair
    }

    func testLanesFormOneGroupInLaneOrderWhateverOrderTheyJoin() {
        let log = GroupLog()
        let grouped = expectation(description: "group")
        let joiner = LaneJoiner { group, first in
            log.append(group, first)
            grouped.fulfill()
        }
        // Kotlin's Random.nextInt() is often negative: the session then has its top bit set.
        let session: UInt32 = 0x8000_0001
        let lane2 = join(joiner, session: session, lane: 2, count: 3)
        let lane0 = join(joiner, session: session, lane: 0, count: 3)
        let lane1 = join(joiner, session: session, lane: 1, count: 3)
        defer { [lane0, lane1, lane2].forEach { $0.mac.close(); $0.tablet.close() } }
        wait(for: [grouped], timeout: 5)

        let entries = log.all
        XCTAssertEqual(entries.count, 1)
        let group = entries[0].group
        XCTAssertEqual(group.lanes.map { ObjectIdentifier($0) }, [lane0, lane1, lane2].map { ObjectIdentifier($0.mac) })
        XCTAssertNil(entries[0].first)
    }

    func testAnAppWithoutJoinBecomesAOneLaneGroupWithItsFirstFrame() {
        let log = GroupLog()
        let grouped = expectation(description: "group")
        let joiner = LaneJoiner { group, first in
            log.append(group, first)
            grouped.fulfill()
        }
        let (mac, tablet) = connectionPair()
        defer { mac.close(); tablet.close() }
        joiner.accept(mac)
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(tablet.readFrame(into: &buffer)?.type, Wire.hello)
        XCTAssertTrue(tablet.send(Wire.audio, bytes: [1, 2, 3, 4]))
        wait(for: [grouped], timeout: 5)

        let entry = log.all[0]
        XCTAssertEqual(entry.group.lanes.count, 1)
        XCTAssertTrue(entry.group.lanes[0] === mac)
        XCTAssertEqual(entry.first?.type, Wire.audio)
        XCTAssertEqual(entry.first?.payload, [1, 2, 3, 4])
    }

    func testJoinWithAnImpossibleLaneCountIsClosed() {
        let joiner = LaneJoiner { _, _ in XCTFail("no group expected") }
        for (lane, count) in [(0, 1), (0, 17), (3, 3)] {
            let pair = join(joiner, session: 42, lane: lane, count: count)
            XCTAssertTrue(peerClosed(pair.tablet), "lane \(lane) of \(count) should be refused")
            pair.mac.close()
            pair.tablet.close()
        }
    }
}
