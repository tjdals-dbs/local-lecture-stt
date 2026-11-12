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

For a signed sandbox check through the T07 recording UI, choose an empty disposable root (never a real lecture root), record for at least 20 seconds, stop, and inspect `recovery/audio.recovery.mov` in QuickTime Player or with AVFoundation. Confirm root access remains valid through stop and that exactly one recovery MOV remains. At T07, the MOV remains and `audio.m4a` must not exist; T08 owns finalization. The synthetic AVFoundation tests are the automated acceptance evidence, while the signed physical-microphone procedure below remains manual. Unsigned local/CI results do not prove persisted sandbox enforcement, TCC authorization, physical microphone behavior, hardware routes, process-kill loss windows, or power-loss recovery; T09/T26 cover the latter recovery matrix. Do not commit any test recordings.

## T07 coordinator and file-authoritative integration verification

`RecordingSessionCoordinatorTests` uses controlled continuation gates, fake time/ticker, and fake root/permission/capture/recorder/repository/catalog implementations. It verifies explicit-start-only side effects; no-root, reauthorization, and failed-root rejection with no resource effects; and created-folder root-change rejection with best-effort `.error/.notStarted` metadata rather than deletion. The writer-start tests assert the exact accepted PCM sequence is appended after user stop, caller-task cancellation, or capture terminal, and assert drain/finish/terminal-persistence ordering with exact-once terminal effects. A recording-metadata and recording-start-event gate matrix injects primary-stream throw, capture terminal, recorder terminal, and caller cancellation while start durability is pending; it proves the first typed failure is retained, no separate settlement runs before persistence returns, and exactly one terminal metadata/event path follows. A second matrix releases the same gated write into a persistence fault after that terminal wins, and verifies public `start()`, snapshot, and last result all retain the terminal failure while the persistence code is surfaced as a warning. The suite also covers unexpected normal primary-stream finish, primary backpressure, `recordingEnded` persistence failure, artifact non-deletion, and a gated prior-pump proof: a new start is busy until the old pump drains and capture/recorder observer streams terminate. View-model tests emit fake snapshots for preparing, recording, securing, secured-awaiting-finalization, interrupted, and error display/action states, and prove observation cancellation/re-subscription does not stop the coordinator-owned recording lifetime. These deterministic tests use no real sleeps or user data.

`RecordingSessionFileIntegrationTests` connects production `MicrophoneCaptureController`, `FileSessionRepository`, `StorageRootManager`, `AVFoundationAudioRecorder`, scanner, and SQLite catalog to a disposable temporary root. A synthetic capture driver yields 32 ordered mono 48 kHz chunks (65,536 frames) without any speech/STT consumer. The test decodes the finished recovery MOV with `AVAssetReader`, checks `.securing/.completed` metadata and ordered start/end events, verifies the catalog projection, proves final audio/transcript/checkpoint artifacts are absent, and requires balanced fake bookmark scope counts. It never requests TCC permission, selects a user root, or contains real lecture audio.

Run T07 tests alone with:

```sh
xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T07-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalLectureSTTTests/RecordingSessionCoordinatorTests \
  -only-testing:LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests \
  test
```

### T07 locally signed opt-in recording check

This procedure is manual and remains pending until explicitly performed. Use only a newly created empty disposable root and one stable local signing identity; never use a real lecture root or reset/edit the system TCC database.

1. Run the locally signed app and select the disposable root.
2. Enter a title, choose a language, and press **녹음 시작**.
3. On the first request only, confirm the microphone permission prompt appears.
4. Speak for at least 20 seconds and confirm device name, elapsed time, and input level update.
5. Stay quiet for at least five seconds; confirm one no-input warning appears while recording continues.
6. Speak again and confirm the warning clears.
7. Press **녹음 종료** and confirm the UI says recovery audio is stored and finalization is pending, not final completion.
8. In the session folder, confirm `metadata.json`, `events.jsonl`, and `recovery/audio.recovery.mov` exist and `audio.m4a` does not.
9. Open the recovery MOV in QuickTime Player or decode it with AVFoundation.

