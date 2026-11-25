# T24 recording pause and resume

Base: dev `d2d96456cc149b58a5fc5cc6248634881c8e7218`. Branch: `task/t24-recording-pause-resume`. Scope: IMPLEMENTATION_PLAN T24, MVP_SPEC 3.1, 4.3, 6, 7 and 11.1. The user authorized implementation, separate read-only review, repairs, task CI, dev integration and cleanup in this session. G1 remains unverified; main and T25+ are excluded.

## Acceptance matrix

| Behavior | Executed test coverage |
| --- | --- |
| Paused PCM excluded from recording and STT; repeated resume removes wall gaps while preserving one capture generation | `MicrophoneCaptureTests.testT24RepeatedPauseRemovesPCMAndWallGapsFromBothStreams` |
| Early/empty pauses, bounded speech marker loss, initial media origin | `MicrophoneCaptureTests.testT24EmptyPausesAndDroppedSpeechMarkerKeepEpochAndInitialOrigin` |
| No-input suppression and fresh grace after resume; paused device failure retains typed terminal state | `testT24MonitorIgnoresPausedInputAndRestartsNoInputGrace`, `testT24DeviceFailureWhilePausedClosesOnceAndRejectsResume` in MicrophoneCaptureTests |
| Paused metadata, wall-clock events, active clock freeze, same media position at resume | `RecordingSessionCoordinatorTests.testT24PauseResumePersistsWallEventsAndFreezesActiveClock` |
| Pause joins buffered audio prefix; simultaneous controls rejected; Stop remains available | `RecordingSessionCoordinatorTests.testT24PauseCutoffWaitsForBufferedWriterButStopRemainsAvailable` |
| Caller cancellation cannot abandon persistence; terminal writes follow admitted transition writes | `testT24CancelledCallerCannotAbandonPausePersistenceOrAllowLateTerminalOverwrite`, `testT24ResumePersistenceJoinsSleepWithoutRestoringRecording` in RecordingSessionCoordinatorTests |
| Metadata/event failures on pause/resume, append failure while joining prefix, capture/flush failures, zero-sample stop preserve recovery and stable errors | `testT24PauseAndResumePersistenceFaultsPreserveRecoveryAndTypedError`, `testT24AppendFailureWhilePauseWaitsCannotDeadlockOrHideTypedError`, `testT24PauseCaptureAndFlushFailuresSettleOnce`, `testT24ZeroSamplePauseResumeAndStopRetainsExistingNoAudioPolicy` in RecordingSessionCoordinatorTests |
| Paused UI exposes Resume/Stop, hides configuration edits; pending control disables duplicate actions | `RecordingSessionCoordinatorTests.testT24PausedUIKeepsModelLockedAndShowsOnlyResumeAndStop` |
| Open speech becomes a queued final without waiting for inference; old partials suppressed; engine/session unchanged | `LiveSTTCoordinatorTests.testT24PauseSealsOpenSpeechWithoutWaitingForSlowInferenceAndSuppressesLatePartial` |
| PCM epoch recovers a dropped marker; empty pauses do not invent text | `testT24LostPauseMarkerStillSeparatesSpeechThroughPCMGenerationEpoch`, `testT24EmptyPauseCyclesDoNotInventSpeechOrRestartEngine` in LiveSTTCoordinatorTests |
| Paused window close retains active work, explicit quit joins one essential save, sleep/wake interrupts without auto-resume | `testT24PausedWindowRetainsActivityAndRequiresExplicitQuitChoice`, `testT24PausedExplicitQuitJoinsOneEssentialSave`, `testT24PausedSleepAndWakeInterruptWithoutAutomaticResume` in AppLifecycleTests |
| Real 44.1 kHz input → 48 kHz mono AAC/m4a plus actual VAD/resampling/fake inference/journal/canonical finalization; pause audio excluded, transcript starts 0/1000/2000 ms | `RecordingSessionFileIntegrationTests.testT24RealAACAndTranscriptExcludePausedAudioAcrossThreeEpochs` |
| Real persisted paused metadata enters startup recovery with interrupted outcome; no microphone restart | `RecordingSessionFileIntegrationTests.testT24PersistedPausedSessionRestartsAsInterruptedWithoutResumingCapture` |

The real-file test decodes the published AAC through AVAudioFile and measures distinct tones in all three active intervals. The paused 3 kHz tone is absent; active duration is three seconds instead of six. Engine output is deterministic fake text; this is not real-model accuracy or latency evidence. The recovery fixture restores actual paused metadata over a normally closed recoverable MOV to simulate a previous owner; it does not claim active-writer process-kill or power-loss verification.

## Verification limits

The same capture driver stays open during pause, but discarded samples enter neither persisted audio nor STT. Pause seals a final-inference request; the final text can arrive later. Slow/failed STT keeps T19's existing visible degradation/error policy. Pause does not upgrade the T06 flush barrier into a fragment/fsync guarantee. Existing zero-sample stop remains a recoverable error, not a fabricated completed recording. No schema migration, dependency, model/engine selection, network behavior or deduplication rule changes.

