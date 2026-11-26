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

For a manual check, use disposable roots and synthetic metadata only. Close the app before moving/deleting a catalog DB and its `-wal`, `-shm`, and `-journal` sidecars, then restart to rebuild from accessible session folders. T21 now displays these catalog rows and statuses in the main-window sidebar.

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

## T11 engine contract and fake verification

No new dependency, setup command, model file, network access or microphone permission is needed. Both new test files belong to the existing unit target and shared scheme. The fake is not wired into live composition or previews.

A scenario supplies `loads`/`starts` preparation delays/failures and a FIFO `requests` array. Each request script contains `FakeSTTStep(after:kind:text:detectedLanguage:failure:)`; `after` is logical milliseconds since **processing start**. Construct a synthetic model/session/request, use the instance through `any STTEngine`, load/start/infer, and advance the concrete fake with `advance(by:)`. The returned feed's `events()` may be claimed once. Read partials as replacement snapshots; the final/failed/cancelled value finishes that request. Use `withdraw()` for explicit cancellation and await cleanup. Nonzero delays require explicit clock advances, including cancellation/unload cleanup. Before advancing held preparation/control tasks, await `waitUntil` for their registered phase or owned waiter count. `advance` itself acknowledges all due events; no `Task.yield` or polling is needed. Breaking a stream loop is not a request cancellation; cancelled `next()` or explicit withdrawal is.

Reproducible focused and full commands (new result names each run):

```sh
t11_run=$(mktemp -d /private/tmp/stt-t11-validation.XXXXXX)
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$t11_run/DerivedData" -resultBundlePath "$t11_run/Focused.xcresult" \
  -only-testing:LocalLectureSTTTests/STTEngineTests \
  -only-testing:LocalLectureSTTTests/FakeSTTEngineTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 30 \
  CODE_SIGNING_ALLOWED=NO test
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$t11_run/DerivedData" -resultBundlePath "$t11_run/Full.xcresult" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path "$t11_run/Full.xcresult" --compact
xcrun xcresulttool get test-results tests --path "$t11_run/Full.xcresult" --compact
```

Tests use explicit synthetic IDs, audio arrays, barriers and logical time. Wall-clock sleep is restricted to the failure watchdog, which releases held work/probes using the same fake lifecycle; it is never a success/timing assertion. Exact execution paths, counts and requirement assertions are in [T11 acceptance](T11_ACCEPTANCE.md). Physical G1 remains Unverified under the user's scheduling decision; it is not a T11 submission prerequisite.

