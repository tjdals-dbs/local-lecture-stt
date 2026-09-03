# T08 acceptance evidence

Phase 1 candidate; official Task completion, status/checklist changes and dev integration are not authorized here.

Baseline: `178471ce00de7b7ca7ecc7dfc77c7e9b45bd9697` (`dev` and `origin/dev`); `main` remains `38e126f92ac823d29306ea8c1f7703f7060a5818`. The baseline unsigned arm64 Debug build and 135 tests passed in this session. The T08 prompt was the only initial untracked file and is included as authorized input.

## Contracts and ownership

- `AudioFinalizationRequest`, `AudioFinalizationSnapshot`, `AudioFinalizationResult`, `AudioMediaReport`, `AudioEndpointReport`, `FinalizationFileEvidence`, `AudioFinalizationCode`: Foundation-only Codable/Sendable values. `presentPaths` describes observed artifacts independently of verified evidence.
- `AudioFinalizationCoordinator`: app-owned serial queue, duplicate-request coalescing, explicit cancellation/waiting, latest snapshots, generation isolation.
- `FinalizationMediaProcessing` / `AVFoundationFinalizationMedia`: Infrastructure-only real remux and streaming validation; framework types stay here.
- `FinalizationFileAccess`: pinned directory descriptors, identity/content checks, sync and exclusive publication.
- `FileAudioFinalizer.removeRecovery`, `FinalizationCompletionEvidence`, `CompletionEvidenceAuthority`, `RemainingFinalizationVerifying`: separate full-completion deletion boundary. T20 must supply the remaining-pipeline verifier; no live transcript placeholder or cleanup call exists in T08.
- `RecordingFinalizationCoordinator`: app-scoped receipt of T07 `.secured`; essential stop never waits for audio finalization. `RecordingSessionViewModel` only observes this lifetime.

## Requirement-to-assertion matrix

Unit test names below belong to `LocalLectureSTTTests/AudioFinalizationTests` unless a different suite is stated. Each test uses actual disposable files; media-path tests use AVFoundation and generated audio, not file-existence-only success.

