# Contributing

Thanks for helping with USB Audio Bridge. This page covers how to build each part, how to run the tests, and what a pull request needs.

## Parts

| Folder | Language | Build | Tests |
| --- | --- | --- | --- |
| `mac/` | Swift 6 (macOS 15+) | `mac/scripts/build-app.sh` | `cd mac && swift test` |
| `driver/` | C++ (CoreAudio, libASPL) | `driver/build.sh` | build only |
| `android/` | Kotlin (minSdk 26) | `cd android && ./gradlew assembleRelease` | `cd android && ./gradlew testDebugUnitTest` |

## Toolchain

- Xcode 16 or newer (Swift 6).
- CMake for the driver (`brew install cmake`).
- JDK 17 and Android SDK 35 for the tablet app. With Homebrew:

  ```sh
  brew install openjdk@17
  brew install --cask android-commandlinetools
  sdkmanager "platforms;android-35" "build-tools;35.0.0"
  cd android
  echo "sdk.dir=$(brew --prefix)/share/android-commandlinetools" > local.properties
  export JAVA_HOME=$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home
  ```

  Any JDK 17 and any SDK location work; point `JAVA_HOME` and `sdk.dir` at them. `local.properties` is git-ignored.

`driver/build.sh` and `mac/scripts/build-app.sh` sign with the first "Apple Development" certificate in your keychain, or ad hoc when there is none. Set `SIGN_IDENTITY="..."` to pick another one.

## Running the tests

```sh
cd mac && swift test                       # wire format, lanes, ring buffer, mic path, policies
cd android && ./gradlew testDebugUnitTest  # JVM unit tests for the tablet's audio logic
driver/build.sh                            # the driver has no unit tests; CI checks that it builds
```

The tests need no tablet, no installed driver, and no audio device. Keep new tests that way: put logic you want to test in plain functions and test those, instead of driving CoreAudio, `AudioTrack` or USB from a test.

## CI

`.github/workflows/ci.yml` runs on every pull request and on `main`:

- **Mac helper tests**: `swift test` on macOS.
- **Tablet Audio driver build**: `driver/build.sh`, ad-hoc signed.
- **Android app build**: `./gradlew testDebugUnitTest assembleRelease` with JDK 17.

All three must pass before a change is merged.

## Pull requests

- Open or find an issue first that says what is wrong or what should change, and how to tell when it is done.
- Keep one change per pull request. For a bug, add a test that fails without the fix where the code allows it, and say in the PR what you ran and what it printed.
- Write commit messages as `type(scope): what changed`, for example `fix(android): keep the speaker playing after the playback position wraps`. Types: `feat`, `fix`, `docs`, `test`, `refactor`, `ci`, `build`, `chore`, `perf`.
- If you change what the app does, update both `README.md` and `README-ko.md`. They keep the same structure; `AGENTS.md` lists the README rules.
- Do not commit build output, `local.properties`, signing keys, or recordings.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