The FIFO callback repair adds four tests to the same focused suite commands: the supplied `testIndependentEarlyCallbackCannotLetNewAdmissionOvertakeQueuedWork`, plus failed-terminal/activation-origin, waiting-end and equal-deadline worker coverage. Accepted `deliver` callbacks acknowledge FIFO progression and drain settlement immediately; no artificial zero-time advance is needed. Exact selectors, the before-fix failure and current execution evidence are in [FIFO callback repair](T11_ACCEPTANCE.md#fifo-callback-repair).

T11 re-review adds regression selectors `FakeSTTEngineTests/testDisabledPartialsStillDetectLanguageAndDeliverTheFinalSnapshot` and `FakeSTTEngineTests/testLogicalClockNearInt64LimitStillSettlesCancellationAndUnload`, plus four coverage tests for rejected clock-budget admissions and language validation. The same focused commands above include all of them; no project or scheme changes are needed. A disabled partial still performs scripted language detection at its logical deadline and only suppresses publication. At Int64's clock boundary, new work must fit its full FIFO/cleanup horizon; cleanup itself remains settleable at the last tick. The real-clock watchdog is joined during teardown. Re-review execution evidence and commands are appended to [T11 acceptance](T11_ACCEPTANCE.md#re-review-and-same-task-repair).

The re-review's first full execution exposed a pre-existing capture test snapshot race. Only `MicrophoneCaptureTests/testDeviceDisconnectRouteChangeAndLateEventsAreTerminalOnce` changes: after terminal events it waits for the exact failed lifecycle using the existing test helper, then checks the fresh state, one stop and ignored late event. Capture production is unchanged. The case passed 20 repetitions after repair; run it with the same Xcode settings plus `-only-testing:LocalLectureSTTTests/MicrophoneCaptureTests/testDeviceDisconnectRouteChangeAndLateEventsAreTerminalOnce -test-iterations 20`. This legacy case's bounded polling helper is separate from the fake's explicit logical-clock timing.

## T12 model repository verification

T12 uses only generated tiny payloads, disposable roots and injected scope/format/reference adapters. No real model weights, user Application Support, lecture recordings, runtime catalogs or bookmarks belong in fixtures. Construction is inert; tests explicitly invoke repository/catalog operations. Test-format validation recognizes a generated header, while the live default reports unavailable validation.

Baseline executed before implementation: unsigned Debug arm64 build/test, **299 passed, 0 failed, 0 skipped** (289 unit + 10 integration). Result: `/private/tmp/stt-t12-baseline.8nwMTV/Baseline.xcresult`; log: `build.log` in that directory.

Focused command (choose a fresh result path on each run):

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t12-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t12-targeted-final.xcresult \
  -only-testing:LocalLectureSTTTests/ModelRepositoryTests \
  -only-testing:LocalLectureSTTTests/RecordingSessionCoordinatorTests/testSettlementWaitsForPriorPumpDrainAndObserverTerminationBeforeNewSessionStarts \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO test
```

Race tests use acknowledged continuation gates. XCTest's bounded waiter is a failure watchdog, not ordering; no sleep, repeated-run quota, yield loop or polling drives correctness. Held filesystem mutation blocks release/join their worker on failure. Focused failures during development are retained in temporary logs/results; they are not passing evidence. The current verified focused/full counts and exact result paths are in [T12 acceptance](T12_ACCEPTANCE.md).

Full command:

```sh
t12_run="$(mktemp -d /private/tmp/stt-t12-validation.XXXXXX)"
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$t12_run/DerivedData" \
  -resultBundlePath "$t12_run/Full.xcresult" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path "$t12_run/Full.xcresult" --compact
xcrun xcresulttool get test-results tests --path "$t12_run/Full.xcresult" --compact
```

Xcode testmanagerd and xcresult cache access require the normal permitted macOS execution path. Runner/cache failure or zero executions is not a pass. Existing warnings must be compared with the baseline; T12 must add no attributable compiler warnings.

Manual signed-Sandbox procedure — Pending, not executed by T12:

1. Build/install a separately authorized signed Sandbox app. A later model-management UI or a narrowly instrumented development harness may call the Infrastructure registration adapter for an explicitly selected test folder; there is no file panel/UI in T12.
2. Prepare a generated package with explicit identity, revision, file hashes, lengths, format and redistributable license metadata. Inject its offline test recognizer; the default recognizer must keep an unrecognized package unvalidated.
3. Select only that source, confirm start/stop balance on success, permission denial and cancellation, and confirm the live path resolves inside the container's Application Support/LocalLectureSTT/Models. Registration records selected directory identity; inability to inspect it must fail conservatively rather than accept a replacement.
4. Remove/unmount the original source after success. Relaunch with no network and verify only the app-owned package. Check revision coexistence and explicit deletion assessment/acknowledgment, including an unavailable historical session root.
5. Verify that session audio/transcripts/metadata remain unchanged and readable after model deletion. Inspect retained operation diagnostics for interrupted cleanup; never manually delete unknown directories as part of the automated procedure.

Physical microphone/TCC, actual inference/model benchmark and G1 hardware checks are outside T12. G1 remains Unverified. The task branch is a Phase 1 candidate only; status/checklist updates, dev integration and the next Task require independent coordinator review and separate authorization.

T12 same-Task review repair adds three formal selectors to `ModelRepositoryTests`: `testReviewPayloadMutationAfterVerificationMustNotPublishSuccess`, `testReviewIdempotentResultMustRevalidateAfterScopeRelease` and `testReviewFutureManifestSchemaMustBeReportedWithoutV1Fields`. All run through the existing production seams. The first two use acknowledged manifest-write/scope-release gates; the third verifies schema-first decode and preservation of unknown future layout. No legacy recorder test changes.

Repair focused command, executed with the final source/test tree:

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t12-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t12-repair-focused-final.xcresult \
  -only-testing:LocalLectureSTTTests/ModelRepositoryTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO test
```

Repair full runs use the full command above, with `-derivedDataPath /private/tmp/stt-t12-work/DerivedData` and a fresh `/private/tmp/stt-t12-repair-validation.XXXXXX/Full.xcresult`. Exact latest paths, actual execution counts and original failing diagnostic evidence are in the acceptance document's same-Task repair section. Executable fingerprints for the repair are `/private/tmp/stt-t12-repair-executable.sha256`; recheck them against the committed tree before push. The initial candidate's 329-test result is historical, not the repaired tree's final result.

## T13 download verification

T13 adds only the outgoing-network client entitlement; Sandbox and production ATS/TLS stay enabled. No app-start download composition or model UI exists. At the T13 baseline the production catalog was empty. T17 supplies the pinned native descriptor and validator. All automated packages are tiny generated bytes, including bounded generated buffers for actual HTTP range tests. No weights, runtime journals/resume data, servers or build artifacts belong in Git.

Focused command (normal permitted macOS Xcode path; unique result bundle required):

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t13-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t13-focused-verified.xcresult \
  -only-testing:LocalLectureSTTTests/ModelDownloadTests \
  -only-testing:LocalLectureSTTTests/ModelRepositoryTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO test
```

Full final-source command:

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t13-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t13-verified/Full.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path /private/tmp/stt-t13-verified/Full.xcresult --compact
xcrun xcresulttool get test-results tests --path /private/tmp/stt-t13-verified/Full.xcresult --compact
```

`ModelDownloadTests` and its fixture helper are members of the actual unit target; both existing targets stay in the shared scheme. `DownloadHTTPServer` uses native loopback TCP sockets, acknowledges request/body delivery, implements Range/ETag/Content-Range, and releases/joins all held workers and sockets on stop. The injected ordinary URLSession uses the actual production delegate/receipt path. No URLProtocol fake, internet/CDN, sleeps, yield loops, polling or daemon scheduling drives automated ordering. Continuation gates/expectations acknowledge cancellation, copy/publication/cleanup races and range prefix receipt. XCTest timeouts are failure watchdogs. A separate test constructs/closes the actual background configuration and checks reconnect against an existing task; that does not prove daemon/process-relaunch behavior.

Compare actual xcresult summary/tree counts, failures/skips, T13/T12/T11 membership and the three T12 review selectors. Do not infer execution from exit status or copy historical counts. Exact outcomes and preserved failed attempts are in [T13 acceptance](T13_ACCEPTANCE.md). The first restricted baseline could not access testmanagerd (zero execution); result inspection also needs permitted xcresult cache access. Use the normal approval path, never treat these failures as passes or disable legacy tests. The unchanged baseline also observed one runner exit during an audio test; preserve that evidence separately from current-tree results.

Manual signed-Sandbox/background continuation procedure — **Pending, not run**:

1. Use a separately authorized signed development harness with the actual app Sandbox/client entitlement. Inject a fixed catalog descriptor/delivery for a generated multi-file package hosted by a controlled HTTPS server with a normally trusted certificate; inject only the generated-header offline recognizer. Use the production background configuration and container Downloads/Models locations. Do not weaken TLS/ATS or point at lecture/session roots. This harness is not model-management UI or a production model choice.
2. Construct/relaunch the service and inspect pending/inventory/catalog while the server records requests. Confirm zero new requests before an explicit start/resume command. Start once, record the stable operation/session/task IDs and server request counts, and confirm no partial payload appears in installed inventory.
3. Pause after an acknowledged body prefix. Record whether Foundation supplies an opaque token and the reported resumability. Reconstruct a fresh service, inspect pending without connecting, then explicitly resume. Check actual positive server Range/didResume offset versus a reported byte-zero fallback; neither a full restart nor nil data is proof of byte-range resume. Repeat with a server that ignores Range and with a changed resource; verify truthful restart/error and catalog hash rejection.
4. Test ordinary app backgrounding/termination separately from user force quit. Relaunch explicitly, inspect pending offline, then issue reconnect/resume and confirm an existing live task is reused rather than duplicated. Record what the macOS daemon actually did. `sessionSendsLaunchEvents = false` adds no automatic app relaunch policy. Do not claim force-quit continuation, lid-closed execution, power-loss durability or a changed T10 exit policy.
5. Cancel during transfer, verification and immediately after publication. Confirm precommit work stays unselectable, postcommit work stays installed with any warning, and only proven operation-owned data is removed. Review retained/unknown records without deleting them. Check scoped local import and its exact-once release still work in the signed Sandbox.
6. Stop the server/block networking, reconstruct the repository and validate/resolve the installed owned copy. Confirm source removal, revision coexistence, no default change and preserved session audio/transcripts. This proves only the implemented model path, not the complete 17.7 MVP offline suite or actual inference.

Physical microphone/TCC, signed bookmarks, sleep/power and G1 remain **Unverified/Pending**. T13 is a Phase 1 candidate until independent review; official completion, status/checklist updates, dev/main integration and T14 need separate authorization.


T13 same-Task review repair (source baseline `0665f32`) adds seven regressions to the existing unit target. The three review diagnostics are now formal tests, plus exact live-association selection/idempotence, cancel claim/pin preservation and transport-error handling across a held discard, same-instance committed retry, and partial-file replacement protection. The original stale-journal test now calls the public `retry` command. Range tests acknowledge positive delegate bytes after the service processes progress before pausing; actual positive Range/resumed offset, request counts and final-byte assertions remain required.

Repair focused command:

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t13-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t13-repair-focused-verified.xcresult \
  -only-testing:LocalLectureSTTTests/ModelDownloadTests \
  -only-testing:LocalLectureSTTTests/ModelRepositoryTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO test
```

Repair full verification uses the full command above with `-resultBundlePath /private/tmp/stt-t13-repair-verified/Full.xcresult`; both xcresult summary/tree commands use that same repaired result path. Exact new counts, retained failed attempts, commands and the reproduced three-failure review evidence are in the acceptance document's same-Task repair section. Production schema/digest/capacity formula, entitlements and recorder/lifecycle/engine composition are unchanged. The signed-Sandbox/background-daemon manual procedure above remains Pending; fresh-cancel tests exercise real ordinary URLSession and explicit production seams, not process-daemon continuation.


T13 postcommit review repair (baseline `db79d38`) adds nine formal `testReReview...` selectors. They cover low/no/unknown download capacity after a verified commit, partial/missing/replaced/symlink/unknown temporary remnants, fresh postcommit cancel truth, unavailable/corrupt final validation, claim/cancel admission and original proof across failed cleanup or missing metadata. The three failed review diagnostics are preserved in the acceptance record. No recorder/engine test is disabled or relaxed.

Latest focused command:

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t13-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t13-postcommit-focused-verified.xcresult \
  -only-testing:LocalLectureSTTTests/ModelDownloadTests \
  -only-testing:LocalLectureSTTTests/ModelRepositoryTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO test
```

Latest full verification uses the same configuration/derived data with `-resultBundlePath /private/tmp/stt-t13-postcommit-verified/Full.xcresult CODE_SIGNING_ALLOWED=NO build test`, without the focused selectors. Inspect summary and tests via `xcrun xcresulttool get test-results summary --path /private/tmp/stt-t13-postcommit-verified/Full.xcresult --compact` and the corresponding `tests` subcommand. Exact outcomes and failed intermediate attempts are in the acceptance postcommit-repair section. All manual signed-Sandbox/background/G1 procedures above remain Pending/Unverified; the app's recording/lifecycle, model catalog, schema, dependencies, entitlements and default unavailable recognizer are unchanged.

## T14 explicit real-model and contract verification

Default app and shared Xcode scheme remain lightweight: no model download, inference or benchmark starts automatically. Both original test targets run. The developer CLI and unit tests link the actual pinned OSS library. Xcode resolves `WhisperKit` at `1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4` (v1.1.1), with resolution committed under `LocalLectureSTT.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Root SwiftPM has its own committed resolution for the opt-in CLI. macOS 15/arm64 and Swift 6 app settings are unchanged.

Executed CLI build (from repository root):

```sh
swift build --scratch-path /private/tmp/stt-t14-swift-build
```

Only run bootstrap explicitly when the matching verified package is absent. It downloads exactly the committed descriptor's ~3.09 GB candidate and tokenizer files; creates a new supplied source directory, verifies every pinned length/SHA256 and retains failures for inspection. It does not install or invoke the SDK downloader. `published-files.json` records official immutable HF revisions, LFS SHA256/Git blob IDs and URLs; LFS hashes are published metadata, while non-LFS SHA256 values were locally derived after verifying the published Git blob identity. This is not a signed author guarantee. `candidate.json` includes immutable license/model/tokenizer references; production catalog is still empty. Standard converted weights are Float16, without compression/quantization; no alternative model is substituted.

```sh
python3 tools/t14/bootstrap.py /private/tmp/stt-t14-assets/source-new
/private/tmp/stt-t14-swift-build/debug/stt-benchmark import \
  tools/t14/candidate.json /private/tmp/stt-t14-assets/source-new /private/tmp/stt-t14-assets/store-new
```

`import` explicitly composes T12's real format validator, catalog authority, security-scope handle, per-file hashing, copied staging and verified atomic installer. The initial actual source is `/private/tmp/stt-t14-assets/source`; installed stores are `/private/tmp/stt-t14-assets/store` and a second independently imported `/private/tmp/stt-t14-offline/store`. No Application Support/user session data is touched. Use canonical no-follow paths (`/private/tmp`, not the `/tmp` symlink); the CLI intentionally avoids Foundation `standardizedFileURL`, which converts `/private/tmp` back to that alias.

The executed nonprivate test input uses the already installed Samantha voice; do not download a voice. Check `say -v '?'` before choosing an available voice on another machine. Generation and one-time canonical preparation:

```sh
say -v Samantha -r 155 -o /private/tmp/stt-t14-assets/speech.aiff \
  'This is a local speech recognition test. The model runs without an internet connection. Audio files remain on this computer.'
afconvert -f WAVE -d LEF32@16000 -c 1 \
  /private/tmp/stt-t14-assets/speech.aiff /private/tmp/stt-t14-assets/speech.wav
/private/tmp/stt-t14-swift-build/debug/stt-benchmark prepare \
  /private/tmp/stt-t14-assets/speech.wav /private/tmp/stt-t14-assets/input.json local-samantha-v1 \
  'Generated locally by macOS say, installed Samantha voice, rate 155, original nonprivate test sentence; afconvert LEF32@16000 mono; no voice download.'
```

Preparation requires an already canonical mono/16 kHz file ≤30 seconds, decodes it once to owned Float32 and exports a checked portable plan at a 5-second media offset. No fresh SDK file decoder participates in subsequent runs. The actual input is 112,640 frames/7.040 s. `run`/`cancel` optionally accept one final `english`, `korean` or `automatic` argument; omitted preserves the original English default. Automatic mode uses explicit checked detection; transcribe always receives a fixed language and `detectLanguage=false`. Preserve this JSON for T15 rather than regenerating speech. `run` performs one warm-up plus two measured load/start/infer/end/unload cycles, reloading each time; a new output directory is mandatory. `cancel` performs the same plan but withdraws the measured repetition 1 on the first actual partial, requires its cancelled terminal, then performs fresh successful inference in repetition 2.

```sh
/private/tmp/stt-t14-swift-build/debug/stt-benchmark run \
  tools/t14/candidate.json /private/tmp/stt-t14-assets/store \
  /private/tmp/stt-t14-assets/input.json /private/tmp/stt-t14-assets/run-new
/private/tmp/stt-t14-swift-build/debug/stt-benchmark cancel \
  tools/t14/candidate.json /private/tmp/stt-t14-assets/store \
  /private/tmp/stt-t14-assets/input.json /private/tmp/stt-t14-assets/cancel-new
```

Actual offline verification uses macOS `sandbox-exec` with the committed process-only `deny network*` profile, without changing system network settings. HTTPS fails with DNS denial; a direct TCP socket to 1.1.1.1:443 fails with `EPERM`. Independently importing the verified local source into a new store also succeeds under this policy. Use fresh explicitly named cache directories, leaving the user's HOME unchanged:

```sh
mkdir -p /private/tmp/stt-t14-final-cache/home /private/tmp/stt-t14-final-cache/cache /private/tmp/stt-t14-final-cache/tmp
/usr/bin/sandbox-exec -f tools/t14/offline.sb /usr/bin/env \
  CFFIXED_USER_HOME=/private/tmp/stt-t14-final-cache/home \
  XDG_CACHE_HOME=/private/tmp/stt-t14-final-cache/cache TMPDIR=/private/tmp/stt-t14-final-cache/tmp \
  /private/tmp/stt-t14-swift-build/debug/stt-benchmark run \
  tools/t14/candidate.json /private/tmp/stt-t14-offline/store \
  /private/tmp/stt-t14-assets/input.json /private/tmp/stt-t14-offline/final-results
/usr/bin/sandbox-exec -f tools/t14/offline.sb \
  /private/tmp/stt-t14-swift-build/debug/stt-benchmark cancel \
  tools/t14/candidate.json /private/tmp/stt-t14-offline/store \
  /private/tmp/stt-t14-assets/input.json /private/tmp/stt-t14-offline/final-cancel
```

The local-only tokenizer factory and fixed model paths do not consult SDK global model/tokenizer caches. The initial offline run also used a fresh model store. These tests do **not** clear undocumented Apple Core ML/Neural Engine system specialization caches or promise a fully cold chip. The OS denial also applies to SDK fallback code even if an unexpected path were reached. For negative verification, clone the disposable store (`cp -cR`), move `tokenizer.json` out of that clone, run under the same denial, restore it, then separately move `MelSpectrogram.mlmodelc/coremldata.bin` out and repeat. Each run must exit nonzero, export `success=false`/typed `loadFailed` with no terminal/inference metric, and leave source/original store intact. Actual clone: `/private/tmp/stt-t14-offline/missing-store`; evidence is listed in acceptance.

Reports use `ProcessInfo.systemUptime` monotonic timing. `loadSeconds` includes repository checksum/format validation and local tokenizer setup; separately measured prewarm/model load are reported when observed. Queue delay is engine admission→worker start; inference is worker start→actual SDK settlement, excluding queue/load/warm-up; final elapsed is caller admission→terminal consumption. First partial exists only if observed. RTF is inference seconds divided by 7.040 s, never inverted; warm-up is marked/excluded and no aggregate speed claim is made. `TASK_VM_INFO.phys_footprint` is process-wide, baseline before load and 50 ms observed peak through unload, plus final sample. Timer cancellation is joined; short peaks can be missed and nil metrics are diagnosed. These are window timings, not microphone utterance-end latency, real-lecture accuracy or G2 performance success.

Focused and full commands actually used on the final executable tree:

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t14-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t14-focused-final.xcresult \
  -only-testing:LocalLectureSTTTests/WhisperKitSTTEngineTests \
  -only-testing:LocalLectureSTTTests/STTEngineTests -only-testing:LocalLectureSTTTests/FakeSTTEngineTests \
  -only-testing:LocalLectureSTTTests/ModelRepositoryTests -only-testing:LocalLectureSTTTests/ModelDownloadTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO test
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t14-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t14-full-final.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path /private/tmp/stt-t14-full-final.xcresult --compact
xcrun xcresulttool get test-results tests --path /private/tmp/stt-t14-full-final.xcresult --compact
```

Use fresh result/output paths when reproducing. Race ordering uses acknowledged continuation/SDK cancellation barriers, not sleep/yield/polling. Gate watchdogs release workers in teardown. Normal signing/TCC, physical microphones, real long recordings/sleep/power, real lectures, accuracy comparisons, and G1/G2 remain unverified/outside T14. Exact current results and candidate pins are in [T14 acceptance](T14_ACCEPTANCE.md).


### T14 same-Task review repairs

The `d2473f2` review found accepted 112–128-token hints being suffix-trimmed by SDK prefill, end/cancel returning before concurrent unload cleanup, and SDK transcription silently falling back to English after detector failure. Current code rejects prompts above the pinned **111-token** prefill limit (plus SDK control tokens), joins the captured cleanup task after work drain, and performs explicit detector calls with supported/finite matching-score validation. The selected language is passed explicitly with SDK redetection disabled. Blank results publish no language, even when the SDK labels its empty result with a default. This adds no VAD or product UI.

`WhisperKitSDKBoundaryTests` executes the actual pinned prefill and public `detectLangauge` helper using tiny synthetic tokenizer/tensors and model-load stubs; it does not download weights, claim format usability, or replace the required real runs. The detector-error case verifies that the SDK helper's typed failure reaches the production backend and that transcription is never called. The cleanup test holds actual backend settlement, acknowledges both control callers capturing the cleanup task and checks the actor-owned waiter count before releasing it. No sleeps/yields/negative-timeout assertions order these races. SDK progress text contains context before SOT; the boundary test verifies output-only token decoding. Empty prefill callbacks cannot publish or create first-partial metrics, and only the first SDK window publishes partials; final results cover all windows.

Repair-focused command (fresh result path on reproduction):

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t14-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t14-repair-accepted-focused.xcresult \
  -only-testing:LocalLectureSTTTests/WhisperKitSDKBoundaryTests \
  -only-testing:LocalLectureSTTTests/WhisperKitSTTEngineTests \
  -only-testing:LocalLectureSTTTests/STTEngineTests -only-testing:LocalLectureSTTTests/FakeSTTEngineTests \
  -only-testing:LocalLectureSTTTests/ModelRepositoryTests -only-testing:LocalLectureSTTTests/ModelDownloadTests \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO test
```

The final full repair command uses the same project/scheme/destination/derived data/lockfile/timeouts, omits the `-only-testing` selectors, uses `/private/tmp/stt-t14-repair-final-full.xcresult` and `build test`. Repair actual SDK/model/cache/output locations and measured outcomes are in [acceptance](T14_ACCEPTANCE.md#same-task-review-repair--three-findings). RTF in automatic mode includes the explicit detection pass; do not compare it to the earlier forced-English timing as an optimization claim. Source/input/output directories, runtime JSON/TXT and logs remain disposable and outside Git. G1/G2 remain unpassed.


Final repair real-model replay (equivalent shell form of the executed subprocess argv/environment; choose new output paths when reproducing because exports never overwrite):

```sh
t14_repair=/private/tmp/stt-t14-repair.RpKBXk
swift build --scratch-path "$t14_repair/CLIBuild"
# Existing input-hints111/112.json are copies of input.json with promptText = " test" repeated 111/112 times.
# Only hints/case/provenance differ; both retain the same canonical samples and PCM checksum.
for t14_cache in home cache tmp; do mkdir -p "$t14_repair/VerifiedCache/$t14_cache"; done
t14_offline() {
  /usr/bin/sandbox-exec -f tools/t14/offline.sb /usr/bin/env \
    CFFIXED_USER_HOME="$t14_repair/VerifiedCache/home" \
    XDG_CACHE_HOME="$t14_repair/VerifiedCache/cache" TMPDIR="$t14_repair/VerifiedCache/tmp" \
    "$t14_repair/CLIBuild/debug/stt-benchmark" "$@"
}
t14_offline run tools/t14/candidate.json /private/tmp/stt-t14-offline/store \
  /private/tmp/stt-t14-assets/input.json "$t14_repair/VerifiedAutomaticOffline" automatic
t14_offline cancel tools/t14/candidate.json /private/tmp/stt-t14-offline/store \
  /private/tmp/stt-t14-assets/input.json "$t14_repair/VerifiedAutomaticCancel" automatic
t14_offline run tools/t14/candidate.json /private/tmp/stt-t14-offline/store \
  "$t14_repair/input-hints111.json" "$t14_repair/VerifiedContext111" automatic
t14_offline run tools/t14/candidate.json /private/tmp/stt-t14-offline/store \
  "$t14_repair/input-hints112.json" "$t14_repair/VerifiedContext112" english
# Last command is expected to exit 1 with invalidInput; do not count that as successful inference.
```

The two negative commands use the same `t14_offline run tools/t14/candidate.json` argv with store `$t14_repair/NegativeStore`, original `input.json`, language `automatic`, and outputs `$t14_repair/VerifiedMissingTokenizer` / `VerifiedMissingComponent`. Before each invocation only its named asset is moved out of that APFS clone, and restored in `finally`; original verified source/stores are untouched. Both exit 1 with `loadFailed` before SDK construction. The network probe is `/usr/bin/sandbox-exec -f tools/t14/offline.sb /usr/bin/python3 -c 'import socket; socket.create_connection(("1.1.1.1",443),timeout=2)'`; exit 1 is expected with EPERM. Cache/profile limits and generation/import commands above still apply.

Actual JSON/TXT exports and per-command `.log`/`.exit` are under that repair root. The 111-token repeated-word stress hint produced repeated model output and slower processing; it proves the accepted boundary, not useful context accuracy or a performance gate. Its corrected first partial is about 7.05 s, rather than counting prompt/prefill text as a transcript. Full validation is repeated after the real runs on the same frozen inputs; current counts, report hashes and measurements are in acceptance.

## T15 native benchmark

Xcode and SwiftPM both consume `Packages/WhisperNative`. Its binary target verifies the upstream XCFramework archive. Git dependencies retain the two T14 resolutions. The macOS arm64 slice has minimum macOS 13.3 and embeds its Metal library. Keep the CLI beside its `whisper.framework`, as emitted by SwiftPM. The app embeds the framework in `Contents/Frameworks`. The default weight-free CI builds the app, runs both Xcode test targets and builds the CLI.

The following shell examples use a new disposable directory, a no-follow absolute store path and the canonical T14 input. Use an installed matching candidate when available. For the first developer bootstrap only, create the source in a fresh directory, fetch the one published LFS object, verify it, then explicitly import it through the repository. Allow space for source, installation, verified temporary snapshot and normal build products.

```sh
P=/Users/andyoon/stt
D=$(mktemp -d /private/tmp/stt-t15-validation.XXXXXX)
I=/private/tmp/stt-t14-assets/input.json
cd "$P"
swift build --scratch-path "$D/CLI"
BIN="$D/CLI/debug/stt-benchmark"
CAT="$P/tools/t15/candidate.json"
mkdir "$D/source"
curl -fL --retry 2 'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin' -o "$D/source/ggml-large-v3.bin"
(cd "$D/source" && echo '64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2  ggml-large-v3.bin' | shasum -a 256 -c -)
cd "$D"
"$BIN" import "$CAT" "$D/source" "$D/store"
"$BIN" run "$CAT" "$D/store" "$I" "$D/Normal" english
```

Each invocation requires a new report directory. `report.json` embeds the checked input, options and all terminal results. `report.txt` shows text and media times. `native-N.log` retains actual backend/device initialization and cancellation diagnostics. The model-free tests use a generated vocabulary-only native fixture and acknowledged load/decode/callback/cleanup boundaries. Real evidence and the original CLI commands are in [T15 acceptance](T15_ACCEPTANCE.md).

```sh
offline() {
  local name="$1"
  shift
  local roots="$D/${name}Cache"
  mkdir -p "$roots/home" "$roots/cache" "$roots/tmp"
  /usr/bin/sandbox-exec -f "$P/tools/t14/offline.sb" /usr/bin/env \
    HOME="$roots/home" CFFIXED_USER_HOME="$roots/home" XDG_CACHE_HOME="$roots/cache" TMPDIR="$roots/tmp" "$@"
}
offline NetworkProbe /usr/bin/python3 -c 'import socket; socket.create_connection(("1.1.1.1",443),timeout=2)'
# Expect EPERM for the probe.
offline Automatic "$BIN" run "$CAT" "$D/store" "$I" "$D/Automatic" automatic
offline Cancel "$BIN" cancel "$CAT" "$D/store" "$I" "$D/Cancel" english
offline WhisperKit "$BIN" run "$P/tools/t14/candidate.json" /private/tmp/stt-t14-offline/store "$I" "$D/WhisperKit" automatic
python3 "$P/tools/t15/check-negative-assets.py" "$BIN" "$D/store" "$I" "$D/Negative"
```

The cancel repetition withdraws the active request after the native encoder hook acknowledges entry. The benchmark checks the subsequent abort acknowledgement, joins native return and reloads the same engine for repetition 2. A GPU graph can finish before the next cancellation checkpoint. The T14 cancel command still withdraws after the first partial. For missing, truncated and same-length corrupt cases the script requires APFS clone support, runs only against new copies, preserves the evidence and checks the original hash afterward.

```sh
cd "$P"
xcodebuild -resolvePackageDependencies -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -derivedDataPath "$D/DerivedData"
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$D/DerivedData" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -resultBundlePath "$D/Full.xcresult" CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path "$D/Full.xcresult"
xcrun xcresulttool get test-results tests --path "$D/Full.xcresult"
```

For the focused execution insert `-only-testing:LocalLectureSTTTests/WhisperCppAdapterTests` and use a fresh `Focused.xcresult` path. The process sandbox covers this benchmark invocation. Physical microphone/TCC, signed app sandbox/bookmarks, lid/power, long recordings and lecture accuracy remain unverified.

## T16 developer lecture comparison

Use Python 3, working FFmpeg/ffprobe, the pinned arm64 CLI and the offline profile. Keep the input folder outside Git and use a fresh ignored output directory for each matrix. The production catalog now holds the G2 selection. T14/T15 describe the two original installations. The two additional catalogs in `tools/t16` pin each file, size, SHA-256, revision and license. The Core ML folder `openai_whisper-large-v3-v20240930` is the 32-encoder/4-decoder model with 128 Mel bins and Float16 weights. It uses the pinned T14 multilingual tokenizer. The native turbo file embeds its vocabulary and contains 235 F16 and 352 F32 tensors. Both packages use the T12 checked import and per-load lease validation.

```sh
swift build --disable-automatic-resolution
BIN="$(swift build --show-bin-path)/stt-benchmark"
D=$(mktemp -d /private/tmp/stt-t16-assets.XXXXXX)
python3 tools/t14/bootstrap.py --candidate whisperkit-turbo "$D/coreml"
python3 tools/t14/bootstrap.py --candidate whispercpp-turbo "$D/native"
"$BIN" import tools/t16/whisperkit-turbo.json "$D/coreml" "$D/store"
"$BIN" import tools/t16/whispercpp-turbo.json "$D/native" "$D/store"
```

Set `WK_LARGE_STORE` and `CPP_LARGE_STORE` to existing installations and `SAMPLE_A/B/C` to three source files. Start/duration arguments are milliseconds. Independent ranges of a longer source are also supported. Each conversion checks the decoded frame count, hashes the source and emits the common 16 kHz mono Float32 input, listening WAV and window manifest. Channel weights are equal. The last window retains all remaining frames. The source offset is available in the plan and listening table.

```sh
mkdir -p benchmark-results/t16
R=$(mktemp -d benchmark-results/t16/lecture.XXXXXX)
python3 tools/t16/compare.py prepare "$SAMPLE_A" 120000 600000 "$R/sample-01"
python3 tools/t16/compare.py prepare "$SAMPLE_B" 120000 600000 "$R/sample-02"
python3 tools/t16/compare.py prepare "$SAMPLE_C" 120000 600000 "$R/sample-03"
# For public recordings, add the per-sample attribution.json described below before rendering.
python3 tools/t16/compare.py run "$R" "$BIN" "$WK_LARGE_STORE" "$CPP_LARGE_STORE" "$D/store"
python3 -B tools/t16/review.py "$R"
python3 -B -m unittest discover -s tools/t16
```

If Homebrew FFmpeg or ffprobe on the comparison Mac cannot load `libx265.216.dylib`, use the installed x265 4.2 library for each of the three `prepare` commands. For sample A the command is

```sh
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/Cellar/x265/4.2/lib python3 tools/t16/compare.py prepare "$SAMPLE_A" 120000 600000 "$R/sample-01"
```

Apply the same prefix to the B and C commands. With this setting all three source and PCM SHA-256 pairs and all 30 window records per sample matched the original run. Where FFmpeg and ffprobe already run, use the commands above without the prefix.

`REVIEW.html` plays the shared PCM and links the original, all window transcripts/timestamps, raw timings, failed attempts and a local ratings sheet. Preserve every existing result directory. The runner verifies network denial, rotates candidate order across samples, and runs one process per pair with one model load and one session. Use `--synthetic` on the run command only for explicitly labelled short developer fixtures. Each exit is recorded and other candidates continue on failure. A missing terminal, a failed terminal and a successful empty final remain distinguishable. Output and cache files must stay local.

For public recordings, put an `attribution.json` alongside each `plan.json` before rendering. Include `title`, `artist`, `source` (original file page), `license`, `licenseURL` and `modification` (excerpt, conversion and applicable reuse terms). The local page displays these credits beside the player. The initial, middle and final windows form the listening sample for all candidates. Separate expandable examples identify the first other failed window and the window in which successful candidates differ most in English spellings.

The protocol uses one measured pass, no extra inference warmup, zero retries, forced Korean transcription by default, temperature zero, no hints, partials and timestamps enabled. WhisperKit uses top K 5, 224 tokens, one worker, no temperature fallback, and configured Core ML prewarming. The native decoder requests Metal, Accelerate, four threads, flash attention and greedy best-of-one. The native log records the effective backend. Throughput uses total engine inference seconds divided by full sample seconds. Tail and median submission latencies use nearest ranks on observed events. The queue simulation uses window-end arrivals and measured service time. Memory is process-level physical footprint sampled every 50 ms with a baseline before load. The listening sheet gives the common 40/25/20/10/5 rubric. Quality needs human listening, including empty finals on audible speech. Two-hour live behavior and utterance-relative latency require separate measurement.

### T16 Phase 1 verification

Use a fresh `OUT` directory and set `CACHE` to the directory containing the resolved Xcode and SwiftPM build caches. Set `SYNTHETIC_WAV` to the short mono 16 kHz speech fixture from T14. The two regression runs below use locally installed large-v3 packages.

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$CACHE/DerivedData" \
  -resultBundlePath "$OUT/Final.xcresult" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path "$OUT/Final.xcresult"
swift build --scratch-path "$CACHE/CLI" --disable-automatic-resolution
BIN="$CACHE/CLI/debug/stt-benchmark"
python3 -B -m unittest discover -v -s tools/t16
"$BIN" prepare "$SYNTHETIC_WAV" "$OUT/legacy-input.json" synthetic-offline 'T16 synthetic speech regression'
/usr/bin/sandbox-exec -f tools/t14/offline.sb "$BIN" run tools/t15/candidate.json "$CPP_LARGE_STORE" "$OUT/legacy-input.json" "$OUT/legacy-cpp" english
/usr/bin/sandbox-exec -f tools/t14/offline.sb "$BIN" cancel tools/t14/candidate.json "$WK_LARGE_STORE" "$OUT/legacy-input.json" "$OUT/legacy-wk" english
```

On the comparison Mac the unsigned app built and all 423 unit and 10 integration tests passed, with zero failures and skips. The CLI built and all four Python tests passed. The fixture reproduced the original T14 PCM digest. The native command returned three finals. WhisperKit returned a final, a cancellation and a final after reload. The lecture audit verified all 360 window identities and playback offsets. The review HTML contains 480 occurrences of `href` or `src`, including repeated references. All 456 local file references resolve to existing files, all 15 in-page anchors have matching targets, and 9 references point to external sources. [Measurements and selected model](T16_ENGINE_MODEL_DECISION.md)


## T17 product engine verification

Run the existing unsigned macOS Debug build and test suite and the SwiftPM benchmark build. CI also builds the Release app and inspects the resulting product. From the repository root:

```sh
t17_build="$(mktemp -d /private/tmp/stt-t17-release.XXXXXX)"
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$t17_build" CODE_SIGNING_ALLOWED=NO build
python3 -B tools/verify_product_engine.py "$t17_build/Build/Products/Release/LocalLectureSTT.app"
```

For a local installed-model recording test, set `T17_STORE` to a verified T12 model store containing the G2 native installation. The developer CLI's explicit `import tools/t15/candidate.json "$MODEL_SOURCE" "$T17_STORE"` command can populate that store from a local model folder. Use the app's sandbox Application Support directory under `LocalLectureSTT/Models` when testing the GUI. The T21 model-management screen can download or import and validate the installation. Recording start reports a model error if the selected installation cannot load.

```sh
TEST_RUNNER_LLSTT_T17_TEST_MODEL_STORE="$T17_STORE" xcodebuild \
  -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests/testProductionCaptureRepositoryRootRecorderAndCatalogPersistDecodableRecoveryAudio \
  CODE_SIGNING_ALLOWED=NO test
```

Check the test log for `T17 integration exercising the installed whisper.cpp model`. The test uses synthetic microphone input and reads the saved metadata and recovery audio. Ordinary CI exercises the same recording path with a deterministic engine and requires no weights. The T16 comparison CLI and both candidate families remain available for reproducing the comparison.

## T18 segmentation and overlap checks

Run the synthetic VAD, media-time, reconciliation and recovery-audio tests on macOS:

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -only-testing:LocalLectureSTTTests/SpeechSegmentationTests \
  -only-testing:LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests/testT18SpeechSilenceBoundaryLeavesEntireCaptureInRecoveryAudio \
  CODE_SIGNING_ALLOWED=NO test
```

The recording test feeds one second of tone and one second of silence to the capture streams. The VAD window closes at 1.8 seconds. The independent writer produces a decodable two-second MOV. The unit fixtures exercise the 20-second split, exact overlap samples, noisy consonants followed by quieter vowels, and mixed Korean/English hypotheses with repeated words at distinct times.

The focused suite above also runs the T18 review regressions:

- `testTenMillisecondsOfSharedAudioPreservesRepeatedUtterance` keeps both utterances of `다시` when their timestamps overlap by 10 ms.
- `testTimedDuplicateBetweenNovelSegmentsKeepsBothNeighbors` suppresses a repeated `기울기` at the same timestamp and keeps the new segments on either side.
- `testKoreanParticleAttachedToLatinTermAndDetachedPunctuation` matches `API를` with `API 를`, consumes a detached period, and preserves distinct technical terms.
- `testPersistentLowPassNoiseAndQuietSpeechOnTheSameBackground` expects zero windows for 32 seconds of seeded, low-pass noise at 0.025 RMS. Adding a 600 ms vowel to that same signal must yield one window containing the whole vowel.
- `testIsolatedPeriodInBackgroundNoiseDoesNotStartAnUtterance` uses another seed with a single frame of correlated noise during startup.
- `testTimingEvidenceAcrossSplitOrMergedHypothesesIsConsumedOnce` covers an engine changing its segment boundaries and one old occurrence followed by two incoming occurrences.
- `testSameSentenceWithAWordMovedAcrossSegmentBoundariesIsEmittedOnce` checks `선형 대수 | 입니다` against `선형 | 대수 입니다`, including shifted timestamps and new words at the edges.
- `testResegmentedRepeatedWordsAreConsumedOnceInEitherDirection` checks all 16 partitions of a five-word phrase on each side at two start times, preserving a later repetition in all 512 cases.
- `testTrimmingAPrefixRequiresTimingEvidenceEvenWithFollowingWords` keeps `다시 확인합니다` with 50 ms of shared audio and removes the duplicated `다시` with 800 ms of support.
- `testAdjacentOldSegmentsJointlySupportAMergedIncomingPrefix` starts the first old segment at 18.930 s and 18.940 s. In both cases 120 ms and 730 ms support the same prefix, leaving only `다음` and preserving a later repetition.
- `testBlankAndCommaIntervalsCannotSupplyMissingWordCoverage` checks that a 650 ms whitespace or comma interval between two words leaves their total shared audio at 50 ms. Both the incoming phrase and its later repetition survive.
- `testDetachedCommaCannotInvalidateMatchedWordCoverage` checks a separately timestamped comma, including a zero-duration comma on either side of the comparison. The overlapping phrase is removed and the novel suffix and later repetition retain their timestamps.
- `testPointCommaInsideMatchedPhraseFollowsTheWordMatch` expects a single `다음` with its original time bounds and sequence 3, both after a space and comma at 19.180 s and when the preceding word ends at 19.170 s.
- `testPointCommaAndLeadingCommaAreInterchangeableInEitherWindow` checks all nine pairings of a point comma, `, 대수` and `,대수`. Only `다음` is added at the incoming segment’s original time bounds.
- `testLeadingCommaPreservesWeaklyOverlappingSpeechAndLaterRepeat` checks that 50 ms of matching speech preserves the entire incoming text, including its leading comma and spacing, and the repetition at 20.110 s.
- `testCommaBeforeFirstMatchedWordAcrossWindows` checks all nine comma groupings at window onset, including preservation of a later repetition and leading marks with insufficient timing or text evidence.
- `testDottedTermsKeepTheirMeaningAfterLeadingPunctuation` checks both directions for `.NET` and `.5`, verifies that `NET` and `5` stay distinct from them, and covers an ellipsis before a Korean word.
- `testTrailingCommaAfterPointSpaceBelongsToTheMatchedWord` and `testTrailingMarkAcrossAGapRequiresTheSameOldMarkAndTime` cover punctuation at the end of a match, punctuation belonging to novel speech, and the exclusive end of the copied audio.

With T19's microphone-to-inference path, use a brief recording from the intended lecture room to check the start and end of quiet phrases, long continuous speech, and audible repetitions at a split. Listen to the saved audio at each transcript timestamp. The synthetic fixtures verify timing and text rules. G1 hardware validation remains pending.

In a local network-denied check, the installed large-v3 processed four consecutive copies of the T14 7.04-second synthetic speech fixture. The VAD sent all 450,560 input frames in windows spanning 0–20 and 19–28.16 seconds. The first native final rendered the repeated passage once within its 20-second window. Model omissions can therefore occur even with full audio coverage, before overlap reconciliation.


## T19 live STT verification

The normal suite uses synthetic PCM and a controlled engine; no model download or microphone access is required:

~~~sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  CODE_SIGNING_ALLOWED=NO build test
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
python3 -B -m unittest discover -s tools/t16 -v
~~~

Use a fresh result-bundle path when adding -resultBundlePath. Focused selectors are LocalLectureSTTTests/LiveSTTCoordinatorTests and the six RecordingSessionFileIntegrationTests/testT19 methods in [acceptance](T19_ACCEPTANCE.md). The named DerivedData/CLI directories reuse local dependency caches; replace them with another resolved build directory if absent.

An explicit actual-engine run requires a verified large-v3 installation and a little-endian Float32, 16 kHz mono synthetic speech file longer than three seconds. The probe used say -v Samantha -r 155 with “This local lecture explains how neural networks learn from examples and why careful validation matters in practical applications.” Convert its AIFF using afconvert -f WAVE -d LEF32@16000 -c 1, then extract the RIFF data chunk (not the header) as .f32. All generated assets remain outside the repository. Import with the existing CLI:

~~~sh
/private/tmp/stt-t15-validation.Uth8xp/CLI/debug/stt-benchmark \
  import tools/t15/candidate.json /private/tmp/stt-t19-model/source /private/tmp/stt-t19-model/store

TEST_RUNNER_LLSTT_T19_MODEL_STORE=/private/tmp/stt-t19-model/store \
TEST_RUNNER_LLSTT_T19_SPEECH_F32=/private/tmp/stt-t19-work/speech.f32 \
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests/testT19LiveSpeechReachesUIAndJournalWhileAudioIsPreserved \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 \
  CODE_SIGNING_ALLOWED=NO test
~~~

The TEST_RUNNER_ prefix passes these values into the test host. Omit both variables for ordinary CI. The installed-model probe loads the real product engine; it must not be reported as a model run when these variables are absent. This procedure does not change system networking and does not establish OS-enforced offline or G1 hardware evidence.


### T19 speech-only quit regression

Run the full Debug build/test command above first. The following command reuses that build and repeats the three lifecycle regression methods plus the file-backed delegate integration 20 times each (80 executions). It deliberately keeps final inference pending instead of advancing the fake engine clock. The delegate must cancel speech, join essential storage/resource settlement, then issue one successful AppKit reply. The unit matrix also holds cleanup at a gate and covers finished/cancelled/failed inference and a metadata-only handoff.

~~~sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests/testT19SpeechOnlyQuitJoinsCleanupAndRepliesExactlyOnce \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests/testT19SpeechOnlyDecisionWithoutSharedAuthorityStillRequiresCleanup \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests/testT19ClosedWindowWaitsForSpeechAndMetadataHandoffThenExitsOnce \
  -only-testing:LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests/testT19DelegateQuitsAfterAudioFinalizationWithoutDrainingSpeechBacklog \
  -test-iterations 20 -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO test-without-building
~~~

The 2026-11-24 repair run added `-resultBundlePath /private/tmp/stt-t19-quit-fix/Repeated.xcresult`. Full Debug and installed-model runs used the commands above with `Full.xcresult` and `Native.xcresult` in that directory. Use new result paths on rerun. These automated checks do not change G1's unverified status.


### T19 automatic-exit error policy regression

After the full Debug build/test command, repeat the four error-policy unit methods, the earlier gated quit test, and the two real capture/file integration methods (seven selectors, 20 iterations each). The journal-failure integration creates a directory at the unused synthetic journal path; the production FileSessionRepository/JSONLWriter then fails the append while metadata and audio remain writable. No real recordings or system permissions are altered.

~~~sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests/testT19SpeechProblemsBlockAutoExitButAllowSafeExplicitQuit \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests/testT19CancellationAndDelayDoNotBecomeAutomaticExitErrors \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests/testT19SpeechWarningDoesNotBypassUnsafeEssentialSave \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests/testT19LateSpeechErrorInvalidatesPendingAutomaticExit \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests/testT19SpeechOnlyQuitJoinsCleanupAndRepliesExactlyOnce \
  -only-testing:LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests/testT19SpeechFailureBlocksAutoExitButAllowsExplicitQuit \
  -only-testing:LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests/testT19TranscriptWriteFailureBlocksAutoExitButAllowsExplicitQuit \
  -test-iterations 20 -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO test-without-building
~~~

Use a fresh `-resultBundlePath` on each run. The repair's artifacts are under `/private/tmp/stt-t19-attention-fix`; completed runs and results are recorded in [acceptance](T19_ACCEPTANCE.md). G1 remains unverified.

## T20 transcript finalization verification

The production app composes `SessionFinalizationWorker` after the T08 audio worker. New storage/rendering regressions are in `TranscriptFinalizationTests`; capture-to-canonical and essential-quit tests are the two `testT20` selectors in `RecordingSessionFileIntegrationTests`. These use generated PCM and an injected STT engine, with the real recorder, file repository and SQLite catalog. They do not establish lecture accuracy or G1 hardware evidence.

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  CODE_SIGNING_ALLOWED=NO build test
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
python3 -B -m unittest discover -s tools/t16 -v
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
python3 -B tools/verify_product_engine.py /private/tmp/stt-t15-validation.Uth8xp/DerivedData/Build/Products/Release/LocalLectureSTT.app
```

Use a new result-bundle name for each run. T20 artifacts are under `/private/tmp/stt-t20-work`. `CandidateFull.xcresult` records the candidate source full suite; `CompatibilityFull.xcresult` repeats it after the explicit-initializer CI compatibility repair. `RepeatedFinal.xcresult` uses 20 iterations for each of:

- `LocalLectureSTTTests/TranscriptFinalizationTests/testTerminalDerivedFailureIsRetryableAndBlocksAutoExitButAllowsEssentialQuit`
- `LocalLectureSTTTests/TranscriptFinalizationTests/testConcurrentEditIsRejectedAndExternalReplacementAcrossAwaitIsPreserved`
- `LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests/testT20ExplicitQuitCancelsTranscriptWaitWithoutDrainingSpeech`

For the repetition command, append those `-only-testing:` arguments and `-test-iterations 20` to the Debug test command. The startup recovery matrix recreates the repository and recovery coordinator after failures at five publication boundaries; the write-fault matrix covers every `TranscriptWritePoint`. Assertions check preserved recovery/journal/canonical bytes, read-back content, outcome, ordered checkpoints, scope release and retry results.

Manual/Pending: record a short real lecture offline, stop and inspect the three transcript files; close/reopen the app after moving between rooms; confirm a derived-write failure is visible and explicit quit leaves the session recoverable. Exercise the text-edit API through the T23 detail UI using the procedure below. G1's physical microphone/TCC, signed Sandbox, lid/process-kill/power-loss and long-recording checks remain unverified. Recovery audio is retained; T20 supplies the verifier for the existing explicit T08 cleanup API but does not invoke deletion automatically.

T20 review repair artifacts are in `/private/tmp/stt-t20-repair`. The same Debug command above uses `-resultBundlePath /private/tmp/stt-t20-repair/Full.xcresult`; the focused run uses `Focused2.xcresult` and these selectors:

```sh
-only-testing:LocalLectureSTTTests/TranscriptFinalizationTests \
-only-testing:LocalLectureSTTTests/SpeechSegmentationTests \
-only-testing:LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests/testT20NormalStopCompletesCanonicalDerivedAndCatalogAfterSpeech \
-only-testing:LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests/testT20ExplicitQuitCancelsTranscriptWaitWithoutDrainingSpeech
```

The three `testReviewT20*` selectors reproduced the independent findings before repair (`Red.xcresult`). The repaired focused suite passed 54 tests. Timing regressions go through real T18 reconciliation, 21-second synthetic media, journal compaction, TXT/MD and reopening. Read-only tests use filesystem permissions, check file identities as well as bytes, and cover missing/stale exports and permission-restored recovery. [Acceptance](T20_ACCEPTANCE.md#same-task-review-repair-overlap-timing-and-read-only-completion) records the exact test names. These filesystem checks do not replace signed Sandbox or physical G1 verification.

## T21 UI and start-readiness verification

`SessionModelUITests` covers model readiness, explicit-only download actions, retained-journal presentation, cancellation/retry/deletion, catalog ordering under racing reads, finite microphone preview and app-lifecycle ownership. Three `RecordingSessionCoordinatorTests/testT21*` cases cover UI admission, owned preview cleanup and exact selected-model metadata. T12/T13 retain real repository and URLSession fault coverage. Tests generate their own payloads and never download model weights.

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/stt-t21-work/ReviewedFinal.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  CODE_SIGNING_ALLOWED=NO build test
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
python3 -B -m unittest discover -s tools/t16 -v
```

Use a fresh result-bundle path on each run. Focus with `-only-testing:LocalLectureSTTTests/SessionModelUITests`, the three T21 coordinator selectors, or `AppLifecycleTests`. Release validation uses the same Xcode project and destination with `-configuration Release`, followed by `python3 -B tools/verify_product_engine.py <DerivedData>/Build/Products/Release/LocalLectureSTT.app`.

Manual/Pending (G1 remains unverified):

1. Launch a separately signed sandbox build with no root/model. Confirm the storage-folder explanation and model-management entry; no network download starts automatically.
2. Select a disposable root. Use **마이크 입력 확인**; verify microphone name, level, no-input warning and automatic stop after 30 seconds. Starting recording must stop preview before capturing the session.
3. In **모델 관리**, explicitly download large-v3 or use **파일 폴더 선택** for the folder containing `ggml-large-v3.bin`. Generic import expects an installation manifest. Verify progress, pause/resume, validation and ready state; close/reopen during download. Never commit weights.
4. Start a short offline recording with empty/manual title and each language mode. Verify selected-model metadata, no model-change controls during capture, and list update after stop/finalization. Compare to the existing T17/T19 recording checks.
5. Cancel model deletion; then inspect reference and incomplete-root warnings using disposable data before confirming deletion. Existing audio/transcripts must remain untouched.
6. Change/reauthorize the session root from the main form/settings and verify previous sessions remain listed. Inspect the UI at the minimum window size and with long titles; previous-session playback and edits use the T23 detail view.

## T22 active recording and transcript verification

`ActiveRecordingUITests` checks 10,000 final segments against 1,000 partial replacements, bounded page updates, segment/time/order preservation, empty-partial normalization, new-session reset, follow-scroll policy, isolated notices and real view-model observation/Stop routing with simultaneous no-input/STT/journal failures. Fixtures are synthetic and no model or network is needed. This is not an FPS benchmark or a physical microphone check.

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/stt-t22-work/FullFinal.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  CODE_SIGNING_ALLOWED=NO build test
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
python3 -B -m unittest discover -s tools/t16 -v
```

Use a fresh result bundle for each run. Focus with `-only-testing:LocalLectureSTTTests/ActiveRecordingUITests`; repeat with `-test-iterations 10`. Release product-engine verification is the same as T21. Do not build Debug and Release concurrently in the same DerivedData directory.

Manual/Pending (G1 remains unverified):

1. Using a signed sandbox build and an installed model, start an offline disposable recording. Confirm title, elapsed time, microphone level, no-input warning, and a persistent enabled **녹음 종료** button. Neither silence nor a slow STT backlog should stop capture.
2. Speak several sentences. Confirm **확정** rows retain their text and timestamps while the separately shaded **임시** row changes. Text selection/copy is allowed; no transcript editor is present.
3. During incoming partial/final updates, scroll upward with trackpad, mouse wheel, scrollbar and keyboard. The reading position should stay put. **최신 내용으로** resumes following; scrolling manually back to the bottom also resumes. Start a new session and verify no old text or detached-scroll state remains. Repeat with enough content to span many pages.
4. Use the existing STT fault procedures/test doubles to inspect delay, failure and journal warnings. Stop must remain usable; warnings must not open a blocking alert. Compare recovered audio with the existing recorder tests; this does not pass G1.
5. Stop and observe **필수 저장**, remaining STT and background finalization. With more than one pending/failed session, verify each status and retry control is present. A completed session must no longer claim that finalization is pending. Close/reopen the window; app-owned capture/STT/finalization should continue per the existing lifecycle policy.
6. Check minimum window size, long titles, large text/VoiceOver, and a long recording. Confirm the stop button remains accessible and the transcript can scroll. Actual native gesture behavior, visual layout, sustained FPS and real lecture performance remain manual; automated publisher assertions do not claim those outcomes.


## T23 session detail verification

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/stt-t23-work/FinalFull.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  CODE_SIGNING_ALLOWED=NO build test
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
python3 -B -m unittest discover -s tools/t16 -v
```

Use a fresh result-bundle path each time. The focused command adds `-only-testing:LocalLectureSTTTests/SessionDetailTests -only-testing:LocalLectureSTTTests/SessionDetailInteractionTests`; `-test-iterations 10` repeats these tests. Release validation uses the same project, destination and DerivedData with `-configuration Release ... build`, then `python3 -B tools/verify_product_engine.py /private/tmp/stt-t15-validation.Uth8xp/DerivedData/Build/Products/Release/LocalLectureSTT.app`. Do not run Debug and Release concurrently in the same DerivedData.

Manual/Pending (use disposable sessions; G1 remains unverified):

1. In a separately signed sandbox build, open a completed session from the sidebar with networking disabled. Play/pause/stop, drag the slider and use keyboard controls; click several transcript timestamps. Check audible output, position, end-of-file and navigation/window-close cleanup. Reopen and repeat with a read-only root; viewing and playback should work without changing files.
2. Edit one segment and save; confirm originalText, IDs, order and timestamps remain unchanged in JSON while TXT/MD reflect new text. Rename the title; the session folder stays unchanged. A pending draft prevents navigating away; Cancel leaves the saved files unchanged. Repeat at minimum window size, with a long title/transcript and VoiceOver.
3. Request app quit with an unsaved draft; successful saving should finish before quit. Use a disposable unwritable root to provoke save failure: the draft and warning remain and the app must stay open. Restore access and retry. Close/reopen the window to confirm in-memory draft retention. Process kill is not a promise of unsaved-draft durability.
4. Use each **파일 위치** button to select audio.m4a, transcript.json and transcript.md in Finder. Delete only a disposable session: Cancel preserves it; Confirm moves the entire folder into the macOS Trash. Use Finder's Put Back (or restore to the original root), reopen/rescan and confirm the session reappears with all files. Do not empty the Trash. If the volume cannot trash an item, the app must show an error without a permanent-delete fallback.
5. Move or corrupt copies of individual files outside the app and reopen/refresh the session. Missing audio disables seeking; invalid audio fails without deleting it; corrupt JSON disables editing while other files stay accessible. Reauthorize an unavailable root using existing settings and retry. Exercise restoration/read-only behavior on the actual storage volume as filesystem permissions and Sandbox behavior are not proved by the unsigned tests.

[Acceptance matrix](T23_ACCEPTANCE.md) distinguishes real media/filesystem tests from controlled driver/Trash adapters and manual platform checks.

## T24 pause and resume verification

Use the existing arm64 Debug `xcodebuild ... build test`, SwiftPM/Python comparison checks and Release product-engine verification commands above. T24 tests are in MicrophoneCaptureTests, RecordingSessionCoordinatorTests, LiveSTTCoordinatorTests, AppLifecycleTests and RecordingSessionFileIntegrationTests; [acceptance matrix](T24_ACCEPTANCE.md) lists exact names. Synthetic fixtures need no model downloads, microphone permission or network. Add `-only-testing:<target>/<class>/<test>` to select them; `-test-iterations 10` repeats race coverage.

Manual checks, still pending (G1 remains unverified):

1. In a signed Sandbox build with an installed model, record a short phrase, pause, say a distinct excluded phrase, resume and say a third phrase. Repeat, including a pause before the first sound and a long pause. Stop while paused. Check audio playback and transcript timestamps omit the paused phrases/time. Final text for the last open utterance may finish asynchronously during pause.
2. Confirm the active timer freezes, the input meter/no-input warning resets, Resume/Stop remain available, and model/language/transcript editing remain locked. The OS microphone indicator can remain on because the capture device stays owned while input is discarded.
3. Close/reopen the window while paused; it must keep active work. Confirm explicit Quit asks to continue or save essentials, and that completing Stop after the last window closes still follows the existing automatic-exit/error rules.
4. Verify screen-off remains allowed and idle system sleep is prevented while paused. Lid/system sleep interrupts; wake must not resume recording. Reopen after a process kill while paused: preserve recoverable audio, mark capture interrupted, and resume finalization without starting the microphone.
5. Disconnect the active microphone or revoke storage access during a transition. Confirm a typed failure, preserved recovery files, no stale transition restoring a terminal session, and usable controls after cleanup.

## T25 diagnostic verification

Use the existing unsigned arm64 Debug build/test command with a fresh result bundle in `/private/tmp/stt-t25-work`. Focus with `-only-testing:LocalLectureSTTTests/DiagnosticsTests`, `-only-testing:LocalLectureSTTTests/StorageRepositoryTests/testT25OnlyDurableEventsAreMirroredAndRecoveryRetriesStayIdempotent` and `-only-testing:LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests/testT25BlockedFailedDiagnosticsDoNotDelayRecordingAndManagementPreservesRealAudio`. Add `-test-iterations 10` for the export/clear/cancellation and recording-isolation repeats. SwiftPM, Python and Release bundle verification use the commands above. Fixtures are generated locally; no lecture, model download or real microphone input is required.

Manual/Pending (use disposable sessions; G1 remains unverified):

1. In a signed Sandbox build, open Settings → 로컬 진단 로그. Reveal the folder in Finder. Confirm it is in this app's Application Support, not a session root. Export to a user-selected folder, including an external volume and a folder reached through a macOS alias. Cancel the chooser and repeat. Files should be new JSONL reports and never overwrite an existing file.
2. During recording, export and delete logs. Confirm meter/Stop remain usable; export contains only schema/date/source/enum signals/session UUID, with no transcript, title, prompt, raw NSError or audio. Stop and compare audio/transcript/events bytes before and after subsequent log deletion/export. Deleting app logs must preserve session events and data.
3. On disposable copies, deny microphone permission, disconnect input, revoke root access, remove/corrupt a model or session file and provoke finalization failure. Check that cause, action and recovery label are distinct and the indicated retry/reauthorization/model controls exist. Restore access and retry; do not delete recovery data.
4. Confirm warning layout, minimum window size, long Korean text and VoiceOver; the recording Stop control must stay visible. Close/reopen during export and request explicit Quit; cancellation should release the selected-folder scope after I/O. Real disk removal, full-volume behavior, TCC, signed Sandbox permissions and hardware/lid/long-recording tests are not established by unsigned fixtures.

The retention clock/size and fault seams are test-only dependency injection. Production logging has no uploader and requires no network. [Acceptance matrix](T25_ACCEPTANCE.md) records automated results separately from these manual checks.


## G3 model management repair verification

Run the repository-backed G3 regression cases together with the existing model and UI suites:

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:LocalLectureSTTTests/ModelRepositoryTests \
  -only-testing:LocalLectureSTTTests/SessionModelUITests \
  -only-testing:LocalLectureSTTTests/ModelDownloadTests \
  -only-testing:LocalLectureSTTTests/DiagnosticsTests \
  CODE_SIGNING_ALLOWED=NO build test
```

Omit the `-only-testing` options for the full suite. Use a fresh `-resultBundlePath` on each run. [Acceptance](G3_MODEL_MANAGEMENT_REPAIR.md) records the actual results and evidence paths. The shared SwiftPM target, four Python tests and Release product-engine verifier use the existing commands above.

Manual (pending): with a signed app and disposable copies of a model package, import via the general manifest-folder button and the catalog-specific weight-folder button; cancel the picker and verify no operation remains active. In a disposable installed copy only, corrupt/remove its manifest, refresh the model list, cancel the preservation sheet once, then acknowledge and confirm. Verify the original bytes remain in the model store's `.preserved-<UUID>` directory (Finder Show Hidden Files), an unaffected revision and session stay intact, and explicit reimport succeeds. A future-schema or symlink package must remain untouched. Never use a real lecture/session or the only copy of a model for destructive fixture preparation. Real filesystem capacity exhaustion, native sheets and Sandbox behavior remain manual; injected capacity and filesystem races are covered automatically. G1 remains unverified.

## T26 fault injection and process recovery

The process suite is a separate required check after building the existing developer benchmark. It kills only its own acknowledged child processes and creates only synthetic data in marked `/private/tmp/T26-*` directories. No installed model, microphone, network or application user store is needed. It does not silently skip a missing helper.

```sh
swift build --disable-automatic-resolution
probe_bin_dir="$(swift build --show-bin-path --disable-automatic-resolution)"
validation_dir="$(mktemp -d /private/tmp/stt-t26.XXXXXX)"
python3 -B tools/t26/test_recovery_process.py \
  --probe "$probe_bin_dir/stt-benchmark" \
  --results "$validation_dir/process.json"
```

The helper is never compiled into the GUI app. CI runs this command after the SwiftPM/Python checks and before Release verification, and prints its measurements. A custom SwiftPM scratch path must be used consistently for both build and executable lookup. XCTest full/focused/repeated commands, 17.6 scenario mapping, loss measurements, known harness failures and pending physical procedures are in [T26 acceptance](T26_ACCEPTANCE.md). G1 remains unverified. Do not treat a generated result file or an active-prefix snapshot as a claim of real hardware/power-loss validation.

## T27 validation preparation

[T27 validation](T27_VALIDATION.md) records the user's preparation-only scope, the local ad-hoc app build, external resource sampler, short actual-model/network-denied checks and the pending long-duration/offline GUI matrix. The GUI excludes all `tools/t27` files. `ModelSandboxProbe.swift` and `SpeechReplayProbe.swift` are compiled into the developer benchmark; the other tools remain standalone. CI runs three observer/build-helper checks and three OS-sandbox repository checks; this does not run or pass the ten-hour physical validation. The helper refuses an existing app output directory and stores all results outside Git. T27, G1 and G4 must not be marked complete from these preparation results.


The T27 signed-GUI import repair uses `O_SEARCH` for ancestors and read access only for the final directory. Existing ancestors are opened before attempting creation; missing paths alone use `mkdirat`, with the existing parent sync retained. Per-component `O_NOFOLLOW`, identity checks and pinned file operations remain. The same ancestor-access correction applies to local diagnostic logs. Reproduce the denied-parent test with:

```sh
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
python3 -B tools/t27/test_model_sandbox.py --probe /private/tmp/stt-t15-validation.Uth8xp/CLI/debug/stt-benchmark
```

The probe uses marked disposable `/private/tmp/T27-Model-*` fixtures, synthetic checksummed models and the real repository/capacity/diagnostic implementations. The test first proves directory listing is denied by the OS profile, then checks source-preserving imports, coexistence, repeat import, scope release and symlink rejection. This is not an NSOpenPanel security-extension test; repeat the native picker import with the rebuilt signed app as described in [T27 validation](T27_VALIDATION.md#sandbox-모델-가져오기-보완).

`stt-benchmark speech-replay CATALOG MODEL_STORE INPUT_F32 NEW_OUTPUT_DIR LANGUAGE` replays up to ten minutes of already-decoded 16 kHz mono Float32 PCM through the product VAD, interval engine and reconciler. `LANGUAGE` is `korean`, `english` or `automatic`. It uses 100 ms input blocks and serially processes all final windows plus sampled open windows, with the same bounded previous-final text hint as the live coordinator. Its `attempts.json` records input times, stage, segment counts and failure codes only. It never updates a session or exports recognized text. This isolates adapter behavior; it does not reproduce microphone scheduling, backpressure or measure real-time latency. Keep inputs, weights, native logs and reports outside Git. See the local replay evidence in [T27 validation](T27_VALIDATION.md).


## T27 automatic speech recovery checks

The approved addition to T27 is specified in MVP_SPEC §10.6. [Acceptance and limitations](T27_STT_RECOVERY.md) cover the live coordinator, atomic recovery sidecar, actual AAC range decoding, real file/catalog/detail integration and fresh-start scanner recovery. Run focused tests using the normal Debug configuration and `-only-testing:LocalLectureSTTTests/LiveSTTCoordinatorTests -only-testing:LocalLectureSTTTests/SpeechRecoveryTests`. The full suite is still required. Local evidence uses `-parallel-testing-enabled NO` and fresh result-bundle paths to separate test-runner exits from assertion failures. CI continues its existing full build/test, SwiftPM, Python, Sandbox, process-kill and Release checks.

Neither the new automated tests nor the previous sequential `speech-replay` probe demonstrate long-duration microphone performance. The 10-hour T27 matrix, signed GUI error/recovery interaction, true native deadlock, lid/TCC and G1 remain unverified. Never delete the recovery ledger or change its attempt counts in a user session to force a retry. Use generated fixtures for failure tests; recovery of pre-feature recordings is not automatically enabled.
