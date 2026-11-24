# T23 session detail, playback, editing and file management

Base: dev `0a2cae014fe409d55480f214b5c804ff117941ab`. Branch: `task/t23-session-detail-playback-files`. Scope: IMPLEMENTATION_PLAN T23 and MVP_SPEC 3.1, 4.4, 5.2, 12 and 16.2. The user authorized implementation, a separate frozen-source review, repairs, exact-commit CI and dev integration/cleanup in this session. G1 remains unverified; main and T24 are outside this task.

## Acceptance evidence

All named tests below are in `LocalLectureSTTTests/SessionDetailTests.swift`. Fixtures create synthetic AAC media and run the real audio/transcript finalizers, filesystem store and SQLite catalog. No lecture, model weight or runtime data is committed.

| Requirement / failure boundary | Automated evidence |
| --- | --- |
| Timestamp selects the segment's start; playback position, pause, bounded seek | `testTimestampSeekAndTextSaveUseRealRepositoryWithoutChangingImmutableFields`, `testPlayerReadsActualAACAndSeeksWhilePausedWithBalancedScopes`, `testTransportRejectsOldCallbacksAndReleasesResourcesOnPlayFailure` |
| Text-only edits preserve segment IDs/order/times/originalText, including overlapping times; regenerate TXT/MD from canonical | `testTextEditRenameAndRegenerationPreserveEveryImmutableFieldAndFolder`; real repository reached through the view model in the timestamp/save test |
| Rename preserves folder, model settings, canonical and audio; derived failure retains new authoritative title and permits retry | `testTextEditRenameAndRegenerationPreserveEveryImmutableFieldAndFolder`, `testRenameDerivedFailureKeepsAuthoritativeTitleAndSupportsRetry` |
| Finder reveals the three requested files under a balanced root scope; symlink/replacement rejection | `testRevealUsesRequestedArtifactAndBalancedRootLease`, `testUnsafeSymlinkAndDirectoryReplacementNeverRevealOrTrashAnotherTarget` |
| Explicit Trash confirmation; no permanent-delete fallback; remove catalog only after the whole directory moves; restoration rebuilds catalog | `testDeleteRequiresCurrentSelectionAndSuccessfulMoveDoesNotLeaveFailureAttention`, `testTrashMovesWholeSessionOnlyAfterSuccessAndRestoredFilesRebuildCatalog`, `testCatalogRemovalFailureAfterTrashIsWarningAndNeverRetriesOrRollsBackMove` |
| Concurrent recording creation, recovery, playback and mutations do not share write ownership; stale scans cannot resurrect a trashed row | `testActivityAdmissionProtectsEditsTrashAndRecoveryIncludingCreationReservation`, `testMetadataReplacementAndRecoveryOwnershipRejectTrashWithoutMovingFiles`, `testScanStartedBeforeTrashCannotReinsertDeletedCatalogRow` |
| Missing/corrupt files, absent recovery directory and read-only root are safe to inspect; playback failure preserves source files | `testReadOnlyDetailAndMissingCorruptFilesNeverRewriteOrDeleteData`, `testCorruptAndMissingAudioFailWithoutDeletionOrLeakedClaims`, `testPlaybackFileReplacementFailsSafelyAndDoesNotDeleteEitherCopy` |
| Save failure keeps the draft; quit waits for an in-flight save and refuses to finish while a draft remains; partial-publication retry is idempotent | `testFailedSaveRetainsDraftAndQuiesceRetriesItWithoutInvalidatingQuitAdmission`, `testPersistentSaveFailurePreventsQuitAndKeepsDraftAndOriginalBytes`, `testQuiesceJoinsSavingAndDuplicateActionsCannotTrashOrSelect` |
| Old callbacks/late root acquisition cannot touch a new playback driver's scope or session claim | `testLateOpenAfterCloseCannotReleaseNewPlaybackClaimOrSecurityScope`, `testTransportRejectsOldCallbacksAndReleasesResourcesOnPlayFailure` |
| A scan that read the old title cannot revert a successfully renamed catalog row | `testOlderScanCannotRevertTitleAfterSuccessfulRename` |
| Cancelling a draft after partial publication shows durable JSON rather than stale text and retains a repair notice | `testCancellingDraftAfterPartialSaveDisplaysDurableCanonicalText` |

The application boundary uses Codable/Sendable values without URL or AVFoundation types. Infrastructure owns `AVAudioPlayer`, scoped file access and Finder/Trash calls. Editing uses the existing canonical transaction; a failed derived write never rolls back a published canonical change. Saving again or **문서 다시 생성** repairs exports. Trash errors preserve the folder; catalog failure after a successful move is reported as a warning. A later external restore and scan reconstructs its row.

