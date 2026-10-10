import AudioToolbox
import CoreAudio
import Foundation

/// `--aec-selftest`: silent, offline check of EchoCanceller on synthetic signals (no audio device is
/// opened). The far end is the same 440 + 1000 + 2500 Hz mix plus noise; the simulated echo is that
/// signal 70 ms late through a short decaying room response; a 600 Hz near-end tone starts halfway.
/// Reports far-tone and near-tone levels in the last 3 s with the canceller off and on.
enum EchoSelfTest {
    static func run() -> String {
        let rate = 48_000, seconds = 10, frame = EchoCanceller.frame
        let total = rate * seconds
        var rng = SystemRandomNumberGenerator()
        var far = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / Double(rate)
            far[i] = Float(EchoTest.farTones.reduce(0) { $0 + 0.15 * sin(2 * .pi * $1 * t) })
                + Float.random(in: -0.05...0.05, using: &rng)
        }
        let delay = rate * 70 / 1000
        let room: [(Int, Float)] = [(0, 0.30), (37, -0.12), (151, 0.07), (433, -0.04), (977, 0.02)]
        var mic = [Int16](repeating: 0, count: total)
        for i in 0..<total {
            var v: Float = Float.random(in: -0.0003...0.0003, using: &rng)
            for (lag, gain) in room where i - delay - lag >= 0 { v += gain * far[i - delay - lag] }
            if i >= total / 2 { v += 0.03 * Float(sin(2 * .pi * EchoTest.nearTone * Double(i) / Double(rate))) }
            mic[i] = Int16(max(-32768, min(32767, (v * 32767).rounded())))
        }

        func levels(_ samples: [Int16]) -> [Double] {
            let tones = EchoTest.farTones + [EchoTest.nearTone]
            let start = total - rate * 3
            var power = [Double](repeating: 0, count: tones.count)
            var windows = 0
            var w = start
            while w + 480 <= total {
                let x = samples[w..<w + 480].map { Float($0) / 32768 }
                for (k, f) in tones.enumerated() { power[k] += EchoTest.goertzel(x, f) }
                windows += 1
                w += 480
            }
            return power.map { 10 * log10(max($0 / Double(windows), 1e-12)) }
        }

        let canceller = EchoCanceller()
        var processed = mic
        var stereo = [Float](repeating: 0, count: frame * 2)
        var offset = 0
        while offset + frame <= total {
            for i in 0..<frame { stereo[2 * i] = far[offset + i]; stereo[2 * i + 1] = far[offset + i] }
            canceller.pushReference(stereo, frames: frame)
            processed.withUnsafeMutableBufferPointer { canceller.process($0.baseAddress! + offset, count: frame, apply: true) }
            offset += frame
        }
        let before = levels(mic), after = levels(processed)
        var report = ""
        for (k, f) in (EchoTest.farTones + [EchoTest.nearTone]).enumerated() {
            report += String(format: "%@ %.0f Hz off=%.1f dB on=%.1f dB change=%.1f dB\n",
                             f == EchoTest.nearTone ? "near" : "far", f, before[k], after[k], after[k] - before[k])
        }
        return report
    }
}

/// `--echo-test <seconds>`: plays a steady 440 + 1000 + 2500 Hz mix into Tablet Audio (the Mac sound the
/// tablet speaker plays) and reports how loud each of those tones, and a 600 Hz tone played on the tablet
/// itself (the near-end talker), comes back on the Tablet Audio input. Levels cover the second half of the
/// run so an echo canceller has converged.
enum EchoTest {
    static let farTones: [Double] = [440, 1000, 2500]
    static let nearTone = 600.0

    static func run(seconds: Double) -> String {
        guard let device = AudioDevices.find(uid: Bridge.deviceUID) else { return "FAIL \(Bridge.deviceName) missing" }
        let lock = NSLock()
        let tones = farTones + [nearTone]
        var power = [Double](repeating: 0, count: tones.count)
        var windows = 0
        var phase = 0
        var window = [Float]()
        let start = Date()

        let output = OutputUnit(channels: 2) { out, frames, _ in
            for i in 0..<frames {
                let t = Double(phase + i) / 48_000
                let v = Float(farTones.reduce(0) { $0 + 0.15 * sin(2 * .pi * $1 * t) })
                out[2 * i] = v
                out[2 * i + 1] = v
            }
            phase += frames
        }
        let input = InputUnit(channels: 2) { samples, frames, _ in
            guard Date().timeIntervalSince(start) > seconds / 2 else { return }
            for i in 0..<frames {
                window.append(samples[2 * i])
                if window.count == 480 {
                    let p = tones.map { goertzel(window, $0) }
                    lock.lock()
                    for k in 0..<p.count { power[k] += p[k] }
                    windows += 1
                    lock.unlock()
                    window.removeAll(keepingCapacity: true)
                }
            }
        }
        do {
            try input.start(device: device)
            try output.start(device: device)
        } catch {
            return "FAIL \(error)"
        }
        Thread.sleep(forTimeInterval: seconds)
        output.stop()
        input.stop()
        lock.lock(); defer { lock.unlock() }
        guard windows > 0 else { return "FAIL no input" }
        var report = "windows=\(windows)\n"
        for (k, f) in tones.enumerated() {
            let db = 10 * log10(max(power[k] / Double(windows), 1e-12))
            report += String(format: "%@ %.0f Hz level=%.1f dB\n", f == nearTone ? "near" : "far", f, db)
        }
        return report
    }

    /// Mean-square amplitude of one frequency in a window (Goertzel).
    static func goertzel(_ x: [Float], _ freq: Double) -> Double {
        let w = 2 * Double.pi * freq / 48_000
        let c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s0 = Double(v) + c * s1 - s2
            s2 = s1
            s1 = s0
        }
        let p = s1 * s1 + s2 * s2 - c * s1 * s2
        return 2 * p / Double(x.count * x.count)
    }
}

/// `--loop-test <seconds>`: plays 1 kHz bursts into Tablet Audio (-> tablet speaker),
/// listens on Tablet Audio's input (<- tablet mic) and reports the acoustic round-trip delay.
enum LoopTest {
    static func run(seconds: Double) -> String {
        guard let device = AudioDevices.find(uid: Bridge.deviceUID) else {
            return "FAIL \(Bridge.deviceName) missing"
        }
        let outID = device, inID = device
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
        report += "\(Bridge.deviceName) input level during bursts=\(db(burstRms)) between bursts=\(db(quietRms))\n"
        report += "loop delays ms=\(delays.map { String(format: "%.1f", $0) }.joined(separator: ","))\n"
        report += "median loop delay=\(median.map { String(format: "%.1f ms", $0) } ?? "n/a")\n"
        report += delays.count * 2 >= max(emissions.count, 1) ? "PASS\n" : "FAIL not enough bursts detected\n"
        return report
    }
}
