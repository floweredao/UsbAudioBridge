# USB Audio Bridge

Use an Android tablet as your Mac's **microphone and speaker over a single USB cable**. No Wi-Fi needed.

```
Mac apps ──► Tablet Audio (output) ──► helper ──USB (adb reverse, TCP 47124)──► tablet speaker
Mac apps ◄── Tablet Audio (input)  ◄── helper ◄──USB (adb reverse, TCP 47123)─── tablet microphone
```

Tools like AudioRelay send audio over UDP, which `adb` cannot forward. This project streams 48 kHz 16-bit PCM over TCP instead, so the existing USB debugging connection carries it.

| Dark | Light |
| --- | --- |
| ![Tablet app, dark](docs/tablet-dark.png) | ![Tablet app, light](docs/tablet-light.png) |

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
4. On the tablet you can toggle the mic and speaker, set mic gain and speaker volume, turn on the tablet's own echo cancellation, and see the round-trip time and playback delay. The UI follows the system's light or dark theme and adapts to landscape and portrait.
5. Tap **Allow** on the tablet's *Keep running with the screen off* banner so battery optimization never pauses the bridge.

## Latency

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
| Tablet hears silence from the Mac | Grant microphone access in System Settings > Privacy & Security > Microphone. |

Logs: `~/Library/Logs/UsbAudioBridge/helper.log` (Mac) and `adb logcat -s UsbAudioBridge` (tablet).

## Protocol

Every message is `[type u8][length u32 big-endian][payload]`. The types are AUDIO (1), PING (2), PONG (3), and HELLO (4). The Mac sends HELLO on accept and answers each PING with a PONG that echoes the payload. Mic audio is s16le mono and speaker audio is s16le stereo, both at 48 kHz.
