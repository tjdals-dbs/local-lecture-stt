# T20 canonical transcript candidate

Phase 1 candidate on `task/t20-canonical-transcript`, based on dev `672688b`. This task does not update completion status, integrate dev, remove the task branch, implement T21 or pass G1. Product behavior is defined in MVP_SPEC 4.4, 12.1, 13.3 and 13.5; checkpoint/recovery/lifecycle integration follows 7.4 and 14.

| Acceptance | Evidence |
| --- | --- |
| Strict, idempotent journal replay | `testReplayRejectsTornForeignFutureConflictingAndOutOfOrderRecords`, `testCorruptAndTornJournalPreserveAllOriginalBytesAndReportLine` |
| Ordered IDs/times, overlap preservation, text-only edits | `testCanonicalPreservesEditsAndOverlapButRejectsImmutableConflictsAndBadTimes`, `testActualFilesCompactEditRegenerateAndReopenWithoutImportingDerivedText` |
| Deterministic TXT/Markdown and safe YAML scalars | `testRendererIsDeterministicEscapesFrontMatterAndSupportsLongTimesAndUnicode` |
| Per-file atomic publication, retry, lease release and recoverable-file preservation | `testEveryWriteBoundaryRetriesWithoutLosingCanonicalOrRecovery`, `testDerivedFailureAfterTextEditRetainsSavedCanonicalAndRetryPreservesOriginal` |
| Cancellation, concurrent edit rejection, symlink and replacement safety | `testCancelledCompactionAndSymlinkDerivedPathNeverPublishCanonical`, `testConcurrentEditIsRejectedAndExternalReplacementAcrossAwaitIsPreserved` |
| Empty transcript and catalog failure are distinct | `testEmptyJournalCompletesAndCatalogFailureDoesNotClaimCatalogCheckpoint` |
| Real scanner/startup resumption at five crash boundaries, deleted MD regeneration, retained edits | `testStartupRecoveryResumesEveryTranscriptCrashWindowAndRegeneratesEditedMarkdown` |
| Interrupted capture remains interrupted | `testInterruptedRecoveryKeepsCaptureOutcomeAndExistingAudioWhileCompletingTranscript` |
| Derived failure: visible/retryable, blocks auto-exit, allows essential quit | `testTerminalDerivedFailureIsRetryableAndBlocksAutoExitButAllowsEssentialQuit` |
| UTF-8 across read boundaries, editing disabled before finalization | `testUTF8JournalAcrossReadChunksAndReadOnlyBeforeFinalization` |
| Corrupt/future/foreign canonical never overwritten | `testCorruptFutureAndForeignCanonicalAreNeverOverwrittenByJournal` |
| Production capture/audio/journal/SQLite to completed files; quit without draining STT backlog | integration `testT20NormalStopCompletesCanonicalDerivedAndCatalogAfterSpeech`, `testT20ExplicitQuitCancelsTranscriptWaitWithoutDrainingSpeech` |

