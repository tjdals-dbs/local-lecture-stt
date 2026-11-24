# T19 candidate verification

Historical Phase 1 scope: implementation candidate on task/t19-live-stt-backpressure. No completion/checklist update, dev integration or branch deletion is authorized in this phase. G1 remains Unverified. Canonical transcript/export (T20) and the model UI (T21) are outside this change.

## Evidence map

| Behavior | Automated evidence |
| --- | --- |
| One mutable provisional, durable immutable finals, pinned session configuration | testProvisionalReplacementAndDurableImmutableFinal |
| Busy partial ticks dropped; sealed-window stale results ignored; finals scheduled next | testBusyTicksAreDroppedAndStalePartialCannotReplaceSealedWindow |
| Four-window production bound; smaller injected capacity fails explicitly once | testFinalQueueHasHardBoundAndReportsOverloadExactlyOnce |
| Context contains only the last durable segment and fits the 96-byte policy | testOnlyLastConfirmedSegmentIsBoundedContext |
| Automatic language locks; empty undetected result remains undecided | testAutomaticLanguagePinsAndRejectsLaterLanguageChange, testEmptyAutomaticResultDoesNotInventLanguageOrDisableLaterSpeech |
| Foreign response rejected before persistence | testForeignResponseIsRejectedWithoutJournalWrite |
| Start/inference/append failure preserves earlier finals and reports typed error | testInferenceAndStartFailuresTerminateSpeechWithoutLosingDurableFinals, testAppendFailureNeverPublishesOrRetriesUndurableFinal |
| Cancel joins pending journal sync and backend cleanup; no late final or duplicate unload | testCancelJoinsDurableAppendAndNativeCleanupBeforeUnload, testCancelDuringEngineStartAndInferenceHasNoLateFinal |
| Empty stream; dropped initial speech; later source gap keep media positions | testEmptyCaptureFinishesWithoutInferenceAndInputGapsKeepMediaTime, testSourceTimeGapFlushesSeparateWindowsWithoutChangingClock |
| Actual mono conversion and in-phase stereo downmix at 16/44.1/48 kHz; continuity, duration and gap | testRealConverterStereoRatesChunkBoundariesAndGap |
| Production capture, converter, VAD, coordinator, ViewModel, journal, audio finalizer and actual AAC decode | testT19LiveSpeechReachesUIAndJournalWhileAudioIsPreserved |
| Speech error leaves capture running and preserves all audio | testT19SpeechFailureDoesNotStopCaptureOrAudioWriter |
| Essential Stop returns with inference pending; lifecycle cancels and joins handoff | testT19LifecycleCancelsPendingSpeechAndJoinsHandoff |
| Real AppKit delegate quit after T08 completes cancels pending final inference and joins file-backed metadata/resource settlement | testT19DelegateQuitsAfterAudioFinalizationWithoutDrainingSpeechBacklog |
| STT-only quit waits for cleanup, including terminal phases and completed speech with a pending handoff; repeated Cmd-Q receives one reply | testT19SpeechOnlyQuitJoinsCleanupAndRepliesExactlyOnce |
| Speech work is tracked without an optional shared authority; closing the window lets speech and handoff finish before one automatic exit | testT19SpeechOnlyDecisionWithoutSharedAuthorityStillRequiresCleanup, testT19ClosedWindowWaitsForSpeechAndMetadataHandoffThenExitsOnce |
| Speech failures and independent storage warnings suppress automatic exit while safe explicit quit remains available | testT19SpeechProblemsBlockAutoExitButAllowSafeExplicitQuit |
| Normal cancellation and transient backlog permit automatic exit after settlement; unsafe essential save still blocks explicit quit | testT19CancellationAndDelayDoNotBecomeAutomaticExitErrors, testT19SpeechWarningDoesNotBypassUnsafeEssentialSave |
| A late speech storage warning invalidates an already waiting automatic exit | testT19LateSpeechErrorInvalidatesPendingAutomaticExit |
| Injected inference failure and file-backed journal append failure preserve audio, inhibit automatic exit and allow explicit quit | testT19SpeechFailureBlocksAutoExitButAllowsExplicitQuit, testT19TranscriptWriteFailureBlocksAutoExitButAllowsExplicitQuit |

The integration test normally uses a deterministic fake under the production model identity. The explicit installed-model run uses ProductionSpeechModel.make, its verified non-quantized large-v3 and the same complete UI/journal/audio path. It uses locally synthesized English speech; no real lecture audio or transcript is committed.

## Local verification

