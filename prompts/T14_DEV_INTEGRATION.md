# T14 Phase 2 — integrate the independently approved WhisperKit candidate into dev

Continue in the **existing T14 implementation session**, repository `/Users/andyoon/stt`. Retain **Astra / high**. Do not start a fresh implementation, switch models, or spawn additional agents automatically.

## 1. Explicit authorization and approved source

The coordinator independently verified T14 and the three same-Task repairs. The user now authorizes **T14 Phase 2 integration into dev**, including latest-dev synchronization, completion/status documentation, a local squash integration, committed-dev build/test, dev push/exact-SHA CI and subsequent verified task-branch cleanup.

```text
task branch: task/t14-whisperkit-adapter
approved source: b4551c21324e76952f07cc4fd3b85a24e2594492
reviewed dev/origin/dev: 1724853e1d1942c7f32c0b8d998177d76d2f7c2c
protected main/origin/main: 38e126f92ac823d29306ea8c1f7703f7060a5818
approved-source CI: https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43571116655
```

Coordinator verification of that source:

- Independent unsigned arm64 Debug build/test: **423 passed (413 unit + 10 integration), 0 failed, 0 skipped**. T14: **42 selectors = 32 engine + 10 SDK boundary**; existing T13 49, T12 33 and T11 35 also executed and passed.
- Result: `/private/tmp/stt-t14-independent.zMaYO3/Full.xcresult`; log `build.log` in that directory.
- Current-source SwiftPM CLI rebuilt successfully. Actual installed non-quantized large-v3 performed repeated inference and active cancellation/fresh reuse under process-only network denial with fresh isolated user/cache directories. Reports: `/private/tmp/stt-t14-independent.zMaYO3/AutomaticOffline/{report.json,report.txt}` and `CancelReuseOffline/{report.json,report.txt}`. Ordinary measured RTF was approximately 0.4285–0.4300; this is short synthetic-speech evidence, not a performance/accuracy gate pass.
- Context prefill preserves 111 accepted tokens and rejects over-budget context; detector errors do not become English success; end/cancel join owning cleanup. Actual SDK-boundary and held-cleanup regressions passed. The documented 111-token stress case's repetition/slower output remains a known experimental limit.
- Both committed lockfiles pin the same SDK/transitive revisions. Source task CI succeeded for the exact approved SHA. Status/checklist/dev/main and the two unrelated untracked prompts remained unchanged.

These are **source-candidate results**, not evidence that a new dev commit has passed validation.

This authorization supersedes only Phase 1's bans on official T14 completion records, dev integration/push and verified T14 branch deletion. Preserve all data/offline/model/engine-boundary invariants. **G1 remains Unverified, G2 remains unpassed.** No main promotion, tag/release, product engine/model selection, model auto-update, live STT wiring or T15+ implementation is authorized.

## 2. Context and safe preflight

Read this instruction/`AGENTS.md`, `PROJECT_STATUS.md`, T14 and Git integration rules in `IMPLEMENTATION_PLAN.md`, and `docs/T14_ACCEPTANCE.md`, including the repair section. Consult specification 9.1–9.4/17.1/17.5 and relevant architecture/development sections only as needed. This is an integration of approved behavior, not a new design/review of every Task.

Inspect repository root, status, current branch, remotes, worktrees, local/remote tips and recent commits. Capture starting SHAs and preserve all unrelated files. Expected current task tip is the approved SHA, with no tracked WIP. This integration prompt may be untracked and may be included unchanged in the integration commit for provenance.

Preserve these unrelated files **untouched, unstaged and uncommitted**:

```text
prompts/T09_FRESH_SESSION_DIAGNOSIS.md
prompts/T10_REVIEW_REPAIR.md
```

No reset/clean/discard, stash, broad staging or force-push. Do not move a branch under another active worktree. Unreviewed task-source commits/WIP beyond the approved source must be identified and returned for review; the new integration prompt alone is an expected documentation addition. Do not silently integrate new SDK/behavior changes under this approval.

## 3. Synchronize the latest dev

1. Fetch and inspect live origin dev/main/task tips. Confirm approved source availability and exact task tip; leave main unchanged even if an unexpected discrepancy needs reporting.
2. Safely fast-forward local dev to origin/dev when possible; do not discard unexpected local commits/WIP.
3. If dev is still `1724853`, proceed directly with the approved candidate. No redundant pre-integration full/real-model run is required merely because this prompt was created.
4. If dev advanced, safely incorporate it into the existing T14 task branch. Preserve the reviewed behavior and the new dev work. Resolve only mechanical integration conflicts; a product/engine change or unsafe ambiguous resolution needs independent review.
5. After changed-dev incorporation, run affected/T14 and full tests, commit/push that preparation on the task branch and verify CI for its exact SHA. Record approved source plus preparation SHA. Repeat relevant actual-model/offline checks when the changed tree affects them; unchanged benchmark evidence may be retained with an explicit input-equivalence check.
6. If synchronization would discard work, overwrite WIP or require an unapproved behavior choice, preserve the safe state and report that concrete conflict. Ordinary synchronization/tests/CI waiting need no further confirmation.

