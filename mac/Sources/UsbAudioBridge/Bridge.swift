import CoreAudio
import Foundation

/// Moves audio between the tablet sockets and the Tablet Audio driver's hidden bridge port.
final class Bridge {
    struct Stats {
        var micConnected = false
        var speakerConnected = false
        var micLevelDb: Float = -90
        var speakerLevelDb: Float = -90
        var rttMs: Double?
        var micBufferMs: Double = 0
        var audioError: String?
        var micMaxGapMs: Double = 0
        var echoCancelling = false
        var echoMicrosPerFrame: Double = 0
        var speakerDropped = 0
    }

    static let deviceName = "Tablet Audio"  // Mac apps play to and record from this
    static let deviceUID = "UsbAudioBridge.TabletAudio"
    // Hidden twin of Tablet Audio: its input carries what apps play, its output feeds what apps record.
    static let portUID = "UsbAudioBridge.TabletAudio.BridgePort"

    private let lock = NSLock()
    private let echo = EchoCanceller()
    private var echoApply = false
    private var micConn: LaneGroup?
    private var speakerConn: LaneGroup?
    private var _stats = Stats()

    var micEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "micEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "micEnabled")
            if !newValue { swapMic(nil) }
        }
    }

    var speakerEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "speakerEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "speakerEnabled")
            if !newValue { swapSpeaker(nil) }
        }
    }

    // Tablet mic, mono, 200 ms max. Playback starts once 15 ms is queued and trims back when it exceeds 45 ms.
    private let micRing = FloatRing(capacity: 9600)
    private let micTarget = 720
    private let micMax = 2160
    private var micPrimed = false
    private var micWindowMin = Int.max
    private var micWindowFrames = 0
    private let mono = UnsafeMutablePointer<Float>.allocate(capacity: 8192)

    // Mac output (Tablet Audio, via the bridge port input), interleaved stereo, 100 ms max.
    private let speakerRing = FloatRing(capacity: 9600)
    private let speakerSignal = DispatchSemaphore(value: 0)

    // 128-frame (2.7 ms) device I/O on both port directions; the loop test keeps 256 to stay comparable.
    private lazy var output = OutputUnit(channels: 2, bufferFrames: 128) { [unowned self] out, frames, _ in self.renderMic(out, frames) }
    private lazy var input = InputUnit(channels: 2, bufferFrames: 128) { [unowned self] samples, frames, _ in self.captureSpeaker(samples, frames) }

    var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        var s = _stats
        s.micConnected = micConn != nil
        s.speakerConnected = speakerConn != nil
        s.micBufferMs = Double(micRing.available) / 48
        s.echoCancelling = echoApply
        return s
    }

    func start() throws {
        let micJoiner = LaneJoiner { [unowned self] group, first in self.acceptMic(group, first) }
        let speakerJoiner = LaneJoiner { [unowned self] group, _ in self.acceptSpeaker(group) }
        try Server(port: Wire.micPort) { conn in micJoiner.accept(conn) }.start()
        try Server(port: Wire.speakerPort) { conn in speakerJoiner.accept(conn) }.start()
        startAudio()
        startThread("speaker-send") { [unowned self] in self.sendLoop() }
        startThread("pinger") { [unowned self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                var now = DispatchTime.now().uptimeNanoseconds.bigEndian
                let bytes = withUnsafeBytes(of: &now) { Array($0) }
                self.current(\.micConn)?.control.send(Wire.ping, bytes: bytes)
                self.current(\.speakerConn)?.control.send(Wire.ping, bytes: bytes)
            }
        }
        startThread("echo-gate") { [unowned self] in
            while true {
                let apply = EchoGate.shouldApply(tabletAudio: AudioDevices.find(uid: Self.deviceUID))
                if apply != self.echoApply {
                    self.echoApply = apply
                    Log.info("echo cancellation \(apply ? "on" : "off") (mode \(EchoGate.mode))")
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        startThread("stats-log") { [unowned self] in
            while true {
                Thread.sleep(forTimeInterval: 5)
                let s = self.stats
                guard s.micConnected || s.speakerConnected else { continue }
                self.lock.lock(); self._stats.micMaxGapMs = 0; self.lock.unlock()
                Log.info(String(format: "stats mic=%@ level=%.1fdB buf=%.0fms maxGap=%.0fms speaker=%@ level=%.1fdB rtt=%@ aec=%@ aecCost=%.0fus spkDrop=%d",
                                s.micConnected ? "on" : "off", s.micLevelDb, s.micBufferMs, s.micMaxGapMs,
                                s.speakerConnected ? "on" : "off", s.speakerLevelDb,
                                s.rttMs.map { String(format: "%.1fms", $0) } ?? "-", s.echoCancelling ? "on" : "off", s.echoMicrosPerFrame, s.speakerDropped))
            }
        }
    }

    private func startAudio() {
        do {
            guard let port = AudioDevices.find(uid: Self.portUID) else {
                throw BridgeError.audio("\(Self.deviceName) driver is not installed (driver/install.sh)")
            }
            try output.start(device: port)
            try input.start(device: port)
            Log.info("audio started: tablet mic -> \(Self.deviceName) input, \(Self.deviceName) output -> tablet speaker")
        } catch {
            Log.info("audio error: \(error)")
            lock.lock(); _stats.audioError = "\(error)"; lock.unlock()
        }
    }

    // MARK: connections

    private func current(_ key: ReferenceWritableKeyPath<Bridge, LaneGroup?>) -> LaneGroup? {
        lock.lock(); defer { lock.unlock() }
        return self[keyPath: key]
    }

    private func swapMic(_ conn: LaneGroup?) {
        lock.lock(); let old = micConn; micConn = conn; lock.unlock()
        old?.close()
        micRing.clear()
        echo.reset()
    }

    private func swapSpeaker(_ conn: LaneGroup?) {
        lock.lock(); let old = speakerConn; speakerConn = conn; lock.unlock()
        old?.close()
        speakerRing.clear()
    }

    /// AOA carries both directions on one connection, so its single reader (the mic thread) also answers
    /// the PINGs that keep the speaker side alive, and keeps reading even while the mic is switched off.
    func acceptAoa(_ conn: Connection) {
        let group = LaneGroup([conn])
        swapSpeaker(speakerEnabled ? group : nil)
        acceptMic(group, nil, viaAccessory: true)
    }

    private func acceptMic(_ group: LaneGroup, _ first: (type: UInt8, payload: [UInt8])?, viaAccessory: Bool = false) {
        let keepAudio = micEnabled
        guard keepAudio || viaAccessory else { group.close(); return }
        swapMic(group)
        Log.info(viaAccessory ? "tablet linked over USB accessory (mic + speaker)" : "tablet mic connected (\(group.lanes.count) lanes)")
        if group.lanes.count > 1 { watchControl(group, "mic-ctl") }
        startThread("mic-read") { [unowned self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: Wire.maxPayload / 2)
            defer { samples.deallocate() }
            var peak: Float = -90
            var lastUi = DispatchTime.now().uptimeNanoseconds
            var lastArrival: UInt64 = 0
            var maxGap: UInt64 = 0
            var pendingFirst = first
            let audioLanes = Array(group.audio)
            var lane = 0
            while true {
                let conn = audioLanes[lane]
                let frame: (type: UInt8, length: Int)
                if let p = pendingFirst {
                    if buffer.count < p.payload.count { buffer = [UInt8](repeating: 0, count: p.payload.count) }
                    buffer.replaceSubrange(0..<p.payload.count, with: p.payload)
                    frame = (p.type, p.payload.count)
                    pendingFirst = nil
                } else {
                    guard let f = conn.readFrame(into: &buffer) else { break }
                    frame = f
                }
                switch frame.type {
                case Wire.audio:
                    let arrival = DispatchTime.now().uptimeNanoseconds
                    if lastArrival != 0 { maxGap = max(maxGap, arrival - lastArrival) }
                    lastArrival = arrival
                    let n = frame.length / 2
                    guard keepAudio else { break }
                    buffer.withUnsafeMutableBytes { raw in
                        let pcm = raw.baseAddress!.assumingMemoryBound(to: Int16.self)
                        if self.current(\.speakerConn) != nil {
                            let t0 = DispatchTime.now().uptimeNanoseconds
                            self.echo.process(pcm, count: n, apply: self.echoApply)
                            let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
                            self.lock.lock()
                            self._stats.echoMicrosPerFrame = self._stats.echoMicrosPerFrame * 0.95 + us * 0.05
                            self.lock.unlock()
                        }
                        for i in 0..<n {
                            samples[i] = Float(Int16(littleEndian: pcm[i])) / 32768
                        }
                    }
                    self.micRing.write(samples, n)
                    lane = (lane + 1) % audioLanes.count
                    peak = max(peak, levelDb(samples, n))
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now - lastUi > 100_000_000 {
                        self.lock.lock()
                        self._stats.micLevelDb = peak
                        self._stats.micMaxGapMs = max(self._stats.micMaxGapMs, Double(maxGap) / 1_000_000)
                        self.lock.unlock()
                        maxGap = 0
                        peak = -90
                        lastUi = now
                    }
                default:
                    self.handleControl(frame.type, buffer, frame.length, conn)
                }
            }
            self.lock.lock()
            let wasCurrent = self.micConn === group
            if wasCurrent { self.micConn = nil; self._stats.micLevelDb = -90 }
            if self.speakerConn === group { self.speakerConn = nil; self._stats.speakerLevelDb = -90 }
            self.lock.unlock()
            group.close()
            if wasCurrent { Log.info("tablet mic disconnected") }
        }
    }

    private func acceptSpeaker(_ group: LaneGroup) {
        guard speakerEnabled else { group.close(); return }
        swapSpeaker(group)
        Log.info("tablet speaker connected (\(group.lanes.count) lanes)")
        // Every lane gets a reader so a dead socket anywhere tears the whole group down.
        for (i, conn) in group.lanes.enumerated() {
            startThread("speaker-read-\(i)") { [unowned self] in
                var buffer = [UInt8](repeating: 0, count: 256)
                while let frame = conn.readFrame(into: &buffer) {
                    self.handleControl(frame.type, buffer, frame.length, conn)
                }
                self.lock.lock()
                let wasCurrent = self.speakerConn === group
                if wasCurrent { self.speakerConn = nil; self._stats.speakerLevelDb = -90 }
                self.lock.unlock()
                group.close()
                if wasCurrent { Log.info("tablet speaker disconnected") }
            }
        }
    }

    /// Reads PING/PONG on the control lane; closing the group on EOF also ends the audio reader.
    private func watchControl(_ group: LaneGroup, _ name: String) {
        startThread(name) { [unowned self] in
            var buffer = [UInt8](repeating: 0, count: 256)
            while let frame = group.control.readFrame(into: &buffer) {
                self.handleControl(frame.type, buffer, frame.length, group.control)
            }
            group.close()
        }
    }

    private func handleControl(_ type: UInt8, _ buffer: [UInt8], _ length: Int, _ conn: Connection) {
        switch type {
        case Wire.ping:
            conn.send(Wire.pong, bytes: Array(buffer[0..<length]))
        case Wire.pong where length >= 8:
            let sent = buffer[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let rtt = Double(DispatchTime.now().uptimeNanoseconds &- sent) / 1_000_000
            lock.lock()
            _stats.rttMs = _stats.rttMs.map { $0 * 0.6 + rtt * 0.4 } ?? rtt
            lock.unlock()
        default:
            break
        }
    }

    // MARK: audio paths

    /// Real-time: tablet mic -> Tablet Audio input (mono duplicated to both channels).
    private func renderMic(_ out: UnsafeMutablePointer<Float>, _ frames: Int) {
        let available = micRing.available
        if !micPrimed {
            if available >= micTarget { micPrimed = true } else {
                out.update(repeating: 0, count: frames * 2)
                return
            }
        }
        if available > micMax { micRing.discard(available - micTarget) }
        // Jitter-buffer trim: if the queue never dipped near the target during the last second, drop the surplus.
        micWindowMin = min(micWindowMin, available)
        micWindowFrames += frames
        if micWindowFrames >= 48_000 {
            if micWindowMin != Int.max && micWindowMin > micTarget / 3 + 240 { micRing.discard(micWindowMin - micTarget / 3) }
            micWindowMin = Int.max
            micWindowFrames = 0
        }
        let n = min(frames, 8192)
        let got = micRing.read(into: mono, n)
        if got < n {
            micPrimed = false
            for i in got..<n { mono[i] = 0 }
        }
        for i in 0..<n {
            out[2 * i] = mono[i]
            out[2 * i + 1] = mono[i]
        }
    }

    /// Real-time: Tablet Audio output -> queue for the tablet.
    private func captureSpeaker(_ samples: UnsafePointer<Float>, _ frames: Int) {
        speakerRing.write(samples, frames * 2)
        speakerSignal.signal()
    }

    private func sendLoop() {
        let chunkFrames = 240 // 5 ms
        let floats = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames * 2)
        var bytes = [UInt8](repeating: 0, count: chunkFrames * 4)
        var peak: Float = -90
        var lastUi = DispatchTime.now().uptimeNanoseconds
        var lastGroup: LaneGroup?
        var lane = 0
        var droppedChunks = 0
        while true {
            _ = speakerSignal.wait(timeout: .now() + .milliseconds(100))
            guard let group = current(\.speakerConn) else {
                speakerRing.clear()
                continue
            }
            if group !== lastGroup {
                // The tablet reads audio lanes in rotation starting at the first one.
                lastGroup = group
                lane = 0
            }
            let audioLanes = group.audio
            while speakerRing.available >= chunkFrames * 2 {
                _ = speakerRing.read(into: floats, chunkFrames * 2)
                bytes.withUnsafeMutableBytes { raw in
                    for i in 0..<(chunkFrames * 2) {
                        let v = Int16(max(-32768, min(32767, (floats[i] * 32767).rounded())))
                        raw.storeBytes(of: v.littleEndian, toByteOffset: i * 2, as: Int16.self)
                    }
                }
                let target = audioLanes[audioLanes.startIndex + lane]
                // The tablet trims its own backlog, but over USB accessory it cannot see what is still queued
                // on the Mac side, so a single stall would otherwise leave that much delay for good.
                if audioLanes.count == 1 && target.unsentBytes > chunkFrames * 4 * 6 {
                    droppedChunks += 1
                    continue
                }
                echo.pushReference(floats, frames: chunkFrames)
                if !target.send(Wire.audio, bytes: bytes) {
                    // A dead link must not hold the sender; closing it lets the readers clear it and the
                    // next loop pick up whatever link replaced it.
                    group.close()
                    break
                }
                lane = (lane + 1) % audioLanes.count
                peak = max(peak, levelDb(floats, chunkFrames * 2))
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastUi > 100_000_000 {
                lock.lock(); _stats.speakerLevelDb = peak; _stats.speakerDropped = droppedChunks; lock.unlock()
                peak = -90
                lastUi = now
            }
        }
    }

    private func startThread(_ name: String, _ body: @escaping () -> Void) {
        let t = Thread(block: body)
        t.name = name
        t.qualityOfService = .userInteractive
        t.start()
    }
}