Commands and environment overrides are in [Development](DEVELOPMENT.md#t19-live-stt-verification). Logs/results are local artifacts under /private/tmp/stt-t19-work; temporary files can expire. The delivery report identifies the final task commit and its exact-commit CI.

On 2026-11-24 the initial candidate source passed the full Debug build and 487 XCTest executions (473 unit, 14 integration; zero failures/skips). These include 15 T19 unit and three T19 integration methods. Four concurrency selectors—busy partial suppression, queue overflow, cancellation during start/inference, and cancellation during journal/backend cleanup—passed 20 iterations each (80 total). The selected-engine integration passed separately with the installed large-v3. Release build plus verify_product_engine.py, SwiftPM CLI build and all four tools/t16 Python tests also passed. Result bundles: FinalFull.xcresult, FinalNative.xcresult and Repeated.xcresult.

The native probe uses /private/tmp/stt-t19-model/store, imported from the pinned tools/t15/candidate.json after full checksum and format verification. Its 7.26625-second Samantha speech fixture is followed by one second of silence. The test requires nonempty provisional text in the actual ViewModel, immutable final journal records and a decoded final audio duration matching all input. This is a local functionality check, not a lecture accuracy/latency gate or an OS network-denial measurement.

## Remaining manual checks

G1 physical microphone/TCC/signed Sandbox/bookmarks/lid/sleep/power-loss and long-recording checks remain unverified. Real lecture-room VAD quality, Korean/English terminology accuracy, three-second latency and sustained RTF targets require the later field/performance checks. The fixed four-window queue and 96-byte context are initial implementation limits, documented in [Architecture](ARCHITECTURE.md#t19-live-speech-coordination-and-backpressure).


## Same-task speech-only quit repair

The independent review of 85d5e2e found that T08 completion hid remaining speech work from lifecycle policy. Cmd-Q skipped essential settlement, then the shared lease guard rejected the quit. The new regression methods reproduced incorrect immediate-quit decisions before the policy change. Lifecycle now accounts for unfinished speech cleanup and active work leases, including the metadata handoff after inference is done. The existing cancellation, storage settlement and final synchronous admission guard remain in use.

Verification on 2026-11-24: the full unsigned arm64 Debug build/test passed 491 tests (476 unit, 15 integration), with zero failures/skips. The three new unit methods and new real-delegate integration passed 20 iterations each (80 executions). The installed non-quantized large-v3 UI/journal/audio integration passed separately. Release build/product-engine inspection, SwiftPM benchmark build and all four Python comparison tests passed. Commands are in [Development](DEVELOPMENT.md#t19-speech-only-quit-regression); logs and result bundles are under `/private/tmp/stt-t19-quit-fix`. Final commit/CI identity is reported in the delivery handoff. This remains a task-branch candidate; G1 is unverified and dev integration requires a separate review and authorization.


## Same-task automatic-exit error policy repair

Review of 0302852 found that completed audio could trigger automatic exit even when live inference failed. The lifecycle snapshot now separates attention that prevents automatic exit from unsafe essential-save state that also blocks explicit termination. Inference/queue failures and independent transcript/metadata storage warnings remain visible after cleanup. Normal coordinator cancellation and temporary backlog do not count as errors; an unexpected cancellation reported as failed inference does. The final automatic-dispatch reservation check rejects a late storage warning, while explicit quit still joins owned work and obeys the existing durable-save/generation/lease checks.

On 2026-11-24 the final source passed the full unsigned arm64 Debug build/test: **497 tests (480 unit, 17 integration), zero failures/skips**. Seven relevant selectors passed 20 iterations each (**140 executions**), including blocked cleanup, unsafe essential save, late-warning invalidation, production capture with synthetic PCM and injected inference failure, and a real FileSessionRepository journal append failure. The latter preserves decoded audio and the completed capture outcome while never presenting undurable transcript text. Release build/product-engine inspection, SwiftPM benchmark build and four Python tests passed. Commands are in [Development](DEVELOPMENT.md#t19-automatic-exit-error-policy-regression). Local artifacts: `/private/tmp/stt-t19-attention-fix/FinalFull.xcresult`, `Repeated.xcresult`, and adjacent logs. Final commit/CI identity is in the delivery handoff. G1 stays unverified; this is a task-branch candidate without dev integration or completion-status changes.


## Phase 2 dev integration

On 2026-11-24 the user accepted the independent review of `ab0e902baa70b4243b57fd2c1d2ad6354700d950` and explicitly authorized squash integration into dev, status/checklist updates, validation of the integration commit and subsequent task-branch deletion. This authorization supersedes the historical Phase 1 restrictions above. Latest dev was `63d7dc5806051845242ca53559525ab040244154`; no source conflict or task-branch rewrite was needed.

The approved product, test, project and dependency files are preserved exactly; integration changes only this handoff and the project status/checklist. Independent review passed 497 tests and three additional persistence/automatic-exit probes. Integration verification runs the committed dev SHA using the [documented commands](DEVELOPMENT.md#t19-live-stt-verification); local artifacts are under `/private/tmp/stt-t19-integration`, including `CommittedHead.xcresult`. The final delivery report identifies the dev SHA, actual validation results, exact-commit CI and branch cleanup. G1 stays unverified; main is unchanged and T20 is not implemented here.
