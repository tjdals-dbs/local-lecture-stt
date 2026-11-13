# T13 Phase 1 acceptance evidence

Assignment: `prompts/T13_MODEL_DOWNLOAD_VERIFICATION_ATOMIC_INSTALL.md`. Starting/latest fetched `dev` and `origin/dev`: `1ff211ffbf73f7d35818a4f2e5d154c21fe5bb63`. Task branch: `task/t13-model-download-install`. `main`/`origin/main` stay at `38e126f92ac823d29306ea8c1f7703f7060a5818`. This records a review candidate, not official completion or integration approval. `PROJECT_STATUS.md`, the implementation-plan checklist and `MVP_SPEC.md` remain unchanged. G1 is **Unverified**. No real weights/inference, model UI, T14, release, dev/main integration or branch deletion is included.

All unqualified function names below are exact `ModelDownloadTests` methods in `LocalLectureSTTTests/ModelDownloadTests.swift`. They exercise production `ModelDownloadService`, `URLSessionModelTransport`, private storage and the shared `FileModelRepository` installer, with generated packages and disposable roots. The actual HTTP fixture is in `ModelDownloadFixtures.swift`; it uses normal TCP/HTTP and the production URLSession delegate, not URLProtocol. Acknowledged gates/condition handshakes order races; timeouts are watchdogs, never sleeps/polling/yield loops or repeated-run quotas. All named automated tests executed and passed in the final focused/full results recorded below. Manual OS/hardware limitations are explicitly separate.

