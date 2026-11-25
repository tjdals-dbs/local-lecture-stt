# T26 fault injection and recovery validation

Base: `e04b5c2673b58a75735dc616a0edabf76a940b3e` (verified G3 dev). Branch: `task/t26-fault-recovery-validation`. On 2026-11-26 the user requested starting T26. This candidate covers IMPLEMENTATION_PLAN T26 and MVP_SPEC 14/17.6. G1 stays **Unverified**, main unchanged, T27 unstarted. The original candidate stopped before completion/checklist changes and dev integration. On 2026-11-26 the user authorized continuing through independent review, any needed repairs, dev integration/validation/CI and branch cleanup; T27 remains excluded.

## Implemented test boundaries

- `tools/t26/RecoveryProbe.swift` is a developer-only `stt-benchmark recovery-probe` command, built with the same Application/Infrastructure source as the app. It uses the real AVFoundation recorder, file repositories, scanner, finalization queue, transcript compaction, SQLite catalog and recovery coordinator. The directory picker/bookmark codec is a disposable path codec; capture receives generated mono PCM and the journal has three known synthetic segments. It does not use a microphone, engine/model, network or user Application Support. The GUI target does not compile this file.
- The Python parent creates an empty marked `/private/tmp/T26-*` fixture. Child state, roots, catalog and persistent completion-proof key remain inside it. An acknowledged pipe boundary precedes a parent-issued **SIGKILL**; exit status must be `-SIGKILL`. The child never calls recorder finish at a recording kill boundary. Fresh child processes reopen the existing registry and recover the files. Timeouts terminate only their owned child, and test-owned fixtures are cleaned afterwards.
- PCM is submitted in 100 ms media chunks paced at 10 ms wall time (10x speed). There is no postfeed flush, active-file copying, readability wait or graceful cancellation before recording/paused kills. The accepted frame count is compared with recovered AAC duration. This is a synthetic process-crash measurement, **not** real-time microphone, signed Sandbox, lid, power-loss or universal worst-case durability evidence.
- `AtomicWriteStep.afterRename` allows testing the committed-but-not-directory-synced boundary. A fault reports the existing typed atomic-rename failure while preserving the whole newly published document; retry is idempotent. Existing pre-rename preservation tests remain. `TranscriptWritePoint.afterCheckpoint` observes a checkpoint after its actual atomic write. Both hooks default to no-op; no app-facing API, schema or product policy changes.
- The closed-window XCTest uses the real audio/transcript finalizers, SQLite catalog and lifecycle policy. Its automatic-termination gateway is an acknowledged observer; it does not terminate the XCTest host. Actual AppKit termination remains M04.
- Checkpoint 8 uses the existing **explicit**, proof-gated cleanup API only after real canonical/transcript/catalog verification. It does not enable automatic recovery-file deletion in the app. Checkpoints 1–7 retain recovery MOV and journal bytes. The remaining writer, media/checksum and write-failure seams already existed and are exercised by the full XCTest suite.

## MVP_SPEC 17.6 scenario matrix

`P.*` names below refer to `tools/t26/test_recovery_process.py::RecoveryProcessTests`. XCTest names are exact method names in the named class. Manual entries have **not been run**.

