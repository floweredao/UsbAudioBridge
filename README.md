<img src="docs/icon.png" width="128" alt="USB Audio Bridge icon">

# USB Audio Bridge

**Turn an Android tablet into your Mac's microphone and speaker with one USB cable.**

[한국어](README-ko.md)

- **One cable, no Wi-Fi.** Audio travels over the same USB cable that charges the tablet. No network, pairing, or account.
- **Low delay.** About 85 ms from the Mac through the tablet speaker and back through the tablet mic, measured over the USB accessory link.
- **No echo.** The Mac removes its own sound from the tablet mic, so dictation and calls don't pick up what the tablet speaker plays.
- **Runs in the background.** Plug in the tablet and the bridge starts with the screen off. It reconnects by itself after a replug or a dropped link.
- **Starts with your Mac.** The menu bar helper opens at login, so the bridge is ready after every restart.
- **One device on the Mac.** Mac apps see a single **Tablet Audio** device for both input and output, and the volume keys work on it.

![Tablet app, light mode](docs/tablet-en-light.png)

![Tablet app, dark mode](docs/tablet-en-dark.png)

## Install

You need a Mac with macOS 15 or later and an Android tablet with Android 8.0 or later.

1. On the tablet, turn on **USB debugging** (Settings > Developer options), plug it into the Mac, and allow this Mac when the tablet asks.
2. On the Mac, install `adb`:
   ```sh
   brew install --cask android-platform-tools
   ```
3. Install the **Tablet Audio** driver. It is not in the release yet, so build it from this repository (needs `brew install cmake`; asks for your password and drops Mac audio for about a second):
   ```sh
   driver/build.sh
   driver/install.sh
   ```