| ID | Test functions | Key assertions / evidence |
| --- | --- | --- |
| A01 | `testContractsRoundTripAndConstructionHasNoSideEffects` | Request/result/snapshot/error round trips enforce Codable & Sendable generic bounds; forbidden URL/framework types are absent from new Application sources; queue construction performs no work/scope acquisition; future request is rejected even through the queue. |
| A02 | `RecordingSessionFileIntegrationTests.testAppOwnedFinalizationDoesNotBlockEssentialSaveOrNextRecording` | Production capture, root manager, recorder, repository, SQLite catalog and finalizer turn a closed T07 recovery MOV into real M4A. Independent source reader matches compressed provenance and endpoint RMS; final endpoints have distinct frequencies. |
| A03 | `testProductionRemuxAndResumePreserveRecoveryAndCheckpointBytes`, `testMediaRejectsActualWrongContainerTrackFormatAndDurationOutsideTolerance`, `testActualSparsePacketTimingIsRejectedAndStagingCannotReplaceMissingSource`, `testMediaAndPersistenceFaultsPreserveFirstCauseAndOriginalBytes` | M4A brand plus one AAC-LC mono 48 kHz track; nonempty separate first/end PCM decode; continuous packet timeline including inside grouped buffers; renamed MOV, video, stereo 44.1 kHz PCM, empty source, zero duration, ±151 ms source-duration mismatch and mid-read fault fail. ±149 ms real-file duration cases and exact 150 ms policy boundary pass. No exact-96,000 average bitrate assertion. |
| A04 | `testInvalidIdentitySchemaAndSymlinkLayoutsPreserveActualBytes`, `testResumeAdoptsProvenStagingAndCanonicalButRetainsDifferentMedia`, `testCompletedStagingWithDifferentVoiceIsRetainedAndCanonicalConflictWins`, `testRootAndFileReplacementDuringAwaitNeverRedirectsPublication`, `testPublicationCollisionAndPostValidationReplacementPreserveFiles`, `testReviewMediaCreateDoesNotWriteThroughReplacedSessionDirectory`, `testMediaAwaitReplacementPreservesExternalFilesAndReleasesOnce`, `testMediaOutputReplacementDuringWritePreservesExternalFilesOnCleanup` | Actual metadata/checkpoint ID/schema/corrupt bytes remain untouched; dangling canonical/staging and metadata symlinks fail; source missing/modified/replaced fails; same-duration/format different voice is preserved as conflict or retained staging. Canonical creation at publication and replacement after validation never becomes false success. Remux-internal replacement at create/created/start/started/write/finish and five framework-await boundaries aborts without writing to a replacement directory; external output files and original recovery bytes survive cleanup. |
| A05 | `testRootAndFileReplacementDuringAwaitNeverRedirectsPublication`, `testReviewMediaCreateDoesNotWriteThroughReplacedSessionDirectory`, `testMediaAwaitReplacementPreservesExternalFilesAndReleasesOnce` | Root reauthorization denial, moved-away root, chmod read-only root fail with typed errors. Changing active root during work still writes original location only, with exactly one acquired/released finalization scope; recovery-directory replacement is rejected. |
| B01 | `testEveryDurableWindowResumesWithNewInstanceAndOrderedCheckpointReadback`, `testProductionRemuxAndResumePreserveRecoveryAndCheckpointBytes`, `testDurationBoundaryInterruptedOutcomeAndTerminalMetadataArePreserved` | Trace proves secured checkpoint → finalizing metadata → export/flush → created checkpoint → validation/publication → canonical verification → verified checkpoint → projection. Actual checkpoint prefix is three; metadata stays finalizing, original outcome/duration/title remain, source and final exist, no transcript/derived files appear. |
| B02 | `testEveryDurableWindowResumesWithNewInstanceAndOrderedCheckpointReadback`, `testResumeAdoptsProvenStagingAndCanonicalButRetainsDifferentMedia`, `testCompletedStagingWithDifferentVoiceIsRetainedAndCanonicalConflictWins`, `testDurationBoundaryInterruptedOutcomeAndTerminalMetadataArePreserved`, `testActualSparsePacketTimingIsRejectedAndStagingCannotReplaceMissingSource`, `testReviewTerminalSessionRevalidationIsNotReportedAsWaitingForRemainingWork` | Twenty side-effect windows use new finalizer instances on retry. Complete staging is reused without export; post-rename canonical is provenance-checked and adopted; both-path canonical priority and conflict preservation; verified checkpoint/updatedAt bytes stay identical on rerun; downstream metadata/transcript summary stay unchanged; `testReviewTerminalSessionRevalidationIsNotReportedAsWaitingForRemainingWork` additionally verifies terminal normal/interrupted results are `audioRevalidated` and pending audio/catalog results remain waiting, with unchanged metadata/checkpoint/source/final/transcript bytes; missing claimed canonical fails without checkpoint regression; staging alone cannot replace missing source. |
| B03 | `testMediaAndPersistenceFaultsPreserveFirstCauseAndOriginalBytes`, `testEveryDurableWindowResumesWithNewInstanceAndOrderedCheckpointReadback`, `testPublicationCollisionAndPostValidationReplacementPreserveFiles`, `testCatalogFailureIsWarningButDoesNotAdvanceWholeCompletionOrDeleteRecovery`, `testMediaOutputReplacementDuringWritePreservesExternalFilesOnCleanup` | Production media seams inject create/start/read/write/finish, disk-full and endpoint decode failures. Storage hooks bracket each metadata/checkpoint write, staging flush and publication/directory-sync boundary. First failure is fixed before writer cleanup and survives cancellation plus cleanup/diagnostic persistence error; source bytes remain; publication followed by failure reports canonical presence. Catalog failure is a warning without rolling back audio or advancing checkpoint beyond 3. |
| B04 | `testCancelledPendingPersistenceRetainsFirstResultAndWaitsForReleaseBeforeRetry` | Controlled pending metadata write sees cancellation first then throws persistence; public result, latest snapshot and re-query all retain cancelled plus persistence warning. A release gate proves restart remains the same flight until scope release completes exactly once. |
| B05 | `testCleanupRejectsMissingDirtyOrForgedProofAndDeletesOnlyRecoveryAudio`, `testPersistentCompletionSealResumesDeletionWithNewAuthorityAndRejectsCatalogFailure` | Live audio readiness retains source and has no deletion. Incomplete checkpoint, nonterminal/changed metadata, corrupted/missing transcript/derived file, wrong session/root or forged/version-changed proof, and mutation after verification refuse deletion. Missing catalog acknowledgment prevents proof issuance. Synthetic full completion deletes only recovery MOV; final/transcript/derived/journal/retained files survive, events retain their original prefix; successful unlink hook occurs once across rerun. |
| B06 | `testDeletionCheckpointFailureRetryAndCancellationCommitPoint`, `testPersistentCompletionSealResumesDeletionWithNewAuthorityAndRejectsCatalogFailure` | Successful unlink followed by checkpoint failure resumes from serialized proof with a newly constructed authority and finalizer; source absence is not an error when complete evidence verifies. Already-completed checkpoint bytes are unchanged. The same sealed proof supports an explicit audio-only revalidation request after source removal, preserving terminal metadata/checkpoint bytes. Cancellation before deletion preserves source; after commit it does not hide deletion or prevent required final checkpoint. |
| C01 | `testSingleFlightSerialQueueCallerCancellationAndLateSnapshots`, `testCancelledPendingPersistenceRetainsFirstResultAndWaitsForReleaseBeforeRetry`, `testOldProgressCallbackCannotMutateNextGeneration` | Duplicate requests share generation/result; two sessions have exactly two sequential exports/releases; caller and observer cancellation do not stop work; real retained old progress callback cannot change next generation; late observer receives completed results. |
| C02 | `RecordingSessionFileIntegrationTests.testAppOwnedFinalizationDoesNotBlockEssentialSaveOrNextRecording`, `testViewObservationRetryAndBackgroundIdentityMapping` | Stop returns while finalizer is gated; new production recording starts and retains its identity/state when prior finalizer completes; both sessions later produce finalizing catalog projections. Essential-save and post-gate audio times are separate. Original T07 standalone recovery-only test remains unchanged in its assertions. |
| C03 | `testViewObservationRetryAndBackgroundIdentityMapping`, `testViewRetryReobservesTheSameSessionAndPreservesFailureCode`, `testReviewTerminalSessionRevalidationIsNotReportedAsWaitingForRemainingWork` | Stage text differentiates essential save/audio-ready/remaining work; real published view-model values receive failure, same-location retry and late ready state; cancelling/restarting observation does not cancel backend work. Terminal revalidation is delivered unchanged through coordinator snapshot and actual published view-model values, with the revalidation text rather than remaining-work text. |
| L01 | `AudioFinalizationLongMediaTests.testTwoHourContinuousAACProductionFinalizationAndRevalidation` | Exactly 337,500 physically present AAC packets, 1,024 frames each, continuous 7,200-second compressed coverage; source/final durations within 150 ms of target and each other, identical packet payload digest/count, independent nonempty endpoint PCM readers, prefix 3, recovery preservation and byte-identical checkpoint on rerun. Fixed hash scratch and measured per-buffer high-water are bounded independently of duration. |
| R01 | Full scheme/build and 20-iteration commands below; task HEAD CI | Local full build/162 tests and 220 repeated regression/race tests passed after the independent review fixes. The candidate report supplies the exact-HEAD CI URL and result, obtained with the command below. |

