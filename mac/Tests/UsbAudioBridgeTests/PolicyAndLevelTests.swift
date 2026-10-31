import XCTest
@testable import UsbAudioBridge

final class DefaultKeeperPolicyTests: XCTestCase {
    private let tablet = "UsbAudioBridge.TabletAudio"
    private let speaker = "speaker:output"
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testRecordedSituationsOfTheBuiltInSelfTest() {
        let report = DefaultKeeperSelfTest.run()
        XCTAssertFalse(report.contains("FAIL"), report)
    }

    /// Classifies a switch to the speaker at 110 s, given when a device last appeared.
    private func classify(arrival: TimeInterval) -> DefaultKeeperPolicy.Action {
        var p = DefaultKeeperPolicy(tabletUID: tablet, keep: true, lastSeen: tablet)
        XCTAssertEqual(p.step(current: speaker, now: at(110), lastArrival: at(arrival), linked: true), .none)
        return p.step(current: speaker, now: at(113), lastArrival: at(arrival), linked: true)
    }

    func testArrivalWindowEdges() {
        XCTAssertEqual(classify(arrival: 100), .automaticSwitch, "a device appeared 10 s before")
        XCTAssertEqual(classify(arrival: 99), .released, "a device appeared 11 s before")
        XCTAssertEqual(classify(arrival: 113), .automaticSwitch, "a device appeared 3 s after")
    }

    func testWaits3sBeforeDecidingAndRetriesARestoreEvery5s() {
        var p = DefaultKeeperPolicy(tabletUID: tablet, keep: true, lastSeen: tablet)
        XCTAssertEqual(p.step(current: speaker, now: at(101), lastArrival: at(100), linked: true), .none)
        XCTAssertEqual(p.step(current: speaker, now: at(103.9), lastArrival: at(100), linked: true), .none)
        XCTAssertEqual(p.step(current: speaker, now: at(104), lastArrival: at(100), linked: true), .automaticSwitch)
        XCTAssertEqual(p.step(current: speaker, now: at(105), lastArrival: at(100), linked: true), .restore)
        XCTAssertEqual(p.step(current: speaker, now: at(109.9), lastArrival: at(100), linked: true), .none)
        XCTAssertEqual(p.step(current: speaker, now: at(110), lastArrival: at(100), linked: true), .restore)
    }
}

final class SwitchGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testARefusedReadinessCheckWaitsBeforeRunningAgain() {
        var gate = AoaTransport.SwitchGate()
        var checks = 0
        for second in 0..<60 {
            let switched = gate.shouldSwitch(now: t0.addingTimeInterval(TimeInterval(second)), wait: 5) { checks += 1; return false }
            XCTAssertFalse(switched)
        }
        XCTAssertEqual(checks, 6, "one adb readiness check per 10 s, not one per 1 s poll")
    }

    func testAnAcceptedCheckSwitchesOnceThenWaitsTheRetryInterval() {
        var gate = AoaTransport.SwitchGate()
        let switches = (0..<60).filter { gate.shouldSwitch(now: t0.addingTimeInterval(TimeInterval($0)), wait: 25) { true } }
        XCTAssertEqual(switches, [0, 26, 52])
    }
}

final class IdleRelaunchTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Seconds (polled every 2 s over 60 s) at which the app would be relaunched.
    private func relaunches(streaming: Bool = false, wantsAudio: Bool) -> [Int] {
        var idle = AdbWatcher.IdleRelaunch()
        return stride(from: 0, through: 60, by: 2).filter {
            idle.due(streaming: streaming, wantsAudio: wantsAudio, now: t0.addingTimeInterval(TimeInterval($0)))
        }
    }

    func testAnIdleAppIsRelaunchedAfter10sAndThenEvery15s() {
        XCTAssertEqual(relaunches(wantsAudio: true), [12, 28, 44, 60])
    }

    func testNothingIsRelaunchedWhileStreaming() {
        XCTAssertEqual(relaunches(streaming: true, wantsAudio: true), [])
    }

    func testNothingIsRelaunchedWhileBothSwitchesAreOff() {
        XCTAssertEqual(relaunches(wantsAudio: false), [])
    }
}

final class LevelAndEchoTests: XCTestCase {
    private func level(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { levelDb($0.baseAddress!, samples.count) }
    }

    func testLevelDb() {
        var unused: Float = 1
        XCTAssertEqual(levelDb(&unused, 0), -90)
        XCTAssertEqual(level([Float](repeating: 0, count: 480)), -90)
        XCTAssertEqual(level([Float](repeating: 1, count: 480)), 0, accuracy: 0.001)
        XCTAssertEqual(level([Float](repeating: -0.5, count: 480)), -6.02, accuracy: 0.01)
        let sine = (0..<480).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
        XCTAssertEqual(level(sine), -3.01, accuracy: 0.01)
    }

    func testEchoCancellerLeavesSamplesAloneUnlessApplied() {
        let canceller = EchoCanceller()
        let reference = (0..<480).map { Float(sin(Double($0) / 7)) * 0.3 }
        reference.withUnsafeBufferPointer { canceller.pushReference($0.baseAddress!, frames: 240) }
        let mic = (0..<250).map { Int16(truncatingIfNeeded: $0 &* 97) }
        var samples = mic
        samples.withUnsafeMutableBufferPointer { canceller.process($0.baseAddress!, count: $0.count, apply: false) }
        XCTAssertEqual(samples, mic)
    }

    func testEchoCancellerOnlyTouchesWhole5msFrames() {
        let canceller = EchoCanceller()
        let mic = (0..<250).map { Int16(truncatingIfNeeded: $0 &* 97) }
        var samples = mic
        samples.withUnsafeMutableBufferPointer { canceller.process($0.baseAddress!, count: $0.count, apply: true) }
        XCTAssertEqual(Array(samples[240...]), Array(mic[240...]), "the 10 samples past the last whole frame stay")
    }
}