| ID | Exact test functions | Fixture/gate/assertion and executed outcome |
| --- | --- | --- |
| T13-01 | `testOldAndNewCatalogIdentityAndDeliverySchemas`; `testConstructionPendingInventoryAndBundleCatalogAreInert`; `ModelRepositoryTests/testValidatedSchemasDecodeAndBoundaryRoundTrips`; `ModelRepositoryTests/testKnownAnswerChunkedHashesAndStablePackageDigest` | Absent v1 delivery field decodes; new table/DTOs round-trip. Namespace/digest and manifests remain compatible. Missing/orphan/duplicate/path/URL/credentials/future/competing metadata fail. Actual Bundle.main catalog is empty. **Passed**. |
| T13-02 | `testConstructionPendingInventoryAndBundleCatalogAreInert`; `testRetainedCompletedPayloadFreshInstanceAndCapacityAccounting`; unchanged `AppShellInfoTests` and `MainWindowViewTests` | Construction, catalog/inventory/validation/pending reads call the counting transport factory zero times and create no download/model root. Fresh retained-state inspection is offline; app/preview composition stays unchanged. **Passed**. |
| T13-03 | `testCapacityBoundaryUnknownOverflowAndAdmissionBeforeTransport`; `testCapacityProviderFailureIsTypedAndDoesNotCreateSession`; `testRetainedCompletedPayloadFreshInstanceAndCapacityAccounting`; `testDiskWriteManifestFlushAndPublishFaultsKeepFirstCauseAndReleaseClaims` | Exact capacity boundary passes; one byte less, unknown/throwing provider, negative/overflowing sum/footprint fail before transport creation. Verified retained bytes receive precise credit; opaque bytes receive none. Injected copy/disk failure cannot install or delete existing/source data. **Passed**. |
| T13-04 | `testRealURLSessionNestedPackageInstallsAndFreshRepositoryResolvesOffline` | Real loopback HTTP + URLSession receives two files including `Native/weights.bin`, uses shared T12 verification/atomic install, and checks actual destination bytes/catalog origin. Server stops and selected-source fixture is removed; a fresh repository validates/resolves only its owned copy offline. **Passed**. |
| T13-05 | `testRealURLSessionPauseFreshServiceResumeUsesRangeAndEarlierBytes`; `testRealRangeNonSupportAndChangedResourceNeverAppendFullBodyToPartial`; `testRealTransportCorruptOpaqueResumeTokenFallsBackOnceWithoutRewritingToken`; `testNilCorruptAndRejectedResumeHaveOneTruthfulFallbackAndNoDuplicateStart`; `testRetainedCompletedPayloadFreshInstanceAndCapacityAccounting` | Server holds body after delivered prefix; URLSession acknowledges received progress before pause. Fresh service uses Apple's unmodified token, actual positive Range request and positive resumed offset, exactly two file requests and exact final bytes. Ignored Range reports offset 0/restart; changed body fails checksum. Actual corrupt token makes one bounded byte-zero fallback. Deterministic nil/rejected/failing fallback and completed-file reuse survive a fresh instance. **Passed**, not a daemon/relaunch claim. |
| T13-06 | `testBackgroundConfigurationAndReconnectReusesExistingTaskAssociation`; `testConstructionPendingInventoryAndBundleCatalogAreInert`; `testRetainedCompletedPayloadFreshInstanceAndCapacityAccounting` | Actual production background factory/configuration is constructed/closed with stable ID and no tasks. Ordinary-session seam holds an already-running task at the HTTP body gate, then reconnect finds its original task description; one request and `reconnected == true`, no duplicate. Pending reads remain inert. **Passed**; signed-Sandbox daemon/process behavior is **Manual/Pending**. |
| T13-07 | `testActualDelegateReceiptLifetimeDuplicateOutOfOrderAndErrorSettlement`; `testRealHTTPFailuresRedirectAndDestinationByteVerification`; `testRealHTTPTruncationOversizeAndWrongChecksumCannotPublish`; `testWrongLengthHashFormatAndUnavailableValidatorNeverInstall`; `testDiskWriteManifestFlushAndPublishFaultsKeepFirstCauseAndReleaseClaims`; `testFinalCollisionStagingSwapAndVerifiedPayloadMutationRejectPublication` | Open receipt survives removal of callback URL. Actual 404/500, rejected redirect, truncated/oversized body and wrong destination checksum cannot install. Missing receipt/error-only/receipt-then-error, format rejection/unavailable recognizer, exclusive write/journal/manifest/fsync/publication faults fail through production paths. Mutating verified staging at manifest-write await is rejected. **Passed**. |
| T13-08 | `testCancellationAcrossServiceAndInstallerGatesAndLateTerminal`; `testActiveTransportCancelJoinsAndOldGenerationProgressCannotMutateExplicitResume`; `testCancelDuringFreshResumeAdmissionCannotStartTransfer`; `testPostCommitReplacementDuringTransportCleanupKeepsOriginalAndReplacement` | Acknowledged cancel at before-request, created-suspended-task association/journal, receipt, copy, before-install, hash/verification, manifest, prepublish and postpublish gates. Admission-time cancel cannot start transfer. Precommit no final install; postcommit installed + cancellation/replacement warning, preserved committed data. Old generation callback is acknowledged/ignored, late wait observes identical settlement, session closes exactly once. **Passed**. |
| T13-09 | `testDownloadClaimsExcludeLocalImportValidationDeletionAndOtherDownloads`; `testDownloadExistingValidationClaimBlocksPreviouslyConfirmedDeletion`; `testCancelCleanupClaimBlocksRetryUntilAcknowledgedRelease`; `testExplicitRetryUsesNewAttemptAfterCleanFailureAndKeepsTerminalObservation`; `testExistingCorruptInstallIsNeverRepairedAndRevisionsCoexist` | Held download claim rejects another service, local import, validation, deletion assessment and an actual previously confirmed delete. Old cleanup retains its claim until gate release; a later attempt then succeeds without stale release. Clean retry gets a new ID; old terminal remains observable. Same-key corrupt bytes and sibling revision remain intact. **Passed**. |
| T13-10 | `testReplacedDownloadRootPayloadAndStagingNeverTouchSentinels`; `testNestedOwnedPayloadReplacementAndCleanupReplacementAreConservative`; `testFinalCollisionStagingSwapAndVerifiedPayloadMutationRejectPublication`; `testReplacedJournalCannotBeOverwrittenOrRemovedByOldAttempt`; `testUnknownFutureDamagedJournalAndCancelledPausedOperationArePreservedOrOwned`; inherited T12 unsafe-layout/replacement selectors | Replace download root, operation root, payload root (including symlink), nested payload, installer staging and final target around actual awaits/I/O. State-file swap cannot be overwritten or cleaned. Pinned ownership rejects replacements and preserves unrelated sentinels/originals/source files. Unknown/future/damaged records are visible and preserved. Only an unchanged proven paused operation is removed on explicit cancel. **Passed**. |
| T13-11 | `testCompletedBytesAndExactCatalogRecheckedBeforeResume`; `testPostCommitCleanupFailureRetainsInstallAndExplicitRetryReconcilesStaleJournal`; `testExistingCorruptInstallIsNeverRepairedAndRevisionsCoexist`; `testRealURLSessionNestedPackageInstallsAndFreshRepositoryResolvesOffline` | Changed completed bytes/tree or exact catalog locations fail before any transfer. Fresh service with committed final install + stale download journal validates/idempotently returns existing install with zero transport factories, then removes only old owned state. Revisions/origin/default policy and offline usability remain intact; incomplete files never enter inventory. **Passed**. |
| T13-12 | `testActualDelegateReceiptLifetimeDuplicateOutOfOrderAndErrorSettlement`; `testSessionInvalidationSettlesWithoutReceiptOrNewNetworkTask`; `testActiveTransportCancelJoinsAndOldGenerationProgressCannotMutateExplicitResume`; `testDiskWriteManifestFlushAndPublishFaultsKeepFirstCauseAndReleaseClaims`; real HTTP tests above | Production delegate receives coalescible/decreasing/duplicate progress, duplicate receipt, completion-before-late-receipt and receipt-then-error: bounded progress (asserted ≤66 for this fixture), one settlement, no progress after terminal. Invalidation cannot admit a new task; Foundation error codes are retained (disk write maps explicitly). First cause/cleanup issue are separate. Sessions/tasks/HTTP workers are closed/joined. **Passed**. |
| T13-13 | All 33 `ModelRepositoryTests` methods, all 35 T11 selectors, existing T05–T10 tests and both original targets | The three review regressions listed below remain byte-for-byte unchanged and passed. No existing test disabled/replaced. Only client entitlement added; production catalog/resource, TLS/ATS/Sandbox and default unavailable recognizer remain intact. No engine dependency, weights, UI, recorder/STT wiring or T14. **Passed**, with scope review. |
| T13-14 | Full shared-scheme arm64 Debug build/test, structured xcresult inspection, executable hashes, diff/ref review and exact-task-head CI | Both targets and all required selectors actually execute; zero failures/unexpected failures/skips. Commands/counts/paths below; final commit/CI URL and SHA are reported in the implementation handoff after push, avoiding a self-referential SHA amendment. `dev`/`main`, status/checklist and unrelated prompts are preserved. Task branch retained; G1 Unverified. |

