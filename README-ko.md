# USB 오디오 브리지

안드로이드 태블릿을 **USB 선 하나로** 맥의 **마이크와 스피커**로 씁니다. 와이파이는 필요 없어요.

```
맥 앱 ──► Tablet Audio(출력) ──► 맥 도우미 ──USB(adb reverse, TCP 47124)──► 태블릿 스피커
맥 앱 ◄── Tablet Audio(입력) ◄── 맥 도우미 ◄──USB(adb reverse, TCP 47123)─── 태블릿 마이크
```

AudioRelay 같은 앱은 소리를 UDP로 보내는데, adb는 UDP를 넘기지 못해요. 이 프로젝트는 48kHz 16비트 PCM을 USB 선으로 두 가지 방법 중 하나로 보내요.

- **USB 액세서리(AOA, 우선).** 도우미가 태블릿을 Android Open Accessory 모드로 바꾸고 USB 벌크 전송으로 직접 주고받아요. 이 모드에서도 adb(USB 디버깅)는 그대로 쓸 수 있어요.
- **adb(대체 경로).** `adb reverse` 위의 TCP예요. 태블릿이 액세서리 모드를 쓸 수 없거나 아직 허용하지 않았을 때 써요.

**다크**

![태블릿 앱 다크](docs/tablet-dark.png)

**라이트**

![태블릿 앱 라이트](docs/tablet-light.png)

## 구성

