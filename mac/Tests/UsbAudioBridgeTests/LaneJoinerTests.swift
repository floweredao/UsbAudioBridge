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

    func testAConnectionThatNeverAnswersHelloIsClosed() {
        let joiner = LaneJoiner(joinTimeout: 0.2) { _, _ in XCTFail("a silent connection must not become a group") }
        let pair = connectionPair()
        defer { pair.tablet.close() }
        joiner.accept(pair.mac)
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(pair.tablet.readFrame(into: &buffer)?.type, Wire.hello)
        XCTAssertTrue(peerClosed(pair.tablet, timeout: 2), "the helper hangs up on a connection that stays silent")
    }

    func testTheJoinDeadlineEndsOnceTheFirstFrameArrives() {
        let log = GroupLog()
        let grouped = expectation(description: "group")
        let joiner = LaneJoiner(joinTimeout: 0.2) { group, first in
            log.append(group, first)
            grouped.fulfill()
        }
        let pair = connectionPair()
        defer { pair.mac.close(); pair.tablet.close() }
        joiner.accept(pair.mac)
        XCTAssertTrue(pair.tablet.send(Wire.ping, bytes: [UInt8](repeating: 0, count: 8)))
        wait(for: [grouped], timeout: 2)

        // The deadline is the behaviour under test: a later read must outlast it.
        let later = expectation(description: "a frame sent after the deadline still arrives")
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 16)
            if log.all[0].group.lanes[0].readFrame(into: &buffer)?.type == Wire.audio { later.fulfill() }
        }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(pair.tablet.send(Wire.audio, bytes: [1, 2]))
        wait(for: [later], timeout: 2)
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

    /// A legacy app never sends JOIN, so a JOIN cut short is not one: taken as a legacy app it would
    /// replace the working link with a connection that carries no audio.
    func testATruncatedJoinIsClosedNotTakenForALegacyApp() {
        let joiner = LaneJoiner { _, _ in XCTFail("no group expected") }
        let (mac, tablet) = connectionPair()
        defer { mac.close(); tablet.close() }
        joiner.accept(mac)
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(tablet.readFrame(into: &buffer)?.type, Wire.hello)
        XCTAssertTrue(tablet.send(Wire.join, bytes: [0, 0, 0, 42, 0]))
        XCTAssertTrue(peerClosed(tablet))
    }

    func testLanesThatDisagreeOnTheLaneCountDoNotFormAGroup() {
        let log = GroupLog()
        let grouped = expectation(description: "group")
        let joiner = LaneJoiner { group, first in
            log.append(group, first)
            grouped.fulfill()
        }
        // Two connections claim lane 5 of 6. Whichever the joiner handles second replaces (closes) the
        // other, so an end-of-file on either means both JOINs were handled.
        let a = join(joiner, session: 7, lane: 5, count: 6)
        let b = join(joiner, session: 7, lane: 5, count: 6)
        XCTAssertTrue(peerClosedAny([a.tablet, b.tablet]))
        // Lane 0 now says the session has 2 lanes. Two lanes are pending, but lane 1 never joined:
        // handing over lanes 0 and 1 would need a lane that does not exist.
        let c = join(joiner, session: 7, lane: 0, count: 2)
        let d = join(joiner, session: 7, lane: 0, count: 2)
        XCTAssertTrue(peerClosedAny([c.tablet, d.tablet]))
        XCTAssertTrue(log.all.isEmpty)

        // A complete session still forms and closes what was left of the inconsistent one.
        let e0 = join(joiner, session: 8, lane: 0, count: 2)
        let e1 = join(joiner, session: 8, lane: 1, count: 2)
        defer { [a, b, c, d, e0, e1].forEach { $0.mac.close(); $0.tablet.close() } }
        wait(for: [grouped], timeout: 5)
        for lane in [a, b, c, d] { XCTAssertTrue(peerClosed(lane.tablet)) }
        let entries = log.all
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.group.lanes.map { ObjectIdentifier($0) }, [e0, e1].map { ObjectIdentifier($0.mac) })
    }

    /// The tablet gives up on a session whose lanes do not all open and starts a new one. Each attempt
    /// left its open lanes pending on the Mac until some session completed, so a tablet that kept failing
    /// (or anything else on the loopback port) could hold sockets until the helper ran out of them.
    func testHalfJoinedSessionsDoNotPileUp() {
        let log = GroupLog()
        let grouped = expectation(description: "group")
        let joiner = LaneJoiner { group, first in
            log.append(group, first)
            grouped.fulfill()
        }
        // Lane 0 joins twice per session: the second closes the first, which shows both JOINs were handled.
        var stale: [(mac: Connection, tablet: Connection)] = []
        for session in UInt32(1)...4 {
            let a = join(joiner, session: session, lane: 0, count: 2)
            let b = join(joiner, session: session, lane: 0, count: 2)
            XCTAssertTrue(peerClosedAny([a.tablet, b.tablet]))
            stale.append(a)
            stale.append(b)
        }
        // A fifth half-joined session closes the four before it.
        let next0 = join(joiner, session: 5, lane: 0, count: 2)
        for (i, lane) in stale.enumerated() {
            XCTAssertTrue(peerClosed(lane.tablet), "lane \(i) of the abandoned sessions is still open")
        }
        XCTAssertTrue(log.all.isEmpty)

        // The new session still completes.
        let next1 = join(joiner, session: 5, lane: 1, count: 2)
        defer { (stale + [next0, next1]).forEach { $0.mac.close(); $0.tablet.close() } }
        wait(for: [grouped], timeout: 5)
        let entries = log.all
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.group.lanes.map { ObjectIdentifier($0) }, [next0, next1].map { ObjectIdentifier($0.mac) })
    }
}
