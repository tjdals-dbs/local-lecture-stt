# Development

## Requirements

- Full Xcode 26.6 (Build 17F113) or a compatible full Xcode installation
- Apple Silicon macOS host; this baseline was verified on macOS 26.6.2 (`arm64`)

Confirm the selected developer directory and toolchain:

```sh
xcode-select -p
xcodebuild -version
swift --version
```

If Command Line Tools is selected while full Xcode exists, prefix each command with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The project is `LocalLectureSTT.xcodeproj` and its shared scheme is `LocalLectureSTT`.

## Verification record

On 2026-08-30, this baseline was verified with Xcode 26.6 (Build 17F113), Swift 6.3.3, macOS 26.6.2, and an arm64 host. The unsigned Debug build and both smoke tests passed. A manual launch displayed the one main window and its initial-shell placeholder; **Settings…** opened the settings placeholder, and the app quit normally.

## Build and test

Run these commands from the repository root. They are unsigned, Debug, and arm64-only.

The project Debug configuration explicitly sets `SWIFT_OPTIMIZATION_LEVEL = -Onone`, so Debug builds use `-Onone` instead of optimized `-O` for Swift compilation. On Xcode 26.6 this produces the `__preview.dylib` JIT product and does not show the prior Preview-disabled guidance.

### Known Xcode 26.6 diagnostic

The project deliberately does not link `AppIntents`. Xcode 26.6 nevertheless invokes `appintentsmetadataprocessor` for the app and both test targets, emitting `Metadata extraction skipped. No AppIntents.framework dependency found.` The build and tests still pass. `EXTRACT_APP_INTENTS_METADATA = NO` was tested and does not suppress this toolchain-generated diagnostic, so it is not retained as an ineffective project setting and no AppIntents dependency is added merely to silence it.

```sh
xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Check the project targets and shared scheme with `xcodebuild -list`. Check the configured deployment target and architecture with `xcodebuild -showBuildSettings`; inspect the built executable with `file` or `lipo -archs`.

## T03 storage-root manual verification

Use a newly created, empty test directory only; never select a real lecture-session root for this procedure.

1. Run the app and choose **저장 폴더 선택** from the main window. Select test directory A.
2. Quit normally, run the same locally signed build again, and confirm that A appears as available without reopening the panel.
3. Open Settings, choose **저장 폴더 변경**, and select empty directory B. Confirm A is neither moved nor changed.
4. Invoke selection and cancel the panel; confirm B remains active.

The committed entitlement enables app-scoped bookmarks, but the CI build is unsigned and cannot prove sandbox persistence. Perform the restart portion with the same locally signed app identity before treating actual sandbox enforcement as verified. Automated tests use a temporary Application Support fixture and a fake scoped-bookmark codec; they never touch the user's Application Support or roots.

## Run locally

Open `LocalLectureSTT.xcodeproj` in Xcode, select the shared `LocalLectureSTT` scheme, and run it. The initial shell shows one main window. Choose **Local Lecture STT → Settings…** to open the settings placeholder. You can also run the Debug app product after the build command.

The committed project intentionally has no development team. Unsigned build/test verification uses `CODE_SIGNING_ALLOWED=NO`; signing may be needed for a separately installed local app. The app target has sandbox, microphone, user-selected read/write, and app-scoped bookmark entitlements. T03 opens a directory-only panel only after an explicit user action.

## CI

[`.github/workflows/macos-ci.yml`](../.github/workflows/macos-ci.yml) runs the same unsigned Debug arm64 build and test commands on the `macos-15` runner for pushes to `task/**`, `dev`, and `main`, and can also be run manually. It reports the Xcode, Swift, and machine architecture in its log.