| 폴더 | 내용 |
| --- | --- |
| `android/` | 태블릿 앱(Kotlin, Jetpack Compose, Material 3, minSdk 26, targetSdk 34). 포그라운드 서비스가 마이크를 녹음하고 맥 소리를 재생해요. 화면이 꺼져도 계속 돌고, 끊기면 알아서 다시 붙어요. |
| `driver/` | 맥 가상 오디오 장치 **Tablet Audio**([libASPL](https://github.com/gavv/libASPL) 기반 Audio Server 플러그인, MIT). 입력과 출력이 한 장치에 있어서 맥 앱에는 장치 하나만 보여요. 플러그인은 도우미만 여는 숨은 *Tablet Audio Bridge Port*도 함께 만들어요. 둘은 같은 시계를 쓰고 서로 엇갈려 이어져 있어요(Tablet Audio 출력 → 포트 입력, 포트 출력 → Tablet Audio 입력). 그래서 앱이 낸 소리가 Tablet Audio 입력으로 되돌아오지 않아요. |
| `mac/` | 메뉴바 도우미(Swift, macOS 15 이상). adb로 태블릿 연결을 감지해 `adb reverse`를 걸어요. 앱이 없으면 설치하고, 마이크 권한을 주고, 앱의 브리지 서비스를 백그라운드에서 시작한 다음 Tablet Audio 브리지 포트와 태블릿 사이로 소리를 옮겨요. |

## 준비물

- 맥: `driver/`의 Tablet Audio 드라이버(아래)와 `adb`(`brew install --cask android-platform-tools`). BlackHole은 더 필요 없어요.
- 드라이버를 빌드하려면 CMake(`brew install cmake`)가 필요해요. libASPL은 빌드할 때 `v3.1.2` 태그로 받아와요.
- 태블릿: 안드로이드 8.0 이상. **USB 디버깅**을 켜고 이 맥을 허용해 두세요.
- 직접 빌드하려면 Xcode 16 이상(Swift 6), JDK 17(`brew install openjdk@17`), Android SDK 35(`brew install --cask android-commandlinetools` 후 `sdkmanager "platforms;android-35" "build-tools;35.0.0"`)가 필요해요.

## 릴리스로 설치

[릴리스](https://github.com/floweredao/UsbAudioBridge/releases)마다 `UsbAudioBridge-<버전>-mac.zip`(메뉴바 도우미, Apple Development 인증서로 서명했고 공증은 안 했어요), `UsbAudioBridge-<버전>.apk`(태블릿 앱), `SHA256SUMS.txt`가 있어요.

```sh
shasum -a 256 -c SHA256SUMS.txt
ditto -x -k UsbAudioBridge-*-mac.zip /Applications
xattr -dr com.apple.quarantine "/Applications/USB Audio Bridge.app"   # 공증 전이라 필요해요
open "/Applications/USB Audio Bridge.app"
adb install -r UsbAudioBridge-*.apk   # 선택: 앱이 없으면 도우미가 들고 있는 APK를 알아서 깔아요
```

Tablet Audio 드라이버는 아직 릴리스에 없어요. 아래처럼 `driver/`에서 빌드해서 설치하세요.

## 소스로 빌드

```sh
# Tablet Audio 드라이버(암호를 물어봐요. coreaudiod를 다시 켜서 소리가 1초쯤 끊겨요)
driver/build.sh
driver/install.sh                 # 지우려면 driver/install.sh -u

# 안드로이드 앱
cd android
echo "sdk.dir=/opt/homebrew/share/android-commandlinetools" > local.properties
JAVA_HOME=$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home ./gradlew assembleRelease
adb install -r app/build/outputs/apk/release/app-release.apk

# 맥 도우미(위 APK를 함께 넣고 Apple Development 인증서로 서명)
cd ../mac
./scripts/build-app.sh            # 인증서를 고르려면 SIGN_IDENTITY="..."
ditto "dist/USB Audio Bridge.app" "/Applications/USB Audio Bridge.app"
open "/Applications/USB Audio Bridge.app"
```

처음 실행하면 **마이크 접근** 허용을 물어봐요. **허용**을 눌러 주세요. macOS는 Tablet Audio 브리지 포트를 읽는 것도 마이크 사용으로 쳐요.

## 쓰는 법

1. 태블릿을 USB로 꽂으면 2초쯤 안에 도우미가 `adb reverse`를 걸고 브리지를 백그라운드에서 시작해요. 태블릿 화면은 그대로이고, 알림 한 줄로만 돌고 있다고 보여요. 설정을 바꾸고 싶을 때만 앱을 직접 여세요.
2. 맥에서 **입력과 출력 모두 Tablet Audio**로 고르세요. 시스템 전체로 바꿔도 되고 Zoom, Discord 같은 앱 하나에서만 골라도 돼요.
3. 연결되면 메뉴바 아이콘이 채워져요. 메뉴에는 다음이 있어요.
   - 태블릿 연결 상태
   - 방향별 상태와 레벨
   - 왕복 시간과 마이크 버퍼 크기
   - 태블릿 마이크·스피커 켜기/끄기
   - **Reconnect Tablet**
   - **Open at Login**
   - **Show Log**
4. 도우미가 처음 태블릿을 액세서리 모드로 바꿀 때 안드로이드가 *USB 오디오 브리지 앱이 USB Audio Bridge에 액세스하도록 허용하시겠습니까?*를 물어봐요. **연결되면 항상 USB 오디오 브리지 열기**를 체크하고 **확인**을 누르면 그다음부터는 창 없이 바뀌어요. 도우미는 태블릿 잠금이 풀려 있거나(이 창이 뜨도록) 이미 항상 열기가 설정돼 있을 때만 바꾸자고 하고, 바꿨는데 연결이 안 되면 10분을 기다려요. 그래서 잠긴 태블릿은 모드를 오가지 않고 adb로 남아요.
5. 태블릿 앱에서는 마이크·스피커를 켜고 끄고, 마이크 증폭과 스피커 볼륨을 조절하고, 태블릿 자체 에코 제거를 켤 수 있어요. 왕복 시간과 재생 지연도 보여요. 화면은 시스템 설정에 따라 다크·라이트로 바뀌고, 가로·세로 배치에 맞춰져요.
6. 태블릿의 *화면이 꺼져도 계속 동작* 안내에서 **허용**을 누르면 배터리 최적화 때문에 멈추는 일이 없어요.

## 지연

루프 테스트(맥 → 태블릿 스피커 → 공기 → 태블릿 마이크 → 맥), 샑 소리 10번의 중앙값이에요. 같은 날 연달아 재었어요.

| 경로 | 태블릿 에코 제거 끔 | 켬 |
| --- | --- | --- |
| USB 액세서리(AOA) | 84.5 / 88.8 ms | 148 ms |
| adb | 142.8 / 150.6 ms | 203.5 / 209.5 ms |

AOA에서는 샑 소리마다 지연이 똑같아요(왕복 약 1.3ms, adb처럼 멈칫하는 일이 없어요). 그래서 태블릿 재생 버퍼가 최소치인 10ms에 머물러요. 태블릿 자체 에코 제거(통화용 녹음 경로)는 약 60ms를 더해요. 맥 앱이 에코를 직접 지우면 꺼 두세요.

adb 경로에서는 이렇게 해요.

- 방향마다 소켓을 다섯 개 써요. 하나는 핑용이고, 나머지 넷이 소리 조각을 번갈아 실어 날라요. adb는 소켓 하나에 확인 안 된 패킷을 하나만 보내기 때문에, 소켓이 하나면 소리가 몰려서 와요. 넷으로 나누면 패킷이 끊기지 않고 흘러요.
- 태블릿 재생 버퍼는 10ms에서 시작해요. 실제로 끊김이 생기면 5ms씩 늘리고(최대 40ms), 5초 동안 끊김이 없으면 다시 5ms씩 줄여요.
- 맥 마이크 버퍼는 15ms를 목표로 해요.
- 양쪽 모두 1초 동안 계속 남아 있던 여분은 버려서 지연이 쌓이지 않게 해요.
- 소리는 5ms 단위로 오가고, 도우미의 장치 버퍼는 128프레임이에요.
- 이 태블릿의 마이크는 빠른 캡처 경로가 없어서 소리를 20ms 덩어리로 내줘요. 그래서 마이크 쪽 지연은 그 아래로 줄지 않아요.

`--loop-test`로 전체 경로를 잴 수 있어요. 맥이 Tablet Audio로 삑 소리를 내면 태블릿 스피커가 재생하고, 태블릿 마이크가 그 소리를 들어요. 도우미는 그 소리가 Tablet Audio 입력에 도착하는 시간을 재요.

```sh
open -n -W "/Applications/USB Audio Bridge.app" --args --loop-test 10 --out /tmp/loop.txt; cat /tmp/loop.txt
```

## 에코 제거

태블릿 스피커가 맥 소리를 태블릿 마이크 바로 옆에서 틀어서, 받아쓰기나 통화가 맥 소리를 다시 듣게 돼요. 도우미는 이 메아리를 맥에서 지워요. 태블릿 스피커로 보낸 소리를 기준 신호로 삼고, 5ms마다 들어오는 마이크 소리를 speexdsp 에코 제거기와 잔향 억제기에 통과시켜요(`mac/Sources/CSpeexDSP`에 포함, BSD-3-Clause). 잡음 제거와 자동 음량은 꺼 두어 목소리는 그대로예요.

- 어떤 앱이 **Tablet Audio**에서 녹음할 때만(받아쓰기, Zoom, 음성 메모 등) 켜져요. 그냥 듣기만 할 때는 원래 경로 그대로예요. 메뉴에 *Echo cancel on/off*로 보여요.
- 비용: 5ms 조각마다 CPU 약 0.2~0.3ms이고 버퍼를 더 쓰지 않아서 느낄 만한 지연이 없어요. 태블릿 자체 에코 제거(태블릿 앱의 *에코 제거* 스위치)는 대신 약 60ms를 더해요.
- 태블릿에서 잰 값(`--echo-test`, 맥이 440·1000·2500Hz를 계속 내고 태블릿이 600Hz "말소리"를 직접 틀 때): Tablet Audio 입력의 맥 소리가 19.9 / 31.2 / 29.4dB 줄고, 말소리는 0.8dB만 줄어요. 조용하다가 갑자기 나는 짧은 삑 소리는 억제기가 처음에 말소리로 봐서 덜 줄어요(약 4dB).
- 태블릿 자체 에코 제거도 맥 소리를 없애지만, 맥이 소리를 내는 동안 말소리까지 거의 묻어 버리고 약 60ms를 더해요.
- `--aec-selftest`는 같은 확인을 소리 없이 가상 신호로 해요.
- 항상 켜거나 끄려면 `defaults write com.floweredao.usbaudiobridge.mac aec on`(또는 `off`), 자동으로 돌리려면 `defaults delete com.floweredao.usbaudiobridge.mac aec`.
- `--echo-test <초>`는 실제 태블릿으로 재요. 440·1000·2500Hz를 태블릿으로 틀고, 그중 얼마가 Tablet Audio 입력으로 돌아오는지 알려 줘요.

## 문제 해결

| 증상 | 해결 |
| --- | --- |
| 메뉴에 *adb not found* | `brew install --cask android-platform-tools` |
| *Waiting for the tablet*에서 안 넘어감 | `adb devices`를 확인하세요. *unauthorized*라면 태블릿에 뜬 USB 디버깅 허용 창에서 허용하세요. |
| 태블릿 앱에 "마이크를 쓸 수 없어요" | 안드로이드 11부터는 adb로 시작했거나 앱이 화면에 보일 때 시작된 서비스만 녹음할 수 있어요. 메뉴에서 **Reconnect Tablet**을 눌러 도우미가 adb로 다시 시작하게 하거나, 앱을 한 번 여세요. |
| 메뉴에 *Tablet Audio driver is not installed* | `driver/build.sh`와 `driver/install.sh`를 실행하세요. |
| 태블릿에서 소리가 안 남 | 맥 앱의 출력이 Tablet Audio인지 확인하세요. 메뉴의 Speaker 레벨도 확인하세요. |
| 맥 앱에 태블릿 소리가 안 들어옴 | 앱 입력을 Tablet Audio로 고르고 메뉴의 Mic 레벨을 확인하세요. |
| "port 47123 is busy" | 도우미가 이미 하나 더 떠 있어요. 하나를 종료하세요. |
| adb만 쓰고 싶음 | `defaults write com.floweredao.usbaudiobridge.mac aoa -bool false` 후 도우미를 다시 켜고 태블릿을 다시 꼽으세요. |
| 계속 adb로만 연결됨(로그에 `aoa: tablet linked`가 없음) | 태블릿 잠금을 한 번 풀어 액세서리 허용 창이 뜨게 하고 *항상 열기*를 체크하세요. |
| 태블릿에 맥 소리가 무음으로 감 | 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 USB Audio Bridge를 허용하세요. |

로그: 맥은 `~/Library/Logs/UsbAudioBridge/helper.log`, 태블릿은 `adb logcat -s UsbAudioBridge`.

## 프로토콜

모든 메시지는 `[type u8][length u32 big-endian][payload]` 형식이에요. USB 액세서리에서는 방향마다 벌크 파이프 하나가 전부를 실어요. 맥 → 태블릿은 스피커 AUDIO와 PING/PONG, 태블릿 → 맥은 마이크 AUDIO와 PING/PONG이에요. 액세서리 이름은 제조사 `floweredao`, 모델 `UsbAudioBridge`예요. 종류는 AUDIO(1), PING(2), PONG(3), HELLO(4)예요. 맥은 연결을 받으면 HELLO를 보내고, PING을 받으면 같은 내용을 담은 PONG으로 답해요. 마이크는 s16le 모노, 스피커는 s16le 스테레오이고 둘 다 48kHz예요.