Diagnostic events are checkpoint-following best effort. Reruns do not duplicate a completed step's event; crash-window event omission is allowed. This is not a claim of a cross-file crash-atomic transaction.

## Commands and current results

Local commands run from `/Users/andyoon/stt`, with Xcode 26.6 / Swift 6.3.3 on arm64 macOS 26.6.2. CI uses macOS 15 arm64, Xcode 16.4 and Swift 6.1.2. The first CI found a test-fixture expression exceeding Swift 6.1 type-check time; the synthetic PCM calculation was split into explicit typed locals without changing assertions or tolerance. The original candidate passed 158 tests after that compatibility fix; current review-fix results are listed below. Logs and xcresult remain outside Git.

```sh
# Baseline (135 tests, passed)
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T08-DerivedData \
  CODE_SIGNING_ALLOWED=NO build test

# Current targeted unit/fault/regression run (25 tests, passed)
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T08-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests test

# Each listed lifecycle/compound-failure/integration test runs 20 times.
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T08-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests/testSingleFlightSerialQueueCallerCancellationAndLateSnapshots \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests/testCancelledPendingPersistenceRetainsFirstResultAndWaitsForReleaseBeforeRetry \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests/testOldProgressCallbackCannotMutateNextGeneration \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests/testDeletionCheckpointFailureRetryAndCancellationCommitPoint \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests/testViewRetryReobservesTheSameSessionAndPreservesFailureCode \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests/testMediaAndPersistenceFaultsPreserveFirstCauseAndOriginalBytes \
  -only-testing:LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests/testAppOwnedFinalizationDoesNotBlockEssentialSaveOrNextRecording \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests/testReviewMediaCreateDoesNotWriteThroughReplacedSessionDirectory \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests/testMediaAwaitReplacementPreservesExternalFilesAndReleasesOnce \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests/testMediaOutputReplacementDuringWritePreservesExternalFilesOnCleanup \
  -only-testing:LocalLectureSTTTests/AudioFinalizationTests/testReviewTerminalSessionRevalidationIsNotReportedAsWaitingForRemainingWork \
  -test-iterations 20 test
```

