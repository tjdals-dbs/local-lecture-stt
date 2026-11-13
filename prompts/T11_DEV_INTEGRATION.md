# T11 Phase 2 — integrate the independently approved candidate into dev

Continue in the **existing T11 implementation session** and repository `/Users/andyoon/stt`.

Session setting: **Astra / high**, retaining the user's current implementation setting.

## 1. Explicit authorization and approved source

The coordinator independently reviewed the T11 implementation and FIFO repair, and the user now explicitly authorizes **Phase 2 integration of T11 into `dev`**.

Authorized operations:

- Recheck/safely synchronize the latest `dev` and prepare the existing T11 branch for integration.
- Update T11's official completion/checklist and concise handoff documentation as part of integration.
- Locally squash-integrate the approved T11 work into the latest `dev`.
- Run full build/test on the resulting committed `dev`, push `dev`, and verify CI for that exact commit.
- After successful remote verification, safely delete the local and remote T11 task branch, preserving unrelated work.

Approved source:

```text
task branch: task/t11-stt-engine-contract
approved T11 SHA: ad9888e2b67b49c89f22759dccfa1b8ce83843e3
last reviewed dev: 73b4a7adaa16a2ff97ff8affda04fe3b99573b0c
protected main: 38e126f92ac823d29306ea8c1f7703f7060a5818
```

Coordinator verification on 2026-11-13:

- Fresh unsigned arm64 Debug build/test: **299 passed (289 unit + 10 integration), 0 failed, 0 skipped**.
- All **35 T11 tests**, including the original FIFO reproducer and three sibling callback/drain tests, actually executed and passed.
- Independent result: `/private/tmp/stt-t11-fifo-independent.UTTQvK/Full.xcresult`.
- Exact approved task-commit CI passed: <https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43349002465>.
- G1 decision documents matched the coordinator's authorized planning versions; T11 was still unchecked; `dev` and `main` had not been integrated/changed by Phase 1.

These are **approved-source** results. They do not replace validation of the new squash commit.

This explicit Phase 2 authorization supersedes only the earlier T11 prompts' restrictions on status/checklist updates, `dev` integration/push, and verified task-branch cleanup. All data-preservation, scope, offline, model, and recording invariants remain in force.

**G1 remains Unverified.** The user's 2026-11-13 decision permits this T11 work and integration with G1 deferred; it does not pass G1, waive hardware checks, or authorize `dev → main`, tags, a release, or T12 implementation.

## 2. Load context and inspect before mutating Git

Read the current user instruction, `AGENTS.md`, `PROJECT_STATUS.md`, the T11 section/G1 scheduling decision and Git integration rules in `IMPLEMENTATION_PLAN.md`, and this prompt. Consult specification 8.2/8.3/9 or the implementation prompts only for a concrete question. Use `docs/T11_ACCEPTANCE.md` for current assertion evidence; do not reimplement or rereview all earlier Tasks.

Inspect:

- Repository root, status, current branch, remotes, local/remote refs, and recent commits.
- The full task diff against `dev` and any working/staged changes.
- The final approved-source CI linkage and whether another session has advanced a branch.

Expected working state when this prompt was created: task HEAD and its origin tracking ref equal the approved SHA, `dev` equals the reviewed baseline above, and there are no tracked WIP changes. This new integration prompt may be untracked.

Preserve these unrelated coordinator-owned files **untouched, unstaged, and uncommitted**:

```text
prompts/T09_FRESH_SESSION_DIAGNOSIS.md
prompts/T10_REVIEW_REPAIR.md
```

Preserve every other unrelated tracked/untracked file too. Do not use reset, clean, checkout-discard, stash, broad staging, or force-push to make integration convenient. The integration prompt may be included unchanged in the integration commit for provenance.

If T11 now contains unreviewed implementation commits beyond the approved SHA, identify them and stop for review instead of silently integrating them. The expected untracked integration prompt is a documentation addition, not unreviewed executable work.

If an implementation defect requiring more than mechanical integration resolution is discovered, preserve the work and report the specific issue. This authorization is for the approved T11 behavior, not new features or an architecture redesign.

## 3. Synchronize the latest dev safely

