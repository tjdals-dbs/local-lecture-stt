# T25 — integrated error presentation and local diagnostics

Scope: MVP 16 and 18; plan T25. Base dev: `04b7bac2f7ce39a6f27458410a51cc3a4c7cfe7c`. The user authorized implementation, a separate read-only review, repairs, validation/task CI, then dev integration/validation/CI and branch cleanup on 2026-11-25. T26 is excluded. G1 remains **Unverified**, main unchanged, repository public by explicit user decision.

## Acceptance evidence

`D/` below means `LocalLectureSTTTests/DiagnosticsTests/`; other selectors are written in full. All fixtures are generated, with no lecture material or model weights.

| Requirement | Automated assertion |
| --- | --- |
| Common cause, action and recoverability; microphone, storage, model, engine, finalization and session errors | `D/testEveryIssueSeparatesCauseActionAndRecoveryWithoutRawErrors` covers every issue's nonempty fields and representative typed errors, including model-folder access versus session-root authorization; unknown NSError content is excluded. |
| App logs omit transcript/title/path/detail strings | `D/testSessionEventProjectionOmitsDetailsTitleAndTranscriptAndExportsValidJSONL`; safe kind/time/session UUID projection and round-trip. |
| Authoritative events first; failure does not produce a false event; repeated recovery stays idempotent | `LocalLectureSTTTests/StorageRepositoryTests/testT25OnlyDurableEventsAreMirroredAndRecoveryRetriesStayIdempotent` uses real repository files and denied scope, checks two durable lines and two mirrored signals. |
| 100 MB maximum, file rotation, no session deletion | `D/testByteRotationClearAndExportPreserveSessionAndUnmanagedFiles` injects smaller byte/file limits and compares audio/transcript/events/recovery sentinels byte-for-byte. `D/testRetentionPolicyCannotExceedSpecification` rejects larger production limits. |
| 30-day retention on restart | `D/testThirtyDayBoundaryAndRestartPruneOnlyOwnedLogs` checks just before/exactly at expiry using the real file scanner, preserving unmanaged files. |
| Slow/failed log storage cannot block audio | `D/testQueueAdmissionIsBoundedAndDiskFailureNeverThrowsToProducer` covers bounded overflow plus write failure. `LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests/testT25BlockedFailedDiagnosticsDoNotDelayRecordingAndManagementPreservesRealAudio` blocks the log queue, finishes a real synthetic AAC recorder's essential save before releasing it, decodes recovery MOV, checks durable pause events and exact session bytes after clear/export. |
| No overwrite, reserved paths, publication race | `D/testExportNeverOverwritesReservedExistingOrRacedFiles` preserves existing bytes and a file created immediately before exclusive publication. |
| Export cancellation/write failure cleanup | `D/testCancelledOrFailedExportLeavesNoDestinationOrPartialFile` preserves input logs and leaves no partial/final output before publication. |
| Reject unsafe file layout | `D/testDirectoryAndManagedFileSymlinksHardlinksAndFIFOAreNeverFollowed` verifies clear/export/summary reject aliases and special files without changing the protected source. |
| Never export arbitrary fields or torn JSONL | `D/testExportReencodesClosedSchemaAndRejectsTruncatedRecords` strips an injected transcript field, and rejects a partial record without publishing output. |
| Concurrent append/clear/export | `D/testConcurrentAppendExportAndClearRemainSerializedAndProtectSessions` decodes all published exports and compares session sentinels. |
| Avoid duplicate snapshot-error noise | `D/testIssueTrackerDeduplicatesSnapshotsButRecordsNewEpisodesAndSessions` checks repeated identical snapshots, clear and recurrence. Recording owners reset the tracker at session changes. |
| Settings operations join cleanup and release lifecycle work | `D/testSettingsCancellationJoinsOperationAndReleasesLifecycleAdmission` checks cancellation, ownership and admission release; `D/testSettingsFailureCanBeInspectedAndDoesNotBlockExplicitQuit` checks attention and explicit-quit behavior. |
| No remote diagnostics | Read-only diff/dependency audit: no telemetry/upload/URLSession endpoint, dependency, entitlement or workflow change. The only export is a user-selected local file. |

## Separate review and repairs

A separate read-only pass compared the final implementation with the matrix and all changed/new source, not just the implementation report. This was a coordinator review pass, not a second model/agent review.

