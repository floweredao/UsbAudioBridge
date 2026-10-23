import XCTest
@testable import UsbAudioBridge

final class FloatRingTests: XCTestCase {
    private func write(_ ring: FloatRing, _ values: [Float]) {
        guard !values.isEmpty else { return }
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, values.count) }
    }

    private func read(_ ring: FloatRing, _ n: Int) -> [Float] {
        guard n > 0 else { return [] }
        var out = [Float](repeating: .nan, count: n)
        let got = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, n) }
        return Array(out[0..<got])
    }

    func testReadsInWriteOrderAcrossTheEndOfStorage() {
        let ring = FloatRing(capacity: 7)
        var next: Float = 0
        var expected: Float = 0
        for _ in 0..<50 {
            write(ring, (0..<5).map { _ -> Float in defer { next += 1 }; return next })
            for value in read(ring, 3) {
                XCTAssertEqual(value, expected)
                expected += 1
            }
            for value in read(ring, 2) {
                XCTAssertEqual(value, expected)
                expected += 1
            }
        }
        XCTAssertEqual(ring.available, 0)
    }

    func testReadReturnsOnlyWhatIsQueued() {
        let ring = FloatRing(capacity: 8)
        write(ring, [1, 2, 3])
        XCTAssertEqual(read(ring, 5), [1, 2, 3])
        XCTAssertEqual(read(ring, 5), [])
    }

    func testOverflowDropsTheOldestSamples() {
        let ring = FloatRing(capacity: 4)
        write(ring, [1, 2, 3])
        write(ring, [4, 5, 6])
        XCTAssertEqual(ring.available, 4)
        XCTAssertEqual(read(ring, 4), [3, 4, 5, 6])
    }

    func testOneWriteLargerThanTheCapacityKeepsItsNewestSamples() {
        let ring = FloatRing(capacity: 4)
        write(ring, [9])
        _ = read(ring, 1)
        write(ring, (1...10).map { Float($0) })
        XCTAssertEqual(read(ring, 10), [7, 8, 9, 10])
    }

    func testDiscardAndClear() {
        let ring = FloatRing(capacity: 6)
        write(ring, [1, 2, 3, 4, 5])
        ring.discard(2)
        XCTAssertEqual(read(ring, 1), [3])
        ring.discard(100)
        XCTAssertEqual(ring.available, 0)
        write(ring, [6, 7])
        ring.clear()
        XCTAssertEqual(ring.available, 0)
        write(ring, [8])
        XCTAssertEqual(read(ring, 2), [8])
    }

    /// The ring keeps no running sample count, only positions within its storage, so it has nothing that
    /// can wrap after hours of audio. Many laps of random-sized reads and writes stay in order.
    func testStaysInOrderOverManyLapsAgainstAPlainQueue() {
        let ring = FloatRing(capacity: 9600)
        var model: [Float] = []
        var head = 0
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func random(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % bound
        }
        var next: Float = 0
        for _ in 0..<5_000 {
            let w = random(700)
            let values = (0..<w).map { _ -> Float in
                next = next >= 1_000_000 ? 0 : next + 1
                return next
            }
            write(ring, values)
            model.append(contentsOf: values)
            if model.count - head > 9600 { head = model.count - 9600 }
            XCTAssertEqual(ring.available, model.count - head)
            let got = read(ring, random(700))
            XCTAssertEqual(got, Array(model[head..<head + got.count]))
            head += got.count
        }
    }
}
