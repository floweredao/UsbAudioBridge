import AudioToolbox
import CoreAudio
import Foundation

/// `--loop-test <seconds>`: plays 1 kHz bursts into BlackHole 16ch (-> tablet speaker),
/// listens on BlackHole 2ch (<- tablet mic) and reports the acoustic round-trip delay.
enum LoopTest {
    static func run(seconds: Double) -> String {
        guard let outID = AudioDevices.find(Bridge.speakerDeviceName), let inID = AudioDevices.find(Bridge.micDeviceName) else {
            return "FAIL devices missing"
        }
        let lock = NSLock()
        var emissions: [UInt64] = []
        var detections: [UInt64] = []
        var burstRms: [Float] = []
        var quietRms: [Float] = []
        let period = 48_000
        let burst = 2_400 // 50 ms
        var phase = 0
        var lastDetect: UInt64 = 0
        let nsPerFrame = 1_000_000_000.0 / 48_000

        let output = OutputUnit(channels: 2) { out, frames, hostTime in
            let baseNs = AudioConvertHostTimeToNanos(hostTime)
            for i in 0..<frames {
                let p = (phase + i) % period
                if p == 0 {
                    lock.lock(); emissions.append(baseNs + UInt64(Double(i) * nsPerFrame)); lock.unlock()
                }
                var v: Float = 0
                if p < burst {
                    let fade = min(1, Float(min(p, burst - p)) / 96)
                    v = 0.5 * fade * sin(2 * .pi * 1000 * Float(p) / 48_000)
                }
                out[2 * i] = v
                out[2 * i + 1] = v
            }
            phase = (phase + frames) % period
        }
        let input = InputUnit(channels: 2) { samples, frames, hostTime in
            let baseNs = AudioConvertHostTimeToNanos(hostTime)
            var sum: Float = 0
            for i in 0..<frames {
                let s = samples[2 * i]
                sum += s * s
                if abs(s) > 0.02 {
                    let t = baseNs + UInt64(Double(i) * nsPerFrame)
                    lock.lock()
                    if t > lastDetect + 500_000_000 { detections.append(t); lastDetect = t }
                    lock.unlock()
                }
            }
            let rms = (sum / Float(max(frames, 1))).squareRoot()
            lock.lock()
            let inBurst = emissions.last.map { baseNs >= $0 && baseNs < $0 + 400_000_000 } ?? false
            if inBurst { burstRms.append(rms) } else { quietRms.append(rms) }
            lock.unlock()
        }
        do {
            try input.start(device: inID)
            try output.start(device: outID)
        } catch {
            return "FAIL \(error)"
        }
        Thread.sleep(forTimeInterval: seconds)
        output.stop()
        input.stop()

        lock.lock(); defer { lock.unlock() }
        var delays: [Double] = []
        for e in emissions {
            if let d = detections.first(where: { $0 >= e && $0 < e + 800_000_000 }) {
                delays.append(Double(d - e) / 1_000_000)
            }
        }
        func db(_ xs: [Float]) -> String {
            guard !xs.isEmpty else { return "n/a" }
            let mean = xs.map { $0 * $0 }.reduce(0, +) / Float(xs.count)
            return String(format: "%.1f dBFS", 20 * log10(max(mean.squareRoot(), 0.0000316)))
        }
        let sorted = delays.sorted()
        let median = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        var report = "bursts=\(emissions.count) detected=\(delays.count)\n"
        report += "BlackHole 2ch level during bursts=\(db(burstRms)) between bursts=\(db(quietRms))\n"
        report += "loop delays ms=\(delays.map { String(format: "%.1f", $0) }.joined(separator: ","))\n"
        report += "median loop delay=\(median.map { String(format: "%.1f ms", $0) } ?? "n/a")\n"
        report += delays.count * 2 >= max(emissions.count, 1) ? "PASS\n" : "FAIL not enough bursts detected\n"
        return report
    }
}