Required unchanged T12 review selectors, all executed:

```text
ModelRepositoryTests/testReviewPayloadMutationAfterVerificationMustNotPublishSuccess
ModelRepositoryTests/testReviewIdempotentResultMustRevalidateAfterScopeRelease
ModelRepositoryTests/testReviewFutureManifestSchemaMustBeReportedWithoutV1Fields
```

## Initial candidate executed results (`0665f32`)

- Final focused result: `/private/tmp/stt-t13-focused-verified.xcresult`, log `/private/tmp/stt-t13-focused-verified.log`: **66 passed = 33 T13 + 33 T12; 0 failed, 0 unexpected failures, 0 skipped**.
- Final full result: `/private/tmp/stt-t13-verified/Full.xcresult`, log `/private/tmp/stt-t13-verified/build.log`: **365 passed = 355 unit + 10 integration; 0 failed, 0 unexpected failures, 0 skipped**. Unsigned arm64 Debug **build test succeeded** on Xcode 26.6/macOS 26.6.2.
- Structured summary/tree: `/private/tmp/stt-t13-verified/summary.json` and `tests.json`; focused summary: `/private/tmp/stt-t13-focused-verified-summary.json`. Tree inspection confirms **33 T13, all 33 T12, all 35 T11** (30 fake + 5 contract) selectors and both targets, including every required T12 review regression and the previously interrupted baseline audio test.
- Source/test/project/resource/entitlement fingerprints captured before the final full run in `/private/tmp/stt-t13-final-executable.json` (77 inputs) match the final tree. Supporting documentation-only evidence additions do not change executable inputs. No new attributable compiler warnings; final focused/full logs contain only the pre-existing AppIntents extraction warning. The initial clean baseline log separately records the six unchanged legacy Swift warning locations.
- `git diff --check` passed. Full source/test/ownership/data-policy and project-membership review is completed before explicit staging; staged scope/input hashes are verified again at commit. Exact task SHA, push and final-head CI are reported in the final implementation handoff, without a circular future-SHA amendment. Previous dev/source CI is not substituted.

