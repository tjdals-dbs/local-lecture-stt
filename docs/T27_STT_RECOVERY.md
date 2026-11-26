# T27 STT recovery candidate

2026-11-26. User-approved addition on `task/t27-validation-readiness`, based on `9dd42e78387802b06ee7fd02b1df66a033f05b38`. Scope is MVP_SPEC §10.6: limited automatic live restart, durable missing ranges and post-stop repair. This is a phase-1 candidate, not completion of the ten-hour T27 validation. G1 remains unverified. PROJECT_STATUS, completion checklist, dev and main are unchanged. No integration or task-branch deletion is authorized.

## Behavior and ownership

- Live final: retry once, then joined cancel/unload/reload of the same pinned model; at most two reloads per session and three consecutive failed final windows. Success resets the consecutive count. Partial failure discards provisional text. Storage/model/permission errors do not loop.
- Capture remains independent. Bounded queue overflow and dropped input are durable pending ranges; current speech wins queue space. Explicit pause/cancel never resumes the microphone automatically.
- Atomic `recovery/speech-recovery.json` contains intents, successful/empty results, pinned configuration/language and persistent attempts. New metadata marks this format; a missing marked ledger is an error. Legacy sessions are not silently migrated or retranscribed.
- After verified audio and live cleanup, repair decodes only missing ranges, at most 20 seconds per request, with the same model. Two attempts per range survive relaunch. Missing model keeps work pending. Completed results are not inferred again; exhaustion remains visible.
- Sixty seconds is a soft inference cancellation deadline, not a guarantee of forcibly stopping native code. Cleanup is joined before release/replacement. Explicit cancellation preserves progress; interrupted attempts are refunded except for timeout/failure. A timeout's already-started attempt remains consumed across launch.
- Existing IDs, original/edited text, times and relative order remain; inserted rows receive their saved IDs and display sequence is reassigned. Torn journals remain errors. Audio is untouched.
- Pending work locks editing. Exhausted partial sessions show incomplete status and ranges. Canonical/derived publication can succeed for partial data, but unresolved work is not automatic-quit or recovery-deletion completion evidence. Healthy completed sessions validate read-only.
- Live UI keeps its append-only rows; after offline insertions the notice directs the user to canonical session detail. Expandable missing ranges include milliseconds. Metadata and TXT/MD mark incomplete transcription.

## Automated acceptance

All names below ran in the final full suite. Live tests are in `LocalLectureSTTTests/LiveSTTCoordinatorTests.swift`; file/repair tests are in `LocalLectureSTTTests/SpeechRecoveryTests.swift`.

| Requirement | Tests |
| --- | --- |
| Retry/reload ordering, model/language pin, exact-once journal | `testT27FinalRetriesThenReloadsSameModelWithPinnedLanguageAndOneJournalCommit` |
| Partial failure and explicit silence coverage | `testT27PartialFailureIsDiscardedAndSilentFinalIsDurableCoverage`, `testCoverageSubtractsCompleteSilenceAndSplitsOnlyMissingIntervals` |
| Bounded failure breaker with continued ingestion | `testT27CircuitBreakerKeepsIngestingAndRecordsAllFailedWindows` |
| Queue overflow/current speech and missing input | `testT27BackpressureDefersOldQueuedWindowButPreservesCurrentSpeech`, `testT27DroppedInputIsPersistedSeparatelyFromSuccessfulWindow` |
| Storage error does not retry an ambiguous write | `testT27StorageFailureNeverRetriesAmbiguousJournalAppend`, `testT27LedgerFailureStopsSpeechWithoutPublishingOrRetrying` |
| Timeout joins cleanup; late response ignored | `testT27TimeoutWaitsForNativeCleanupAndIgnoresLateResult`, `testTimeoutConsumesBoundedAttemptAndJoinsEngineBeforeReleasingScope` |
| Slow durable save is not inference timeout | `testT27SlowJournalAfterFinalIsNotMisclassifiedAsInferenceTimeout` |
| Explicit cancel and fresh-store resume | `testT27ExplicitCancellationLeavesPendingWithoutReload`, `testCancellationCheckpointResumesOnlyUncommittedGapInFreshStore` |
| Real AAC range read, offset, frequency, samples; audio byte preservation | `testActualAudioGapRepairAndCanonicalRetryAreIdempotentAndPreserveAudio` (synthetic 440/1320 Hz halves, actual second-half decoding; sub-ms AAC rounding allowed) |
| Prepared result survives pre-journal crash window | `testPreparedResultSurvivesCrashBeforeJournalAndDoesNotReinfer` |
| Persistent retry ceiling and incomplete export/detail notice | `testPersistentAttemptLimitPublishesPartialNoticeAndNeverRetriesExhaustedGap` |
| Missing model, pin preservation and editing lock | `testMissingModelLeavesPendingAndLocksEditingUntilModelRestored` |
| Exact IDs/text/time/order preservation and saved-result replay | `testCanonicalInsertsGapPreservingEditsIDsAndNonmonotonicT18SegmentOrder`, `testCanonicalPublicationFaultResumesFromDurableResultWithoutAnotherInference` |
| Actual startup scanner/shared queue/canonical refresh | `testStartupScannerResumesPendingRepairAfterModelRestored` |
| Healthy read-only validation | `testHealthyCompletedRecoveryValidatesReadOnlyWithoutLoadingEngine` |
| Corruption, missing ledger, torn journal and model mismatch preserve data | `testCorruptLedgerAndModelMismatchFailClosedPreservingAllSessionBytes`, `testMissingLedgerIsNotLegacyAndIncompleteJournalIsNeverSilentlyDiscarded`, `testCompletedLedgerStillChecksModelProvenanceBeforeReadOnlySuccess` |
| Legacy opt-out and unobserved crash tail | `testLegacySessionWithoutRecoveryMarkerDoesNotTranscribeEntireAudio`, `testCrashTailAndOverlappingPendingRangeExcludeAlreadyCommittedSpeech` |