Implementation: [architecture](ARCHITECTURE.md#t20-canonical-transcript-and-derived-files). Commands and manual checks: [development](DEVELOPMENT.md#t20-transcript-finalization-verification). The final delivery identifies the actual task SHA, local results and exact-commit CI; no future pass is implied by this matrix.

Canonical JSON plus metadata are the deterministic renderer inputs. TXT/MD are individually atomic; a failure between them can leave stale derived bytes until retry/reopen. A successful canonical edit remains saved if a later derived write fails; replay and regeneration preserve it. Journal corruption fails with a line number without skipping, truncating or overwriting the source. Single records above 4 MiB are rejected; recording duration has no new limit. All automatic T20 paths retain journal and recovery MOV. Checkpoints advance through `catalogUpdated`; the existing proof-gated T08 delete API remains separate, with a T20 production verifier available and tested. No editing UI or automatic recovery-audio deletion is introduced in this task.

Known prior test issue: T19 integration's first CI attempt failed in T10 `testRepeatedEssentialQuitSharesOneInterruptedSaveAndOwnedCleanup` because it does not acknowledge the second concurrent caller before releasing the first. Controlled temporary probes confirmed the scheduling gap; its retry passed. T20 does not change that unrelated test. Report any new occurrence instead of hiding it.

Local validation on 2026-11-25: final candidate source passed **514 XCTest (495 unit + 19 integration), zero failures/skips**, including 15 T20 storage/rendering/recovery tests and two T20 production-composition integration tests. Three termination/concurrency selectors passed **20 iterations each, 60 executions**. Release build/product-engine inspection, final SwiftPM developer-tool build and all four Python comparison tests passed. Artifacts: `/private/tmp/stt-t20-work/CandidateFull.xcresult`, `RepeatedFinal.xcresult`, `release.log`, `product-engine.log`, `cli-final.log`, `python.log`. Earlier intermediate build failures were corrected before these runs. The final task SHA and CI result are recorded in the delivery; G1 and physical checks remain unverified.

CI compatibility repair: the first candidate `1465fe1` failed during Debug compilation because the CI Swift compiler gives the synthesized `TranscriptJournalReplay` initializer private visibility. An explicit `init(sessionID:)` removes that compiler-version dependency. The repair again passed all 514 tests (`CompatibilityFull.xcresult`) and the SwiftPM build (`cli-compatibility.log`); behavior and task scope are unchanged. The final delivery reports the repaired SHA's CI result, not the failed candidate's status.

## Same-task review repair: overlap timing and read-only completion

The three independent probes failed against `94b79be` and were added to the repository before the repair (`/private/tmp/stt-t20-repair/Red.xcresult`). They are permanent regressions:

| Review case | Evidence |
| --- | --- |
| T18 boundary shift from 19.450 s to 19.440 s remains valid | `SpeechSegmentationTests.testReviewT20AcceptsExistingT18BoundaryShiftOutput` |
| The weak 50 ms overlap and later repetition survive canonical storage | `SpeechSegmentationTests.testReviewT20AcceptsWeakOverlapPreservedByT18` |
| Healthy completed session verifies on a read-only root without file replacement | `TranscriptFinalizationTests.testReviewT20CompletedSessionReopensOnReadOnlyRoot` |
| Missing/stale TXT and MD require repair, preserve edited canonical data and resume after permission returns | `TranscriptFinalizationTests.testReadOnlyDerivedRepairIsDistinguishedAndResumesAfterPermissionReturns` |
| Replacement while read-only verification awaits the catalog fails without clobbering it | `TranscriptFinalizationTests.testReadOnlyVerificationRejectsReplacementDuringCatalogAwait` |

The two timing cases use the real T18 reconciler, generated 21-second audio, the real journal/canonical/derived pipeline and a reopened verification. Equality checks preserve every segment field and journal byte. Display sequence remains validated; segment bounds still require `0 <= start <= end <= duration`, but starts across independent overlap windows need not increase.

The completed-session probe checks file bytes, inode and modification/change timestamps, not just equal contents. Read-only inspection and permission acquisition retain session ownership and revalidate pinned identities across awaits. Recovery distinguishes `repairRequired` from a healthy verification and offers folder reauthorization. Four missing/stale TXT/MD combinations check file preservation, permission-restored retry, canonical edits, balanced scopes and lifecycle attention without blocking safe explicit quit. The previous derived disk-full regression now removes MD first so it exercises a necessary write.

The focused repaired suite passed 54 tests with no failures/skips (`Focused2.xcresult`). The full unsigned arm64 Debug build/test passed **519 XCTest (500 unit + 19 integration), zero failures/skips** (`Full.xcresult`). Release build and product-engine inspection, SwiftPM developer-tool build and four Python tests also passed (`release.log`, `product-engine.log`, `cli.log`, `python.log`). Exact commands are in [development](DEVELOPMENT.md#t20-transcript-finalization-verification). An intermediate Swift isolation compile error was corrected by capturing the Sendable roots actor explicitly; no unchecked Sendable workaround was added. The repair delivery records the final SHA and its CI, without implying a future pass. This remains Phase 1; G1 and all physical checks remain unverified.


## Phase 2 dev integration

On 2026-11-25 the user separately authorized integration after independent approval of `51a452d4bf323d42f6c6c758ae949cfe0436d99c`. The review reran all 519 tests and added two temporary write-scope probes for cancellation, file replacement, concurrent admission, balanced release and retry; both passed. Source CI [45429543015](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45429543015) passed for that exact commit.

The latest dev base is `672688b8ca4cbb659f8f189419350398048bd937`. Integration preserves all approved code/tests/dependency/project inputs; only this handoff, `PROJECT_STATUS.md` and the T20 checklist change from the approved tree. The committed dev SHA is validated using the [documented commands](DEVELOPMENT.md#t20-transcript-finalization-verification), with `-resultBundlePath /private/tmp/stt-t20-integration/CommittedDev.xcresult`. Release inspection, SwiftPM build and Python tests are also rerun; logs use that same temporary directory. The final integration delivery identifies actual results, exact-dev CI and branch cleanup rather than recording a future pass here. G1 stays unverified, main remains at T01 and T21 is not implemented by this integration.