- Initial tests exposed Foundation's normalization of `/private/var` back into the `/var` symlink. Trusted OS/user-chosen base folders now use POSIX realpath without later Foundation normalization; no-follow validation remains below the base. All real filesystem fixtures exercise this path.
- Review found that model import permission failure incorrectly pointed at session-root reauthorization. `modelAccess` now names model management/reselection, with a regression assertion. Preview no-input presentation also uses the common cause/action/recovery view.
- A failed app-log append starts a fresh log on the next successful write, preserving potentially torn data; reading a file changed into a FIFO uses nonblocking open and validates its regular-file identity. Damaged logs are not silently exported.
- Read-only review confirmed fixed enum-only diagnostic payloads, bounded producer admission, exclusive export publication, serialized management, session-root isolation, existing essential-save/quit policies and local-only behavior. It added actual repository write-denial/idempotency and lifecycle admission assertions.

## Validation record

Final task-tree Debug build/test: **607 passed (585 unit + 22 integration), 0 failed, 0 skipped**, verified in `FinalFull.xcresult`. SwiftPM build and all four Python tests passed. Focused repetition: **16 selectors × 10 = 160 successful executions**, no failures/skips (`Repeated.xcresult`, raw XCTest execution counts). Release build and product-engine verification passed (native linkage, bundle contents and pinned catalog). Exact task/dev CI and committed-dev results are recorded with integration evidence; local checks alone do not imply CI success. Evidence lives outside the repository under `/private/tmp/stt-t25-work`; no logs/results/media are committed. Exact-commit CI is required separately for both task and dev before branch cleanup. Initial focused diagnostics: 14 passed; initial full build/test: 606 passed before the additional durable-event regression and final review repairs.

Commands (fresh result-bundle/log basename for each stage):

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/stt-t25-work/FinalFull.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
python3 -B -m unittest discover -s tools/t16 -v
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build
python3 -B tools/verify_product_engine.py /private/tmp/stt-t15-validation.Uth8xp/DerivedData/Build/Products/Release/LocalLectureSTT.app
```

Repeat the Debug command with the three selectors in [Development](DEVELOPMENT.md#t25-diagnostic-verification), `-test-iterations 10` and a fresh `Repeated.xcresult`. Do not build Debug/Release concurrently in the shared DerivedData.

## Limits and manual verification

[Development](DEVELOPMENT.md#t25-diagnostic-verification) contains the signed Sandbox, Finder/export chooser, real permission/device/storage failure, native layout and VoiceOver checks. Those remain **Manual/Pending**. These tests use actual local files and AAC with controlled capture/write fault seams; they do not simulate physical power loss or pass G1. Retention is applied on app activity/management, not by a daemon while the app is stopped. Nonessential pending app diagnostics may be lost on abrupt process exit; authoritative session storage retains its existing durability policy. No product-spec deviation or new network behavior is intended. T26/G3 work is not claimed by this task.

## Dev integration

Approved source `ccff3ebfddd745c0c3b56a5086b6ebb0b95627d1` passed [exact-task CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45560893166), including 585 unit + 22 integration tests, CLI/Python and Release engine verification. Latest dev remained `04b7bac2f7ce39a6f27458410a51cc3a4c7cfe7c`; no conflict or source rebase was required. The continuous-work authorization permits this squash and the T25 status/checklist update. Only this integration evidence, project status and plan checklist differ from the approved candidate; code/test/project tree equality is checked before committing.

The actual integration commit is tested with the same full Debug command using `CommittedDev.xcresult`, plus SwiftPM/Python/Release verification. After these pass, dev is pushed and its exact-commit CI must pass before local/remote task-branch deletion. The delivery message records the resulting SHA, live CI result and cleanup; this document does not preclaim a future CI outcome. G1 stays unverified, G3 pending, main unchanged and T26 excluded.

The first local integrated-tree run (`CommittedDev.xcresult`) reported 604 passes and three test-host exits with code 0 before completion (two AudioFinalizationTests and the two-hour synthetic AAC test), not failed data assertions. The reviewed source and first integration tree were byte-identical for code/tests. T13 acceptance already records this host-exit symptom on an unchanged baseline; this does not establish its cause or excuse the failed run. The failed bundle is retained. Focused repetition passed all three affected selectors × 3 = 9 executions (`DevHostExitRecheck.xcresult`). A fresh complete run (`CommittedDevVerified.xcresult`) is required on the final documentation-inclusive commit before dev push; its observed result is reported in the delivery evidence. No test is skipped, relaxed or removed to bypass this run.
