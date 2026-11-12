# T10 fresh-session repair — four reproduced safety failures

## 1. Assignment and authority

Recommended session setting: **GPT-6 Astra / high**. This is the user's selected setting, not a request to switch models, increase effort, or spawn additional agents automatically.

Continue T10 Phase 1 in `/Users/andyoon/stt`. Repair the existing committed candidate, complete its original acceptance requirements, and deliver a genuinely review-ready task branch. The user explicitly authorizes a **fresh session for this same-Task repair**. Prior conversation history is not required.

Read in order:

1. This user assignment and `AGENTS.md`.
2. `PROJECT_STATUS.md`.
3. Only T10 in `IMPLEMENTATION_PLAN.md` and chapter 7 of `MVP_SPEC.md`.
4. `prompts/T10_APP_LIFECYCLE.md`, especially safety rules, acceptance A01–E03, and the Phase 1 boundary.
5. This repair prompt and `prompts/fixtures/T10_REVIEW_REGRESSIONS.patch`.
6. Current Git state, relevant implementation/tests, and `docs/T10_ACCEPTANCE.md`; consult relevant architecture/development sections as needed.

This prompt supersedes the **obsolete starting-state and work-order instructions** in `prompts/T10_REVIEW_REPAIR.md` and the original prompt's initial branch-creation procedure. Do not reread earlier conversation history or restart from `dev`. Original T10 product behavior and acceptance requirements remain in force. The old repair file is historical context, not another independent work package.

`PROJECT_STATUS.md` still describing T10 as unstarted is the expected official integration state: Phase 1 does not update it. That is not a document conflict or reason to stop.

Authorized: T10 implementation fixes, necessary narrow T07–T09 ownership/settlement seam changes, tests, accurate supporting docs, task-branch commit/push, and exact-head task CI.

Not authorized: T11, STT/transcript placeholders, G1 promotion, `dev`/`main` integration or push, official completion, status/checklist changes, branch deletion, PR creation, or unrelated refactoring.

## 2. Verified starting point — recheck, do not assume

Coordinator review on 2026-09-20 observed:

- Branch: `task/t10-app-lifecycle`.
- Candidate HEAD and remote task HEAD: `798443f5cc014980174f3c85bc75275938bfd1f9`.
- `dev` / `origin/dev`: `1001613c441bd91944a3f9f818cc99527bfcd204`.
- `main` / `origin/main`: `38e126f92ac823d29306ea8c1f7703f7060a5818`.
- Full independent unsigned arm64 Debug build/test: **230 passed, 0 failed, 0 skipped; 221 unit + 9 integration**.
- Candidate CI: run `34248913442`, success, at that exact candidate SHA: <https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/34248913442>.
- Four additional safety tests on an isolated copy of that HEAD: **4 executed, 4 failed, 0 skipped**, with the intended assertion failures, not compilation/environment failures.

These are historical starting-point evidence, not proof that the repaired HEAD passes. Green existing tests and CI did not cover the four defects below. The old repeated-result path was unavailable during the latest review; do not claim its counts as a new run.

Preflight:

- Inspect repository root, status, branch, remotes, recent log, and actual diff before editing.
- Continue this existing task branch and preserve its candidate commit. Do not recreate T10 from scratch or reset to `dev`.
- If HEAD moved, inspect ancestry/diff and whether the reported defects already changed. Do not overwrite another session's work. A compatible descendant is not automatically a blocker; an unrelated concurrent implementation requires coordination.
- Preserve `prompts/T09_FRESH_SESSION_DIAGNOSIS.md` and the older `prompts/T10_REVIEW_REPAIR.md` unmodified and unstaged. Preserve all other unrelated tracked/untracked work.
- This new prompt and its diagnostic patch may be committed with the T10 repair for handoff continuity.
- No reset, clean, checkout-discard, stash, broad staging, force-push, or runtime/user-data deletion.

## 3. First reproduce, then repair; do not stop at a progress report

The attached patch contains the exact four diagnostic tests from the independent review. It changes only existing test files; it includes no production changes or user media. It has been checked to apply to the candidate above.

On the unchanged candidate, inspect and apply it using:

```sh
git apply --check prompts/fixtures/T10_REVIEW_REGRESSIONS.patch
git apply prompts/fixtures/T10_REVIEW_REGRESSIONS.patch
```