Exact final full command (output redirected to the log above):

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t13-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t13-verified/Full.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path /private/tmp/stt-t13-verified/Full.xcresult --compact
xcrun xcresulttool get test-results tests --path /private/tmp/stt-t13-verified/Full.xcresult --compact
```

The focused command in `docs/DEVELOPMENT.md#t13-download-verification` uses the same configuration/derived data with `-only-testing:LocalLectureSTTTests/ModelDownloadTests -only-testing:LocalLectureSTTTests/ModelRepositoryTests` and its unique focused result bundle. The baseline command used the same configuration and `build test`, with derived data `/private/tmp/stt-t13-baseline.ZUXnJ1/DerivedData` and the distinct result paths below.

Earlier attempts are retained, not represented as passes:

- `/private/tmp/stt-t13-baseline.ZUXnJ1/Baseline.xcresult`, `build.log`: restricted runner could not connect to testmanagerd; **zero test execution**, not a baseline pass.
- Permitted unchanged baseline `/private/tmp/stt-t13-baseline-permitted/Baseline.xcresult`, `build.log`: **332 total, 331 passed, 1 failed, 0 skipped**. `AudioFinalizationTests/testCleanupRejectsMissingDirtyOrForgedProofAndDeletesOnlyRecoveryAudio` reported that the runner exited with code 0 before finishing; this is preserved baseline failure evidence, not an asserted recorder defect or T13 regression. It passed in subsequent complete current-tree runs.
- Initial focused attempt `/private/tmp/stt-t13-focused1.xcresult`/`.log`: **9 executed, suite failed** (10 assertion/unexpected failures). It caught receipt ctime changes after Foundation's legitimate unlink, a non-live reconnect fixture and resulting downstream failures. Fixed the receipt check to pin inode/size/mtime while allowing that unlink; no source/content check was removed from installed-model verification.
- `/private/tmp/stt-t13-focused3.xcresult`/`.log`: **56 executed, 1 failed**, because the synthetic transport collapsed a deliberately injected typed journal/disk error. Its fault mapping was corrected to preserve the first typed error. Production service tests then passed.
- Compilation-only failures remain in `/private/tmp/stt-t13-compile.log`, `/private/tmp/stt-t13-focused6.log` and `/private/tmp/stt-t13-focused7.log`: initial Sendable capture/SDK symbol and test existential/capture diagnostics were fixed. They have no passing test evidence.
- Intermediate focused runs (`focused2`, `focused4`, `focused5`, `focused8`, `focused-final`) and full runs (`stt-t13-final-validation/Full.xcresult`, `stt-t13-final-source/Full.xcresult`) passed their then-current trees. Final evidence below supersedes them; no arbitrary repeated-run quota is used.

## Changed paths and decisions

- `Domain/ModelDelivery.swift`, `Domain/ModelPackage.swift`: validated backward-compatible catalog delivery extension; descriptor/digest/manifest authority unchanged.
- `Application/ModelDownload.swift`: value-only explicit download commands, progress, typed failures and capacity assessment.
- `Infrastructure/ModelDownloadService.swift`: generation/admission/cancel/resume ownership, bounded explicit fallback, shared install and retained outcomes.
- `Infrastructure/ModelDownloadTransport.swift`: real URLSession background factory/delegates, synchronous owned receipt, bounded progress, task reconciliation and joined settlement.
- `Infrastructure/ModelDownloadStorage.swift`: private durable bounded state, conservative capacity provider and no-follow owned cleanup.
- `Infrastructure/FileModelRepository.swift`, `Infrastructure/ModelPackageFiles.swift`: minimal shared owned-source installer, original install evidence and nonce-guarded shared claims; persisted file stamps. Public T12 import behavior and verification algorithm stay shared.
- `LocalLectureSTTTests/ModelDownloadTests.swift`, `ModelDownloadFixtures.swift`: production-service faults/races and actual local HTTP tests; Xcode project records real source/test membership.
- `App/LocalLectureSTT.entitlements`: only outgoing-network client permission. No server/ATS exception.
- `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT.md`, this acceptance record and the assigned T13 prompt: actual architecture, commands, manual limitations and acceptance evidence.

Capacity is **3 × sum(payload lengths) − verified retained completed bytes + 16 MiB**, all arithmetic checked; both owned destination volumes must report sufficient known capacity. This intentionally over-reserves for the OS temporary/opaque-resume file plus owned/staging copies. No opaque partial-byte credit and no model/session deletion for space. Preflight is not a reservation.