| Scenario | Automated evidence | Physical/manual evidence |
| --- | --- | --- |
| Recording force quit | P.`test_sigkill_recording_and_paused_loss_at_most_ten_seconds`: two recording positions and one paused state, accepted frames, actual SIGKILL, fresh recovery, decoded endpoints, original bytes | M01: GUI process / physical capture, Pending |
| Close MacBook lid during recording | `AppLifecycleTests.testT24PausedSleepAndWakeInterruptWithoutAutomaticResume`; `RecordingSessionFileIntegrationTests.testT10SleepInterruptionRetainsReadableRecoveryMOVWithoutDerivedPlaceholders` | M02: actual lid/sleep/wake, Pending |
| Kill at each finalization checkpoint | P.`test_sigkill_at_every_durable_checkpoint`: **all 8** actual persisted prefixes, fresh recovery three times | M03: GUI checkpoints/power behavior, Pending |
| Complete and auto-exit after last window closes | `AppLifecycleTests.testT26ClosedWindowWaitsForRealAudioTranscriptAndCatalogBeforeAutomaticExit`; `testT26ClosedWindowKeepsAppOpenAfterRealTranscriptWriteFailureAndPreservesAudio` | M04: actual AppKit window/termination, Pending |
| Exit during final audio generation | P.`test_sigkill_during_export_and_canonical_publication`: writer has appended media but `finishWriting` has not run | M03, Pending |
| Exit during transcript merge | Same P. test after canonical atomic publication but before its checkpoint; P. atomic-write test covers interrupted temporary write/flush/rename boundaries | M03, Pending |
| Lose storage-root access | P.`test_read_only_root_preserves_source_until_access_is_restored`; `StorageRepositoryTests.testStaleBookmarkRefreshesSameRootAndFailedScopeDoesNotRunOperation` | M05: TCC/bookmark/external-volume revocation, Pending |
| Disk full / file-write failure | `AudioRecorderContractAndFaultTests.testConverterCreationConversionReadinessSampleAppendAndDiskFullFaultsShareTerminalPolicy`; `AudioFinalizationTests.testMediaAndPersistenceFaultsPreserveFirstCauseAndOriginalBytes`; `TranscriptFinalizationTests.testEveryWriteBoundaryRetriesWithoutLosingCanonicalOrRecovery`; new closed-window failure test | M06: bounded disposable volume exhaustion, Pending |
| No microphone signal | `MicrophoneCaptureTests.testLevelMathThrottleNoInputAtFiveSecondsAndRecovery`; `testNoInputDoesNotStopCaptureAndRepeatedTicksDoNotSpam` | M07: physical input/no-input UI, Pending |
| Microphone disconnect | `MicrophoneCaptureTests.testDeviceDisconnectRouteChangeAndLateEventsAreTerminalOnce`; `testT24DeviceFailureWhilePausedClosesOnceAndRejectsResume` | M08: physical route disconnect, Pending |
| Delete SQLite and rebuild from files | P.`test_sqlite_and_markdown_rebuild_preserves_canonical_and_audio`: closed DB and sidecars removed, fresh store/scanner produces one row | No physical requirement for the deterministic file case |
| Delete derived Markdown and regenerate | Same P. test checks exact Markdown regeneration, preserved canonical/audio/journal and stable subsequent recovery | UI check covered by M04 |

Additional safety coverage:

- P.`test_normal_stop_preserves_full_timeline`: full 22.5-second timeline, AAC/mono/48 kHz, continuous packet timestamps, decoded first/last PCM with nonzero signal, three unchanged synthetic transcript IDs/texts and retained recovery MOV.
- P.`test_missing_and_corrupt_source_are_diagnosed_and_never_deleted`: actual removed/truncated source, visible recovery reason, no false ready result, retained session/journal/damaged bytes on repeated runs.
- P.`test_sigkill_atomic_write_retains_whole_old_or_new_document`: before write, before flush, before rename and after rename; destination is valid complete old/new JSON after real process death.
- `StorageRepositoryTests.testT26PostRenameFaultKeepsWholePublishedDocumentAndRetryIsIdempotent`: typed post-commit error, whole new destination and clean retry.
- `ModelRepositoryTests.testKnownAnswerChunkedHashesAndStablePackageDigest`, `testMissingLengthHashAndFormatFaultsRejectDestinationBytes`, `testInjectedFailuresRetainFirstCauseAndPermitRetry`: actual hash mismatches and verification failure seams. `AudioFinalizationTests.testReviewTerminalAudioRequiresMediaAndSourceMatchNotAtomNames` checks media/source provenance rather than trusting container names.
- Repeat recovery compares canonical JSON, audio, journal, checkpoint, TXT and Markdown hashes and transcript IDs/order/text. Interrupted-to-settled revalidation may add its distinct audit episode once; event IDs and `(kind, code)` must remain unique. After that first revalidation, **all session file hashes, including the event log**, must be identical on subsequent fresh-process runs. This preserves the existing diagnostic policy instead of hiding event changes.

## Measurements and local validation

Evidence directory: `/private/tmp/stt-t26-validation`; no generated media, result JSON, logs, model weights or DBs are committed.

The first harness run exposed fixture/reporting issues: the reporting helper used a write-requiring read API on a read-only root, an export counter boundary was not reached, Foundation's `/tmp` path alias needed canonicalization, and interruption-to-settled audit episodes needed separate duplicate/content checks. These were corrected in the harness. They were not treated as product failures or passing evidence. A compile attempt also caught an Int/Int64 mismatch. `process-second.json` then passed all **8 process tests**, including all subcases; `Focused.xcresult` passed **80 XCTest**, zero failures.