1. Fetch and inspect the live `origin/dev`, `origin/main`, and T11 branch. Capture the starting local/remote SHAs.
2. Confirm the approved source exists and is the intended task tip. Confirm `main` still matches its protected baseline. Do not alter `main` to resolve any discrepancy.
3. Bring local `dev` to the latest remote state by a safe fast-forward when possible. Do not discard unexpected local commits or move a branch under another worktree.
4. If `dev` is unchanged from `73b4a7a`, reuse the approved task candidate and proceed; no redundant pre-integration full run is required solely because this prompt was created.
5. If `dev` advanced, safely incorporate it into the existing T11 task branch, preserving other Tasks. Resolve straightforward integration conflicts only when the reviewed T11 behavior and current dev behavior can both be retained.
6. After incorporating a changed `dev`, run affected/T11 tests plus the full suite, commit/push the integration-preparation change on the task branch, and verify CI for its new exact SHA before squash integration. Record both the originally approved source SHA and this tested integration-preparation SHA. Do not force-push or include unrelated feature changes.
7. If safe synchronization would overwrite WIP, discard commits, or require a product/scope decision, stop at that point and report the concrete conflict.

## 4. Prepare one narrow squash integration

Use the latest synchronized `dev` as the destination. Locally squash-merge the approved task source (or the safe, tested latest-dev incorporation from section 3). No PR or merge commit is required.

As part of this integration, update:

### PROJECT_STATUS.md

- Record T11 as the latest completed Task **through independently approved dev integration**.
- Keep milestone M2, with M1/G1 hardware validation explicitly unverified.
- Make T12 model repository/manifest/import the next planned Task, **awaiting a separate implementation prompt**. Do not implement it.
- Describe the application accurately: a framework-independent STTEngine contract and deterministic fake now exist; actual model inference, live STT wiring and transcript finalization remain unimplemented.
- Replace stale current-position/repository fields that still identify T10 as the latest integration. Keep T10's historical handoff intact.
- Add a concise T11 handoff with the original approved SHA, the FIFO correction, contract/ownership decisions, source verification, actual integration validation, CI linkage policy, and retained G1 limitations. Link to acceptance/architecture rather than copying the entire matrix.
- Keep unrelated decisions, earlier evidence, and all gate results. **G1 stays Unverified** and the latest passed gate remains unchanged.

### IMPLEMENTATION_PLAN.md

- Check **only T11's completion checkbox**.
- Preserve T12 and all subsequent unchecked Tasks, the G1 deferral note, Task scopes and release/promotion rules.
- No gratuitous plan-version change is required for a completion checkbox.

### docs/T11_ACCEPTANCE.md

- Add concise Phase 2 authorization/integration context so the document no longer implies integration remains forbidden after this separate approval.
- Preserve Phase 1 reproduction and review evidence as historical records.
- Clearly distinguish approved-source results from integration-commit results. Update supporting architecture/development documentation only if integration actually changes its facts/commands.

Avoid self-referential commit amendments: a document need not contain the SHA or CI URL of the very commit that first contains that document. Record known source/baseline/results before commit; link the final integration SHA and its CI in the final handoff. Do not endlessly amend to make a commit name itself.

Before committing:

- Inspect the complete staged diff and verify only the reviewed T11 work, authorized planning changes, completion/handoff updates and optional integration prompt are included.
- Compare the integrated executable/project/test tree with the source being integrated. Differences must be explained by the safely incorporated latest `dev`; status/acceptance/prompt changes are documentation, not an excuse for unnoticed source differences.
- Check whitespace. Literal context markers in the existing `.patch` fixture may contain required whitespace; preserve the reproducer's semantics and distinguish patch data from source whitespace errors. Use `git apply` checks where applicable rather than rewriting a test fixture solely to silence a patch-data warning.
- Confirm no recordings/transcripts, model weights, runtime DB/bookmarks, logs/xcresults/DerivedData, user storage, built apps or credentials are staged.

Create one local squash integration commit on `dev`, for example:

```text
feat(stt): integrate engine contracts and deterministic fake (T11)
```

Capture its exact SHA. Do not push a failing or unverified integration commit.

## 5. Validate the committed dev before push

Run full build/test on the **actual committed integration HEAD**, with unique output paths. For example:

```sh
t11_integration_run="$(mktemp -d /private/tmp/stt-t11-integration.XXXXXX)"
xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$t11_integration_run/DerivedData" \
  -resultBundlePath "$t11_integration_run/CommittedHead.xcresult" \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test

xcrun xcresulttool get test-results summary --path "$t11_integration_run/CommittedHead.xcresult" --compact
xcrun xcresulttool get test-results tests --path "$t11_integration_run/CommittedHead.xcresult" --compact
```

Require build success, both test targets executed, all existing T11 and FIFO regression tests actually included, and zero failures/unexpected failures/skips. The approved tree had **299 tests, including 35 T11 tests**; report actual integration counts rather than copying these numbers. More tests may exist if dev advanced, but existing tests cannot disappear without explanation.