## 4. Prepare the squash integration and completion records

From the latest synchronized dev, locally squash-merge the approved source or the tested latest-dev preparation. No PR is used. With an unchanged baseline, create one normal dev squash integration commit, for example:

```text
feat(stt): integrate offline WhisperKit adapter and benchmark (T14)
```

As part of integration, update only relevant completion/handoff documentation:

**PROJECT_STATUS.md**

- Use the actual current date; record T14 as the latest completed Task through **independent review and separately authorized dev integration**. Current Task becomes none in progress after successful integration; local branch is dev.
- Keep milestone M2 and G1 explicitly Unverified. Keep G2 pending/unpassed and the latest passed gate unchanged.
- Make T15 whisper.cpp experimental adapter the next planned Task, **awaiting a separate implementation prompt**. Do not implement it.
- Correct stale current/repository fields that still identify T13 as the latest Task. Preserve T13 and earlier historical handoffs.
- Describe actual scope: the pinned experimental WhisperKit backend, real local format/tokenizer support, optional bounded context, safe model-use lease and developer benchmark exist. Actual developer inference is implemented; product model-management UI, live capture/STT integration, canonical transcript finalization and final engine/model selection remain unimplemented/undecided. Production catalog remains empty.
- Add a concise T14 handoff with approved source and CI, the three repaired contracts, SDK/model pins, independent source verification, committed-dev validation policy and remaining limits. Link acceptance/architecture/development instead of copying the matrix. Preserve the short-speech/context-stress limitations; no accuracy/latency/RTF/G1/G2 pass claim.

**IMPLEMENTATION_PLAN.md**

- Check **only T14's completion checkbox**. Preserve T15+ unchecked, Task scopes, G1 deferral and release/promotion policy. No gratuitous plan-version change.

**docs/T14_ACCEPTANCE.md**

- Add concise Phase 2 authorization/integration context, making clear historical Phase 1 restrictions are superseded only by this instruction.
- Preserve initial failures, repair evidence, real-run measurements and provenance as historical source results. Distinguish them from new committed-dev test/CI results. Update architecture/development only if integration changes their facts/commands.

The status document need not contain the SHA/CI URL of the commit that first contains it. Record known approved-source/baseline/results before committing and report the actual final dev SHA/CI in the handoff; do not loop through self-referential amendments.

Review the complete staged diff, whitespace and data policy. The integrated executable/test/project/package/tool/catalog tree must equal the approved source when dev has not advanced. Include both Package.resolved files, Package.swift, tools/t14, model descriptor/bootstrap/offline profile, tests and project settings in the comparison, not only app Swift files. Expected additional differences are the authorized status/checklist/acceptance and integration-prompt documentation. Explain every other difference; do not accidentally integrate stale SDK code or a different model catalog.

Stage explicit paths only. Never commit weights, real transcripts/media, runtime benchmark reports/inputs, model/source/store/cache folders, logs/xcresults, DerivedData, application support/bookmarks or credentials. Preserve unrelated untracked prompts. Commit the narrow squash integration locally and capture its exact SHA **before** the required committed-HEAD validation.

## 5. Validate the actual committed dev

Run full unsigned Debug arm64 build/test on the **committed dev HEAD**, with a unique result bundle. Reuse verified dependency/build caches if available; a clean rebuild is not required. Example using the existing resolved cache:

```sh
t14_integration_run="$(mktemp -d /private/tmp/stt-t14-integration.XXXXXX)"
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t14-work/DerivedData \
  -resultBundlePath "$t14_integration_run/CommittedHead.xcresult" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path "$t14_integration_run/CommittedHead.xcresult" --compact
xcrun xcresulttool get test-results tests --path "$t14_integration_run/CommittedHead.xcresult" --compact
```

If the example cache is absent, resolve/build using the committed lockfiles in another disposable cache, without changing pins. Dependency setup is not authorization for model downloads. Confirm the root SwiftPM benchmark also builds from committed inputs using its pinned resolution; an existing CLI scratch directory is acceptable. Record actual commands and paths.

Require real nonzero execution in both original test targets, all **42 T14 tests (32 engine + 10 SDK boundary)**, T13 49/T12 33/T11 35 and earlier safety regressions, with **zero failures/unexpected failures/skips**. The approved baseline total is 423 (413 unit + 10 integration); report actual new execution counts rather than copying it. Explain additional tests if dev advanced; no missing selector may be hidden by an unchanged total.

In particular, retain/execute:

```text
WhisperKitSDKBoundaryTests/testReviewAcceptedPromptSurvivesActualPinnedSDKPrefill
WhisperKitSDKBoundaryTests/testOverBudgetPromptFailsBeforeAnySDKTranscription
WhisperKitSDKBoundaryTests/testSDKTokenProgressExcludesContextAndControlTokens
WhisperKitSDKBoundaryTests/testActualSDKDetectorErrorCannotFallThroughToTranscribe
WhisperKitSDKBoundaryTests/testReviewDetectionFailureNeverBecomesEnglishSuccessAndReuseWorks
WhisperKitSDKBoundaryTests/testCancellationDuringExplicitDetectionJoinsBeforeTranscription
WhisperKitSTTEngineTests/testReviewEndAndCancelledCancelJoinHeldUnloadCleanup
```

Real-model evidence may be reused **only after proving** the merged adapter/backend/lease/DTO/benchmark/package/experimental catalog/bootstrap/offline-profile inputs and pins equal those independently reviewed. Record that equivalence and refer to the existing real outputs. No repeated ~3 GB acquisition or repeated inference is required for a documentation-only squash. If synchronization/conflict resolution changes relevant executable/assets/settings, rerun the affected real offline repetition/cancel/context/negative checks with existing verified assets and fresh output paths, following `docs/DEVELOPMENT.md`. Never replace real evidence with a fake/skip or silently change model/precision to make integration pass.

Runner/testmanagerd/xcresult cache restrictions require the permitted normal Xcode/macOS execution path; zero/unknown tests are not success. Keep genuine failures visible. Mechanical integration/build issues can be repaired and revalidated, but a new SDK/behavior defect requires review of its task-branch repair before integration is treated as approved. Do not push failing dev or claim success from the task CI alone.

Recheck committed HEAD and executable inputs after tests. Any executable change invalidates affected/full results. A changed final commit, even for documentation, needs CI for that final SHA; avoid unnecessary post-validation amendments.

## 6. Push dev and verify exact-commit CI

1. Immediately before pushing, recheck live origin/dev. Incorporate concurrent changes safely and repeat affected/full verification if the tree changes; never force-push dev or discard another Task's work.
2. Push only dev with a normal non-force push.
3. Verify GitHub Actions for the **exact pushed dev SHA and dev branch**. Record run ID/URL/head/status/conclusion and confirm the actual build/test job ran with nonzero test execution. Approved-source task CI is not integration CI.
4. Wait through queued/running states with concise updates. If CI fails, preserve the task branch, diagnose the exact issue and validate any permitted integration fix/new final SHA. A behavior-changing repair goes back to review; do not clean up the source branch while that remains unresolved.
5. Confirm local dev, origin/dev and the live remote dev ref all equal the validated commit. Reconfirm local/remote main remain at the protected baseline.

## 7. Delete only the verified T14 task branch

The user authorizes deletion of **only `task/t14-whisperkit-adapter` locally and remotely**, after committed-dev tests, dev push and its exact-SHA CI all succeed.

Work from dev. Check worktrees and immediately re-read local/live remote task tips before deletion. Both must be the approved source or the explicitly tested latest-dev preparation actually integrated; if either advanced unexpectedly, preserve it and report that newer work. Verify the successful dev contains the reviewed source/tests/project/package/tool changes, with only authorized integration-document differences. Record the source SHA and preserve unrelated files before removing refs.

Delete the matching remote branch, then local branch. Squash integration does not retain task ancestry, so `git branch -d` may refuse. **`git branch -D task/t14-whisperkit-adapter` is authorized only for this exact verified branch after successful dev push/CI and tip/tree preservation checks.** This does not authorize reset/discard, deleting other branches, force-push or removing worktrees/user files.

If dev is successfully integrated/pushed/verified but cleanup is prevented by permissions or new task work, report integration and remaining cleanup separately; keep the protected/newer work. Never falsely describe branch cleanup as completed.

## 8. Final handoff

Report **`T14 — integrated`** only after authorized squash integration, actual committed-dev full validation, dev push and exact-dev-SHA CI success. Otherwise report the concrete blocker and which steps already occurred, retaining the task branch/work safely.

Include approved source, any latest-dev preparation SHA, starting/latest dev and final dev SHA; updated status/checklist/acceptance paths; actual full/CLI build commands, result paths, unit/integration/T14/T13/T12/T11 counts and required regressions; real-input equivalence or any rerun commands/results; exact dev CI URL/run/head/result; local/origin/live dev agreement; unchanged main, G1 Unverified/G2 unpassed and no product engine/model selection/release; local/remote task deletion outcome; unrelated-file preservation and remaining manual/experimental risks. **T15 remains unimplemented and awaits a separate implementation prompt.**

Proceed through the authorized integration/verification/push/verified-cleanup workflow without another confirmation round for ordinary steps. Do not implement T15 or promote main.