Unsigned build/CI and this synthetic test do not prove a signed sandbox bookmark across relaunch, real TCC authorization, physical microphone/hardware-route behavior, window/app termination, system sleep/wake, process-kill recovery, or T08 finalization.

## Verification record

On 2026-09-01, this baseline was verified with Xcode 26.6 (Build 17F113), Swift 6.3.3, macOS 26.6.2, and an arm64 host. The unsigned Debug build and unit/integration tests passed. The app exposes storage-root state plus the minimal T07 recording flow; signed sandbox bookmark persistence and physical microphone behavior still require the manual procedures below.

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

1. Build and run the app from Xcode using one stable local signing identity. In System Settings, manually allow microphone access for that app when the explicit recording action requests it. Do not run `tccutil reset` or edit TCC databases.
2. In the T07 recording flow, confirm the current system input's displayed name and its source sample rate/channel count. Speak or clap and confirm PCM chunks and the level meter change; do not log sample bytes or device IDs.
3. Leave the input silent (or disconnect the source) for at least five seconds. Confirm exactly one no-input warning appears while capture remains running, then confirm speech clears the warning.
4. Repeat explicit start/stop several times and confirm no duplicate-tap crash or duplicate level updates occur.
5. When an external input is available, disconnect it or change the macOS default input during capture. Confirm the current generation reports a device/route failure and does not silently continue using another microphone. Reconnect only for a new explicit start.

These steps require the T07 opt-in recording composition because T05 deliberately does not add debug recording UI, write session files, or prompt for permission during app/view construction.

## T08 audio finalization verification

T08 uses no packages, downloaded media, FFmpeg, network runtime, or microphone input in automated tests. New tests use disposable temporary roots and generated AAC. `AudioFinalizationTests` covers actual-file checkpoints, exclusive publication, retained staging, corruption/identity conflicts, full-completion proof gates, and controlled lifecycle continuations. `RecordingSessionFileIntegrationTests.testAppOwnedFinalizationDoesNotBlockEssentialSaveOrNextRecording` uses production capture/repository/root/recorder/catalog/finalizer composition with synthetic asymmetric endpoint signals. The original standalone T07 recovery-only assertion remains in place.

`AudioFinalizationLongMediaTests.testTwoHourContinuousAACProductionFinalizationAndRevalidation` runs in the default shared scheme and CI. A bounded synthetic PCM seed supplies a real encoded AAC packet and sample description. The test writes repeated payload in <=64 KiB batches and a compact QuickTime sample table with 337,500 consecutive 1,024-frame packets at 48 kHz. It does not wait two hours, insert sparse silence, or load whole media into memory. Production readers independently assert packet count, continuous timeline coverage, duration, provenance, and nonempty first/end PCM seek decode. Fixture generation, audio finalization, and revalidation times are logged separately; `getrusage(RUSAGE_SELF).ru_maxrss` records process peak RSS on macOS, while the media buffer high-water and fixed scratch limits explain bounded application buffering. Process RSS includes the test host and AVFoundation caches and is not an isolated allocator measurement. A 60-second whole-MVP target is not established by this audio-only test.

Use a task-specific derived-data directory:

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T08-DerivedData \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T08-DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

See [T08 acceptance](T08_ACCEPTANCE.md) for exact targeted/repeated commands and current results. Logs, media, xcresult and generated artifacts stay outside Git. Zero tests or a missing/unknown xcresult is not a pass.

