import AudioToolbox
import CoreAudio
import Foundation

enum AudioDevices {
    static func all() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    static func find(_ name: String) -> AudioDeviceID? {
        all().first { self.name(of: $0) == name }
    }
}

private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw BridgeError.audio("\(what) failed (OSStatus \(status))") }
}

private func makeHAL() throws -> AudioUnit {
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &desc) else { throw BridgeError.audio("AUHAL not found") }
    var unit: AudioUnit?
    try check(AudioComponentInstanceNew(component, &unit), "AudioComponentInstanceNew")
    return unit!
}

private func floatFormat(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
        mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
}

private func setCommon(_ unit: AudioUnit, device: AudioDeviceID, bufferFrames: UInt32) throws {
    var dev = device
    try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "set device")
    var frames = bufferFrames
    // Small I/O buffer keeps the device side of the latency budget to a few ms.
    _ = AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                             &frames, UInt32(MemoryLayout<UInt32>.size))
}

/// Plays interleaved float frames to one output device. `fill` runs on the real-time thread.
final class OutputUnit {
    typealias Fill = (_ out: UnsafeMutablePointer<Float>, _ frames: Int, _ hostTime: UInt64) -> Void
    let channels: Int
    let bufferFrames: UInt32
    private let fill: Fill
    private var unit: AudioUnit?

    init(channels: Int = 2, bufferFrames: UInt32 = 256, fill: @escaping Fill) {
        self.channels = channels
        self.bufferFrames = bufferFrames
        self.fill = fill
    }

    func start(device: AudioDeviceID) throws {
        let unit = try makeHAL()
        self.unit = unit
        try setCommon(unit, device: device, bufferFrames: bufferFrames)
        var format = floatFormat(rate: Wire.sampleRate, channels: UInt32(channels))
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "output format")
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, timeStamp, _, frames, ioData in
                let me = Unmanaged<OutputUnit>.fromOpaque(refCon).takeUnretainedValue()
                guard let ioData else { return noErr }
                let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                guard let data = buffers[0].mData else { return noErr }
                me.fill(data.assumingMemoryBound(to: Float.self), Int(frames), timeStamp.pointee.mHostTime)
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "render callback")
        try check(AudioUnitInitialize(unit), "AudioUnitInitialize(output)")
        try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart(output)")
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }
}

/// Captures the first `channels` channels of an input device as interleaved float frames.
final class InputUnit {
    typealias Deliver = (_ samples: UnsafePointer<Float>, _ frames: Int, _ hostTime: UInt64) -> Void
    let channels: Int
    let bufferFrames: UInt32
    private let deliver: Deliver
    private var unit: AudioUnit?
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 8192

    init(channels: Int = 2, bufferFrames: UInt32 = 256, deliver: @escaping Deliver) {
        self.channels = channels
        self.bufferFrames = bufferFrames
        self.deliver = deliver
        scratch = .allocate(capacity: scratchFrames * channels)
    }

    deinit { scratch.deallocate() }

    func start(device: AudioDeviceID) throws {
        let unit = try makeHAL()
        self.unit = unit
        var one: UInt32 = 1
        var zero: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "disable output")
        try setCommon(unit, device: device, bufferFrames: bufferFrames)

        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "input hw format")
        guard hardware.mSampleRate == Wire.sampleRate else {
            throw BridgeError.audio("input device runs at \(Int(hardware.mSampleRate)) Hz; set it to 48000 Hz in Audio MIDI Setup")
        }
        var format = floatFormat(rate: Wire.sampleRate, channels: UInt32(channels))
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                       &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "input client format")
        var map = (0..<channels).map { Int32($0) }
        _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                                 &map, UInt32(MemoryLayout<Int32>.size * channels))
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frames, _ in
                let me = Unmanaged<InputUnit>.fromOpaque(refCon).takeUnretainedValue()
                return me.pull(flags, timeStamp, bus, frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")
        try check(AudioUnitInitialize(unit), "AudioUnitInitialize(input)")
        try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart(input)")
    }

    private func pull(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timeStamp: UnsafePointer<AudioTimeStamp>,
                      _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit, Int(frames) <= scratchFrames else { return noErr }
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: frames * UInt32(4 * channels), mData: scratch))
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, &list)
        if status == noErr { deliver(scratch, Int(frames), timeStamp.pointee.mHostTime) }
        return status
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }
}

func levelDb(_ samples: UnsafePointer<Float>, _ count: Int) -> Float {
    guard count > 0 else { return -90 }
    var sum: Float = 0
    for i in 0..<count { sum += samples[i] * samples[i] }
    let rms = (sum / Float(count)).squareRoot()
    return rms <= 0.0000316 ? -90 : 20 * log10(rms)
}