The view model prevents navigation with a pending draft, joins owned work before quit/sleep, and closes playback on navigation/window close. It retains failed drafts in memory and blocks automatic/explicit completion until a save succeeds or the user cancels the edit. It does not promise draft durability against process kill or power loss. The already-saved canonical file and recoverable audio remain protected by existing publication contracts.

## Verification limits

The actual AVAudioPlayer test opens generated AAC and seeks while paused. Transport/delegate fault tests use a controlled driver, and Trash tests use a reversible move adapter to an isolated temporary directory. They verify application ownership, file preservation and restoration, not audible speaker output, Finder UI, signed Sandbox permissions or Finder's native Put Back gesture. Production calls `FileManager.trashItem` with no permanent-delete path. The manual procedure in [DEVELOPMENT](DEVELOPMENT.md#t23-session-detail-verification) remains pending. These limitations do not change G1's unverified status.

## Initial candidate validation

`/private/tmp/stt-t23-work/ReadyFull.xcresult` passed **568 XCTest (549 unit + 19 integration)** with zero failures/skips after the unsigned arm64 Debug build. `ReadyRepeated.xcresult` passed all 20 T23 tests × 10 iterations (**200 executions**, zero failures/skips). Final fixtures close SQLite connections before removing their temporary directories; the repeated run has no unlinked-database warning. Earlier successful runs preceded that test-cleanup repair and are not the final evidence.

SwiftPM benchmark compilation, four Python comparison tests, the Release build and `tools/verify_product_engine.py` all passed. The Release check confirms native engine linkage, bundle contents and pinned model catalog. Commands are recorded in DEVELOPMENT. Exact-source CI and a separate frozen-source acceptance/diff review remain integration prerequisites; their evidence is recorded after execution.

## Frozen-source review repair

The separate read-only review of `9bb8965346185ec3486233218dc7dd0e708cbf16` found that a pre-rename scan could publish after the rename's own scan and revert only the catalog title. `ReviewRed.xcresult` reproduced this with the actual filesystem scanner and SQLite: the saved metadata remained correct but the row returned to `Synthetic finalization`. The added regression requires `최신 제목` in both files and catalog after the delayed scan settles.

The repair invalidates older scans on every catalog publication and serializes store publication/deletion across awaits. A stale scan reads the filesystem again after releasing publication ownership. No session schema, audio or canonical transcript rule changes. `ReviewGreen.xcresult` passed 84 tests across detail interaction/files and the existing catalog suite. Full/repeated/Release validation and exact repaired-source CI are required before integration.

The repaired source passed `RepairedFull.xcresult`: **569 XCTest (550 unit + 19 integration)**, zero failures/skips. `RepairedRepeated.xcresult` passed **21 tests × 10 = 210 executions**, zero failures/skips. SwiftPM build, four Python tests, Release build and product-engine verification passed again. The initial candidate [CI 45461924630](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45461924630) also passed on the existing Xcode 16.4 runner, but it does not certify this repair; exact repaired-source CI and its separate final review are recorded at integration.

The follow-up review of `cca7e4396af1ab632c94ede98c919c7da4d51c82` (whose [CI 45463160269](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45463160269) passed) found one display inconsistency: Cancel after a canonical write followed by export failure cleared the draft but left the old document visible. `CancelRed.xcresult` reproduced it. Cancel now rereads authoritative files after a failure, explains that already-saved changes remain, and keeps attention until repair/another explicit action. It does not roll back JSON or silently regenerate on Cancel. The new test then regenerates and verifies Markdown against canonical JSON.

Final candidate evidence: `FinalFull.xcresult` passed **570 XCTest (551 unit + 19 integration)**; `FinalRepeated.xcresult` passed **22 × 10 = 220 executions**. Both have zero failures/skips. Final SwiftPM/Python checks and Release build/product-engine verification passed. No remaining blocking source finding is identified in the separate final diff review; exact-final-commit CI is still required before integration.


## Separate final review and dev integration

The separate read-only review of `f0402e56982960abb313ae5cf92535c9d1a18c4d` checked the complete task diff and both reproduced repair cases, the 22-test acceptance mapping, canonical transaction boundaries, application composition, scope/claim cleanup, UI action admission and lifecycle behavior. No blocking source or automated-acceptance finding remains. [Exact-source CI 45465041972](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45465041972) passed on the existing runner. Specification, Domain schemas, dependencies, engine/model selection and CI workflow are unchanged.

The approved source is squash-integrated onto the rechecked dev base `0a2cae014fe409d55480f214b5c804ff117941ab` under the explicit continuous-work authorization. Only status/checklist and this evidence differ from the reviewed tree. Validation on committed dev uses `/private/tmp/stt-t23-work/CommittedDev.xcresult`, followed by SwiftPM/Python/Release checks and exact-dev CI. The final delivery records actual results and cleanup after execution. G1 and main remain unchanged; manual limitations above still apply.
