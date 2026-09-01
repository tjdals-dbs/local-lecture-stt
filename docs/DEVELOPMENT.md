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

## T06 recovery-writer verification

`AudioRecorderTests` generates PCM in temporary disposable roots; it does not request microphone permission, touch a user root, or use a real lecture recording. The test groups are:

- `AudioRecorderContractAndFaultTests`: framework boundary, storage/writer/converter/readiness/sample/append/disk-full/flush/finish/cancellation faults, first-error retention, late event, partial-byte preservation, and exact-once cleanup.
- `AudioRecorderLifecycleTests`: ordering and format violations, repeated/concurrent lifecycle, append-stop-failure races, cleanup-gated restart, stale-operation isolation, contiguous PTS, one tail drain, and per-chunk bounded conversion high-water.
- `AudioRecorderStorageAndConversionTests`: fixed location-root path, collision and symlink rejection, active-root change isolation, security-scope balance, and stateful 44.1 kHz mono/48 kHz stereo/32 kHz mono conversion with explicit two-channel contribution.
- `AudioRecorderFragmentedMOVIntegrationTests`: streams 22 seconds of small irregular synthetic chunks, asserts at least two top-level `moof` boxes in a byte-for-byte active-file snapshot, and decodes that prefix with a separate `AVAssetReader` before normal finish. It then independently verifies the normally finished file by decoding nonempty first and last sample buffers and checking AAC-LC, mono 48 kHz, audio-only tracks, duration, fixed path, and absence of `audio.m4a`.

`AVAssetWriter.finishWriting()` may canonicalize the completed movie so the completed file is not used as evidence for the pre-finish recovery fragments. The test records the completed top-level `moof` count for diagnostics, while the multiple-fragment assertion is on the active output snapshot and the completed-file assertions are on its independently decoded payload. This distinction prevents a normally finished asset from being mislabeled as active-prefix recovery evidence.

Run all T06 groups with the normal test command below, or target them explicitly:

```sh
xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalLectureSTTTests/AudioRecorderContractAndFaultTests \
  -only-testing:LocalLectureSTTTests/AudioRecorderLifecycleTests \
  -only-testing:LocalLectureSTTTests/AudioRecorderStorageAndConversionTests \
  -only-testing:LocalLectureSTTTests/AudioRecorderFragmentedMOVIntegrationTests \
  test
```

For a signed sandbox check after T07 supplies the recording UI, choose an empty disposable root (never a real lecture root), record for at least 20 seconds, stop, and inspect `recovery/audio.recovery.mov` in QuickTime Player or with AVFoundation. Confirm root access remains valid through stop and that exactly one recovery MOV remains. At T06, the MOV remains and `audio.m4a` must not exist; T08 owns finalization. Before T07 there is intentionally no production UI that starts capture or the writer, so the synthetic AVFoundation test above is the current executable acceptance evidence. Unsigned local/CI results do not prove persisted sandbox enforcement, TCC authorization, physical microphone behavior, hardware routes, process-kill loss windows, or power-loss recovery; T09/T26 cover the latter recovery matrix. Do not commit any test recordings.

## Verification record

On 2026-09-01, this baseline was verified with Xcode 26.6 (Build 17F113), Swift 6.3.3, macOS 26.6.2, and an arm64 host. The unsigned Debug build and unit/integration tests passed. The app exposes the minimal storage-root state in its main window and Settings; signed sandbox bookmark persistence and physical microphone behavior still require the manual procedures below.

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

Open `LocalLectureSTT.xcodeproj` in Xcode, select the shared `LocalLectureSTT` scheme, and run it. The main window shows the storage-root state and a selection/reapproval action as appropriate. Choose **Local Lecture STT → Settings…** to change the active storage root or reauthorize it. You can also run the Debug app product after the build command.

The committed project intentionally has no development team. Unsigned build/test verification uses `CODE_SIGNING_ALLOWED=NO`; signing may be needed for a separately installed local app. The app target has sandbox, microphone, user-selected read/write, and app-scoped bookmark entitlements. T03 opens a directory-only panel only after an explicit user action.

## CI

[`.github/workflows/macos-ci.yml`](../.github/workflows/macos-ci.yml) runs the same unsigned Debug arm64 build and test commands on the `macos-15` runner for pushes to `task/**`, `dev`, and `main`, and can also be run manually. It reports the Xcode, Swift, and machine architecture in its log.

## T04 catalog verification

The app links macOS system `libsqlite3`; no package installation is required. Runtime catalog data is at `Application Support/LocalLectureSTT/Catalog/session-catalog.sqlite3`; damaged copies are retained under `Catalog/Corrupt/` and all of these runtime paths are ignored by Git.

For a manual check, use disposable roots and synthetic metadata only. Close the app before moving/deleting a catalog DB and its `-wal`, `-shm`, and `-journal` sidecars, then restart to rebuild from accessible session folders. T21 has not added a catalog list UI yet, so automated tests are the acceptance evidence for catalog rows and statuses.

## T05 microphone capture manual verification

The default CI build is unsigned and its synthetic test driver does not prove TCC authorization, physical microphone input, or hardware route changes. Perform this opt-in check only with a locally signed build that retains the committed App Sandbox microphone entitlement and usage description; do not use a real lecture-session root or record diagnostic PCM to a file.

1. Build and run the app from Xcode using one stable local signing identity. In System Settings, manually allow microphone access for that app when the future T07 explicit recording action requests it. Do not run `tccutil reset` or edit TCC databases.
2. In the T07 recording flow, confirm the current system input's displayed name and its source sample rate/channel count. Speak or clap and confirm PCM chunks and the level meter change; do not log sample bytes or device IDs.
3. Leave the input silent (or disconnect the source) for at least five seconds. Confirm exactly one no-input warning appears while capture remains running, then confirm speech clears the warning.
4. Repeat explicit start/stop several times and confirm no duplicate-tap crash or duplicate level updates occur.
5. When an external input is available, disconnect it or change the macOS default input during capture. Confirm the current generation reports a device/route failure and does not silently continue using another microphone. Reconnect only for a new explicit start.

These steps require the T07 opt-in recording composition because T05 deliberately does not add debug recording UI, write session files, or prompt for permission during app/view construction.
