# T15 Phase 2 — integrate the approved whisper.cpp candidate into dev

Continue in the **existing T15 implementation session**, repository `/Users/andyoon/stt`, using the retained **Astra / high** setting. Do not start a fresh implementation, switch models or spawn additional agents automatically.

## 1. Explicit authorization and approved source

The coordinator independently reviewed T15 against its original prompt and acceptance matrix. The user accepted that review and now authorizes **T15 Phase 2 dev integration**: synchronize latest dev, update T15 completion/handoff documents, squash integrate locally, validate the committed dev, push dev, confirm its exact-SHA CI and then safely delete the verified T15 task branch.

```text
task branch: task/t15-whisper-cpp-adapter
approved source: 6a5f0dde8e35423ecd8d4ab918cb73f5ea556def
reviewed dev/origin/dev: 59690f3dee5e21330e3ac60646b3da51d0dbd433
protected main/origin/main: 38e126f92ac823d29306ea8c1f7703f7060a5818
approved-source CI: https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43625949746
```

Independently verified approved-source results:

- Unsigned macOS arm64 Debug build/test: **432 passed (422 unit + 10 integration), zero failed/skipped**. Test tree includes **9 WhisperCppAdapterTests**, **42 T14 tests (32 shared engine + 10 WhisperKit SDK boundary)**, **49 T13**, **33 T12**, **35 T11 (30 fake + 5 contract)** and prior recording/recovery/lifecycle regressions.
- Current-source SwiftPM benchmark rebuilt successfully. Independent result root: `/private/tmp/stt-t15-independent.ivpV8X`; full result `FullRetry.xcresult`, `summary.json`, `tests.json`, logs `full-retry.log` and `cli-build.log`. An initial restricted-cache build attempt failed environmentally; the normal permitted Xcode execution above succeeded. Preserve the distinction.
- Actual installed non-quantized large-v3 ran under process-only OS network denial with fresh isolated user/cache/temp roots, outside the checkout. `Automatic/report.json` contains warmup plus two successful measured automatic-language repetitions. Measured RTF was approximately **0.2175/0.2199**. `Cancel/report.json` contains **final → cancelled → final**, with native abort acknowledgement and subsequent successful reuse of the same engine. These short synthetic results do not pass a performance/accuracy gate.
- Both reports embed the same T14 canonical PCM: `local-samantha-v1`, **112640 mono Float32 frames, 16000 Hz, 7.040 seconds**, media origin 5000 ms, PCM SHA-256 `319c127d3e77fc3d425cd93a78d6df167e3c6fdfc9daa8ea26748a1aace42a88`. The final intervals remained within 5000–12040 ms.
- Independent automatic report SHA-256: `6724604b636ed45d4fdfbfe96e9a5a37fd057e6a6a569b43ff76a8d49c5f41a1`; cancel/reuse report SHA-256: `8673d0d5e325dd9e81a3c2308d0cffcf5411e51ebfc64a79f201ee58ce7fa980`.
- The coordinator inspected the worker's normal/offline/cancel/WhisperKit regression reports, negative missing/truncated/corrupt asset results and pinned native code. Worker evidence remains `/private/tmp/stt-t15-validation.Uth8xp/Final`, documented in `docs/T15_ACCEPTANCE.md`. The official artifact digest/source matched live upstream metadata. Task CI and remote task/dev/main tips were independently confirmed.

These are **approved-source results**, not validation of a future dev squash commit.

This instruction supersedes only Phase 1's restrictions on official **T15** completion records, dev integration/push and verified T15 branch deletion. **G1 remains Unverified; G2 remains pending/unpassed.** No main promotion, tag/release, product engine/model selection, production-catalog population, automatic model update, live STT/transcript wiring or T16+ work is authorized.

## 2. Context and safe preflight

Read this prompt and `AGENTS.md`, `PROJECT_STATUS.md`, T15 and Git integration rules in `IMPLEMENTATION_PLAN.md`, then `docs/T15_ACCEPTANCE.md`. Consult specification 9.1–9.4/17.1/17.5 and relevant architecture/development sections only as needed. This integrates approved behavior; do not redesign the native adapter or re-open the product engine decision.

Inspect root, worktrees, status, current branch, remotes, recent commits and local/live remote tips. Capture starting SHAs. Expected task HEAD is the approved source with no tracked WIP. This new integration prompt may be untracked and is an authorized documentation addition to the integration commit.