After the independent review fixes, the `AudioFinalizationTests` target passed **25 tests**, then the complete `build test` command passed **162 tests (159 unit + 3 integration), zero failures**. The eleven listed regression/lifecycle/compound-failure/app tests passed **20 iterations each: 220 executions (200 unit + 20 integration), zero failures**. The full run includes L01. Git diff checks passed; the task commit and exact-head CI URL are reported with the review candidate. To reproduce the CI lookup, run `gh run list --branch task/t08-final-audio-finalization --commit <candidate-sha> --json headSha,conclusion,url`.

Current local evidence is in `/private/tmp/T08-review-targeted.log`, `/private/tmp/T08-review-full.log` and `/private/tmp/T08-review-races220.log`; logs and generated media are not committed.

## Long media measurements

The fixture has an exact 7,200-second compressed sample table. AVFoundation accounts for AAC priming when reporting playable duration: source and final both measured **7,199.956 seconds**, a 44 ms offset from the metadata target and a **0 ms source/final difference**. Coverage assertions use the actual packet timeline as well as asset duration. Begin and end readers each decoded **48,000 bytes**; end range **7,199.706–7,199.956 seconds**. Maximum packet gap was approximately **9.1e-13 seconds** (floating point conversion).

Review-fix full-suite long-test measurement: fixture generation **0.0064 s**, audio finalization **1.341 s**, revalidation **0.811 s**, media buffer high-water **9,108 bytes**, process peak RSS **163,332,096 bytes**. The isolated long test previously observed about **111 MB** process peak RSS. The RSS value includes the XCTest host and framework caches. Application media buffers are capped at 1 MiB and fingerprint scratch at 64 KiB; fixture payload batching is <=64 KiB. No full media `Data` or PCM array is accumulated by production or long-fixture generation.

The audio stage is below the 60-second whole-MVP target on this synthetic run; this is **not** a whole-MVP finalization pass because transcript/derived generation remains T20. Essential production-composition save measured about **0.024 s** with synthetic capture; hardware/TCC latency remains manual.

## Manual evidence and scope

The signed sandbox/bookmark/TCC and physical-microphone procedure in [Development](DEVELOPMENT.md#manual-t08-check-pending) remains pending. The automated suite does not establish power-loss durability, process-kill recovery, window/quit/sleep behavior or real lecture quality. Those remain the relevant later Tasks.

No product behavior deviation is intended. No STT, transcript renderer/compactor, startup scan, pause/resume, full session list or T10 lifecycle policy is implemented. `PROJECT_STATUS.md`, `IMPLEMENTATION_PLAN.md`, `MVP_SPEC.md`, dev/main and gate state must remain unchanged. The task branch remains available for independent review and same-Task fixes; starting the next Task requires the coordinator's independent review and separately authorized integration.

## Independent review fixes on b548283

The two supplied review probes were copied from the independent temporary checkout and first run against `b548283fad9596aa11b894d7eb4183fa7af7d1e5`: **2 tests, 2 assertion failures**. They reproduced a staging file created in the replacement session directory and an already-terminal session reported as awaiting remaining work.

- `testReviewMediaCreateDoesNotWriteThroughReplacedSessionDirectory` now covers create/created/start/started/write/finish. Each actual rename-and-empty-replacement case asserts `identityChanged`, an empty replacement directory, unchanged original recovery bytes, no canonical publication, exactly one media cleanup and scope release, and the identical coordinator result.
- `testMediaAwaitReplacementPreservesExternalFilesAndReleasesOnce` uses continuation gates after tracks/duration/formats loads, readiness and writer finish. External staging/canonical markers in the replacement directory remain byte-identical; original recovery and exact-once cleanup/release are asserted.
- `testMediaOutputReplacementDuringWritePreservesExternalFilesOnCleanup` replaces the open staging path at append and finish boundaries. It asserts preservation of both external markers and recovery while cancellation plus a cleanup persistence error cannot replace the original `identityChanged` cause.
- `testReviewTerminalSessionRevalidationIsNotReportedAsWaitingForRemainingWork` covers normal/interrupted terminal metadata through `catalogUpdated`, the pending catalog step, and the live audio-only prefix. It asserts the result, coordinator snapshot, actual published view-model value/text, unchanged metadata/checkpoint/audio/transcript bytes and no recovery deletion.

The command above includes the original seven race/integration tests and all four new regression tests with `-test-iterations 20`: **220 executions passed**. The final-HEAD CI link is supplied in the candidate report; no official completion or integration is recorded here.