One explicit-command fallback per affected file is allowed when the OS rejects opaque resume data. Positive range offset, live task continuation and full restart have separate result fields. Known partial owned copies without completed verification are never appended/adopted. Publication is shared T12 `RENAME_EXCL`; precommit failures cannot install, and postcommit cleanup/cancel warnings preserve committed truth. Shared claims remain held until transport and cleanup settle. Existing installations are never overwritten/repaired automatically.

## Remaining manual limitations and scope

Signed-Sandbox access, actual background-daemon/process continuation/relaunch, force quit, lid/power events and real-model inference remain **Pending/Unverified**. The reproducible manual procedure is in `docs/DEVELOPMENT.md#t13-download-verification`. Actual range resume is automated through ordinary URLSession; that does not prove daemon behavior. Background sessions automatically follow redirects without the normal redirect delegate; system ATS/TLS remains enforced and final credential-free HTTPS URL is revalidated before receipt acceptance, as documented from the installed SDK. No automatic launch/retry policy was added.

An interrupted conservative journal replacement can leave unknown/scratch state; it is diagnosed/preserved rather than automatically repaired. Opaque Apple cache paths are not owned/deleted by the app. Process-wide claims do not promise multi-process store mutation. The default recognizer remains unavailable, so actual model installation/inference requires later engine work. No intended product-spec deviation; these explicit limitations do not turn G1 or full MVP offline behavior into passes.

Official T13 completion/integration and whether T14 is safe to start remain the coordinator's independent post-review decision.


## Same-Task review repair — three findings

The user authorized repairs on the existing T13 task branch after read-only review of `0665f32caee261ebcf4a76e906a2fe2dfca5812a`. No official completion/integration/status/checklist authorization is implied. The original candidate's 365-test/CI pass is historical evidence, not acceptance of the uncovered paths. `dev`/`origin/dev` remain `1ff211ffbf73f7d35818a4f2e5d154c21fe5bb63`; main remains at the T01 baseline and G1 stays **Unverified**.

The read-only review re-ran the original full tree: `/private/tmp/stt-t13-readonly-review/Full.xcresult`, **365 passed (355 unit + 10 integration), 0 failed/skipped**, and original focused `/private/tmp/stt-t13-readonly-review/Focused.xcresult`, **66 passed**. A production-identical temporary copy with only appended diagnostic tests then reproduced **3 failures / 3 executions, 0 skips** (four assertion failures) in `/private/tmp/stt-t13-review.CO47uS/Diagnostics.xcresult`, log `diagnostics.log` and structured `diagnostic-summary.json` in that directory. Those are retained failing evidence, not passes. The three original diagnoses were: clean cancellation while an associated real task remained running; `resumable=true` but owned partial-copy resume rejected; and public retry leaving the original committed stale journal/payload. Original repository sources were unchanged during review.

All functions below are formal `ModelDownloadTests` selectors in the original registered test file and run through production services/adapter/storage, not a separate installer.