Preserve these unrelated files **untouched, unstaged and uncommitted**:

```text
prompts/T09_FRESH_SESSION_DIAGNOSIS.md
  SHA-256: 7352bbc778ec56dda12d55896e435a22908d95da500ffc6bd463068b996471e7
prompts/T10_REVIEW_REPAIR.md
  SHA-256: 5cb69843facdc0a947ec894854fe558aef99318889a95830a7fde82de065f96f
```

Preserve any other unrelated WIP too. No reset/clean/discard, stash, broad staging, history rewrite or force-push. Do not move/delete a branch used by another worktree. Unreviewed commits or executable WIP beyond the approved source must be identified and returned for review before integration; do not silently include them under this authorization.

## 3. Synchronize latest dev without changing reviewed behavior

1. Fetch and inspect live origin dev/main/task tips. Confirm the approved source exists and identify any task-tip discrepancy. Preserve unexpected work; main must remain unchanged.
2. Safely fast-forward local dev to origin/dev when possible, without discarding unexpected local commits/WIP.
3. If dev is still `59690f3`, integrate the approved candidate directly. No redundant preparation commit, pre-integration full run or real-model rerun is required solely because this documentation prompt was created.
4. If dev advanced, incorporate latest dev safely into the **existing T15 task branch**, preserving reviewed T15 behavior and new dev work. Resolve only mechanical conflicts. A native/SDK/model/settings/product-behavior choice or ambiguous resolution requires independent review, not an assumed approval.
5. For changed-dev preparation, run affected tests and the full suite, build the CLI, commit/push the preparation on the task branch and verify its exact-SHA CI before integration. Record the original approved source and preparation SHA. Repeat relevant actual-model checks only when changed execution inputs invalidate them.
6. If synchronization cannot preserve all work safely, stop at the concrete conflict, retaining the task branch and evidence. Routine synchronization, test execution, CI waiting and the authorized cleanup need no additional confirmation.

## 4. Squash integration and narrow completion records

From the latest synchronized dev, squash-merge the approved source or its tested latest-dev preparation locally. No PR is used. With an unchanged baseline, create one normal dev integration commit, for example:

```text
feat(stt): integrate offline whisper.cpp adapter and shared benchmark (T15)
```

Update only the relevant completion/handoff documentation as part of that integration:

**`PROJECT_STATUS.md`**

- Use the actual current date. Record T15 as the latest completed Task through independent review and separately authorized dev integration; include its completed-work table row. Current Task becomes none in progress after successful integration, local branch dev.
- Keep milestone M2, latest passed gate unchanged, G1 explicitly Unverified and G2 pending/unpassed.
- Make **T16 engine/model comparison and user decision** the next planned Task, awaiting a separate comparison prompt. Do not start comparison, solicit/select a winner, implement T17 or claim the short synthetic smoke replaces the required lecture samples/user decision.
- Update stale top-level current/repository fields from T14 to the new integrated position. Preserve T14 and earlier historical handoffs/results.
- State the actual scope: both experimental WhisperKit and whisper.cpp interval adapters and developer inference/benchmark exist. Native dependency/model manifests, strict local validation, safe model-use leases, cancellation and shared reports are implemented. The production catalog stays empty; product model-management UI, live capture/STT integration, canonical transcript finalization and final product engine/model remain unimplemented/undecided.
- Add a concise T15 handoff with approved-source CI, reviewed tests, pins, native ownership/cancellation/checked language/context/time contracts, source evidence versus committed-dev validation policy and remaining experimental/manual limits. Link acceptance/architecture/development rather than duplicate their full matrix.

**`IMPLEMENTATION_PLAN.md`**

- Check **only T15's completion checkbox**. Preserve T16+ unchecked, Task scopes/dependencies, G1 deferral, gate and release/promotion policies. No gratuitous plan-version change.

**`docs/T15_ACCEPTANCE.md`**

- Add concise Phase 2 authorization/integration context. Preserve Phase 1 results and restrictions as history; this instruction alone supersedes the integration restrictions.
- Preserve failed intermediate attempts, native ABI suffix, pinned trust/license records, actual real-run measurements, missing/corrupt negatives and limitations. Distinguish source tests/CI from new committed-dev tests/CI.
- Update architecture/development only if their facts or verified commands actually change during integration. Do not rewrite T14 measurements as new T15 results.

Keep these reviewed pins/limits truthful:

- Native source `d1be6fde11ac6e0407606b4e42fe72d34add8037`, v1.9.5/build b5454; actual linked ABI reports **1.9.5-dev**. Artifact URL/checksum remain fixed in `Packages/WhisperNative/Package.swift`, SHA-256 `e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b`.
- GGML large-v3 revision `5359861c739e955e79d9a303bcbc70fb988958b1`, payload size **3095033483** bytes, SHA-256 `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`; package checksum `e12bbe7a21e4ec6be9983fd0f76d04735e115e5ac5d8a3edf9292211c4a20d9c`. This is non-quantized mixed F16/F32 storage, distinct from the existing WhisperKit package.
- Preserve the WhisperKit SDK/model/transitive pins and both existing package resolutions. No opportunistic dependency/model updates or new acquisition.
- Native Metal preference/CPU fallback, four threads, flash attention, greedy strategy and actual acceleration diagnostics stay documented. Native segment partials differ from WhisperKit token-progress partials; physical-footprint GPU/ANE attribution is incomplete.
- Native load uses one model-sized unlinked verified temporary snapshot; preserve its space/load cost. Native cancellation can wait for the next checkpoint. Native prompt limit is 223 tokens, WhisperKit's is 111; native hints at temperatures >=0.5 are explicitly rejected. No lecture accuracy, sustained live-throughput or gate claim follows from these smoke results.

Do not require a document to contain the future SHA/CI URL of the commit that first contains it. Record known source/baseline/evidence and the committed-dev verification policy before committing; report the actual final dev SHA/CI in the final handoff. Avoid self-referential amendments.

Review the complete staged diff, whitespace and data policy. On unchanged latest dev, the **entire executable/test/project/package/tool/catalog tree must equal the approved source**, including both `Package.resolved` files, root and native-wrapper manifests, native/backend/profile/validator/lease/repository code, shared benchmark runner/CLI, all tests, CI, model metadata, negative-check script and the offline profile. Compare content/paths, not just app Swift files. Record an input manifest or equivalent Git tree/hash proof. Expected additional differences from the approved source are only `PROJECT_STATUS.md`, the T15 checkbox, `docs/T15_ACCEPTANCE.md` and this integration prompt. Explain every other difference.

Stage explicit paths only. Never commit weights/media/PCM/transcripts/reports, model/source/store/cache folders, native binary archives/XCFramework builds, runtime DBs/bookmarks, logs/xcresults/DerivedData or credentials. Preserve unrelated untracked prompts. Commit the local squash and capture its exact SHA **before** committed-HEAD verification.

## 5. Validate the actual committed dev

Run full unsigned arm64 Debug build/test on **committed dev HEAD**, plus the root SwiftPM CLI build. Reusing verified dependency/build caches is allowed; no clean rebuild is required. Example using the existing T15 cache:

```sh
t15_integration_run="$(mktemp -d /private/tmp/stt-t15-integration.XXXXXX)"
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData \
  -resultBundlePath "$t15_integration_run/CommittedHead.xcresult" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path "$t15_integration_run/CommittedHead.xcresult" --compact
xcrun xcresulttool get test-results tests --path "$t15_integration_run/CommittedHead.xcresult" --compact
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
```

If caches are absent, resolve/build in another disposable cache using the committed pins and verified native artifact, without changing dependency versions. Dependency resolution is not permission to fetch models. Use the permitted normal Xcode/macOS execution path when testmanagerd/cache/xcresult permissions require it. Record exact commands, expanded paths and actual outcomes.

Require nonzero execution in both original test targets with **zero failures/unexpected failures/skips**, including all **9 T15**, **42 T14**, **49 T13**, **33 T12**, **35 T11** and earlier safety tests. The approved total is **432 (422 unit + 10 integration)**; inspect both xcresult summary and test tree and report actual new execution counts. If latest dev adds tests, explain the changed total and preserve all reviewed selectors; an unchanged total cannot hide missing tests.

In particular, retain/execute these native regressions and the shared/T14 tests they rely on:

```text
WhisperCppAdapterTests/testLinkedVersionParametersAndCallbackPolarity
WhisperCppAdapterTests/testCheckedDetectorStatusAndSupportedNativeIDs
WhisperCppAdapterTests/testLinkedNativeTokenizerMultibyteBoundaryResetAndNoByteLoss
WhisperCppAdapterTests/testBoundedCallbackConsumerJoinsBeforeReturningFirstNativeFailure
WhisperCppAdapterTests/testTimestampTickBoundsOverflowAndSessionOffset
WhisperCppAdapterTests/testHeaderRequiresArchitecturePrecisionVocabularyAndExactSize
WhisperCppAdapterTests/testNativeLoadCancellationJoinsLateAllocationAndExactlyOneFree
WhisperCppAdapterTests/testNativeCallRetainsPCMUTF8PromptAndControlUntilActualReturn
WhisperCppAdapterTests/testCancelledControlsJoinHeldCleanupAndModelClaim
WhisperKitSTTEngineTests/testReviewEndAndCancelledCancelJoinHeldUnloadCleanup
```

Reuse the approved actual-model/offline evidence **only after proving** merged execution inputs/pins equal those independently reviewed. Record the equivalence and report paths/hashes. A documentation-only squash does not require another ~3 GB model download, repeat acquisition or duplicate inference. If synchronization changes the relevant source/native artifact/model/benchmark/options/resource inputs, rerun affected real offline inference/cancel/reuse/negative and WhisperKit regression checks with existing verified packages, fresh output paths and the documented commands. Do not substitute a fake, skip, different model/precision or earlier-source CI for required evidence.

If tests fail, preserve and diagnose the real failure. Repair mechanical integration/build issues and rerun affected/full verification. A new native/SDK/behavior defect needs independent review of its task-branch repair before integration is considered approved. Do not push a failing dev. Recheck HEAD and executable inputs after validation; any change invalidates affected/full results. A changed final commit, even for documentation, needs CI for that final SHA; avoid unnecessary post-validation amendments.

## 6. Push dev and confirm exact-commit CI

1. Immediately before push, recheck live origin/dev. Incorporate concurrent changes safely and repeat required verification when the tree changes; no force-push or discarded work.
2. Push **only dev** using a normal non-force push.
3. Confirm successful GitHub Actions on the **exact pushed dev SHA and dev branch**. Record run ID/URL/head/status/conclusion and actual nonzero build/test execution plus the native-enabled CLI build. Task-branch CI is not dev integration CI.
4. Wait through queued/running states with concise progress updates. If CI fails, retain the task branch, diagnose and verify any permitted fix/new final SHA. Behavior-changing repairs return for review before treating integration as approved.
5. Confirm local dev, origin/dev and the live remote dev ref equal the validated successful SHA. Reconfirm local/live remote main remain at the protected baseline.

## 7. Delete only the verified T15 task branch

The user authorizes deletion of **only `task/t15-whisper-cpp-adapter`, locally and remotely**, after committed-dev tests, dev push and its exact-SHA CI all succeed.

Work from dev. Check worktrees and immediately re-read local/live remote task tips before deleting. Both must still match the approved source or the explicitly tested latest-dev preparation that was actually integrated. Preserve/report any unexpected newer commit. Confirm successful dev contains the reviewed source/test/project/package/tool changes, with only authorized integration-document differences. Record the source tip and input-equivalence proof before removing refs.

Delete the verified matching remote branch, then the local branch. A squash does not retain task ancestry, so `git branch -d` may refuse. **`git branch -D task/t15-whisper-cpp-adapter` is authorized only for this exact verified branch after successful dev push/CI and tip/content preservation checks.** This does not authorize deleting another branch, resetting/discarding work, force-pushing commits or removing worktrees/user files.

If integration/push/dev CI succeeded but cleanup is blocked by permissions or new task work, report successful integration and remaining cleanup separately. Preserve protected/newer work; do not falsely report deletion.

## 8. Final handoff

Report **`T15 — integrated`** only after authorized squash integration, current committed-dev full validation, dev push and exact-dev-SHA CI success. Otherwise report the concrete blocker and steps already performed, preserving work/task branch as applicable.

Include approved source, any preparation SHA, starting/latest dev and final dev SHA; updated status/checklist/acceptance paths; actual full/CLI commands/result paths and unit/integration/T15/T14/T13/T12/T11 counts; execution-input equivalence or affected real reruns; exact dev CI URL/run/head/result; local/origin/live dev agreement; unchanged main; local/remote task deletion outcome; unrelated-file preservation; remaining native/manual limits and **G1 Unverified/G2 unpassed**. **T16 awaits a separate comparison prompt; product engine/model selection and T16+ implementation remain unauthorized.**

Proceed through ordinary authorized integration, validation, push, CI verification and conditional cleanup without another confirmation round. Do not promote main or start T16.