Physical microphone/TCC, audible playback, signed Sandbox, real lid sleep/process kill and long lecture testing remain manual. See [T24 manual procedure](DEVELOPMENT.md#t24-pause-and-resume-verification). G1 remains unverified.

## Validation and review

Candidate validation on the final source tree:

- `/private/tmp/stt-t24-work/Full.xcresult`: unsigned arm64 Debug build and **591 XCTest (570 unit + 21 integration)** passed, zero failures/skips.
- `/private/tmp/stt-t24-work/Repeated.xcresult`: **21 T24 tests × 10 = 210 executions**, zero failures/skips.
- SwiftPM developer CLI build, four Python comparison tests, Release build and product-engine linkage/catalog verification passed.

Executed commands (Xcode commands also used `-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile` and the existing DerivedData cache):

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build test
# Repeat: the 21 exact test selectors above plus -test-iterations 10.
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
python3 -B -m unittest discover -s tools/t16 -v
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Release -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
python3 -B tools/verify_product_engine.py /private/tmp/stt-t15-validation.Uth8xp/DerivedData/Build/Products/Release/LocalLectureSTT.app
```

The first focused attempt found async default-method selection on concrete capture calls and an outdated UI prohibition. Both were repaired; the concrete capture controls now explicitly implement async requirements. The flush-failure test double was also corrected to publish the recorder's required terminal event; the stalled first test invocation was interrupted and is not passing evidence. `focus2.xcresult`, then Full/Repeated above, passed with these fixes.

Separate final frozen-commit review and exact-commit CI remain integration prerequisites. Completion/checklist updates wait for authorized dev integration.

## Separate frozen-source review and initial external CI block

The separate read-only pass against `08dad3a762bb6511a90e456ed1013ca7fda96b86` checked the complete task diff, the 21 named acceptance tests and actual results, all recording-phase lifecycle branches, capture gate ordering, recorder-prefix joins, pause/stop/sleep persistence serialization, speech epoch fallback, resampler/VAD boundaries, immutable engine selection, generation cleanup and UI admission. No blocking source or automated-acceptance finding remains. The existing T18 reconciler and timestamp preservation rules are unchanged. This is a separate review pass in the coordinator session, not a claim of a second model/agent review.

[Task CI 45546198577](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45546198577), exactly matching that source commit, was rejected before any runner step. Its check annotation reports: **“The job was not started because recent account payments have failed or your spending limit needs to be increased.”** The job has zero executed steps and no build/test log. The secondary notice about arm64 runner capacity is not the blocking failure. This is GitHub account billing/spending availability, not an observed code/test failure. Local success does not substitute for required task CI.

At that initial handoff, the phase was **blocked on GitHub Actions availability**. The task branch remained pushed and reviewable, without completion/checklist changes, dev integration or branch cleanup. G1 remained unverified.

## Public-repository CI retry and recovery assertion repair

On 2026-11-25 the user explicitly retained public visibility, accepted the audited email/local-path exposure, and authorized CI retry followed by dev integration, full committed-dev checks/CI and branch cleanup. G1 remains unverified; main and T25 are outside this authorization.

[Attempt 2 of CI 45546430014](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45546430014/attempts/2), on `8608be2740bd42e374174e41b7cf41a746e9eb85`, started successfully. All 570 unit tests and 20 of 21 integration tests passed. The paused-session recovery assertion measured `AVAsset.duration` as 0.956 s on macOS 15 and rejected it with an ad hoc 25 ms tolerance, although T08's existing AAC presentation-duration contract permits 150 ms.

The test now uses that existing contract, additionally checks the exact 1,000 ms paused metadata clock and nonempty decoded PCM, and independently compares source/recovered AAC packet count, compressed byte count, full payload SHA-256 and both compressed timeline boundaries (one sample tolerance). Production code and the existing three-epoch PCM duration/tone assertions are unchanged.

Repair validation: `/private/tmp/stt-t24-integration-5qbdofgn/RepairFull.xcresult` passed all **591 XCTest**, zero failures/skips. `RepairRepeated.xcresult` passed the two real-AAC T24 integration tests **10 times each (20 executions)**. Commands used the full Debug build/test above and those two exact selectors with `-test-iterations 10`; the same pinned packages and DerivedData were reused. A separate read-only review of the repair diff confirmed that the T08 policy is unchanged and the additional equality checks reject recovery packet loss or changed timing. Required exact-task CI and committed-dev validation still gate integration and branch cleanup.

## Phase 2 dev integration

Approved source `3de80561bd1f4a2a8034a1bc42d01fb6194ab3eb` passed [exact-task CI 45551796137](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45551796137): 570 unit + 21 integration tests, Debug/CLI/Python/Release checks and product-engine verification. The final repair diff was separately reviewed against the original frozen-source review; production code is unchanged from `08dad3a`. Re-fetch confirmed dev remained `d2d96456cc149b58a5fc5cc6248634881c8e7218` before the authorized squash integration.

The integration commit preserves that source tree and updates only `PROJECT_STATUS.md`, `IMPLEMENTATION_PLAN.md` and this integration evidence. G1 remains unverified; main remains `38e126f92ac823d29306ea8c1f7703f7060a5818`. Public visibility is explicitly retained by the user.

Committed-dev verification uses the same full Debug build/test, SwiftPM, Python and Release/product-engine commands listed above. Debug verification additionally sets `-resultBundlePath /private/tmp/stt-t24-integration-5qbdofgn/CommittedHead.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 60`. Exact argument arrays, exit codes and the validated HEAD are stored locally in `validation.json` and `validated-head.txt` beside that bundle. The final delivery handoff records actual committed-dev results, its exact-SHA CI and branch cleanup; this paragraph does not claim those future checks have already passed. Local and remote task branches are removed only after all checks succeed and dev is safely pushed. T25 is not implemented here.
