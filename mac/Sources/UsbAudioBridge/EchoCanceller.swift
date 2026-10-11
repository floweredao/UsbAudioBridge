import CoreAudio
import CSpeexDSP
import Foundation

/// Removes the Mac's own sound, which the tablet speaker plays and the tablet microphone hears again,
/// from the microphone stream (speexdsp's MDF echo canceller plus its residual echo suppressor).
///
/// The reference is what the helper sends to the tablet speaker, queued in 5 ms frames as it is sent;
/// each 5 ms microphone frame is paired with the oldest queued reference frame. The echo reaches the
/// microphone 50-150 ms after its reference left the Mac (tablet playback buffer, speaker, capture), so
/// the queue is capped at 40 ms (the paired reference is never newer than the echo it explains) and the
/// 250 ms filter tail covers the rest. Clock drift between Mac and tablet only shifts the echo within
/// that window. Processing is frame by frame in place, so it adds no buffering delay.
final class EchoCanceller {
    static let frame = 240           // 5 ms at 48 kHz, the size of every tablet mic frame
    private static let tail = 12_000 // 250 ms
    private static let maxQueued = frame * 8

    private let echo: OpaquePointer
    private let preprocess: OpaquePointer
    private let lock = NSLock()
    private var reference = [Int16](repeating: 0, count: maxQueued + frame)
    private var queued = 0
    private var input = [Int16](repeating: 0, count: frame)
    private var paired = [Int16](repeating: 0, count: frame)
    private var output = [Int16](repeating: 0, count: frame)

    init() {
        echo = speex_echo_state_init(Int32(Self.frame), Int32(Self.tail))
        var rate: Int32 = 48_000
        speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        preprocess = speex_preprocess_state_init(Int32(Self.frame), 48_000)
        // Only the residual echo suppressor. speexdsp applies it through the denoiser's gain stage, so the
        // denoiser stays on with its noise suppression at 0 dB (no noise removal); AGC stays off so the
        // talker's voice is untouched.
        var on: Int32 = 1, off: Int32 = 0, noNoiseSuppression: Int32 = 0
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_DENOISE, &on)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &noNoiseSuppression)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_AGC, &off)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_DEREVERB, &off)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(echo))
        // Residual echo suppression in dB (speexdsp defaults -40 / -15). Deeper values remove more echo but
        // also duck the talker while the Mac plays; aecSuppress / aecSuppressActive tune it.
        var suppress = Int32(UserDefaults.standard.object(forKey: "aecSuppress") as? Int ?? Self.suppress)
        var suppressActive = Int32(UserDefaults.standard.object(forKey: "aecSuppressActive") as? Int ?? Self.suppressActive)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, &suppress)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, &suppressActive)
    }

    static var suppress = -40
    static var suppressActive = -15

    deinit {
        speex_preprocess_state_destroy(preprocess)
        speex_echo_state_destroy(echo)
    }

    /// Speaker side: interleaved stereo floats exactly as sent to the tablet.
    func pushReference(_ stereo: UnsafePointer<Float>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<frames {
            if queued == reference.count {
                reference.removeFirst(Self.frame)
                reference.append(contentsOf: repeatElement(0, count: Self.frame))
                queued -= Self.frame
            }
            let mono = (stereo[2 * i] + stereo[2 * i + 1]) * 0.5
            reference[queued] = Int16(max(-32768, min(32767, (mono * 32767).rounded())))
            queued += 1
        }
        if queued > Self.maxQueued {
            let drop = queued - Self.maxQueued
            reference.replaceSubrange(0..<queued - drop, with: reference[drop..<queued])
            queued -= drop
        }
    }

    /// Microphone side: cancels the echo in `samples` (s16 mono) whole 5 ms frames at a time, in place.
    /// With `apply` false the filter still adapts but the samples are left untouched.
    func process(_ samples: UnsafeMutablePointer<Int16>, count: Int, apply: Bool) {
        var offset = 0
        while offset + Self.frame <= count {
            lock.lock()
            let take = min(queued, Self.frame)
            for i in 0..<Self.frame { paired[i] = i < take ? reference[i] : 0 }
            if take > 0 {
                reference.replaceSubrange(0..<queued - take, with: reference[take..<queued])
                queued -= take
            }
            lock.unlock()
            for i in 0..<Self.frame { input[i] = samples[offset + i] }
            speex_echo_cancellation(echo, input, paired, &output)
            speex_preprocess_run(preprocess, &output)
            if apply {
                for i in 0..<Self.frame { samples[offset + i] = output[i] }
            }
            offset += Self.frame
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        queued = 0
        speex_echo_state_reset(echo)
    }
}

/// Decides when echo cancellation is applied. `aec` user default: "auto" (default) applies it only
/// while some other process records from the Tablet Audio input, so plain listening keeps the
/// untouched path; "on" and "off" force it.
enum EchoGate {
    static var mode: String { UserDefaults.standard.string(forKey: "aec") ?? "auto" }

    static func shouldApply(tabletAudio: AudioDeviceID?) -> Bool {
        switch mode {
        case "on": return true
        case "off": return false
        default: return tabletAudio.map(inputInUse) ?? false
        }
    }

    private static func inputInUse(_ device: AudioDeviceID) -> Bool {
        let me = getpid()
        for process in objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal) {
            guard pid(process) != me, uint(process, kAudioProcessPropertyIsRunningInput) != 0 else { continue }
            if objects(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput).contains(device) { return true }
        }
        return false
    }

    private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    private static func pid(_ process: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value)
        return value
    }
}
