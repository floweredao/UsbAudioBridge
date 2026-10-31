import Darwin
import Foundation
import XCTest
@testable import UsbAudioBridge

/// The menu switches while the tablet is linked over the USB accessory. That link is one connection for both
/// directions and the tablet never reconnects by itself, so a switch has to take effect on the live link.
final class AccessoryToggleTests: XCTestCase {
    private var savedMic: Any?
    private var savedSpeaker: Any?

    override func setUp() {
        savedMic = UserDefaults.standard.object(forKey: "micEnabled")
        savedSpeaker = UserDefaults.standard.object(forKey: "speakerEnabled")
    }

    override func tearDown() {
        restore(savedMic, "micEnabled")
        restore(savedSpeaker, "speakerEnabled")
    }

    private func restore(_ value: Any?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func link(mic: Bool, speaker: Bool) -> (bridge: Bridge, tablet: Connection) {
        UserDefaults.standard.set(mic, forKey: "micEnabled")
        UserDefaults.standard.set(speaker, forKey: "speakerEnabled")
        let bridge = Bridge()
        let pair = connectionPair()
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(pair.tablet.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        bridge.acceptAoa(pair.mac)
        return (bridge, pair.tablet)
    }

    /// 240 frames (5 ms) of mono audio, as the tablet sends them.
    private func sendAudio(_ tablet: Connection) {
        tablet.send(Wire.audio, bytes: [UInt8](repeating: 0x11, count: 480))
    }

    /// Answers true once the helper has replied to a PING on the same connection, which happens only after it
    /// has read every frame queued before it: the barrier that makes the assertions below deterministic.
    private func drained(_ tablet: Connection) -> Bool {
        tablet.send(Wire.ping, bytes: [UInt8](repeating: 0, count: 8))
        var buffer = [UInt8](repeating: 0, count: 256)
        while let frame = tablet.readFrame(into: &buffer) {
            if frame.type == Wire.pong { return true }
        }
        return false
    }

    func testTheMicSwitchTakesEffectOnALiveAccessoryLink() {
        let (bridge, tablet) = link(mic: true, speaker: true)

        sendAudio(tablet)
        XCTAssertTrue(drained(tablet), "the helper answers PINGs over the accessory link")
        XCTAssertEqual(bridge.micRing.available, 240, "audio is kept while the switch is on")

        bridge.micEnabled = false
        sendAudio(tablet)
        XCTAssertTrue(drained(tablet), "switching the mic off leaves the accessory link up")
        XCTAssertEqual(bridge.micRing.available, 0, "audio is dropped while the switch is off")

        bridge.micEnabled = true
        sendAudio(tablet)
        XCTAssertTrue(drained(tablet), "switching the mic on leaves the accessory link up")
        XCTAssertEqual(bridge.micRing.available, 240, "the switch going back on makes the reader keep audio again")
    }

    func testTheSpeakerSwitchUsesTheLinkThatIsAlreadyUp() {
        let (bridge, tablet) = link(mic: true, speaker: false)
        XCTAssertTrue(drained(tablet), "the link is up with the speaker switch off")

        bridge.speakerEnabled = true
        XCTAssertTrue(bridge.stats.speakerConnected, "the speaker switch going on uses the accessory link")
    }

    func testSwitchingTheSpeakerOffKeepsTheMicRunning() {
        let (bridge, tablet) = link(mic: true, speaker: true)

        bridge.speakerEnabled = false
        sendAudio(tablet)
        XCTAssertTrue(drained(tablet), "the accessory link survives the speaker switch")
        XCTAssertEqual(bridge.micRing.available, 240, "the mic keeps streaming while the speaker is off")
    }
}