In particular, retain and execute:

```text
FakeSTTEngineTests/testIndependentEarlyCallbackCannotLetNewAdmissionOvertakeQueuedWork
FakeSTTEngineTests/testEarlyFailedCallbackPreservesFIFOOriginsCapacityAndTerminalOwnership
FakeSTTEngineTests/testEarlyTerminalCallbackSettlesWaitingEndWithAndWithoutPendingFIFO
FakeSTTEngineTests/testEarlyCallbackPumpsEqualDeadlineSnapshotsAndNextWorkerWithoutReentry
```

No arbitrary additional repetition requirement applies. The complete suite includes earlier clock-budget, language, partial/final, cancellation, model-pinning and stale-generation regressions as well as T05–T10 recording safety coverage.

If sandbox/helper/cache access blocks Xcode or xcresulttool, retry through the permitted normal macOS Xcode/approval path. Zero/unknown execution counts are not success. If a genuine test failure remains, keep the task branch and local integration work, do not push false completion evidence, and report the exact failure and safe preserved state.

Verify the committed HEAD and executable/test/configuration tree are unchanged after tests. Any subsequent executable change requires fresh affected and full validation. Documentation-only changes still change the commit SHA and require CI on that final commit; avoid unnecessary amendments after successful validation.

## 6. Push dev and verify CI for its exact SHA

1. Immediately before push, recheck `origin/dev` has not advanced. A concurrent update must be incorporated safely; never force-push dev. Repeat affected integration validation after a changed tree.
2. Push only `dev` using a normal non-force push.
3. Verify GitHub Actions for **the exact pushed integration SHA on `dev`**, not the approved task run or an older dev run. Record run ID, URL, head SHA, branch and completed result, and confirm its build/test job executed.
4. While CI is queued/running, continue waiting with concise progress updates; an unchanged queued state alone is not a blocker.
5. If CI fails, investigate and preserve the task branch. Correct only an authorized integration issue and validate the new final commit. A new implementation defect/scope choice goes back to independent review. Do not claim integration success from the source branch's green CI.
6. Confirm local `dev`, `origin/dev`, and the live remote dev ref agree on the validated commit; confirm local/remote `main` are unchanged.

## 7. Cleanup only after dev is pushed and verified

The user authorizes removal of **only `task/t11-stt-engine-contract` locally and remotely**, after the checks above succeed.

Before deletion:

- Work from `dev`, and confirm no worktree/session has newer work on the task branch.
- Re-read the local and live remote task tips immediately before deletion. Both must be the source actually integrated (including any authorized latest-dev incorporation). If either advanced unexpectedly, retain the branch and report the new tip; never delete unknown work.
- Verify all reviewed source/test/project changes are present in the successful dev tree. Expected differences from the integrated source are the explicitly authorized status/checklist/handoff/prompt updates; inspect any other differences.
- Preserve the approved/integrated source SHA in the handoff before deleting refs. Preserve unrelated untracked files.

Delete the matching remote task branch, then its local branch. A squash merge may cause `git branch -d` to refuse because ancestry is not retained. In that case **`git branch -D task/t11-stt-engine-contract` is authorized only for this exact verified branch after remote dev CI success and tree/tip preservation checks**. It is not permission to discard WIP, delete other branches, or force-push any branch.

If a cleanup permission or concurrent-tip issue prevents deletion after dev was already successfully integrated/pushed/verified, report the completed integration and the specific remaining cleanup separately. Do not discard newer work or misrepresent the actual dev integration state.

## 8. Final handoff

Report `T11 — integrated` only after the authorized dev integration, local committed-HEAD build/test, dev push and CI for that exact SHA have succeeded. Otherwise report the precise blocker and which operations already happened.

Include:

- Originally approved source SHA, any integration-preparation SHA, starting dev SHA, and final dev SHA.
- Actual full build/test command, result path, unit/integration and T11 test counts, failures/skips, and FIFO regression execution.
- Exact-dev-commit CI URL, run ID, head SHA and result; local/origin/live dev equality.
- Updated status/checklist/acceptance files and next planned Task T12 (not implemented).
- Explicit **G1 Unverified**, actual STT/model inference still unimplemented, and unchanged `main`/no release tag.
- Local/remote task-branch deletion result and whether any cleanup remains.
- Preserved unrelated files, remaining risks/manual checks, and the next safe handoff.

Proceed through the authorized workflow without another confirmation round for ordinary synchronization, squash integration, validation, push or verified branch cleanup. Do not implement T12 or promote main.
