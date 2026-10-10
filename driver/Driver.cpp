// Tablet Audio: one CoreAudio virtual device that is both the tablet's microphone and speaker.
//
// The plug-in publishes two devices that share one clock:
//   - "Tablet Audio" (visible): Mac apps play to its output and record from its input.
//   - "Tablet Audio Bridge Port" (hidden): only the USB Audio Bridge helper opens it.
// The devices are cross-wired, so nothing loops back on the visible device:
//   Tablet Audio output -> Bridge Port input  (helper reads it and sends it to the tablet speaker)
//   Bridge Port output  -> Tablet Audio input (helper writes the tablet mic into it)

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <atomic>
#include <cstring>

namespace {

constexpr UInt32 SampleRate = 48000;
constexpr UInt32 ChannelCount = 2;
constexpr UInt32 ZeroTimeStampPeriod = 16384;
constexpr SInt64 RingFrames = 65536;

// Shared timeline for both devices, so a sample time on one means the same instant on the other.
struct Clock {
    UInt64 anchor = mach_absolute_time();
    Float64 ticksPerPeriod = [] {
        mach_timebase_info_data_t base;
        mach_timebase_info(&base);
        const Float64 ticksPerSecond = 1e9 * Float64(base.denom) / Float64(base.numer);
        return ticksPerSecond * ZeroTimeStampPeriod / SampleRate;
    }();
};

Clock& SharedClock()
{
    static Clock clock;
    return clock;
}

// One-way stereo pipe indexed by absolute sample time. One writer (the mixed output of one
// device), any number of readers (input clients of the other device). Frames that were not
// written in the current run read back as silence, so a stopped writer means a silent input.
class Pipe
{
public:
    void Write(SInt64 start, const Float32* src, UInt32 frames)
    {
        const SInt64 end = writtenEnd_.load(std::memory_order_acquire);
        if (start != end) {
            // A gap or restart begins a new run; older ring contents are no longer valid.
            runStart_.store(start, std::memory_order_release);
        }
        for (UInt32 i = 0; i < frames; i++) {
            const SInt64 slot = Slot(start + i);
            ring_[slot * ChannelCount] = src[i * ChannelCount];
            ring_[slot * ChannelCount + 1] = src[i * ChannelCount + 1];
        }
        writtenEnd_.store(start + frames, std::memory_order_release);
    }

    void Read(SInt64 start, Float32* dst, UInt32 frames) const
    {
        const SInt64 end = writtenEnd_.load(std::memory_order_acquire);
        const SInt64 lo = std::max(runStart_.load(std::memory_order_acquire), end - RingFrames / 2);
        for (UInt32 i = 0; i < frames; i++) {
            const SInt64 frame = start + i;
            if (frame >= lo && frame < end) {
                const SInt64 slot = Slot(frame);
                dst[i * ChannelCount] = ring_[slot * ChannelCount];
                dst[i * ChannelCount + 1] = ring_[slot * ChannelCount + 1];
            } else {
                dst[i * ChannelCount] = 0;
                dst[i * ChannelCount + 1] = 0;
            }
        }
    }

private:
    static SInt64 Slot(SInt64 frame)
    {
        return ((frame % RingFrames) + RingFrames) % RingFrames;
    }

    Float32 ring_[RingFrames * ChannelCount] = {};
    std::atomic<SInt64> writtenEnd_ {0};
    std::atomic<SInt64> runStart_ {0};
};

class CrossHandler : public aspl::IORequestHandler
{
public:
    CrossHandler(Pipe& toOther, Pipe& fromOther)
        : toOther_(toOther)
        , fromOther_(fromOther)
    {
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        toOther_.Write(SInt64(timestamp),
            static_cast<const Float32*>(bytes),
            bytesCount / (sizeof(Float32) * ChannelCount));
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override
    {
        fromOther_.Read(SInt64(timestamp),
            static_cast<Float32*>(bytes),
            bytesCount / (sizeof(Float32) * ChannelCount));
    }

private:
    Pipe& toOther_;
    Pipe& fromOther_;
};

class SharedClockDevice : public aspl::Device
{
public:
    using aspl::Device::Device;

protected:
    OSStatus GetZeroTimeStampImpl(UInt32 clientID,
        Float64* outSampleTime,
        UInt64* outHostTime,
        UInt64* outSeed) override
    {
        const Clock& clock = SharedClock();
        const UInt64 periods =
            UInt64(Float64(mach_absolute_time() - clock.anchor) / clock.ticksPerPeriod);
        *outSampleTime = Float64(periods) * ZeroTimeStampPeriod;
        *outHostTime = clock.anchor + UInt64(Float64(periods) * clock.ticksPerPeriod);
        *outSeed = 1;
        return kAudioHardwareNoError;
    }
};

aspl::StreamParameters StreamParams(aspl::Direction direction)
{
    aspl::StreamParameters params;
    params.Direction = direction;
    params.Format = {
        .mSampleRate = SampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
                        kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4 * ChannelCount,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 4 * ChannelCount,
        .mChannelsPerFrame = ChannelCount,
        .mBitsPerChannel = 32,
    };
    return params;
}

std::shared_ptr<SharedClockDevice> MakeDevice(const std::shared_ptr<aspl::Context>& context,
    const char* name,
    const char* uid,
    bool hidden,
    Pipe& toOther,
    Pipe& fromOther)
{
    aspl::DeviceParameters params;
    params.Name = name;
    params.Manufacturer = "UsbAudioBridge";
    params.DeviceUID = uid;
    params.ModelUID = "UsbAudioBridge.TabletAudio";
    params.SampleRate = SampleRate;
    params.ChannelCount = ChannelCount;
    params.ZeroTimeStampPeriod = ZeroTimeStampPeriod;
    params.CanBeDefault = !hidden;
    params.CanBeDefaultForSystemSounds = !hidden;
    params.EnableMixing = true;

    auto device = std::make_shared<SharedClockDevice>(context, params);
    if (hidden) {
        device->SetIsHidden(true);
        device->AddStreamAsync(StreamParams(aspl::Direction::Input));
        device->AddStreamAsync(StreamParams(aspl::Direction::Output));
    } else {
        // Volume and mute controls let the Mac volume keys work on the visible device.
        device->AddStreamWithControlsAsync(StreamParams(aspl::Direction::Input));
        device->AddStreamWithControlsAsync(StreamParams(aspl::Direction::Output));
    }
    device->SetIOHandler(std::make_shared<CrossHandler>(toOther, fromOther));
    return device;
}

std::shared_ptr<aspl::Driver> CreateDriver()
{
    static Pipe appsToTablet; // Tablet Audio output -> Bridge Port input
    static Pipe tabletToApps; // Bridge Port output -> Tablet Audio input

    auto context = std::make_shared<aspl::Context>();
    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(MakeDevice(
        context, "Tablet Audio", "UsbAudioBridge.TabletAudio", false, appsToTablet, tabletToApps));
    plugin->AddDevice(MakeDevice(context,
        "Tablet Audio Bridge Port",
        "UsbAudioBridge.TabletAudio.BridgePort",
        true,
        tabletToApps,
        appsToTablet));
    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* TabletAudioEntryPoint(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    static std::shared_ptr<aspl::Driver> driver = CreateDriver();
    return driver->GetReference();
}
