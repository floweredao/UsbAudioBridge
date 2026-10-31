import XCTest
@testable import UsbAudioBridge

final class LogTests: XCTestCase {
    private func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? -1
    }

    func testTheLogMovesAsideOnceItWouldPassTheLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uab-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("helper.log")
        let line = String(repeating: "x", count: 99) + "\n"

        for _ in 0..<25 { Log.append(line, to: url, maxBytes: 1000) }

        // Lines 1-10 fill the first file, 11-20 the second (the first is dropped), 21-25 the current one.
        XCTAssertEqual(size(url), 500, "the current log holds only what came after the last move")
        XCTAssertEqual(size(url.appendingPathExtension("1")), 1000, "one previous log is kept")
    }
}