| Finding / acceptance | Exact formal selectors | Repair / assertion |
| --- | --- | --- |
| Fresh cancel left a surviving transfer — T13-06, 08, 12 | `testReviewFreshCancelMustSettlePersistedLiveTransferBeforeCleanCancellation` | A durable association and real ordinary URLSession task are held at the HTTP body gate. Fresh cancel enumerates the operation session, cancels/joins the exact associated task, closes the session, rechecks original state/payload pins and removes only its owned state. Task is completed, factory was used, cleanup is clean, journal is absent and the server saw only the original request. This proves adapter/orchestration logic, not OS-daemon/process behavior. |
| Partial-copy pause claimed resumability but resume failed — T13-05, 08, 10 | `testReviewPauseDuringOwnedCopyMustResumeWithoutDiscardingCompletedPayload` | Acknowledged copy-chunk pause leaves one completed payload and a 131,072-byte owned partial nested payload. Fresh resume preserves/revalidates the completed file, unlinks only the original pinned current partial plus empty owned ancestors, durably updates evidence and restarts that one file. Exactly one transfer is created; final bytes validate and restart is reported truthfully. |
| Public retry leaked original committed stale state — T13-11 | `testReviewPublicRetryMustReconcileOriginalCommittedStaleJournal`; `testReviewSameInstanceRetrySettlesCommittedCleanupWarning`; updated `testPostCommitCleanupFailureRetainsInstallAndExplicitRetryReconcilesStaleJournal` | A durable journal takes precedence over cached phase. Both fresh-instance and same-instance public retry keep the original ID, validate the installed model idempotently, settle old transport state if needed, then remove the original owned journal/payload. No transfer/new publication/default/origin change. The old acceptance selector now actually calls `retry`, not `resume`. |
| Preserve ownership/claim through new cancel awaits — T13-08, 09, 10, 12 | `testReviewFreshCancelKeepsClaimAndOwnershipThroughDiscardAwait` | Held discard proves the same-key model claim remains busy and state remains present until acknowledgement. Payload/journal replacement during the await preserves sentinels and produces a cleanup diagnostic. Injected transport reconciliation failure retains original state, source bytes and first cancel cause with a separate transport cleanup failure. |
| Exact task selection and bounded settlement — T13-06, 08, 12 | `testReviewDiscardSelectsOnlyExactLiveTaskAssociation` | Real live task remains running for a nonmatching association. Matching discard joins completion; repeating discard is idempotent and does not create another request. No broad session cancellation or task restart. |
| Reject partial replacement after resume suspension — T13-05, 10 | `testReviewPartialRestartRejectsReplacedFileAndPreservesCompletedSibling` | Replace the partial payload at the acknowledged resume-admission gate. Revalidation rejects it before transport creation and preserves the replacement sentinel, original partial and byte-for-byte completed sibling. Unknown/replaced ownership is never adopted for reset. |

Implementation changes are limited to `ModelDownloadService.swift`, `ModelDownloadTransport.swift`, `ModelDownloadStorage.swift`, the two existing download test/helper files and architecture/development/acceptance documentation. Application/Domain schema, catalog/digest algorithm, capacity formula, entitlements, T12 installer/claims and all existing recorder/lifecycle/engine code/tests remain unchanged. The protocol's internal discard seam reconciles existing tasks only; pending/catalog/inventory reads remain inert. Clean retry whose state was already removed still creates a new operation; retained retry reuses the original ID. Postcommit active cancellation continues reporting the committed install. Unknown private state remains preserved.

Repair execution evidence and exact final-HEAD CI are recorded below and in the implementation handoff. No circular future-SHA amendment is required. Manual signed-Sandbox/background-daemon/process/power checks and real inference remain Pending; T14 and full MVP 17.7 are outside this repair.

Repair focused command:

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t13-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t13-repair-focused-verified.xcresult \
  -only-testing:LocalLectureSTTTests/ModelDownloadTests -only-testing:LocalLectureSTTTests/ModelRepositoryTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO test
```

Repair full command:

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t13-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t13-repair-verified/Full.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path /private/tmp/stt-t13-repair-verified/Full.xcresult --compact
xcrun xcresulttool get test-results tests --path /private/tmp/stt-t13-repair-verified/Full.xcresult --compact
```

Failed/intermediate repair attempts remain visible:

- `/private/tmp/stt-t13-repair-focused1.xcresult` / `.log`: **69 executed, 68 passed, 1 failed**; the existing actual Range test timed out waiting for a particular progress threshold. The service/fixture handshake now waits until the service has processed actual positive received bytes before pause; Range offset/request count/final-byte assertions are retained. This is acknowledged ordering, not a sleep/retry quota.
- `/private/tmp/stt-t13-repair-focused-final.xcresult` / `.log`: a newly nested fixture sorted the large `Native/...` file before lowercase `a.bin`, so the supposed prior completed payload did not yet exist. The fixture's first file is now `Config/a.bin`, explicitly before `Native/z.bin` in the descriptor's UTF-8 ordering. Failed assertions and runner interruption from this attempt are retained, not passed evidence.
- `/private/tmp/stt-t13-repair-focused2.xcresult` / `.log`: **72 passed** on that intermediate tree. The latest focused/full evidence supersedes it.