If the tests already exist or HEAD changed, inspect and port only missing cases; do not apply twice. Run the four focused tests before fixing the implementation, using a unique disposable result directory:

```sh
t10_review_run="$(mktemp -d /private/tmp/stt-t10-astra-repro.XXXXXX)"
xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$t10_review_run/DerivedData" \
  -resultBundlePath "$t10_review_run/Regressions.xcresult" \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests/testReviewCachedIdleDecisionMustNotAllowQuitAfterRecordingStarts \
  -only-testing:LocalLectureSTTTests/AppLifecycleTests/testReviewNewRecordingDuringFinalQuitReadsMustDenyOldQuit \
  -only-testing:LocalLectureSTTTests/RecordingSessionCoordinatorTests/testReviewQuitMustDenyFailedTerminalMetadataPersistence \
  -only-testing:LocalLectureSTTTests/RecordingSessionCoordinatorTests/testReviewWakeMustWaitForNormalStopEssentialSettlement \
  CODE_SIGNING_ALLOWED=NO test
```

On the reviewed starting HEAD these are expected to fail. Record the actual failures, then continue implementing. The original 230-test baseline need not be run again before every small edit; use focused checks during development and the complete final validation below.

The patch is diagnostic scaffolding, **not a frozen test architecture**:

- R1 models delayed observation through a fake. A reset in `configure` alone can make this reproducer pass without fixing production. Add a test using the actual app/work admission path after initial idle readiness has been established.
- R2 gates the second finalization read, matching the old implementation. If that call structure changes, move the gate to the equivalent ownership boundary and preserve the race assertion.
- R3's repository fault ordinal matches the candidate. If write order changes, target the actual terminal metadata write explicitly and prove fault delivery. Its `persistenceWarningCode` assertion describes the old diagnostic surface: a corrected typed first-failure result may replace that surface. Preserve proof of the injected failure, retained durable artifacts, surfaced error, and denied termination; do not require a required failure to remain classified as merely a warning.
- **R4 must be adapted before running it against a correct join implementation**: its old synchronous await of `didWake` can deadlock once wake correctly waits for the blocked normal Stop. Launch the sleep/wake handling as owned tasks as needed, handshake at the actual join/recovery barrier, assert no refresh while the save gate is held, release the save gate, await completion, then assert exactly one valid refresh and the unchanged normal outcome. Do not remove the wait merely to make the test finish.
- Preserve or strengthen each behavioral assertion. Do not delete, skip, weaken, or replace a failing safety regression with an unrelated passing test. Rename tests if appropriate and record the mapping.

Briefly state the causes and intended ownership invariants, then continue without waiting for another confirmation. Work in the order R1/R2, R3, R4, remaining acceptance, final validation, submission. Routine implementation difficulty or remaining tests are work to finish, not an external blocker.

## 4. R1 — cached idle readiness must not permit termination of new work

Affected baseline: `SynchronousTerminationReadiness` and `MacLifecycleDelegate.applicationShouldTerminate(_:)` in `LocalLectureSTT/App/MacLifecycleAdapters.swift`.

Observed failure: establish idle `.terminateNow`, start recording before asynchronous observation updates the mirror, then invoke the delegate. It returns `.terminateNow` despite new live work. The cached enum contains no freshness/ownership proof.

Required invariant:

- A synchronous safe-exit answer must be invalidated **before relevant new work is admitted**, through the actual shared app/work ownership boundary, not eventually through a snapshot stream.
- Definitely safe idle explicit quit still supports synchronous `.terminateNow` without a presenter, disk mutation, or later reply.
- Busy or unknown readiness takes the conservative asynchronous path; the AppKit callback never blocks waiting on actors or I/O.
- Cover preparation, recording, securing, finalization/recovery admission, and handoff ownership, not only the visible recording phase.
- Merely adding another asynchronous refresh, a timestamp, or an unconnected generation field is insufficient.

Prove initial idle → new work admission → delegate call while observation delivery is intentionally held. Assert the actual return value and absence of premature true replies. Test with production composition/seams as well as a minimal fake.

## 5. R2 — an old quit must not authorize newer work, including at the reply gateway

Affected baseline: `AppLifecycleCoordinator.resolveTermination(_:)` in `LocalLectureSTT/Application/AppLifecycle.swift`, plus the final AppKit reply path.

