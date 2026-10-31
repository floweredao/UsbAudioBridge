import XCTest
@testable import UsbAudioBridge

final class AudioHealthTests: XCTestCase {
    func testAudioStartsOnlyOnceTheDriverPortExists() {
        XCTAssertEqual(AudioHealth.action(startedOn: nil, port: nil, rendersSinceCheck: 0), .missing)
        XCTAssertEqual(AudioHealth.action(startedOn: nil, port: 42, rendersSinceCheck: 0), .start)
    }

    func testRunningAudioIsLeftAloneWhileItRenders() {
        XCTAssertEqual(AudioHealth.action(startedOn: 42, port: 42, rendersSinceCheck: 750), .none)
    }

    func testAudioRestartsWhenCoreAudioStopsDrivingIt() {
        XCTAssertEqual(AudioHealth.action(startedOn: 42, port: 42, rendersSinceCheck: 0), .restart)
    }

    func testAudioRestartsWhenThePortGoesAwayOrChanges() {
        XCTAssertEqual(AudioHealth.action(startedOn: 42, port: nil, rendersSinceCheck: 750), .restart)
        XCTAssertEqual(AudioHealth.action(startedOn: 42, port: 57, rendersSinceCheck: 750), .restart)
    }
}