The real file tests use `StorageRootManager`, pinned `FinalizationFileAccess`, actual AAC finalization/reading, `FileTranscriptRepository`, SQLite scanner/catalog and `FileSessionDetailStore`. Only inference/failure scheduling is controlled; no downloaded model or lecture data is committed. Fresh instances and write-boundary faults simulate progress loss. The existing T26 process-kill suite remains a separate OS-process verification; it does not specifically kill the new STT ledger between every instruction.

## Commands and local results

Final source build/test: **631 unit + 22 integration = 653 passed**, no failures. Evidence outside Git: `/private/tmp/stt-t27-auto-recovery/full3.xcresult` and `full3.log`.

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO \
  -resultBundlePath /private/tmp/stt-t27-auto-recovery/full3.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
python3 -B -m unittest discover -s tools/t16
swiftc -O tools/t27/ProcessMonitor.swift -o /private/tmp/stt-t27-auto-recovery/process-monitor
python3 -B tools/t27/test_validation_tools.py --monitor /private/tmp/stt-t27-auto-recovery/process-monitor
python3 -B tools/t27/test_model_sandbox.py --probe /private/tmp/stt-t15-validation.Uth8xp/CLI/debug/stt-benchmark
python3 -B tools/t26/test_recovery_process.py \
  --probe /private/tmp/stt-t15-validation.Uth8xp/CLI/debug/stt-benchmark \
  --results /private/tmp/stt-t27-auto-recovery/process-results-reviewed.json