The passthrough choice follows Apple's [source format hint contract](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/sourceformathint) and the installed SDK's `AVAssetWriterInput.h` description of `outputSettings: nil` and reader trim attachments. Endpoint readers set a [time range before starting](https://developer.apple.com/documentation/avfoundation/avassetreader/timerange). The deterministic fixture uses Apple's [sample duration table](https://developer.apple.com/documentation/quicktime-file-format/time-to-sample_atom/time-to-sample_table). The chosen APIs predate macOS 15; deployment target and arm64 requirement remain unchanged.

### Manual T08 check (pending)

Use one stable local signing identity and a newly created disposable root only. Record at least 20 seconds with different beginning/end signals. On Stop, confirm “안전하게 저장 중” is followed by audio-finalization stages and “오디오 파일 준비 완료 · 나머지 마무리 대기”. Open `audio.m4a` in QuickTime and inspect both endpoints. Confirm recovery MOV remains, metadata is `finalizing` with the original capture outcome, and no transcript/derived placeholders appear. Start a second recording while prior finalization is in progress and confirm its capture UI remains independent. Reopen the view and verify background progress persists. Permission reauthorization, signed sandbox enforcement, physical microphone/TCC latency and hardware routes remain manual. Process-kill, sleep/window/quit policy and power-loss scenarios remain T09/T10/T26 work; unsigned synthetic evidence does not establish them.
# T09 startup recovery checks

Use a disposable storage root. Create or retain a session with `recording` or `paused` metadata and a recovery MOV, terminate the app without normal completion, then relaunch it. Confirm the metadata becomes `interrupted/interrupted` before audio work, `audio.m4a` is produced only after T08 verification, recovery MOV bytes remain, and the UI says audio is ready while remaining finalization is pending. Reopen the app and use the retry action: recovery diagnostics must not accumulate duplicate events for the same durable state. Reauthorize a historical root and confirm its discovered result appears without moving existing sessions.

For deterministic T09 regressions, run C01 coalesced startup/root refresh, C02 live T07/T08 protection, C03 blocked historical recovery alongside a new T07 recording, C04 owned cancellation through its cleanup gate, B06 first-failure plus diagnostic/catalog/cleanup warnings, plus the R1 terminal-media/cache-separation, R2 late-success cancellation, and R3 same-root reauthorization presentation tests with `-test-iterations 20`. They do not replace the disposable-root relaunch check above or signed TCC/process-kill testing.

This manual procedure does not validate physical microphone/TCC, actual process kill/power loss, sleep/wake, window close, or app quit behavior. Those are pending T10/T26 validation.

## T10 lifecycle verification

Use generated PCM, disposable session roots, fresh result bundles and an injected AppKit presenter/reply/termination gateway. No automated test should terminate XCTest or open a real confirmation modal. `T10_ACCEPTANCE.md` records the current requirement/assertion mapping and actual result paths. Hardware tests below are separate.

The unchanged-candidate reproduction used the four exact `testReview...` identifiers in `prompts/T10_ASTRA_REVIEW_REPAIR.md`, after `git apply --check` and `git apply prompts/fixtures/T10_REVIEW_REGRESSIONS.patch`. They executed and failed 4/4 at `/private/tmp/stt-t10-astra-repro-native.GSLb2Q/Regressions.xcresult`. The R4 test was subsequently adapted to join wake asynchronously and acknowledge the real normal-Stop barrier before releasing its metadata gate.

Focused command used during repair (with new result names `focused-1` through `focused-6`, and additional individual F/I selectors as recorded in each log):

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t10-astra-final.N4Sysd/DerivedData \
  -resultBundlePath /private/tmp/stt-t10-focused-6.xcresult \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests \
  -only-testing:LocalLectureSTTTests/RecordingSessionCoordinatorTests \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests/testLifecycleQuitWaitsForProductionCleanupThenRepliesOnceWithoutExport \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests/testPowerOffQuiesceRetainsCheckpointAndFreshRecoveryResumesSameFiles \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO test
```

That focused command executed 61 passes, zero failures/skips. It is development evidence, not a substitute for the final full run after all edits. The follow-up two-test reproduction on `0fd6552` failed both tests with four expected assertions (`/private/tmp/stt-t10-followup.wT9Nm8/Repro.xcresult`). It used the usual project/scheme/Debug/arm64/unsigned flags with `-only-testing:LocalLectureSTTTests/RecordingSessionCoordinatorTests/testAuditSleepCancelsStartWaitingForInitialDiscovery` and `-only-testing:LocalLectureSTTTests/AppLifecycleTests/testAuditDuplicateEmptyWindowObservationCannotLoseAutomaticExit`, before production changes. Follow-up focused checks used both entire `AppLifecycleTests` and `RecordingSessionCoordinatorTests` classes and passed 67 tests (`FocusedFinal.xcresult` in that directory). The final full run includes the subsequent admission-generation hardening.

The final commands actually run were:

```sh
# The directory was originally allocated with mktemp -d /private/tmp/stt-t10-followup.XXXXXX.
# For a new run, use a new directory/result name rather than overwriting a bundle.
t10_run=/private/tmp/stt-t10-followup.wT9Nm8
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$t10_run/DerivedData" -resultBundlePath "$t10_run/Full.xcresult" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  CODE_SIGNING_ALLOWED=NO build test > "$t10_run/full.log" 2>&1

xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$t10_run/DerivedData" -resultBundlePath "$t10_run/Repeated.xcresult" \
  -test-iterations 20 -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests/testProductionActivityLeasesOverlapAndRejectCapturedOldIdleGeneration \
  -only-testing:LocalLectureSTTTests/RecordingSessionCoordinatorTests/testSystemSleepUsesInterruptedSettlementAndRetainsRecoveryPath \
  -only-testing:LocalLectureSTTTests/RecordingSessionCoordinatorTests/testAuditSleepCancelsStartWaitingForInitialDiscovery \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests/testLastWindowWaitsForFiniteFinalizationThenRequestsAutomaticTerminationOnce \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests/testAuditDuplicateEmptyWindowObservationCannotLoseAutomaticExit \
  -only-testing:LocalLectureSTTTests/RecordingSessionCoordinatorTests/testRepeatedAdapterQuitPerformsOneProductionSaveAndTrueReply \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests/testLifecycleQuitWaitsForProductionCleanupThenRepliesOnceWithoutExport \
  -only-testing:LocalLectureSTTTests/RecordingSessionCoordinatorTests/testProductionEssentialFailurePreservesFirstErrorAndLaterWarnings \
  CODE_SIGNING_ALLOWED=NO test > "$t10_run/repeated.log" 2>&1

xcrun xcresulttool get test-results summary --path "$t10_run/Full.xcresult" --compact
xcrun xcresulttool get test-results summary --path "$t10_run/Repeated.xcresult" --compact
xcrun xcresulttool get test-results tests --path "$t10_run/Repeated.xcresult" --compact
```

Full evidence is **264 passed (254 unit + 10 integration), zero failed/skipped**. Repeated evidence must have eight unique Test Case nodes, 20 Passed Repetition nodes per case and 160 passed device/configuration executions. The summary's top-level `passedTests` is eight for repetitions; that alone is not 160 executions. Confirm it against repetition nodes and individual log pass lines. Sandbox `testmanagerd` or xcresult cache permission failures require rerunning in the permitted normal Xcode environment; they are not a feature pass. Timeouts are watchdogs; continuation/expectation handshakes establish tested ordering.

Manual checks remain pending. Use a locally signed app and a new empty disposable root:

1. Confirm active recording/finalization prevents idle system sleep while display sleep remains possible.
2. Close Main during recording, leave Settings open, then close Settings; confirm capture/file progress continues. Reopen through Dock and check no unexpected automatic exit.
3. Close all user windows during finalization. Confirm exit once after successful completion; provoke a safe recoverable failure in a disposable root and confirm attention prevents auto-exit.
4. During recording use Cmd-Q → 계속 사용; confirm continued capture and unchanged metadata/events. Use Cmd-Q → 필수 저장 후 종료; relaunch and inspect retained recovery, interrupted outcome and T09 resume.
5. Close the lid during recording: interrupted outcome, readable MOV, no capture restart after wake. Repeat during securing/finalization and check checkpoint resume after cleanup.
6. Exercise real logout/power-off/process kill and power loss only under a separately safe hardware procedure. Keep recoverable artifacts for inspection. Do not infer physical TCC/microphone, signed sandbox/bookmark behavior or power-loss durability from unsigned synthetic tests.
