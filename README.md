# USB Audio Bridge

Use an Android tablet as your Mac's **microphone and speaker over a single USB cable**. No Wi-Fi needed.

```
Mac apps ──► Tablet Audio (output) ──► helper ──USB (adb reverse, TCP 47124)──► tablet speaker
Mac apps ◄── Tablet Audio (input)  ◄── helper ◄──USB (adb reverse, TCP 47123)─── tablet microphone
```

Tools like AudioRelay send audio over UDP, which `adb` cannot forward. This project streams 48 kHz 16-bit PCM over the USB cable in one of two ways:

- **USB accessory (AOA, preferred).** The helper asks the tablet to switch to Android Open Accessory mode and moves audio over raw USB bulk pipes. adb (USB debugging) stays available in this mode.
- **adb (fallback).** TCP over `adb reverse`, used when the tablet cannot or may not use accessory mode.

**Dark**

![Tablet app, dark](docs/tablet-dark.png)

**Light**

![Tablet app, light](docs/tablet-light.png)

## Pieces

| Folder | What it is |
| --- | --- |
| `android/` | Tablet app (Kotlin, Jetpack Compose, Material 3, minSdk 26, targetSdk 34). A foreground service records the mic and plays Mac audio, keeps running with the screen off, and reconnects automatically. |
| `driver/` | **Tablet Audio**, a CoreAudio virtual device (Audio Server plug-in built on [libASPL](https://github.com/gavv/libASPL), MIT) with both an input and an output. Mac apps see one device. The plug-in also publishes a hidden *Tablet Audio Bridge Port* that only the helper opens; the two share a clock and are cross-wired (Tablet Audio output → port input, port output → Tablet Audio input), so nothing an app plays comes back on the Tablet Audio input. |
| `mac/` | Menu bar helper (Swift, macOS 15+). Watches `adb` for the tablet, runs `adb reverse`, installs the app if it is missing, grants its mic permission, opens the app, and moves audio between the tablet and the Tablet Audio bridge port. |

## Requirements

- Mac: the Tablet Audio driver from `driver/` (below), plus `adb` (`brew install --cask android-platform-tools`). BlackHole is no longer needed.
- To build the driver: CMake (`brew install cmake`); libASPL is fetched at its `v3.1.2` tag during the build.
- Tablet: Android 8.0 or later, with **USB debugging** enabled and this Mac authorized.
- To build: Xcode 16+ (Swift 6 toolchain), JDK 17 (`brew install openjdk@17`), and Android SDK 35 (`brew install --cask android-commandlinetools`, then `sdkmanager "platforms;android-35" "build-tools;35.0.0"`).

## Build and install

```sh
# Tablet Audio driver (asks for your password; restarts coreaudiod, so audio drops for a second)
driver/build.sh
driver/install.sh                 # driver/install.sh -u removes it

# Android app
cd android
echo "sdk.dir=/opt/homebrew/share/android-commandlinetools" > local.properties
JAVA_HOME=$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home ./gradlew assembleRelease
adb install -r app/build/outputs/apk/release/app-release.apk

# Mac helper (bundles the APK above and signs with your Apple Development certificate)
cd ../mac
./scripts/build-app.sh            # SIGN_IDENTITY="..." to pick a certificate
ditto "dist/USB Audio Bridge.app" "/Applications/USB Audio Bridge.app"
open "/Applications/USB Audio Bridge.app"
```

The first launch asks for **microphone access**. Allow it, because macOS treats reading the Tablet Audio bridge port as microphone input.

## Use

1. Plug in the tablet. Within about two seconds the helper sets up `adb reverse` and opens the app, which wakes the screen.
2. On the Mac, choose **Tablet Audio** as the output and as the input, either system-wide or in a single app such as Zoom or Discord. The Mac volume keys work on it.
3. The menu bar icon fills in once the tablet is streaming. Its menu shows:
   - the tablet's connection status
   - level and state for each direction
   - round-trip time and the size of the mic buffer
   - toggles for the tablet microphone and speaker
   - **Reconnect Tablet**
   - **Open at Login**
   - **Show Log**
4. The first time the helper switches the tablet to accessory mode, Android asks *Allow USB Audio Bridge to access USB Audio Bridge?*. Tick **Always open USB Audio Bridge when USB Audio Bridge is connected** and tap **OK**; after that the switch is silent. The helper only asks while the tablet is unlocked (so this prompt can appear) or once that default is set, and waits 10 minutes after a switch that did not link, so a locked tablet stays on adb instead of flapping.
5. On the tablet you can toggle the mic and speaker, set mic gain and speaker volume, turn on the tablet's own echo cancellation, and see the round-trip time and playback delay. The UI follows the system's light or dark theme and adapts to landscape and portrait.
6. Tap **Allow** on the tablet's *Keep running with the screen off* banner so battery optimization never pauses the bridge.

## Latency

Loop test (Mac → tablet speaker → air → tablet mic → Mac), median of 10 beeps, measured back to back on the same day:

| Path | Tablet echo cancellation off | on |
| --- | --- | --- |
| USB accessory (AOA) | 84.5 / 88.8 ms | 148 ms |
| adb | 142.8 / 150.6 ms | 203.5 / 209.5 ms |

Over AOA every beep arrives with the same delay (round trip about 1.3 ms, no adb stalls), so the tablet playback buffer settles at its 10 ms floor. The tablet's own echo cancellation (voice-call capture path) adds about 60 ms; turn it off when the Mac app cancels echo itself.

On the adb path:

- Each direction uses five sockets: one for pings and four that carry audio frames in turn. adb lets only one unacknowledged packet travel per socket, so a single socket delivers audio in bunches; four keep packets flowing.
- The tablet keeps a small playback buffer that starts at 10 ms, grows 5 ms after a real underrun (up to 40 ms), and shrinks 5 ms after every 5 s without one.
- The Mac keeps a 15 ms mic buffer.
- Both sides drop any surplus that persisted for a full second, so the delay does not creep up over time.
- Audio moves in 5 ms frames, and the helper uses 128-frame device buffers.
- The tablet microphone delivers audio in 20 ms blocks on this hardware (no fast capture path), which sets a floor on the mic side.

`--loop-test` measures the whole chain. It plays beeps into Tablet Audio, the tablet speaker plays them, the tablet mic hears them, and the helper times their arrival on the Tablet Audio input:

```sh
open -n -W "/Applications/USB Audio Bridge.app" --args --loop-test 10 --out /tmp/loop.txt; cat /tmp/loop.txt
```

## Echo cancellation

The tablet speaker plays the Mac's sound right next to the tablet mic, so dictation and calls would hear the Mac again. The helper removes that echo on the Mac: what it sends to the tablet speaker is the reference, and every 5 ms mic frame runs through speexdsp's echo canceller and residual echo suppressor (vendored in `mac/Sources/CSpeexDSP`, BSD-3-Clause; noise suppression and AGC stay off so your voice is untouched).

- It is applied only while some app records from **Tablet Audio** (dictation, Zoom, Voice Memos). Plain listening keeps the untouched path. The menu shows *Echo cancel on/off*.
- Cost: about 0.2-0.3 ms of CPU per 5 ms frame and no extra buffering, so it adds no noticeable delay. The tablet's own echo cancellation (the *Echo cancellation* switch in the tablet app) adds about 60 ms instead.
- Measured on the tablet (`--echo-test`, steady 440 + 1000 + 2500 Hz from the Mac while the tablet itself plays a 600 Hz "talker"): the Mac's sound on the Tablet Audio input drops by 19.9 / 31.2 / 29.4 dB and the talker by only 0.8 dB. Short beeps that start out of silence are suppressed much less (about 4 dB), because the suppressor first treats them as speech.
- The tablet's own echo cancellation removes the Mac's sound too, but also mutes the talker while the Mac plays and adds about 60 ms.
- `--aec-selftest` repeats the check offline on synthetic signals, without sound.
- Force it with `defaults write com.floweredao.usbaudiobridge.mac aec on` (or `off`); `defaults delete com.floweredao.usbaudiobridge.mac aec` returns to automatic.
- `--echo-test <seconds>` measures it on the real tablet: it plays a 440 + 1000 + 2500 Hz mix through the tablet and reports how much of it comes back on the Tablet Audio input.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Menu says *adb not found* | `brew install --cask android-platform-tools` |
| Menu shows *Waiting for the tablet* | Check `adb devices`. If it shows *unauthorized*, accept the USB debugging prompt on the tablet. |
| Tablet mic shows *busy or blocked* | Android 11+ only lets a foreground service record when it was started while the app was visible. Unlock the tablet and open the app once, or choose **Reconnect Tablet**. |
| Menu says *Tablet Audio driver is not installed* | Run `driver/build.sh` and `driver/install.sh`. |
| Tablet plays nothing | Make sure the Mac app's output is Tablet Audio. Check the speaker meter in the menu. |
| Mac apps hear nothing from the tablet | Choose Tablet Audio as the app's input and watch the *Mic* meter in the menu. |
| "port 47123 is busy" | Another copy of the helper is running. Quit it. |
| Want adb only | `defaults write com.floweredao.usbaudiobridge.mac aoa -bool false`, restart the helper, and replug the tablet. |
| Tablet stays on adb (menu log shows no `aoa: tablet linked`) | Unlock the tablet once so Android can show the accessory prompt, and tick *Always open*. |
| Tablet hears silence from the Mac | Grant microphone access in System Settings > Privacy & Security > Microphone. |

Logs: `~/Library/Logs/UsbAudioBridge/helper.log` (Mac) and `adb logcat -s UsbAudioBridge` (tablet).

## Protocol

Every message is `[type u8][length u32 big-endian][payload]`. Over USB accessory one bulk pipe per direction carries everything: Mac → tablet speaker AUDIO plus PING/PONG, tablet → Mac mic AUDIO plus PING/PONG. The accessory identifies itself as manufacturer `floweredao`, model `UsbAudioBridge`. The types are AUDIO (1), PING (2), PONG (3), and HELLO (4). The Mac sends HELLO on accept and answers each PING with a PONG that echoes the payload. Mic audio is s16le mono and speaker audio is s16le stereo, both at 48 kHz.