4. Download `UsbAudioBridge-<version>-mac.zip`, `UsbAudioBridge-<version>.apk`, and `SHA256SUMS.txt` from the [latest release](https://github.com/floweredao/UsbAudioBridge/releases/latest), then check them:
   ```sh
   shasum -a 256 -c SHA256SUMS.txt
   ```
5. Install the menu bar helper and open it. The helper is signed but not notarized, so remove the quarantine flag first:
   ```sh
   ditto -x -k UsbAudioBridge-*-mac.zip /Applications
   xattr -dr com.apple.quarantine "/Applications/USB Audio Bridge.app"
   open "/Applications/USB Audio Bridge.app"
   ```
6. Allow **microphone access** when macOS asks. The helper reads the tablet's sound through the Tablet Audio device, which macOS counts as microphone input.
7. The helper installs the tablet app by itself when it is missing. To install it yourself instead, run `adb install -r UsbAudioBridge-*.apk`.

## First use

1. Plug in the tablet. Within about two seconds the bridge starts in the background and a notification on the tablet shows it is running. The tablet screen stays as it is.
2. On the Mac, choose **Tablet Audio** as the input and the output, either in System Settings > Sound or in a single app such as Zoom.
3. The first time, the tablet asks *Allow USB Audio Bridge to access USB Audio Bridge?*. Tick **Always open USB Audio Bridge when USB Audio Bridge is connected** and tap **OK**. This moves audio onto the faster USB accessory link and is not asked again.
4. On the tablet, tap **Allow** on the *Keep running with the screen off* banner so battery optimization never pauses the bridge.

The menu bar icon fills in when audio is flowing. Its menu shows the connection, a level meter for each direction, and the round-trip time, with switches for the tablet mic and speaker, **Reconnect Tablet**, **Open at Login**, and **Show Log**.

Open the tablet app when you want its controls: mic and speaker on/off, mic gain, speaker volume, and the tablet's own echo cancellation. Leave that switch off when the Mac already removes echo; it adds about 60 ms.

## FAQ

**The tablet plays no sound.**
Check that the Mac app's output is Tablet Audio and that the tablet's media volume is up. The *Speaker* meter in the menu shows whether the Mac is sending anything.

**Mac apps hear nothing from the tablet.**
Choose Tablet Audio as the app's input and watch the *Mic* meter in the menu. If the meter moves but the app records silence, allow USB Audio Bridge in System Settings > Privacy & Security > Microphone.

**The menu stays on *Waiting for the tablet*.**
Run `adb devices`. If the tablet shows *unauthorized*, accept the USB debugging prompt on the tablet. If `adb` is missing, the menu says *adb not found*; install it as in step 2.

**The menu says *Tablet Audio driver is not installed*.**
Run `driver/build.sh` and `driver/install.sh`.

**The tablet mic shows *busy or blocked*.**
Choose **Reconnect Tablet** in the menu, or open the tablet app once.

**The delay feels higher than usual.**
The tablet may still be on the slower adb link. Unlock the tablet once so it can show the accessory prompt from *First use* step 3, and tick *Always open*. The helper log then shows `aoa: tablet linked`.

**"port 47123 is busy".**
Another copy of the helper is running. Quit it.

Logs: `~/Library/Logs/UsbAudioBridge/helper.log` on the Mac and `adb logcat -s UsbAudioBridge` for the tablet.

## How it works

```
Mac apps ──► Tablet Audio (output) ──► menu bar helper ──USB──► tablet speaker
Mac apps ◄── Tablet Audio (input)  ◄── menu bar helper ◄──USB─── tablet microphone
```

Audio is 48 kHz 16-bit PCM in 5 ms frames. The helper moves it over one of two USB links:

- **USB accessory (AOA, preferred).** The helper switches the tablet to Android Open Accessory mode and sends audio over raw USB bulk pipes. USB debugging stays available.
- **adb (fallback).** TCP over `adb reverse` (ports 47123 for the mic and 47124 for the speaker), used until the tablet allows accessory mode. Each direction uses several sockets so audio keeps flowing evenly.

**Latency.** Loop test (Mac → tablet speaker → air → tablet mic → Mac), median of 10 beeps:

| Link | Tablet echo cancellation off | on |
| --- | --- | --- |
| USB accessory (AOA) | 84.5 / 88.8 ms | 148 ms |
| adb | 142.8 / 150.6 ms | 203.5 / 209.5 ms |

The tablet keeps a playback buffer that starts at 10 ms and grows only after a real underrun, and both sides drop surplus that lasts a full second, so the delay does not creep up over long sessions. Measure your own setup with:

```sh
open -n -W "/Applications/USB Audio Bridge.app" --args --loop-test 10 --out /tmp/loop.txt; cat /tmp/loop.txt
```

**Echo cancellation.** What the helper sends to the tablet speaker is the reference, and every mic frame runs through speexdsp's echo canceller and residual echo suppressor. Noise suppression and automatic gain stay off, so your voice is untouched. It runs only while an app records from Tablet Audio and costs about 0.2-0.3 ms of CPU per 5 ms frame, with no extra buffering. On the tablet it lowered the Mac's sound on the Tablet Audio input by 20-31 dB, while a test tone standing in for your voice dropped by only 0.8 dB. Force it with `defaults write com.floweredao.usbaudiobridge.mac aec on` (or `off`); `defaults delete com.floweredao.usbaudiobridge.mac aec` returns to automatic.

**Protocol.** Every message is `[type u8][length u32 big-endian][payload]` with types AUDIO (1), PING (2), PONG (3), and HELLO (4). Mic audio is s16le mono and speaker audio is s16le stereo. The accessory identifies itself as manufacturer `floweredao`, model `UsbAudioBridge`. To stay on adb only, run `defaults write com.floweredao.usbaudiobridge.mac aoa -bool false` and restart the helper.

## Project layout

| Folder | What it is |
| --- | --- |
| `android/` | Tablet app (Kotlin, Jetpack Compose, Material 3, minSdk 26). A foreground service records the mic and plays Mac audio, keeps running with the screen off, and reconnects automatically. |
| `driver/` | **Tablet Audio**, a CoreAudio virtual device built on [libASPL](https://github.com/gavv/libASPL) (MIT). It also publishes a hidden port that only the helper opens, wired so that nothing an app plays comes back on the Tablet Audio input. |
| `mac/` | Menu bar helper (Swift, macOS 15+). Finds the tablet through `adb`, installs and starts the tablet app's bridge service, links the tablet over USB, cancels echo, and moves audio between the tablet and Tablet Audio. Includes speexdsp (BSD-3-Clause) in `mac/Sources/CSpeexDSP`. |

## Build from source

Needs Xcode 16+ (Swift 6), JDK 17 (`brew install openjdk@17`), CMake, and Android SDK 35 (`brew install --cask android-commandlinetools`, then `sdkmanager "platforms;android-35" "build-tools;35.0.0"`).

```sh
# Tablet Audio driver (driver/install.sh -u removes it)
driver/build.sh
driver/install.sh

# Android app
cd android
echo "sdk.dir=/opt/homebrew/share/android-commandlinetools" > local.properties
JAVA_HOME=$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home ./gradlew assembleRelease
adb install -r app/build/outputs/apk/release/app-release.apk

# Mac helper (bundles the APK above; SIGN_IDENTITY="..." picks a certificate)
cd ../mac
./scripts/build-app.sh
ditto "dist/USB Audio Bridge.app" "/Applications/USB Audio Bridge.app"
open "/Applications/USB Audio Bridge.app"
```