```

Use fresh result/output paths when reproducing. SwiftPM build passed. Python groups passed **4 + 3 + 3 + 8 = 18**, no failures/skips. Process suite retained expected interrupted audio loss measurements (14.7s input → 11.006s recoverable, 22.5s → 21.032667s), not a new hardware guarantee. Logs are the matching `swift-build-reviewed.log`, `python-*.log` and `process-results-reviewed.json` in the evidence directory. Task CI must be checked against the pushed final SHA and reported with its run URL; an earlier green run is not substituted.

Earlier focused runs exposed two test compile errors and a catalog stub that could not satisfy actual finalization; those were fixed and replaced with real SQLite catalog checks. `full1` exposed the new artifact enum expectation and two runner exits; the enum expectation was updated and new fixture databases now close before directory cleanup. `full2` passed 652 tests. The final read-only review additionally required provenance validation even for a completed ledger; its regression is included in the 653-test `full3` run. Existing no-async/unused-value/AppIntents/QoS diagnostics are not represented as product failures or hardware verification.

## Review and remaining manual validation

Separate read-only source/diff review checked retry counters, cleanup joins, timeout cancellation, session/model/language pinning, durable prepare-before-journal ordering, canonical edit preservation, missing-ledger detection, actual app composition and lifecycle failure propagation. Two review findings were repaired before final validation: a slow journal sync must not trigger the native inference timer; already-completed ledgers must still match metadata provenance. Unrelated untracked handoff prompts were preserved. Completion/checklist and protected branches remain untouched.

Manual checks still required with a newly built signed local app:

1. Use a **new** recording, confirm microphone audio continues through a controlled STT failure, and inspect retry/pending time notices. Do not damage real model files to provoke a failure; controlled failures are already automated.
2. Stop, let missing-range repair finish, open session detail and compare audio/transcript around the gaps. Confirm old lines/times are stable and repaired rows appear once.
3. During optional repair, explicitly quit after essential save, relaunch and check continuation; verify actual UI/picker/TCC and lid behavior separately.
4. Run the deferred long lecture/offline/thermal matrix and latency observations in `T27_VALIDATION.md`. Single-process native deadlock/crash, actual disk exhaustion/power loss and G1 physical tests remain unverified.

No dev integration, release readiness, G1/G4 pass or next-task approval is implied by this candidate.

## 2026-11-27 timeout-exhaustion repair

Repair of the `fa1e435` review finding: the post-stop timer used to fail the shared finalization control before saving the timeout outcome, leaving an exhausted attempt pending and skipping partial publication. The deadline now produces a local timeout outcome, joins native cancellation, saves pending/exhausted state, and returns the summary for partial publication. The first timeout consumes one attempt and ends that pass; the second marks the range exhausted without another inference. Old pending entries with two attempts are normalized before model construction. Normal cancellation refunds an unfinished attempt; cancellation after timeout expiry retains the consumed attempt. Partial output still reports `speechIncomplete`, blocking healthy-completion proof and automatic exit.

Five new regressions in `SpeechRecoveryTests.swift`:

- `testSecondTimeoutPublishesExhaustedPartialWithoutThirdInferenceAndPreservesExistingData`: two fresh stores, exactly two requests, pending then unresolved counts, canonical/MD output and detail editing state, preserved segment ID/text/user edit/times, journal and MOV/M4A bytes, no model required on retry.
- `testAlreadyConsumedPendingBudgetPublishesPartialWithoutConstructingMissingModel`: persisted pending/attempts=2 becomes exhausted without constructing the missing model; entry IDs, audio and incomplete notice remain.
- `testExplicitCancelOfSecondAttemptRefundsBudgetAndPreservesPublishedPartial`: ordinary cancellation retains one available attempt and all published transcript/audio bytes.
- `testTimeoutCleanupIsJoinedAndLaterUserCancelDoesNotRefundConsumedTimeout`: held cancellation keeps the scope open and publication blocked; later explicit cancellation retains the timeout count, joins unload and balances scope release.
- `testSecondTimeoutPublicationFaultRetriesSavedPartialWithoutModelOrInference`: a Markdown publication fault after exhaustion leaves canonical data intact; a fresh store completes partial publication without model construction or extra inference.

The new two-timeout regression failed on the original source (`red.xcresult`, `red-second.xcresult`: shared storage failure/absent partial Markdown). The first repair test run found a test fault hook placed after an unchanged canonical write, which correctly did not run; the test now faults the required Markdown update. Focused recovery/lifecycle/live-STT/transcript suites then passed **108 tests**. Final full validation passed **636 unit + 22 integration = 658 tests**, zero failures. SwiftPM build and Python groups **4 + 3 + 3 + 8 = 18** also passed. No physical long-duration/TCC/lid/power-loss verification was added; G1 remains unverified.

Current repair evidence directory: `/private/tmp/stt-t27-timeout-repair`. Commands actually run (output logs in that directory):

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO \
  -resultBundlePath /private/tmp/stt-t27-timeout-repair/full.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
python3 -B -m unittest discover -s tools/t16
swiftc -O tools/t27/ProcessMonitor.swift -o /private/tmp/stt-t27-timeout-repair/process-monitor
python3 -B tools/t27/test_validation_tools.py --monitor /private/tmp/stt-t27-timeout-repair/process-monitor
python3 -B tools/t27/test_model_sandbox.py --probe /private/tmp/stt-t15-validation.Uth8xp/CLI/debug/stt-benchmark
python3 -B tools/t26/test_recovery_process.py \
  --probe /private/tmp/stt-t15-validation.Uth8xp/CLI/debug/stt-benchmark \
  --results /private/tmp/stt-t27-timeout-repair/process-results.json
```

Final diff review covered deadline/completion arbitration, joined cleanup, model-free exhaustion, ordinary/late cancellation, storage-failure propagation, and existing canonical/journal/audio preservation. Only the repair source, its tests and architecture/acceptance documentation change. This remains a review-ready task candidate only after final-commit CI is verified; PROJECT_STATUS, the plan checklist, dev and main remain unchanged. The next task remains the coordinator's post-review decision.