Observed failure: quit reads an interrupted recording snapshot, suspends while reading another owner, a new recording begins, and the old attempt returns true using the stale recording snapshot. `activeQuitAttempt` protects only the quit ID; it does not establish atomic ownership of all work through the actual reply.

Required invariant:

- Single-flight quit owns an attempt identity and relevant work/admission generation through essential save, cleanup, and final reply authorization.
- A newer admitted operation invalidates the old affirmative reply; alternatively, a correctly owned termination reservation prevents new admission until the attempt settles. Prove that real admission respects it. Do not forcibly stop a newer recording to rescue an old quit.
- Revalidate after relevant awaits and at the real adapter gateway. Another await between a check and the side effect must not reopen the race.
- Multiple Cmd-Q/menu/Dock requests coalesce: one presenter, one essential settlement, one quiesce/cancellation per owner, and one AppKit reply for the owned terminate-later attempt.
- Retry is not admitted before failed/cancelled attempt cleanup settles.
- Teardown/cancellation cannot strand a returned `.terminateLater` request. Test the actual injected reply seam, not only the coordinator Boolean.

Prove the new-work race during final owner reads **and** delayed gateway dispatch. Assert session/operation identity, reply order, exact counts, and preservation of newer work. A phase-only check is not an ownership proof.

## 6. R3 — required persistence failure is not durable essential-save success

Affected baseline: `RecordingSessionCoordinator` abnormal settlement and `AppLifecycleCoordinator` construction of `EssentialTerminationSaveResult`.

Observed failure with the real T07 coordinator and repository fault: the terminal metadata write fails, durable metadata still says `recording`, and the snapshot has `persistenceWarningCode`, but lifecycle authorizes termination. The existing result is derived from a phase and an always-empty warning list, not actual save evidence.

Required invariant:

- Obtain the outcome from the owner that performed essential save: actual required persistence success/failure, recoverable audio settlement, cleanup/scope settlement, first typed operational failure, and later warnings.
- Do not infer durability merely from `.interrupted` or `.error`, or introduce a DTO that still wraps that inference.
- An intentional sleep/quit interruption reason is not itself a save failure. Distinguish the reason from recorder/persistence/cleanup failure.
- Required terminal metadata or required journal/checkpoint failure must not authorize success. Preserve prior/recoverable bytes and expose attention; do not invent completion.
- Preserve the first real failure and later warnings without overwriting it with a generic lifecycle error.
- Catalog refresh remains best-effort where the existing contract says so. Do not turn every catalog warning into a fatal error or permanent exit blocker.
- Do not regress T07 ordinary Stop/abnormal settlement or T08/T09 first-error, no-clobber, and file-retention behavior.

Use fault injection through production settlement, not solely a stub preloaded with `.error`. Cover required metadata/event/checkpoint writes as applicable, writer flush/stop, and cleanup; separately prove best-effort warning behavior. Assert fault delivery, durable artifacts, retained bytes, first error, later warnings, settled scopes, user-attention state, and exactly one false reply on essential failure. Keep the terminal-metadata regression in the final suite.

## 7. R4 — sleep/wake must join normal Stop and its finalization handoff

Affected baseline: `AppLifecycleCoordinator.handlePowerEvent(_:)` and the T07 → T08 normal-Stop handoff.

Observed failure: normal Stop is blocked writing essential terminal metadata in `.securing`; sleep skips recording settlement, and wake calls recovery refresh while the normal Stop still owns essential save. Cancelling currently listed T08/T09 workers cannot join a T07 settlement that has not enqueued its T08 work yet.

Required invariant:

- Sleep/quit encountering normal Stop joins its existing essential settlement exactly once and preserves its normal completed capture outcome. It must not append an interrupted outcome.
- The join covers required durability and owned resource settlement, including the wrapper's possible T08 enqueue handoff. A late enqueue cannot escape a completed quiesce pass.
- Wake recovery starts only after the appropriate sleep generation's save, quiesce, and ownership cleanup settle.
- Reuse T07/T08/T09 owners and registry; no duplicate finalizer or recovery implementation.
- Do not wait for full M4A export or future transcript work; distinguish essential settlement from long finalization.
- Duplicate/stale sleep/wake and a newer recording cannot multiply recovery or overwrite newer ownership. Capture never restarts automatically.