Initial measured process results (48 kHz generated input):

| Case | Accepted seconds | Recovered seconds | Loss seconds |
| --- | ---: | ---: | ---: |
| Normal Stop | 22.500 | 22.500 | 0.000 |
| SIGKILL recording | 14.700 | 11.006 | 3.694 |
| SIGKILL recording | 22.500 | 21.033 | 1.467 |
| SIGKILL paused | 22.500 | 21.033 | 1.467 |

These observed losses meet the 10-second target for the synthetic fixtures. They do not establish the unperformed G1 hardware/power-loss checks.

Final local candidate validation:

- `Full.xcresult`: Debug build and **624 XCTest (602 unit + 22 integration), zero failures/skips**. Counts were read from the xcresult summary and target logs.
- `Repeated.xcresult`: three new XCTest methods x 20 iterations = **60 successful executions**.
- `process-final-1.json` through `process-final-3.json`: all eight process tests passed three times (**24 test-method executions, 51 actual SIGKILL subcases**), zero errors/failures/skips. All three runs reproduced the durations above. Every successful recovery was reopened three additional times to check content and audit stability.
- `swift-final.log`, `python-t16.log`: SwiftPM build and all four existing Python benchmark tests passed. No new unhandled-file warning remains.
- `release.log`, `product-engine.log`: Release build and native-engine/bundle/catalog verification passed.
- The documented 25 exact test references were checked against saved source. `git diff --check` passed. Existing unrelated compiler/QoS warnings remain; none are newly introduced by T26.

A read-only final-diff pass checked process ownership, actual signal termination, fixture isolation, post-commit error semantics, real checkpoint acknowledgment, no source overwrite, canonical/id/event uniqueness and CI failure propagation. No remaining blocker was found in the candidate scope. Exact task SHA and task CI are reported after push; no future CI success or official integration is asserted here. `PROJECT_STATUS.md`, the plan checklist, dev/main and the two pre-existing untracked prompt files remain unchanged.

## Reproduction commands

Use a fresh result directory outside Git. The exact local invocation used `/private/tmp/stt-t15-validation.Uth8xp/DerivedData` and `/private/tmp/stt-t15-validation.Uth8xp/CLI` for existing build caches.

```sh
validation_dir="$(mktemp -d /private/tmp/stt-t26.XXXXXX)"
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
python3 -B tools/t26/test_recovery_process.py \
  --probe /private/tmp/stt-t15-validation.Uth8xp/CLI/debug/stt-benchmark \
  --results "$validation_dir/process.json"
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath "$validation_dir/Full.xcresult" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
python3 -B -m unittest discover -s tools/t16
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build
python3 -B tools/verify_product_engine.py /private/tmp/stt-t15-validation.Uth8xp/DerivedData/Build/Products/Release/LocalLectureSTT.app
```

Focused XCTest selects `StorageRepositoryTests`, `TranscriptFinalizationTests`, `AppLifecycleTests`. Repetition selects the three new `testT26*` XCTest methods with `-test-iterations 20`. Process repetition runs the complete eight-method Python suite three times with separate result JSON files. CI runs the process suite after the existing developer-benchmark build, prints measurements and fails on any nonzero child/test result. Tests are not silently skipped if the probe is missing.

## Manual procedures — all Pending, G1 Unverified

Use a signed app, a disposable session root and an installed model. Never corrupt the sole copy of a lecture or model. Record OS/app/engine versions, input duration, recovered duration, error text and before/after file hashes. G1 is not promoted by writing these procedures.

