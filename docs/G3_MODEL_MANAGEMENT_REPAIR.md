# G3 model management repair and review

Base: dev `5fd30d5ef9a08cb4ed08284847d1acf7ef843812`. Branch: `task/t21-g3-model-management-repair`. The user authorized the three G3 findings, regression tests, full validation, task commit/push/CI and submission for G3 re-review. That phase excluded dev integration and completion/checklist changes. The separate integration authorization and independent review are recorded below; G1 pass and T26 implementation remain excluded.

## Behavior and boundaries

- Generic folder import reads the selected directory's bounded, no-follow `manifest.json` and uses its validated descriptor. The manifest's previous installation provenance or claimed verification does not grant trust: copied bytes still pass the shared checksum, format and atomic-publication pipeline. Catalog-specific weight-folder import remains supported without a source manifest. Both UI routes use the same production `ModelFolderImporter`; selection cancellation, errors and completion unregister the opaque selection, and acquired scopes are released exactly once.
- Local copy requires the sum of descriptor payload sizes plus 16 MiB before staging/payload copy. Unknown/negative capacity, overflow and insufficient capacity are typed failures; a verified already-installed package needs no extra copy space. This is a preflight, not a reservation against unrelated disk writes. The download path keeps its existing three-copy admission policy.
- Missing, malformed or namespace-mismatched installation manifests expose a confirmation flow through the inventory row. The user acknowledges that references cannot be identified; existing session audio/transcripts are never mutated. A strict three-component hashed namespace, stored assessment/fingerprint, process-wide claim, cancellation and repeated no-follow identity checks protect the selected directory. An exclusive atomic rename preserves it under `Models/.preserved-<UUID>` and frees only that namespace for explicit reimport/download. No preserved contents are deleted or overwritten, and retained packages are excluded from usable inventory after relaunch. Post-rename failures return a committed preservation result with a warning.
- A valid manifest with the wrong namespace is withheld from the UI so that its key cannot target a different healthy model's deletion. Future schemas, unsafe symlink layouts and unreadable directories are conservatively retained and rejected; this repair does not reinterpret unknown schemas or auto-repair arbitrary filesystem corruption. Preserved directories remain available for manual inspection in the app's model store (Finder's Show Hidden Files reveals `.preserved-*`).

## Regression evidence

All names below are in `ModelRepositoryTests`; tests use generated model bytes, a format recognizer, actual file repository, temporary roots and scope accounting. The UI tests use the actual view model, production picker/import adapter and real download-service inventory inspection, with only directory selection and format recognition supplied by the fixture. They do not download weights or use personal models/sessions.

| Requirement | Tests |
| --- | --- |
| Generic import, independent copy, source unregister/release, local-only readiness | `testG3GenericImportUsesProductionUIAdapterAndRepository` |
| Picker cancellation, malformed metadata and changed payload reject usability and preserve originals | `testG3ImportCancellationBadManifestAndTamperedPayloadRemainUnavailable` |
| Catalog weight folder and future manifest rejection preserve the installed revision | `testG3CatalogFolderImportAndFutureManifestUseRealUIRepository` |
| Cancellation after selection unregisters without acquiring scope | `testG3FolderAdapterCancellationAfterSelectionUnregistersWithoutOpeningScope` |
| Exact capacity boundary, unknown/negative capacity, integer overflow | `testG3ImportCapacityExactBoundaryUnknownAndOverflow` |
| Denied capacity reaches neither copy hook nor staging; source and older revision survive | `testG3CapacityRejectsBeforeCopyAndPreservesSourceAndExistingRevision` |
| Capacity query throw, exact-fit installation, no-space idempotent import | `testG3CapacityQueryFailureAndAlreadyInstalledLowSpace` |
| Recovery UI recording lock, cancel/acknowledgment, exact preserved bytes, sibling/session sentinels, same-model reinstall | `testG3ManifestRecoveryUIRequiresConfirmationPreservesBytesAndAllowsReinstall` |
| Missing manifest, absent/stale confirmation and one-use assessment | `testG3RecoveryMissingManifestAndStaleOrAbsentConfirmation` |
| Manifest key mismatch cannot act on a healthy sibling | `testG3WrongManifestIdentityCannotTargetHealthySiblingFromUI` |
| Healthy package, future schema, traversal and symlink rejection | `testG3RecoveryRejectsHealthyFutureSchemaAndPathOrSymlinkEscape` |
| Concurrent recovery/import exclusion, precommit cancellation, claim release | `testG3RecoveryClaimAndCancellationCannotMoveOrDeletePackage` |
| Replacement during suspension and postcommit flush warning preserve all data | `testG3RecoveryRechecksReplacementAtPublicationAndReportsCommittedWarning` |

`DiagnosticsTests.testEveryIssueSeparatesCauseActionAndRecoveryWithoutRawErrors` also verifies all three new typed capacity mappings. Existing T12 claim/scope tests retain their original expectations; a focused run caught extra scope acquisition for known-key concurrent imports, and the implementation was corrected to retain claim-before-acquisition ordering rather than relaxing those tests.

## Validation

Evidence directory: `/private/tmp/stt-g3-repair`. Early focused attempts caught test compilation issues (missing `try` and Swift 6 actor isolation). The first executable focused run exposed the two existing scope-count regressions described above. `Focused5.xcresult` then passed 124 tests. Final source validation after the namespace-identity repair:

- `Full.xcresult`: **620 XCTest (598 unit + 22 integration), zero failures/skips**, Debug build passed.
- `Repeated.xcresult`: **13 G3 tests x 10 iterations = 130 passed executions**, zero failures/skips. The result-summary counts 13 unique tests; execution count is confirmed from iteration log entries.
- `swift-build.log`: SwiftPM developer benchmark build passed.
- `python-tests.log`: all four Python tests passed.
- `release.log` and `product-engine.log`: Release build and native-engine/catalog/bundle verifier passed.

Exact local commands (repository root):

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -resultBundlePath /private/tmp/stt-g3-repair/Full.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO build test
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
python3 -B -m unittest discover -s tools/t16
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
python3 -B tools/verify_product_engine.py /private/tmp/stt-t15-validation.Uth8xp/DerivedData/Build/Products/Release/LocalLectureSTT.app
```

Repetition used the Debug invocation with `test`, `-test-iterations 10`, `Repeated.xcresult` and one `-only-testing:LocalLectureSTTTests/ModelRepositoryTests/<name>` for each of the 13 G3 cases above. The exact argument list is in `repeated-command.txt` in the evidence directory. The separate read-only final-diff pass checked the application wiring, copy admission, scope/claim lifetime, namespace identity, pre/post-rename ownership, confirmation/lifecycle guards and preservation assertions. It found no remaining blocker in the assigned repair scope. Formal G3 re-review is still required; this is not integration approval.

Exact-head task CI and the submitted SHA are reported in the delivery message after push; no future CI result is asserted here. `PROJECT_STATUS.md`, `IMPLEMENTATION_PLAN.md`, `dev`, `main` and the two pre-existing untracked prompt files remain unchanged.

Manual checks remain pending: signed Sandbox folder-picker access, native confirmation-sheet interaction, real model import and actual external-disk exhaustion. Physical microphone, TCC, sleep/lid/process-kill and long/offline recording gates are unchanged and unverified. G3 readiness remains the coordinator's post-review decision.


## Independent G3 re-review and authorized integration

On 2026-11-25 the coordinator re-reviewed exact commit `fda22c90a77fe43d9bca5fe13f76cd5c8c30ac78` against the three findings, MVP_SPEC 12.2/15/16 and the G3 criteria. The separate pass checked the actual application picker/import adapter, repository verification and capacity admission, confirmation/lifecycle controls, corrupt/missing/wrong-namespace manifest paths, preservation and revision/session isolation. No remaining integration blocker was found. The broader G3 feature inventory had confirmed recording/pause/live transcript, file-authoritative finalization/recovery, root reauthorization, session playback/editing/Trash and local diagnostics; no post-MVP functionality was added.

Re-review ran the focused Debug command in DEVELOPMENT.md with `-resultBundlePath /private/tmp/stt-g3-independent-review/Focused.xcresult`: **125 passed, zero failures/skips**, and confirmed [source CI 45589731661](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45589731661) at that exact SHA: **598 unit + 22 integration tests**, SwiftPM/Python and Release engine verification all passed. G3 is therefore accepted for feature completeness; physical reliability and later performance/offline gates are not implied.

After this review, the user explicitly selected **dev integration, validation and branch cleanup only**. Latest dev remained `5fd30d5ef9a08cb4ed08284847d1acf7ef843812`. Integration preserves the reviewed production/test/project/dependency files; only PROJECT_STATUS.md, IMPLEMENTATION_PLAN.md, this evidence and the architecture gate note change. Build/full tests, CLI/Python/Release checks and exact integration-commit CI must finish before cleanup. Actual integration SHA, validation and branch cleanup are reported in the delivery, not preclaimed by this document. G1 remains unverified, main/tag promotion is excluded, and T26 is not started.

## Integration CI repair

The initial dev integration `b3018b26ba0a9b269b8a0c4b925fa321bed29287` passed local Debug build and all 620 tests, SwiftPM, four Python tests and Release verification. [Dev CI 45632808098](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45632808098) then failed two pre-existing assertions: the second recorder's append had not yet completed when read, and the UI speech failure was absent after an observed failure. Branch cleanup was withheld. Both original tests passed 50 local repetitions each, so that repetition alone was not treated as a resolution.

The existing task branch incorporated that dev baseline for narrow CI repairs. `testSettlementWaitsForPriorPumpDrainAndObserverTerminationBeforeNewSessionStarts` now waits for the independent pump's second-recorder append before asserting its contents; start never promised synchronous append completion. `testSuspendedPublicationCannotOvertakeTerminalFailure` holds a healthy publication while inference fails and proves an older healthy snapshot could overtake and erase the terminal failure. It failed on the previous production code with both the inverted delivery expectation and the failure-retention assertion (`Counterexample.xcresult`). The test uses the existing async publication closure; no new production fault-injection interface was added. The original CI scheduling cannot be replayed, but this controlled counterexample demonstrates the same state-regression hazard.

`LiveSTTCoordinator.emit` now joins deliveries in emission order, retains terminal publication through cancellation and releases the completed task chain. The actual file-backed integration/UI test additionally checks every observed snapshot after a speech failure retains that failure while recording and audio finalization continue. Existing normal-cancel, journal-failure, backpressure and essential-save assertions are retained. This changes neither model selection nor recording/storage contracts and does not implement T26.

Evidence is in `/private/tmp/stt-g3-ci-repair`. The relevant coordinator/file integration suites passed **92 tests**. After strengthening the UI assertion, the two original failures plus the new ordering regression passed **3 tests x 50 iterations = 150 executions** in `Repeated.xcresult`. `Full.xcresult` passed **621 tests (599 unit + 22 integration), zero failures/skips**, with a successful Debug build. SwiftPM, all four Python tests, Release build and the product-engine verifier also passed. Committed-dev tests and exact-commit task/dev CI remain required before branch cleanup; their final results and SHAs are recorded in the delivery.

A separate read-only pass of the complete six-file repair diff checked publication admission/order, cancellation and cleanup joining, task-chain release, unchanged audio isolation, preservation of the original assertions and the new UI failure-retention check. No remaining integration blocker was found. The original G3 model files, schemas and dependencies remain byte-for-byte unchanged from the reviewed integration. The documentation conflict caused by merging a previously squash-integrated branch was resolved to the existing dev documents, with no source conflict or discarded user files.

Commands use the same Debug/Release/SwiftPM/Python invocations above with this evidence directory. Focused tests select `LiveSTTCoordinatorTests`, `RecordingSessionCoordinatorTests` and `RecordingSessionFileIntegrationTests`. Repetition selects the two fully named tests above and `RecordingSessionFileIntegrationTests.testT19SpeechFailureDoesNotStopCaptureOrAudioWriter`, with `-test-iterations 50`. `Counterexample.xcresult` selects only the new ordering regression before the production fix; `Full.xcresult` runs the complete suite.

The reviewed repair commit is `0987cf382e13b00580e1cfd0cb756cb1e20585c7`. [Task CI 45636621836](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45636621836) passed at that exact SHA, including all 599 unit/22 integration tests and the three named regressions, SwiftPM, Python and Release product-engine verification. Latest dev remained `b3018b2` before the authorized repair integration. Only integration evidence/status/checklist notes differ from the reviewed repair tree. Committed-dev evidence uses `/private/tmp/stt-g3-integration-final` and the same commands; final SHA/CI/cleanup are reported after actual completion. G1 remains unverified, main unchanged and T26 unstarted.
