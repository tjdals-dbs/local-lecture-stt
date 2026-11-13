# T11 acceptance and design

The Phase 1 candidate was independently reviewed and separately authorized for Phase 2 dev integration on 2026-11-13. See [Phase 2 integration](#phase-2-integration) for the current authority and validation policy. Earlier submission restrictions and results below are historical Phase 1 records. G1 remains Unverified.

## Lifecycle design (before implementation)

| Operation | Allowed state → result | Invalid/duplicate policy |
| --- | --- | --- |
| construct | unloaded, no work | no I/O, tasks or app composition |
| load | unloaded/ready → loading → ready | busy during session or cleanup; failed/cancelled load → unloaded; retry allowed |
| start | ready → starting → running | exact loaded model required; duplicate/concurrent start rejected; failure → ready |
| submit | running → bounded FIFO | before load/start, mismatched configuration/identity, invalid capability or full capacity throws before admission |
| end | running → draining → ready after accepted FIFO settles | repeated end joins same settlement; no session → invalidLifecycle |
| cancel session | running/draining → cancelling → ready | repeated cancel joins; pending/active requests get exactly one terminal; no session → invalidLifecycle |
| unload | any settled state or active operation → unloading → unloaded | repeats join; unloaded is explicitly idempotent; cancellation of its caller does not release ownership early |
| request cancel/consumer withdrawal | queued → terminal now; active → cleanup → terminal | terminal request cancellation is explicitly idempotent; unrelated requests preserved |
| retry | only after owned cleanup settles | admission stays closed throughout cleanup |

The fake uses an explicitly advanced logical clock and a single serial FIFO worker state machine, rather than background timers. `advance` is the acknowledgment: all due transitions (equal deadlines in script order, then next FIFO request) are processed before it returns. Delays are relative to processing start, not enqueue time. Control preparation and cleanup use the same logical driver. Pending capacity excludes the one active request. Output is a bounded single-consumer mailbox holding at most two newest events; after termination these are the latest partial (if any) and the retained terminal. Consumer cancellation withdraws and cancels only that request. Terminal failures are value events, while admission/control failures throw `STTEngineError`.

Explicit internal generation plus request ownership is checked at every callback and control settlement; injected stale callbacks use the same publication path as scripted success/failure. No new model/session starts until old cleanup is acknowledged. Configuration pins engine version, model revision/checksum, language and options. Segment bounds use session-relative milliseconds within the request extent; input duration rounds frame-count/sample-rate to nearest millisecond.

## Execution and assertion matrix

The C/F registry records the original candidate tests. The re-review adds R1–R6; the latest FIFO callback repair adds Q1–Q4 and supersedes prior final-run evidence. All original selectors are rechecked. No Task completion or gate result is changed.

| ID | Tests / fixture or barrier | Exact observable assertions |
| --- | --- | --- |
| T11-01 | C2; F9/F13; `STTTestFixture.ready` through `any STTEngine`; source-boundary audit | Generic `Codable & Sendable & Equatable` round-trips format/audio/options/model/session/context/request/hypothesis/response/error/IDs; every terminal variant, engine version `1.0`, revision `r1`, checksum `sha256-r1` retained. New Domain imports only Foundation; no framework/vendor objects in payloads. |
| T11-02 | C1/C3/C4/C5; F14; R2/R3/R4; synthetic JSON mutations and finite-clock boundary | NaN/Infinity with a configured nonconforming decoder, nonpositive rates, bad channel/sample/frame counts, Int.max multiplication, 30-second-plus-one-frame input, duration mismatch, negative/reversed bounds, start+duration Int64 overflow, empty config/provenance, bad response revision and out-of-range segments all throw. Malformed decoding and rejected callbacks leave the active snapshot and output unchanged. Clock overflow/admission rejection also preserves model/session, active work, script and sequence; accepted cleanup settles at the Int64 boundary. |
| T11-03 | F2/F7/F17; R1/R5/R6; explicit Korean/English codes | Unsupported format, mode, engine and output options reject before admission; active snapshot stays equal. Automatic partial starts with nil language, detects `ko`, retains it on the next request, rejects a later `en` switch. Text `한국어와 English` / `한국어 Swift concurrency` is preserved exactly. Disabled partials produce no partial/error, retain language detection and deliver final revision 1; hidden unsupported language still fails once. Unsupported language capability cannot pin the session. |
| T11-04 | F4/F5/F8/F9/F12/F13/F19; R2/R4 | Before-load infer/start and invalid duplicate settled end/cancel reject; concurrent preparation/second start are busy. Failed load settles unloaded; failed start settles ready; three cycles on one instance retain expected output. End/cancel/unload settle with no active sequence, pending requests, session or owned continuations. Unloaded unload is explicitly tested twice. |
| T11-05 | F15/F19 | Changed ID, revision, checksum, engine version, temperature options or language cannot replace the running session; every observed session stays equal to the original. Load/start remain busy in cleanup. After end, an explicit r2 load/new session produces r2 provenance. |
| T11-06 | C5/F14/F17; R1 | At logical 10/20/30 ms output is revision 1 partial `한국`, 2 partial `한국어 Swift`, 3 final; segment bounds are 5000–5010 ms. Stale/jumped revisions and callbacks after final return false; next() then returns nil, publication count is three, terminal count one. |
| T11-07 | F8/F17/F18; R1/R2/R3 | Preparation is still held at 9/10 ms; inference observation is nil at 9/10 or 4/5 ms and due afterward. Two identical explicit-ID scripts/advances produce equal response arrays. Equal-deadline partial/final remain revisions [1,2] in script order. No success assertions use sleeps, yield loops or polling. |
| T11-08 | F3/F12; R3; Q1–Q4; pending capacities 1 and 2 | Full backlog rejects only new work; queued cancellation frees capacity without consuming rejected script/sequence. Previously omitted early final/failed callbacks now promote the pending head before another admission: A → B → C, never A → C → B. B/C delays start at activation; equal-deadline snapshots remain ordered. Waiting/duplicate end drains the existing FIFO and leaves zero workers/continuations without an extra admission or zero-time advance. See Q1–Q4 for exact assertions. |
| T11-09 | F1/F4/F5/F6/F10/F12/F19; R2/R5; cleanup/phase/waiter barriers | Queued cancellation is immediate; active withdrawal remains unterminated at cleanup 9/10 ms, then terminates once and unrelated queued output continues. Consumer task cancellation withdraws only its request, and a second consumer throws. Load/start caller cancellation and cancelled unload caller retain ownership until cleanup acknowledgment. Duplicate active end/cancel/unload join; four owned settlement waiters are acknowledged before cleanup advances. Four cancellation-before/after-final/failure schedules each yield exactly one expected terminal and typed cause. |
| T11-10 | F16/F20; captured callback lease injected after settled cancel/unload and new start | The old final callback returns false, before/after newer snapshot stays equal, fresh feed is still empty until due, then emits only new output with new r2/session provenance. Reusing every serialized identity still rejects the old generation. Repeated stale injection cannot add a terminal or clear current ownership. Cleanup deadlines are owned fields removed before new admission; no independent delayed cleanup task exists. |
| T11-11 | F11/F5; R1/R5 | An eager completed request delivers final to its first late subscriber. Two hundred unconsumed partials plus failure retain exactly the newest partial and the first inferenceFailed terminal (revision 201); later withdrawal cannot replace that cause. Already-selected loadFailed survives unload/cancellation. All streams and awaited cancellation/control tasks return. |
| T11-12 | Full existing/new suites; source/diff/hash audit below | Latest FIFO-repaired local suite: 289 unit + 10 integration Passed Test Case nodes, zero failed/unexpected/skipped; evidence is below. App/Features contain no fake/engine composition; existing capture/recorder/recovery/lifecycle sources and persisted schemas are unchanged. No new dependency or runtime data is staged. G1 decision file hashes stay byte-identical and T11 remains unchecked. Exact final-commit CI is a separate submission check reported in the handoff, not preclaimed here. |

### Exact test registry

| Reference | Test selector | Full result |
| --- | --- | --- |
| C1 | `STTEngineTests/testConfiguredNonfiniteDecodingStillUsesValidatedInitializers()` | Passed |
| C2 | `STTEngineTests/testEveryBoundaryPayloadIsCodableSendableEquatableAndPreservesProvenance()` | Passed |
| C3 | `STTEngineTests/testInvalidAudioTimeOverflowAndMalformedDecodedAudioAreRejected()` | Passed |
| C4 | `STTEngineTests/testInvalidConfigurationAndMalformedDecodedValuesAreRejected()` | Passed |
| C5 | `STTEngineTests/testInvalidResponseBoundsRevisionOrderAndDecodedResponsesAreRejected()` | Passed |
| F1 | `FakeSTTEngineTests/testActiveWithdrawalWaitsForCleanupThenOtherQueuedRequestContinues()` | Passed |
| F2 | `FakeSTTEngineTests/testAutomaticLanguageInitiallyUnknownThenPinnedAcrossRequestsAndMixedTextPreserved()` | Passed |
| F3 | `FakeSTTEngineTests/testBoundedFIFOExcludesActiveRejectsOnlyNewAndQueuedCancellationFreesSlot()` | Passed |
| F4 | `FakeSTTEngineTests/testCallerCancellationDuringLoadAndCleanupKeepsAdmissionClosedUntilSettlement()` | Passed |
| F5 | `FakeSTTEngineTests/testCancellationDuringStartRetriesAndFirstPreparationFailureSurvivesUnload()` | Passed |
| F6 | `FakeSTTEngineTests/testCancellationVersusFinalAndFailureKeepsExactlyOneTerminal()` | Passed |
| F7 | `FakeSTTEngineTests/testCapabilitiesRejectUnsupportedFormatLanguageOptionsAndEngineWithoutStateMutation()` | Passed |
| F8 | `FakeSTTEngineTests/testConcurrentStartAndLoadRejectWhilePreparationIsHeld()` | Passed |
| F9 | `FakeSTTEngineTests/testConstructionAndProtocolLifecycleRejectUnpreparedAndDuplicateOperations()` | Passed |
| F10 | `FakeSTTEngineTests/testConsumerTaskCancellationWithdrawsOnlyItsRequestAndSingleConsumerIsEnforced()` | Passed |
| F11 | `FakeSTTEngineTests/testEagerLateSubscriberAndBoundedPartialRetentionPreserveFirstFailure()` | Passed |
| F12 | `FakeSTTEngineTests/testEndDrainsHeldWorkRejectsAdmissionsAndDuplicateEndJoins()` | Passed |
| F13 | `FakeSTTEngineTests/testFailedLoadAndStartRetryOnSameInstanceAndRepeatedCycles()` | Passed |
| F14 | `FakeSTTEngineTests/testMalformedInputAndInvalidCallbackCannotChangeActiveWorkOrConsumeCapacity()` | Passed |
| F15 | `FakeSTTEngineTests/testModelPinningRejectsIDRevisionChecksumEngineOptionsAndLanguageMutation()` | Passed |
| F16 | `FakeSTTEngineTests/testOldGenerationIsRejectedEvenWhenAllSerializedIdentitiesAreReused()` | Passed |
| F17 | `FakeSTTEngineTests/testPartialsReplaceInOrderFinalOnceAndRejectLateOrReversedCallbacks()` | Passed |
| F18 | `FakeSTTEngineTests/testSameScriptIDsAndClockAdvancesProduceEqualEventsIncludingEqualDeadlines()` | Passed |
| F19 | `FakeSTTEngineTests/testSessionCancellationAndUnloadJoinCleanupBeforeNewAdmission()` | Passed |
| F20 | `FakeSTTEngineTests/testStaleCompletionAfterCancellationAndNewModelCannotPublishOrClearNewOwnership()` | Passed |

## Original candidate local execution evidence

Directory: `/private/tmp/stt-t11-validation.qboXGv` (Xcode reports its `/tmp` alias). Logs and xcresult bundles are intentionally outside Git.

| Run | Result and actual executions |
| --- | --- |
| Baseline | First sandbox attempt could not contact testmanagerd; it is not a passing result. Permitted `BaselinePermitted.xcresult`: 264 passed (254 unit + 10 integration), zero failed/skipped. Executed before source changes. |
| Focused1 | Interrupted after a test omitted advancing its final cleanup delay. No pass claim; the test was corrected and a five-second failure watchdog/teardown release was added. |
| Focused2 | 22 executed, 21 passed / 1 failed: 30 seconds plus one frame was accepted through millisecond rounding. Production now checks the actual frame extent before rounding. |
| Focused3 | 25 passed (5 contract + 20 fake), zero failed/unexpected/skipped. Includes nonfinite custom-decoder, malformed-active-state and reused-identity generation regressions. |
| Full (before final test-only strengthening) | Unsigned arm64 Debug **build succeeded**, **289 passed: 279 unit + 10 integration**, zero failed/unexpected/skipped. Both bundles and all 25 new selectors structurally counted in `FullTests.json`; all nodes Passed. |
| Focused4 | Final test tree: 25 passed, zero failed/unexpected/skipped. Adds acknowledged duplicate unload joining to F19 and fixes test indentation; no production behavior changed after Full. |
| Full2 (final) | Final unsigned arm64 Debug build succeeded; **289 passed (279 unit + 10 integration), zero failed/unexpected/skipped**. Unique Passed Test Case nodes counted in `Full2Tests.json`; executable source/project hashes captured at launch and rechecked unchanged before commit. |

Exact baseline/full invocation (only result/log filename differs):

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t11-validation.qboXGv/DerivedData \
  -resultBundlePath /private/tmp/stt-t11-validation.qboXGv/Full2.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
```

Focused3/Focused4 use the same project/scheme/configuration/destination/DerivedData with `-resultBundlePath .../Focused3.xcresult` or `.../Focused4.xcresult`, `-only-testing:LocalLectureSTTTests/STTEngineTests`, `-only-testing:LocalLectureSTTTests/FakeSTTEngineTests`, allowance `30`, and action `test`. Each focused suite was run once at that executable revision; no repetition count is implied.

Results inspected with both `xcrun xcresulttool get test-results summary --path <bundle> --compact` and `xcrun xcresulttool get test-results tests --path <bundle> --compact`. The latter produced `FullTests.json`/`Full2Tests.json` and their unique Test Case nodes established both-target counts. Xcode/xcresult commands required the permitted normal macOS path because sandbox testmanagerd/cache access failed. No tests were skipped or disabled.

No new STT-attributable compiler warning was emitted. Incremental full build retains Xcode's existing AppIntents metadata-extraction diagnostic. The earlier test-module rebuild also emitted pre-existing AudioFinalizationTests/AppLifecycleTests warnings; those sources were preserved.

## Scope and preservation audit

- Starting dev/origin/dev: `73b4a7adaa16a2ff97ff8affda04fe3b99573b0c`; main/origin/main: `38e126f92ac823d29306ea8c1f7703f7060a5818`.
- `PROJECT_STATUS.md` SHA-256: `2c3af0f2225bad58ad99c9d11986fde8db2365ae5871181ec481d31d4ee1fb35`.
- `IMPLEMENTATION_PLAN.md` SHA-256: `7bd6c99b69a31056e445b56ce1d3648966dba971ca55873d7a788d675ffb04fd`.
- These coordinator planning files are carried unchanged. T11 is unchecked. G1 stays Unverified; no official completion, integration, main promotion, tag or branch deletion is authorized.
- `prompts/T09_FRESH_SESSION_DIAGNOSIS.md` and `prompts/T10_REVIEW_REPAIR.md` remain unchanged/untracked/unstaged; SHA-256 checked against the captured files. This T11 prompt is included as authorized.
- Source audit: `rg -n 'FakeSTTEngine|STTEventFeed|STTEngine' LocalLectureSTT/App LocalLectureSTT/Features` returns no matches. New engine source imports only Foundation; Domain payloads have no URL/Date/framework/closure/task/stream fields. Stream and cancellation closures occur only in Application control handles.
- No audio files, runtime DBs, model weights, real transcripts, user storage, dependencies or production capture changes are introduced. No physical microphone/lid/long-recording validation is claimed. No actual STT/model integration is implemented.
- Design choice within the authorized scope: an explicit manual-clock FIFO worker state machine provides scheduler acknowledgments without a background timer/task. There is no general simulator or live backlog controller. No specification deviation is identified.

Final-commit SHA, push and exact-head CI run/job status belong in the Phase 1 handoff after submission. A green local suite alone does not mark T11 officially complete or authorize the next Task.


## Re-review and same-Task repair

The user requested a fresh review against the original T11 prompt and T11-01–12, with same-branch repairs and no official completion/integration. Review source: `a80df2ed56e37cfdcc125cd9599bb0febf47a6eb`, branch `task/t11-stt-engine-contract`. `dev`/`main` and the coordinator planning file hashes above remain unchanged.

### Findings, repairs and new assertions

1. **Disabled partials lost a successful final (T11-03/06/11).** On the original worker, a scripted partial under `options.partialResults == false` failed response construction, emitted `invalidResponse`, and terminated the request before its valid final. The repaired same worker processes each deadline and language detection but omits partial publication; the final retains provenance/language and revision 1. Hidden invalid language still follows the existing first typed failure/terminal path.
2. **Accepted work could become unadvanceable near the clock limit (T11-02/07/09).** The old `advance` accepted the last safe-headroom time, then rejected every positive advance although accepted inference/cleanup was due later. The clock now advances through Int64.max and rejects only negative/overflowing advances. New preparation/inference checks its whole FIFO plus cleanup time budget before consuming a script/sequence/generation. Nonthrowing cleanup saturates at the last tick and teardown advances only the representable remainder.
3. **Existing capture regression test observed a transient snapshot (T11-12 verification).** The initial repaired full run failed only `MicrophoneCaptureTests/testDeviceDisconnectRouteChangeAndLateEventsAreTerminalOnce`. Unmodified repetition confirmed 19 Passed / 1 Failed out of 20. Its loop stopped as soon as `.running` changed, including `.stopping`, then stored that lifecycle before awaiting stream completion. Production correctly finishes the terminal stream before awaiting driver cleanup. The test now derives the single terminal code from the stream, uses its existing bounded lifecycle helper to wait for exactly `.failed(code)`, and reads a fresh lifecycle. All prior device/error/one-stop/late-event assertions remain; terminal count is strengthened to exactly one. Capture production code is byte-identical. This legacy helper uses bounded yield polling; T11 fake timing remains entirely clock/barrier-driven.

| Reference | Exact test selector | New observable proof |
| --- | --- | --- |
| R1 | `FakeSTTEngineTests/testDisabledPartialsStillDetectLanguageAndDeliverTheFinalSnapshot()` | No output at 5 or 9 ms with partials disabled; at 10 ms exactly one final, revision 1, original Korean/English text, detected ko and exact session provenance; settled end. |
| R2 | `FakeSTTEngineTests/testLogicalClockNearInt64LimitStillSettlesCancellationAndUnload()` | At max−120000, accepted work advances beyond the former ceiling; cancellation stays unterminated one tick before cleanup, settles once, unload joins at max; overflowing advance rejects without state mutation. |
| R3 | `FakeSTTEngineTests/testClockBudgetRejectionPreservesActiveRequestSequenceAndScript()` | Insufficient FIFO budget rejects without active snapshot/output changes. Early acknowledged completion frees budget, then the rejected sequence retries and receives its original second script exactly at the 60 ms deadline. |
| R4 | `FakeSTTEngineTests/testClockBudgetRejectsLoadAndStartBeforeMutatingPreparation()` | Insufficient preparation+cleanup budget leaves unloaded/ready snapshots exactly equal; no model/session/preparation is admitted. |
| R5 | `FakeSTTEngineTests/testDisabledPartialsStillValidateLanguageAndPreserveTheFirstFailure()` | Hidden fr/incorrect en in Korean mode emits exactly one invalidResponse failure; later withdrawal/advance cannot replace it or publish the scripted final. |
| R6 | `FakeSTTEngineTests/testUnsupportedLanguageCapabilityDoesNotPinTheSessionOrChangePreparation()` | An English-only capability rejects Korean start without state change, rejects unsupported automatic ko output, then accepts supported en output on the same session, preserving text. |

T11 watchdog teardown now also joins the cancelled watchdog task before releasing its scenario. No real inference, dependency, file/network/microphone activity, capture behavior, persisted schema or app composition is added.

### Re-review execution evidence

Run directory: `/private/tmp/stt-t11-review.v1yw8W`; logs/xcresults remain outside Git.

| Run | Actual result |
| --- | --- |
| `Diagnostics.xcresult` | Before production repair: both new regression tests failed (0 passed / 2 failed / 0 skipped), reproducing the two T11 defects. |
| `RepairFocused1.xcresult` | After production repair: 27 passed / 0 failed / 0 skipped. |
| `RepairFocused2.xcresult` | Final T11 selectors: 31 passed (5 contract + 26 fake), 0 failed/unexpected/skipped. Includes all six new regression/coverage tests and all original selectors. |
| `RepairFull.xcresult` | Build succeeded; 294 passed / 1 failed / 0 skipped out of 295. Only the existing capture snapshot test failed; all 31 T11 tests passed. This is not a passing full-suite result. |
| `CaptureDiagnostic.xcresult` | Unmodified capture test: one Test Case with 20 Repetition nodes, 19 Passed / 1 Failed. |
| `CaptureRepair.xcresult` | Corrected capture test: 20 Passed Repetition nodes / 0 Failed; summary's one unique test is not misreported as 20 different tests. |
| `RepairFull2.xcresult` | Final unsigned arm64 Debug build succeeded; **295 passed (285 unit + 10 integration), zero failed/unexpected/skipped**. Both targets, all 31 T11 selectors and the corrected capture case have Passed Test Case nodes in `RepairFull2Tests.json`. |

Exact commands use the project/scheme/configuration/destination/unsigned settings in the original command above, with this new directory for DerivedData and results. Focused actions use `test`, allowance 30 and the two suite selectors; the diagnostic action uses only R1/R2. Capture actions use `-only-testing:LocalLectureSTTTests/MicrophoneCaptureTests/testDeviceDisconnectRouteChangeAndLateEventsAreTerminalOnce -test-iterations 20`, allowance 30. Full uses `build test`, allowance 60. Summaries and Test Case/Repetition nodes are extracted using both xcresulttool commands shown above. Exact final full command:

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t11-review.v1yw8W/DerivedData \
  -resultBundlePath /private/tmp/stt-t11-review.v1yw8W/RepairFull2.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path /private/tmp/stt-t11-review.v1yw8W/RepairFull2.xcresult --compact
xcrun xcresulttool get test-results tests --path /private/tmp/stt-t11-review.v1yw8W/RepairFull2.xcresult --compact
```

The final executable/project hashes (including the test-only capture correction) were captured before launch and verified unchanged afterward and before commit. Only the existing Xcode AppIntents metadata-extraction warning appears in the incremental final build; no new attributable compiler warning is observed. All T11-01–11 local assertions and T11-12's local/full-suite/scope checks pass; exact final-commit task CI is checked after commit/push and reported in the handoff. The original 289-test run and earlier CI do not substitute for this candidate's verification.

No official T11 completion, checklist change, G1 pass, dev/main integration, tag or branch deletion is authorized by this repair. Independent post-review approval and next-Task readiness remain the coordinator's decision.

## FIFO callback repair

Reviewed source: `b1b4158b0fd283886156e08ce498320aa2c51fd6`. Its green 295-test suite missed a supported early-terminal callback while another request was queued. `deliver` cleared active ownership without promoting pending work or settling end; a subsequent admission became active ahead of the pending head. The supplied permanent regression reproduced A → C → B, with all five order/output assertions failing. Thus the earlier T11-08 evidence was incomplete.

The narrow repair makes all admissions append to the FIFO and reserves activation/origin assignment for `drive`. Accepted external callbacks run that driver before returning. Scripted responses use the same private ownership/revision/language-checked `accept` publication path without recursively invoking the driver. Cancellation and settlement retain their existing driver paths. Rejected callbacks leave state untouched. No scheduling framework, adapter, live coordinator or production capture change is added.

| Reference | Exact `FakeSTTEngineTests/` selector | Actual assertions |
| --- | --- | --- |
| Q1 | `testIndependentEarlyCallbackCannotLetNewAdmissionOvertakeQueuedWork()` | Supplied patch retained unchanged: early A final at time 0; after admitting C, active=1/queue=[2]; B final/text at 10 ms while C is empty; end settles after 20 ms. No inserted zero-time advance. |
| Q2 | `testEarlyFailedCallbackPreservesFIFOOriginsCapacityAndTerminalOwnership()` | Capacity 1 rejects C while B is queued; early A failure at 7 ms immediately promotes B before retrying C with its original script/sequence. B absent at 16/final at 17 ms; C absent at 26/final at 27 ms with matching identities/text. Repeated failure/late partial rejected with equal before/after snapshots. Advancing past A's old deadline leaves one event/terminal per feed and preserves inferenceFailed. |
| Q3 | `testEarlyTerminalCallbackSettlesWaitingEndWithAndWithoutPendingFIFO()` | Four scenarios: final/failed × empty/two-request pending FIFO. Two end waiters acknowledged before callback. Empty FIFO settles ready with zero continuations immediately; pending FIFO stays draining with B active/C queued, B/C finish at 10/20 ms in order. Both end tasks return; no active/queue/session/continuation remains. Repeated callback rejected and each feed collected with exactly one event/terminal. Five-second failure watchdog releases held work; success uses barriers/clock only. |
| Q4 | `testEarlyCallbackPumpsEqualDeadlineSnapshotsAndNextWorkerWithoutReentry()` | Early A final immediately processes B's zero-delay partial/final as revisions [1,2] with matching text, then leaves C active and uncompleted until its 10 ms deadline. Repeated A callback rejected; C still completes correctly; all three feeds have one terminal. Proves due-event progression cannot recursively double-process or clear the next worker. |

Run directory: `/private/tmp/stt-t11-fifo.U1v5wi`; logs/results stay outside Git.

| Result bundle | Actual execution |
| --- | --- |
| `Reproduce.xcresult` | Initial sandbox attempt failed testmanagerd lookup (error 159); environment failure, no pass claim. |
| `ReproduceAllowed.xcresult` | Before production repair, exact Q1 selector: 1 executed, 0 passed / 1 failed / 0 skipped; five FIFO assertions failed. |
| `Focused.xcresult` | After repair, 35 passed (5 contract + 30 fake), zero failed/expected-failure/skipped. All original clock-budget, backlog/cancel/end/unload, disabled-partial/language and stale-generation selectors plus Q1–Q4 executed once. |
| `Full.xcresult` | Fresh DerivedData unsigned arm64 Debug build/test succeeded: **299 passed (289 unit + 10 integration), zero failed/expected-failure/skipped**. Both target counts and Q1–Q4 Passed Test Case nodes verified in `FullTests.json`; all 35 T11 tests executed. |

Exact commands (logs redirected to `reproduce-allowed.log`, `focused.log`, `full.log` respectively):

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t11-fifo.U1v5wi/DerivedData \
  -resultBundlePath /private/tmp/stt-t11-fifo.U1v5wi/ReproduceAllowed.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -only-testing:LocalLectureSTTTests/FakeSTTEngineTests/testIndependentEarlyCallbackCannotLetNewAdmissionOvertakeQueuedWork \
  CODE_SIGNING_ALLOWED=NO build test
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t11-fifo.U1v5wi/DerivedData \
  -resultBundlePath /private/tmp/stt-t11-fifo.U1v5wi/Focused.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -only-testing:LocalLectureSTTTests/STTEngineTests \
  -only-testing:LocalLectureSTTTests/FakeSTTEngineTests \
  CODE_SIGNING_ALLOWED=NO build test
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t11-fifo.U1v5wi/FullDerivedData \
  -resultBundlePath /private/tmp/stt-t11-fifo.U1v5wi/Full.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path /private/tmp/stt-t11-fifo.U1v5wi/Full.xcresult --compact
xcrun xcresulttool get test-results tests --path /private/tmp/stt-t11-fifo.U1v5wi/Full.xcresult --compact
```

The same xcresulttool inspections were applied to the focused result and the reproduction summary. Xcode and xcresulttool ran through the permitted normal macOS path after sandbox runner/cache restrictions. No tests were skipped/disabled. Fresh compilation emitted existing warnings only in unchanged FileAudioFinalizer/AppLifecycleTests/AudioFinalizationTests and AppIntents metadata extraction; no new warning belongs to the changed fake/tests. Executable/project hashes were captured after full validation and rechecked before commit; subsequent changes are documentation/prompt/fixture only.

The complete task-branch and repair diffs are reviewed before submission. `git diff --cached --check` reports only the supplied patch's required blank context marker at fixture line 8; the fixture is preserved byte-for-byte. The check excluding that `.patch` passes. Coordinator planning hashes remain exactly as recorded above; T11 stays unchecked. Historical T09/T10 prompts retain SHA-256 `7352bbc778ec56dda12d55896e435a22908d95da500ffc6bd463068b996471e7` / `5cb69843facdc0a947ec894854fe558aef99318889a95830a7fde82de065f96f` and remain untracked/unstaged. Final repair commit/push and its exact-head CI are reported in the handoff. G1 remains Unverified; official completion, integration and next-Task readiness still require the coordinator's independent post-review decision.

## Phase 2 integration

- [Explicit authorization](../prompts/T11_DEV_INTEGRATION.md) approves source `ad9888e2b67b49c89f22759dccfa1b8ce83843e3` for a local squash onto the latest dev, status/T11-checklist updates, committed-dev validation, push/exact-head CI, then safe deletion of only its matching task branch. This supersedes the earlier Phase 1 integration/completion restrictions; it authorizes neither G1 passage, main promotion, a release tag nor T12 implementation.
- Starting local/origin dev remained `73b4a7adaa16a2ff97ff8affda04fe3b99573b0c`; task refs matched the approved source and main remained `38e126f92ac823d29306ea8c1f7703f7060a5818`. No latest-dev incorporation or integration-preparation SHA was needed. Executable/project/test files must remain byte-identical to the approved source; integration-only differences are completion/handoff documentation and the unchanged authorization prompt.
- Approved-source evidence: 299 passed (289 unit + 10 integration), zero failed/skipped, all 35 T11 tests and Q1–Q4 executed; [CI run 43349002465](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43349002465) has that exact source head and successful build/test steps. These do not establish the new squash commit's result.
- The new committed dev HEAD is validated with the command below. Actual committed-HEAD counts/result, final SHA, exact-dev CI URL/run/head/result and branch cleanup outcome are recorded in the Phase 2 final handoff after execution. At commit creation those post-commit checks remain required; do not amend solely to write the commit's own SHA/CI into this file.

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t11-integration.0PZz4D/DerivedData \
  -resultBundlePath /private/tmp/stt-t11-integration.0PZz4D/CommittedHead.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path /private/tmp/stt-t11-integration.0PZz4D/CommittedHead.xcresult --compact
xcrun xcresulttool get test-results tests --path /private/tmp/stt-t11-integration.0PZz4D/CommittedHead.xcresult --compact
```

Both test targets, all T11 selectors and Q1–Q4 must execute with zero failed/unexpected/skipped tests. Push is conditional on that result; branch cleanup is conditional on exact-head dev CI success and unchanged local/live task tips. Preserve the approved source SHA above and the unrelated T09/T10 prompts. G1 remains Unverified and T12 awaits a separate implementation session/prompt.