Use a real T07 coordinator with a blocked required save, an explicit acknowledgment of the join barrier, and a gated T08 admission/cleanup handoff. Assert zero premature recovery, one settlement, retained normal outcome, no escaped work, eventual one valid refresh, and no automatic capture start. Also exercise `.willPowerOff` directly; a sleep-only test is not D07 evidence.

## 8. Finish the original acceptance; do not only fix these four tests

Audit every A01–E03 row against actual assertions. Current `docs/T10_ACCEPTANCE.md` says Covered too broadly. Preserve valid tests and add only the missing proof; do not rewrite the app or duplicate whole subsystems.

Specific gaps identified in the review:

| Area | Evidence that must exist before review ready |
| --- | --- |
| A01/E01 | Actual app composition and framework-free new lifecycle contracts; construction/previews cause no observers, assertions, I/O, prompts, or termination. Existing documented T03 URL exception is not a T10 redesign target. |
| A02/A04 | Injected production activity-token begin/end seam proves first acquisition, overlap/handoff without gaps, final release once, failure/cancellation cleanup, and no leak. Hold a **captured old inactive result** while admitting newer active work; returning the new state after a gate does not prove stale-false rejection. |
| B01/B02 | Production settlement ordering: stop accepting PCM, drain accepted primary frames, writer flush/stop, required durable writes, one terminal effect; test before and after durable start. |
| B04/B05/D05 | Real retained files/checkpoint/identity through T08 quiesce and fresh T09 resume; old unrelated cancellation tests alone are insufficient. Deterministic multi-cycle sleep/wake ownership proof. |
| C01 | Last-window close during capture preserves PCM/file progress and app-owned observation; it invokes neither interruption nor quit presenter. A static fake snapshot alone is insufficient. |
| C03/C04/C05 | Main/Settings open-close order, Dock reopen before visibility, hidden/transient filtering, and fresh in-memory reservation. Observe actual relevant user-window changes. At automatic termination dispatch, recheck current visible windows/reservation and work authority without a check-to-MainActor gap. |
| D02 | Continue/dismiss while actively recording leaves state, accepted PCM/file bytes, metadata, events, workers, and assertion ownership unchanged. An idle fake plus zero interrupt calls is insufficient. |
| D03/D04/D06 | Production essential-save durability/first-error evidence plus adapter presenter/reply exact-once tests, delayed cleanup, retry gating, and blocked full export not awaited. Coordinator call counts alone do not prove the AppKit contract. |
| D07 | Direct power-off semantic event test with blocked full finalization, retained recovery state, and essential-only wait. Keep physical logout testing manual. |
| Minimal UI | Wire observable essential-save progress, save-failure/attention, and sleep interruption into the existing UI. Merely adding protocol conformance or preview methods is insufficient. Test state binding without a real modal or process termination. |

For each row, document test function, fixture/gate, exact observable assertion, and current execution evidence. Automated requirements cannot be marked Covered using only test names, comments, a generic full-suite result, or another acceptance label. If the old claim was inaccurate, correct it explicitly.

Use bounded continuation/expectation handshakes for ordering. `Task.sleep`, repeated `Task.yield`, or polling until a race happens is not deterministic proof. A timeout may act as a failure watchdog, not as the mechanism that makes the tested order happen. Release test gates and join tasks even on failure. Await actor values into locals before XCTest assertions.

## 9. Final validation and accurate documentation

After focused repairs pass:

1. Run the complete unsigned arm64 Debug **build and test** with a unique DerivedData/result path. Structurally inspect xcresult for actual passed/failed/skipped counts, including both unit and integration targets. Do not copy 230 or any prior count.
2. Keep the four regression behaviors in the executed full suite. Re-run the existing B06 production repository/capture/writer integration: retained recovery MOV must actually decode, match the session identity, carry interrupted metadata/events, and create no premature M4A/transcript placeholder.
3. Keep T07–T09 regression coverage for normal/abnormal outcomes, PCM drain, single-flight/exclusion, first error/warnings, identity/no-clobber, retained files, exact-once scope release, and view-cancellation independence.
4. Select **eight real tests**, one for each category below, and run each **20 iterations**. Verify eight unique selected identifiers and **160 actual successful executions, zero failures/skips**, not merely a command line containing the flags.

Repeated categories:

1. Activity acquisition/release and stale-generation protection.
2. Recording sleep interruption exact-once.
3. Essential cleanup → wake recovery ordering across generations.
4. Last-window close → finite completion → one automatic exit.
5. Close/reopen/late gateway race.
6. Repeated quit → essential save → exactly one adapter reply.
7. Finalization cancellation/cleanup → quit reply, without waiting full export.
8. Essential-save first error plus later warnings and preserved artifacts.

Choose meaningful tests for those behaviors; the old repeated selection did not prove all eight categories. The four review regressions may be included where they fit. Do not require 160 separate duplicated tests.

Use `xcrun xcresulttool get test-results summary --path <actual-result> --compact` and iteration/test details as needed. If `testmanagerd`, sandbox, or cache permissions prevent test execution/result inspection, use the normal permitted macOS Xcode environment through the approval flow. Unknown/zero counts are not success; do not weaken tests to work around a runner problem.

Update:

- `docs/T10_ACCEPTANCE.md`: truthful row → test → assertion mapping, current commands/counts/results, four-regression mapping, and clearly separated historical evidence.
- `docs/ARCHITECTURE.md`: actual shared admission/readiness authority, quit ownership/reply, typed durability outcomes, sleep/join/handoff, window observation, activity ownership, and UI state.
- `docs/DEVELOPMENT.md`: reproducible focused/full/repeated commands and manual procedures.

Physical microphone/TCC, signed Sandbox, lid, real logout/power loss/process kill, and physical window/quit UX remain explicitly Manual/Pending unless actually performed. Synthetic automated tests do not prove those physical behaviors. Pending physical checks do not excuse missing automatable policy, adapter, ordering, or file-preservation tests.

## 10. Commit/push/CI sequence and stop condition

Resolve all mandatory **local** automated acceptance requirements before submission. E03 task CI is naturally established **after** commit/push; do not create a circular prerequisite requiring future CI before the commit exists.

1. Review complete task diff against the starting `dev`, current working diff, and `git diff --check`.
2. Confirm no unrelated files, recordings, model weights, runtime roots/DB/bookmarks, logs, xcresults, build artifacts, or secrets are staged.
3. Stage explicit T10 paths only. This prompt and the diagnostic patch may be included. Preserve the two historical untracked prompts named in section 2; leave status/checklist untouched.
4. Commit the repair on `task/t10-app-lifecycle`, with T10 in the commit message; no amend/rebase of the existing candidate is required.
5. Establish final local build/test evidence at the committed HEAD. If the already-tested tree is byte-identical to the committed source/tests/configuration and only evidence docs were added, record that equivalence explicitly; otherwise rerun affected validation and the full suite. Never reuse results after further executable changes.
6. Push only the task branch, without force, and verify exact-final-HEAD CI success, including run ID, head SHA, job/result, and nonzero test execution evidence.
7. Fix any same-Task CI failure and repeat affected validation/CI for the new HEAD. Do not amend merely to insert its own future SHA/CI URL into a committed doc; report final commit/run linkage in the handoff.
8. Keep the branch for independent review. Do not integrate, update official status, promote a gate, or start T11.

Continue through this workflow rather than ending after a partial implementation/status report. Stop safely as blocked only when a genuine authorization/product conflict, unsafe data choice, concurrent work conflict, or unavailable external/tooling prerequisite cannot be resolved within scope. Preserve all work and give the precise missing input/evidence; do not label unfinished ordinary implementation as an external blocker.

Final report:

- `T10 — review ready` only after all mandatory automated acceptance, commit/push, and exact-head CI pass; otherwise `T10 — blocked` with specific unmet IDs and cause.
- Starting and final task SHA, branch, unchanged `dev`/`main` SHA, CI URL/run/head/result.
- R1–R4: root cause, production correction, final regression test identifiers, and actual outcomes.
- Key changed files, ownership decisions, and accurate A01–E03 traceability link.
- Actual focused/full/repeated commands, result paths, pass/fail/skip counts, eight repeated identifiers and 160 executions.
- Real-file integration outcome, remaining physical manual checks, deviations/risks.
- Confirmation that unrelated work, `PROJECT_STATUS.md`, plan checklist, `dev`, and `main` were preserved.
- Official T10 completion, integration, and next-Task readiness remain the coordinator's independent post-review decision.