1. **M01 physical force quit:** feed known timed synthetic speech/tone from a speaker into the intended microphone. Record 30–60 seconds, force-quit the GUI during recording and while paused in separate disposable sessions, then relaunch. Expect interrupted capture, no automatic microphone restart, recovery completion where possible, preserved original artifacts and measured tail loss ≤10 seconds. Repeat recovery twice and compare original/canonical hashes and transcript IDs. If the measurement exceeds the target, record failure; do not trim or replace the source to make it pass.
2. **M02 lid:** repeat while closing the lid during recording. Reopen/wake. Expect interruption, retained audio, no capture restart, and resumed eligible finalization. Separately let only the display turn off; recording should continue while automatic idle system sleep is prevented. This does not promise lid-closed execution.
3. **M03 GUI crash windows:** run the automated acknowledged-boundary suite first. For GUI/process lifecycle validation, force-quit once while exporting and once while showing transcript finalization, then reopen; inspect the persisted prefix and recovered data. Exact checkpoint placement is established by the automated helper, not inferred from a status label. Power-loss behavior requires a separately controlled hardware experiment and remains unverified.
4. **M04 window/exit:** close the last window while a disposable session is finalizing. Verify one automatic app exit only after audio/transcript/catalog settlement; reopen during finalization and verify automatic exit is cancelled. Reopen the completed session and play the start/end, then remove only its derived Markdown and confirm regeneration. For the failure case, create a directory named `transcript.md` in a fresh disposable session folder before Stop; this blocks derived publication without modifying the audio. The app must stay available with recovery guidance; explicit quit may wait only for essential saving. Remove only that empty fixture directory before retry.
5. **M05 access:** revoke a disposable external root/bookmark or unmount its volume during recording/finalization. Expect visible access/reauthorization guidance and no deletion. Restore/reselect the same root and retry; verify other roots and original files are unchanged. POSIX chmod tests do not replace Sandbox/TCC testing.
6. **M06 disk:** use a small disposable test volume with a fixed capacity, never fill the host/home volume. Exhaust that test volume during writer/finalization/derived output separately; verify typed errors, retained original audio, no false completion and successful retry after freeing test-only space. Record whether the fault occurred before or after atomic publication.
7. **M07 no input:** record with an available but silent microphone. Verify the meter/no-input warning after its grace period, continued recording and warning recovery when sound returns. A silent input is not a device disconnect.
8. **M08 route loss:** if a removable microphone is available, disconnect it during recording and while paused. Verify the implemented interruption/error policy, preserved audio and UI guidance. This does not add automatic route fallback or declare optional hardware tested when unavailable.

T26's automated candidate can be reviewed independently of these manual results. T27/G4 and production reliability claims must retain the pending evidence boundaries.

## Independent review and authorized dev integration

On 2026-11-26 a separate read-only pass reviewed `eaca579be95cbc1da35d748a6bea3438765fb7d0` against T26, MVP_SPEC 14/17.6, the complete diff and the actual writer/finalizer/checkpoint call sites. It confirmed that checkpoints are acknowledged after durable publication, SIGKILL precedes recorder finish at active recording boundaries, recovery runs in new processes, and the GUI target excludes the developer probe. The hook defaults preserve product behavior. No blocking finding or product-spec deviation remained in this scope.

The reviewer rebuilt the SwiftPM probe and independently reran **80 focused XCTest** (AppLifecycleTests, StorageRepositoryTests, TranscriptFinalizationTests) and **8 process tests / 17 SIGKILL subcases**, with zero failures/skips. Evidence is in `/private/tmp/stt-t26-independent-review` (`Focused.xcresult`, `focused-summary.json`, `swift.log`, `process.json`, `process.log`); the commands above were used with the three `-only-testing:LocalLectureSTTTests/<class>` selectors. Normal 22.5 seconds recovered as 22.5 seconds; observed crash losses were 3.694 and 1.467 seconds. An initial sandboxed xcresult summary read could not write Xcode's report cache; rerunning that read with cache access succeeded without rerunning or altering the tests.

[Exact-source CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45650508753) was independently rechecked: success at the same `eaca579` SHA, including 624 XCTest, CLI/Python/process checks and Release verification. CI's normal AAC duration was 22.456 seconds for 22.5 seconds of input, within the existing 80 ms presentation tolerance; its largest observed crash loss was 3.759 seconds. These are bounded synthetic observations, not proof of zero physical capture loss or a universal crash bound. M01–M08 and G1 stay unverified.

Latest `dev` was re-fetched and remained `e04b5c2673b58a75735dc616a0edabf76a940b3e`. The authorized squash integration preserves the reviewed source/test/build/CI files; only scope authorization, status/checklist and review evidence change. The committed dev SHA must pass the full Debug XCTest, SwiftPM build, four benchmark Python tests, eight process tests and Release product-engine verification, then its own exact-commit CI, before local/remote task-branch cleanup. Actual resulting SHA, results and cleanup are recorded in the delivery handoff without self-referential commit amendments. Main stays at `38e126f`; T27 is next but not implemented or authorized by this integration.