Latest repaired-tree results (supersede the initial candidate's passing totals):

- Focused `/private/tmp/stt-t13-repair-focused-verified.xcresult`, log `/private/tmp/stt-t13-repair-focused-verified.log`: **73 passed = 40 T13 + 33 T12, 0 failed/unexpected/skipped**.
- Full `/private/tmp/stt-t13-repair-verified/Full.xcresult`, log `build.log` in the same directory: unsigned arm64 Debug **build test succeeded; 372 passed = 362 unit + 10 integration, 0 failed/unexpected/skipped**.
- Structured `summary.json`, `tests.json` and `focused-summary.json` in `/private/tmp/stt-t13-repair-verified/` verify actual target counts, all 40 T13, all 33 T12 including the three required review selectors, and all 35 T11 selectors. All original T05–T11 tests remain enabled and passed.
- `inputs.json` in that directory records 76 tracked source/test/project/resource/configuration fingerprints captured before the final full run; they still match the reviewed tree. No new attributable compiler warning; latest focused/full logs contain only the unchanged AppIntents metadata-extraction diagnostic. Documentation-only evidence updates do not change executable inputs.
- Full/staged diff review, `git diff --check`, explicit eight-path staging and committed-input equivalence are required before push. Final task-head SHA and exact CI URL/result are recorded in the repair handoff after commit/push; no dev/main/status/checklist change, task-branch deletion or official Task completion is authorized.

## Postcommit review repair — two additional findings

Source baseline: `db79d3836d01d848d4cfc0ab8abbd2bbacbcba22`. The user separately authorized these same-Task repairs on `task/t13-model-download-install`, with no official completion/status/checklist/dev/main integration or branch deletion. G1 remains **Unverified**. The original three review regressions stay enabled and pass; this section addresses additional canonical-install reconciliation gaps.

Read-only re-review baseline: `/private/tmp/stt-t13-db79-readonly/Full.xcresult` — **372 passed (362 unit + 10 integration), 0 failures/skips**. The then-exact-head CI also passed. A production-identical temporary copy with only three appended diagnostic tests reproduced **3 failed / 3 executed, 0 skips** (four failed assertions) at `/private/tmp/stt-t13-db79-review.WRPhLp/Diagnostics.xcresult`, with `diagnostics.log` and `summary.json` in that directory. These are retained failing evidence: retry was rejected by new-install capacity or partly removed temporary files despite a valid final model; fresh cancel returned `cancelled/result=nil` for a committed installation. Original repository files were unchanged during that review.

All selectors below are formal `ModelDownloadTests` methods in the existing registered unit-test file, using real repository validation and the production download service/storage. No alternate installer is used.

| Acceptance / finding | Exact formal selectors | Executed assertion |
| --- | --- | --- |
| T13-03, 11 — canonical commit before download-only admission | `testReReviewCommittedRetryMustNotRequireAnotherInstallFootprint`; `testReReviewPartiallyCleanedJournalMustNotHideVerifiedCommittedInstall`; `testReReviewCommittedReconciliationDoesNotQueryDownloadCapacity` | Existing final revision is independently revalidated before disposable payload integrity or capacity checks. A generated 2 MiB model reconciles with only 17 MiB reported free; a journal whose first temporary file was already unlinked also reconciles. Capacity providers that would throw are never queried for committed reconciliation; zero transfers/copies/publications, same operation ID and original manifest. Normal uncommitted capacity rejection tests remain enabled. **Passed**. |
| T13-08 — fresh postcommit cancel reports publication truth | `testReReviewFreshCancelAfterCommitMustReportInstalledTruth` | After successful install + cleanup failure, a fresh service returns `installed`, the committed manifest and cancellation warning, then cleans only owned disposable state. Final model bytes remain usable; no `cancelled/result=nil` outcome. **Passed**. |
| T13-08, 10, 11 — disposable remnants cannot erase valid final installation | `testReReviewCommittedCommandsPreserveMissingReplacedAndUnknownPayloadRemnants` | Both retry and cancel are exercised with missing payload root, swapped root, symlink to an unrelated root and an unknown extra file. Metadata-only pending inspection stays inert. Valid final installation is reported with cleanup warning; unsafe journal/remnants/sentinels and moved original data are preserved. No network factory for these cases. **Passed**. |
| T13-07, 11, 13 — verification cannot be bypassed | `testReReviewCommittedDiscoveryNeverPromotesCorruptOrUnavailableModels` | Corrupt final bytes and unavailable format validation never become installed success. Retry gives the typed repository failure; cancel still settles its operation and retains the repository diagnostic. Existing target bytes are preserved in all variants. **Passed**. |
| T13-08, 09 — cancellation and claims across committed admission | `testReReviewCancelDuringCommittedResumeAdmissionReportsCommitAndKeepsClaim` | An acknowledged admission gate holds the original verified model evidence and same-key claim. Another repository cannot validate under that claim. Cancel during the held retry still returns committed installation plus cancellation warning; claim releases after settlement. **Passed**. |
| T13-08, 10, 12 — original proof and first error survive failed awaits | `testReReviewCommittedProofSurvivesCleanupFailureAndTargetReplacement`; `testReReviewCommittedAdmissionFaultAndLostJournalPreservePublishedTruth` | Cleanup fault concurrent with final-target replacement preserves original/replacement bytes, first typed disk-write cause, separate cleanup cause and identity-change warning. A post-discovery metadata/admission fault cannot erase the committed result; lost/moved private metadata is preserved and diagnosed. **Passed**. |

Implementation is limited to `ModelDownloadService.swift`, `ModelDownloadStorage.swift`, `ModelDownloadTests.swift` and the three architecture/development/acceptance documents. Retained resume/retry and fresh cancel share `settleCommitted` with active publication. Canonical final revision validation retains the original evidence/claim through every admission/transport/cleanup await. Disposable payload-root access is optional only for already-verified committed reconciliation; ordinary uncommitted resume still demands pinned original payload evidence and download preflight. Metadata-only record reads are bounded/schema/identity validated and do not themselves assert model usability. Cleanup permits original remaining owned nodes and empty owned directories after partial removal, without adopting unknown files or replacement roots.

No catalog/schema/digest, capacity formula, entitlements, dependency, transport policy, T12 installer/claims or recorder/lifecycle/engine code change. Capacity is still `3S − C + 16 MiB` before any uncommitted transfer. Existing model format validation remains mandatory; default recognizer stays unavailable. All manual signed-Sandbox/background-daemon/process/power/inference limits remain Pending/Unverified, not automated passes. T14 remains outside this work.

Latest focused command:

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t13-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t13-postcommit-focused-verified.xcresult \
  -only-testing:LocalLectureSTTTests/ModelDownloadTests -only-testing:LocalLectureSTTTests/ModelRepositoryTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO test
```

Latest full command:

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t13-work/DerivedData \
  -resultBundlePath /private/tmp/stt-t13-postcommit-verified/Full.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path /private/tmp/stt-t13-postcommit-verified/Full.xcresult --compact
xcrun xcresulttool get test-results tests --path /private/tmp/stt-t13-postcommit-verified/Full.xcresult --compact
```

Latest evidence:

- Focused `/private/tmp/stt-t13-postcommit-focused-verified.xcresult`, log `/private/tmp/stt-t13-postcommit-focused-verified.log`: **82 passed = 49 T13 + 33 T12; 0 failed/unexpected/skipped**.
- Full `/private/tmp/stt-t13-postcommit-verified/Full.xcresult`, log `build.log` in that directory: unsigned arm64 Debug **build test succeeded, 381 passed = 371 unit + 10 integration; 0 failed/unexpected/skipped**.
- Structured `summary.json`, `tests.json`, `focused-summary.json` in the same directory confirm real target/T13/T12/T11 execution. All required T12 review selectors and all 35 T11 selectors remain enabled. `inputs.json` pins 76 tracked executable/config inputs before final full validation; supporting documentation-only updates do not change them.
- Intermediate `/private/tmp/stt-t13-postcommit-focused1.xcresult` / `.log`: **76 passed** on the initial repaired tree. `/private/tmp/stt-t13-postcommit-focused2.log` records a new-test async-autoclosure compile failure (zero executed tests), fixed by awaiting the Task value before the assertion. `/private/tmp/stt-t13-postcommit-focused3.xcresult` / `.log`: **82 executed, 81 passed, 1 failed**; the new failed-cleanup/target-replacement regression caught an identity warning overwritten by a generic cleanup warning. The original verification evidence and specific identity warning are now preserved. These failed/intermediate attempts remain visible and are not used as final passing evidence.
- No new attributable compiler warnings; final focused/full diagnostics are compared with the unchanged legacy warnings. Exact committed-input equivalence, six-path staged review, `git diff --check`, push and exact-final-head CI are verified in the implementation handoff. Prior SHA CI is not substituted and no self-referential SHA amendment is needed.
