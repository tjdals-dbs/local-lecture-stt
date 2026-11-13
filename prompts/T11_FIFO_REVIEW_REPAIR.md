# T11 same-Task repair — preserve FIFO after an accepted early callback

Continue **T11 Phase 1 only**, in `/Users/andyoon/stt`, on `task/t11-stt-engine-contract`. Session setting: **Astra / high**. The existing implementation session can continue; a fresh local session can also use this self-contained handoff without conversation history.

Read `AGENTS.md`, `PROJECT_STATUS.md`, T11 in `IMPLEMENTATION_PLAN.md`, relevant specification sections 8.2/8.3/9, then `prompts/T11_STT_ENGINE_CONTRACT_AND_FAKE.md` and this repair. Preserve the original Task scope and acceptance requirements. G1 remains **Unverified**, with the user's explicit authorization to proceed with T11. Do not implement T12 or real STT integration.

## Starting evidence and review result

Independently reviewed on 2026-11-13:

- Task HEAD and remote task HEAD: `b1b4158b0fd283886156e08ce498320aa2c51fd6`.
- `dev` / `origin/dev`: `73b4a7adaa16a2ff97ff8affda04fe3b99573b0c`.
- `main` / `origin/main`: `38e126f92ac823d29306ea8c1f7703f7060a5818`.
- Fresh independent unsigned arm64 Debug build/test: **295 passed, 0 failed, 0 skipped**. Result: `/private/tmp/stt-t11-independent.mFlvFQ/Full.xcresult`.
- CI for that exact task commit passed: <https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43341676751>.
- An additional test on a production-identical temporary copy executed **1 test, 0 passed, 1 failed, 0 skipped**, with five FIFO/order assertions failing. This is a real behavior failure, not a build, runner, or watchdog failure.
- Diagnostic result: `/private/tmp/stt-t11-diagnostic.RF9AdE/FIFO.xcresult`; log: `fifo.log` in the same directory.

Overall review: **partial; T11-08 is not satisfied**. Most contracts, scope, tests and submission boundaries landed correctly. Do not rebuild T11 from scratch or reopen unrelated T10 work.

## Exact defect

Relevant code: `LocalLectureSTT/Infrastructure/FakeSTTEngine.swift`:

- `deliver(_:lease:)` accepts a valid terminal callback and clears `active`, but does not promote the already-accepted pending head or settle waiting control operations.
- `infer(_:)` assumes `active == nil` means a new request can become active directly; it does not account for an existing nonempty queue.

Deterministic reproduction, all at logical time zero until the first advance:

1. Start a loaded session.
2. Submit A (sequence 0, scripted final at 100 ms), then B (sequence 1, final 10 ms after processing starts). B is pending.
3. Capture A's current callback lease and deliver a valid revision-1 final for A early. The production fake accepts it.
4. Submit C (sequence 2, final 10 ms after processing starts).
5. Advance by 10 ms.

Required order: **A → B → C**, with B final at 10 ms and C still pending/active until 20 ms. Actual behavior: **A → C → B**. Immediately after step 4, `activeSequence` is 2 and `queuedSequences` is `[1]`; at 10 ms C has a final while B has no output.

This is the existing supported callback/fault seam, not an invented transport. The current `testClockBudgetRejectionPreservesActiveRequestSequenceAndScript` already uses a valid early final through this seam. Existing tests cover it only without pending work.

## Reproduce before fixing

The durable test attachment is `prompts/fixtures/T11_FIFO_REVIEW_REGRESSION.patch`. It adds one test to the existing `FakeSTTEngineTests` class and changes no production code. Inspect and apply it once:

```sh
git apply --check prompts/fixtures/T11_FIFO_REVIEW_REGRESSION.patch
git apply prompts/fixtures/T11_FIFO_REVIEW_REGRESSION.patch
```

If source has advanced or the test is already present, inspect and port only what is missing; preserve other work. Run the exact selector with the original project's Debug/arm64/unsigned settings and a fresh result path:

```text
LocalLectureSTTTests/FakeSTTEngineTests/testIndependentEarlyCallbackCannotLetNewAdmissionOvertakeQueuedWork
```

Expect failure on the reviewed HEAD, then continue the repair. Do not weaken the FIFO assertions, add an artificial `advance(by: 0)` between callback and admission solely to hide the defect, or delete/skip the test.

## Required correction and focused proof

Restore one coherent queue/worker progression rule for accepted callbacks, scripted terminal events, cancellation, admissions and settlement. New requests cannot bypass pending accepted work. Preserve request-processing origins, bounded capacity, script/sequence consumption, model/session identity, language detection and exactly-once terminal delivery.

Choose a narrow implementation; no new scheduler framework or live STT coordinator. If callback publication re-enters a transition pump, avoid recursive double-processing, out-of-date local Work copies, double completion or clearing the next worker. Tests must prove observable behavior rather than a helper call count.

Keep the supplied test permanently and add focused sibling coverage for the same correction:

- Accepted early final **and failed terminal** with an already queued head and another admission: the original FIFO survives and each processing delay begins at actual activation.
- A normal `end()` already waiting in draining while a valid terminal callback completes the last owned work must settle correctly. With pending work, drain that existing FIFO and then settle; do not strand end waiters or require an unrelated new admission to make progress. Use clock/barrier acknowledgments and bounded failure watchdogs.
- Late/stale/repeated callbacks remain rejected, and each accepted feed terminates exactly once.
- Re-run the existing clock-budget early-completion test, backlog/cancel/end/unload cases, disabled-partial/language regressions and stale-generation tests. Do not regress the previous repairs while normalizing worker progression.

Correct `docs/T11_ACCEPTANCE.md`'s T11-08 evidence and briefly record this uncovered callback path, its fix, actual assertions and commands. Update architecture/development docs only where the correction changes their described contract or verified commands.

## Submission and preservation

Recheck live Git state and preserve unrelated work. The two historical untracked prompts (`T09_FRESH_SESSION_DIAGNOSIS.md`, `T10_REVIEW_REPAIR.md`) remain untouched and unstaged. The pre-authorized coordinator G1 planning files remain byte-identical to the original T11 prompt's hashes; T11 stays unchecked. This repair prompt and its test patch may be included in the T11 repair commit.

After focused tests pass, run a fresh complete unsigned arm64 Debug build/test, inspect actual unit/integration pass/fail/skip counts and verify the new test executed. No arbitrary T10 repetition requirement applies. Review the entire branch/staged diff, commit the narrow repair with T11 in the message, push only the existing task branch without force, and verify CI for the new final SHA. Current 295/green CI is historical evidence, not proof of the repair.

Report `T11 — review ready` only after all original acceptance, the callback/FIFO regression, full build/test and final-commit CI pass. Include final SHA, CI run/head/result, actual test selectors/counts/results, the corrected ordering/settlement behavior, and remaining risks. Preserve the branch for independent review. Do not mark T11 officially complete, update its checklist, pass G1, integrate/push dev/main, create tags, delete the branch or start T12.
