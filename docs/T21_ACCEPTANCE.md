# T21 session list, new recording and model management

Base: dev `0b45dc7e4543544e4b73094f5ae542c5f6af45ed`; branch `task/t21-session-model-ui`. Scope: IMPLEMENTATION_PLAN T21 and MVP_SPEC 4.1, 4.2, 5 and 15, with existing lifecycle safety preserved. On 2026-11-25 the user authorized continuous implementation, a separate read-only review, same-Task repair, task CI, dev integration and verified cleanup. This authorization does not skip any validation gate, pass G1, promote main or implement T22/T23.

| Requirement | Automated evidence |
| --- | --- |
| Local-only startup, explicit blocking for absent/corrupt/incompatible/unvalidated models and inventory errors | `SessionModelUITests.testStartupIsLocalOnlyAndBlocksMissingCorruptAndUnsupportedModels` |
| Explicit download, progress, pause/resume, capacity failure, retry and installed readiness | `testExplicitDownloadProgressPauseResumeFailureAndRetry` |
| Restart never auto-resumes; failed resume remains actionable | `testRestartRetainedTransferNeedsExplicitResumeAndFailedResumeDoesNotInventActivity` |
| One active transfer observer; cancelling a transfer preserves existing installation selection | `testSecondTransferCannotReplaceObserverAndCancelLeavesExistingModelUsable` |
| Folder picker cancellation, copied import completion, validation failure and locked controls | `testImportCancellationValidationAndLockedActions`; actual install/scope guarantees remain covered by T12/T13 tests |
| Permanent deletion requires references/incomplete-coverage acknowledgment; cancellation and stale assessment preserve models | `testDeletionRequiresBothAcknowledgmentsAndRefreshesSelection`, `testCancelledAndStaleDeletionDoNotClaimRemoval` |
| Failed catalog reads preserve rows; older results cannot replace newer rows | `testCatalogFailuresPreserveRowsAndNewerReadWins` |
| Title/date/duration/status presentation and model view construction | `testSessionLabelsAndModelScreensConstructWithoutNetwork`; signed interactive layout remains a manual check |
| Selected model forwarded only when ready; no changes during capture; exact selection saved in metadata; automatic title retained | `RecordingSessionCoordinatorTests.testT21StartUIRequiresValidatedSelectionAndHidesChangesWhileRecording`, `testT21SelectedModelIsPinnedAndPersistedWithoutFallingBackToDefault` |
| Model work survives window close, success permits exit, errors block automatic exit, explicit quit pauses network and joins installer cleanup | `testModelWorkOwnsLifecycleUntilPausedAndSupportsExplicitQuit`, `testClosedWindowWaitsForModelAndErrorSuppressesAutomaticExit`, `testShutdownCancelsInstallerAndWaitsForCleanup` |
| Explicit finite microphone check: levels/no-input, permission denied, pending permission cancellation and lease cleanup | `testMicrophonePreviewIsExplicitFiniteAndReleasesBeforeRecording`, `testDeniedPreviewAndStopDuringPermissionNeverStartCapture`, `RecordingSessionCoordinatorTests.testT21PreviewCleanupHoldsStartOwnershipBeforeCapture` |
| Existing recorder, recovery, transcript, STT and engine boundaries preserved | Full XCTest, SwiftPM benchmark build, four Python tests, Release product-engine inspection and exact-commit task/dev CI |

Root selection and historical-root reauthorization still use the T03/T09 tested controller. Session rows are a projection of authoritative files; no session file is edited by this task. Completed-session detail is a metadata summary; playback/editing/Finder actions remain T23. Existing live transcript UI is retained; T22 redesign is not included.

Validation commands and physical checks are in [Development](DEVELOPMENT.md#t21-ui-and-start-readiness-verification). The final handoff records actual source and integration commits, test counts and exact-commit CI; this matrix does not assert future results. G1 remains unverified. Physical TCC, sandbox folder selection, microphone hardware, live remote download, real installed-model GUI recording and visual interaction remain manual; all network/weights in automated UI tests are replaced with deterministic local fixtures.

## Candidate validation

Local `Full3.xcresult`: unsigned arm64 Debug build and **536 XCTest passed (517 unit + 19 integration)**, zero failures. The four Python comparison tests and SwiftPM benchmark build also passed. The final candidate SHA and exact-commit CI are recorded in the delivery; release verification is rerun after the final source changes. No visual screenshot pass is claimed: NSHostingView bitmap capture produced an empty image in this test environment, so visual interaction remains in the manual procedure.

## Separate read-only review and same-Task repair

The review of `0bfff0956291de354f11232971bae9e3c78f616a` checked task/spec coverage, the complete diff, original repository/downloader wiring, model compatibility and metadata, startup network call sites, catalog races, and app-lifetime ownership. Its 536-test suite, 17 new tests × 10 iterations (170 runs), SwiftPM/Python checks, Release inspection and [exact-source CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45442973237) passed.

A further review found that microphone-preview errors did not prevent automatic exit after window close. The repair publishes typed preview failure and invalidates cached exit admission **before** cleanup releases the preview lease. Normal preview stop and explicit safe quit remain allowed. `testPreviewFailureBlocksAutomaticExitButPermitsExplicitQuit` holds capture cleanup deterministically, checks attention while the lease is still held, then checks no reserved automatic exit and successful explicit quit. The repaired source requires its own complete test run and exact-commit CI; prior green results do not approve that new source.

The same review also requires explicit-quit cleanup evidence to include auxiliary work after a pause failure, even when attention was already visible before quit. `testFailedTransferPauseCannotReportExplicitQuitCleanupComplete` injects that failure, verifies rejection with the lease held, then verifies a successful retry.

Repaired-source validation: `ReviewedFinal.xcresult` passed **538 XCTest (519 unit + 19 integration), zero failures or skips**. `ReviewRepairRepeated.xcresult` passed both review regressions × 20 iterations (40 executions). The earlier 170 repeated runs remain evidence for the original 17 selectors, not an assertion that all 19 were repeated on the repaired source. SwiftPM compilation passed after the lifecycle repair.

## Dev integration

The approved final source is `bc2ed27e0fd2220cec3e8f85ba7729b2f7554be0`, with [exact-source CI success](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45444792082). The latest dev base is `0b45dc7e4543544e4b73094f5ae542c5f6af45ed`. Integration uses the advance authorization recorded in AGENTS/IMPLEMENTATION_PLAN and preserves the reviewed production/test/project tree. Only completion/checklist and this handoff change. The committed dev is rebuilt and tested using `-resultBundlePath /private/tmp/stt-t21-work/CommittedDev.xcresult`; its actual SHA, local outcome, exact-commit CI and branch cleanup are reported after they finish. G1 and main remain unchanged.
