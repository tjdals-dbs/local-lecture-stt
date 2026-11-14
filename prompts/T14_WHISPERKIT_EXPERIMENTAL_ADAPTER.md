# T14 — WhisperKit experimental adapter and reproducible local benchmark

## 1. Assignment and authorization

Implement **T14 only** in `/Users/andyoon/stt`, in a fresh implementation session. Retain the user's implementation setting: **Astra / high**. Previous chats are unnecessary. Do not switch models or spawn additional agents automatically.

The coordinator independently verified T13 and its authorized dev integration. This is the separate T14 assignment anticipated by `PROJECT_STATUS.md`. **G1 remains Unverified**, neither passed nor waived, under the user's accepted deferral. It does not block this isolated adapter/benchmark Task. Do not claim G1, G2, real-lecture accuracy or complete live STT verification.

Deliver **Phase 1: review-ready task branch**, including implementation, meaningful automated tests, a real installed-model inference/benchmark run, accurate documentation, task commit/push and CI for the final commit. **Do not** officially complete T14, update `PROJECT_STATUS.md` or the plan checklist, integrate/push dev/main, delete the task branch, create a release/tag, implement whisper.cpp/T15 or choose the product engine/model/T16–T17. Those need independent review and later authorization.

## 2. Context and preflight

Read in order:

1. This prompt and `AGENTS.md`.
2. `PROJECT_STATUS.md`.
3. T14 in `IMPLEMENTATION_PLAN.md`; T11–T13 and T15–T17 only for relevant dependencies/boundaries.
4. `MVP_SPEC.md` **9.1, 9.2, 17.1, 17.5**; **9.3, 9.4, 8.3, 15.1–15.4, 17.7** for provenance, language, model authority and offline constraints.
5. Actual Git state/code; relevant T11/T12/T13 architecture, development and acceptance sections.

Observed baseline at prompt creation:

```text
branch: dev
dev/origin/dev: 1724853e1d1942c7f32c0b8d998177d76d2f7c2c
main/origin/main: 38e126f92ac823d29306ea8c1f7703f7060a5818
latest integrated Task: T13
independent current baseline: 381 passed (371 unit + 10 integration)
T13: 49 selectors; T12: 33; T11: 35
dev CI: https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43459675124
```

Inspect root, status, branches, remotes and log before editing. Safely fetch/check latest dev and use **`task/t14-whisperkit-adapter`**. If dev moved, inspect/incorporate it safely rather than discarding work or pinning an obsolete baseline. Preserve unrelated WIP/untracked files, especially `prompts/T09_FRESH_SESSION_DIAGNOSIS.md` and `prompts/T10_REVIEW_REPAIR.md`, untouched/unstaged/uncommitted. No reset/clean/discard, stash, broad staging or force-push. No tracked WIP currently needs carrying; this prompt may be untracked and belongs in the eventual T14 commit.

Run one baseline full build/test before source edits, recording actual nonzero counts. Historical 381-pass evidence is not a new execution.

Read the actual contracts first:

- `Application/STTEngine.swift`: load/start/infer/end/cancel/unload and `STTEventFeed` ownership.
- `Domain/STTContracts.swift`: immutable model/session/request identity; owned Float32 input (≤30 seconds); absolute session-media response bounds; options, error codes and Codable/Sendable validation.
- `Infrastructure/FakeSTTEngine.swift`, `STTEngineTests.swift`, `FakeSTTEngineTests.swift`: bounded FIFO, terminal retention, sequence/language rules and cancellation settlement. The deterministic fake is evidence of the contract, not a real inference backend.
- `Domain/ModelPackage.swift`, `ModelDelivery.swift`, `Application/ModelRepository.swift`, `Infrastructure/FileModelRepository.swift`, `ModelPackageFiles.swift`: authoritative manifests/checksums, compatibility seam, scoped resolver and per-key claims.
- `ModelDownloadService.swift`/storage/transport and `ModelDownloadTests.swift`: explicit catalog downloads, shared verified installation and repaired cancellation/postcommit behavior.
- App/project/scheme/CI: macOS 15.0+, arm64, Swift 6 app; manual PBX source/resource membership. No Swift package dependency or real format validator currently exists. Production catalog is empty.

## 3. Deliverables and scope

Implement the open-source WhisperKit adapter behind `STTEngine`; exact dependency/model provenance; a real offline model-format/tokenizer integration with T12/T13; Korean/English/session-fixed automatic language, bounded text context, interval inference, partial/final response conversion and cancellation; an engine-neutral benchmark input/output format usable by T15; a developer harness and actual inference evidence; contract/fault tests and documentation.

Keep this experimental service/harness isolated from ordinary app construction, previews and recording. No model-selection/download UI, microphone/capture wiring, T18 streaming/VAD/overlap reconciliation, canonical transcript persistence, summaries, diarization, system audio or product file-import feature. Developer benchmark audio-file input is expressly in scope; it is not a new user-facing import workflow. Do not refactor recorder/lifecycle code to demonstrate the adapter.

T14 requires a real model run. **Mocks alone, upstream CLI output alone, a missing-model test that skips, or a placeholder adapter are not sufficient.** A missing default-model decision is not a blocker: T16 makes that product choice later.

## 4. Pin the open-source dependency and inspect its actual behavior

Use only the open-source **WhisperKit** library product. Verify canonical upstream identity, release compatibility, license and exact source before choosing a revision. The old WhisperKit URL may redirect to Argmax's OSS repository; this naming change is not permission to adopt Pro/paid SDKs, API keys, server products, TTS or diarization.

At prompt preparation, upstream exposes a `WhisperKit` product and a `v1.1.1` release. Treat that as a candidate to verify, not a floating latest requirement. Select one compatible released revision, pin its full commit/revision in the Xcode package reference, commit `Package.resolved` with transitive resolution, and record URL/tag/40-hex revision, license and effective engine identity. No branch/up-to-next-major dependency or runtime update checking. Maintain the current deployment target unless an actual unavoidable conflict is reported; do not silently raise it.

Inspect the **pinned** source for local model/tokenizer lookup, default downloads, decoding options, callbacks, cancellation and Core ML compute/prewarm settings. Explicitly configure them; do not rely on undocumented defaults. In particular, disabling model download is not proof that tokenizer/recommendation/config fallback cannot make a network request. Prevent such fallback, fail locally for missing assets, and keep generated cache/compiled files separate from immutable installed payloads when necessary.

Primary references (re-check against your chosen commit and record immutable links in the implementation docs):

- [Upstream package products/dependencies](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Package.swift).
- [WhisperKit local setup, tokenizer and inference entry points](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Sources/WhisperKit/Core/WhisperKit.swift).
- [WhisperKit initialization/decoding options](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Sources/WhisperKit/Core/Configurations.swift).
- [Upstream releases](https://github.com/argmaxinc/argmax-oss-swift/releases).

Package resolution during development/CI is distinct from application runtime network behavior. Default CI must compile/link the actual pinned adapter but must not download model weights or run expensive real-model benchmarks. Do not vendor the entire upstream repo or run its unrelated weight-downloading tests.

## 5. Real model package, offline validation and use lifetime

Start with **one accuracy-oriented, non-quantized large-v3 candidate** compatible with the pinned WhisperKit backend. Resolve its exact converted Core ML variant/revision from authoritative upstream metadata rather than guessing a folder name. Do not silently substitute tiny/base/medium/turbo or a compressed/quantized variant to declare T14 complete. No speed comparison or final accuracy decision is required here; record actual timings even if performance targets are missed.

This assignment authorizes **one explicit development bootstrap** to obtain that candidate and required tokenizer/license assets if no matching verified local package exists. Use disposable/ignored storage outside Git and the T12/T13 verified import/download services. No automatic acquisition on adapter load/start/infer, no SDK model downloader, no unrelated model collection or model conversion project. Reuse an already available matching package where possible. Public source access is sufficient; do not request user credentials.

The production catalog may remain empty. Commit a fixed **experimental candidate descriptor/delivery catalog** with exact source revisions, file lists/lengths/SHA-256 and license provenance for an explicit developer harness; keep it separate from ordinary selectable product entries/defaults. No remote latest/catalog lookup at runtime. Derive expected data from immutable published metadata/content and explain its trust provenance; do not invent hashes or mislabel a checksum computed after an arbitrary download as a previously published author guarantee. Tokenizer and other required runtime assets are part of the verified package, not incidental files from a developer's global cache.

Implement a real offline WhisperKit-format validator through `OfflineModelFormatValidating` and explicit Infrastructure composition. Validate the required Core ML component/tokenizer layout and compatible model/engine/settings from the pinned source, reject missing/corrupt/unsupported packages, and retain existing checksum and unknown-schema policy. Do not make a generated test-header recognizer the live validator or accept an arbitrary directory by name. Validator work must not recurse into repository validation or start a network/engine download. If Core ML probing is needed, make its effects and cleanup explicit; avoid eagerly running inference merely to list models.

**The current `withResolvedPackage` callback ends its claim on return. It does not by itself grant a loaded backend a lifetime-long right to reopen model URLs.** Add the minimum internal model-use lease needed to pin verified identity and prevent same-key deletion/replacement while the backend may use files, through load/inference/cancel/unload cleanup. Conservatively holding the existing exclusive claim until unload is acceptable for T14; document its `busy` behavior rather than building a general reader/writer lock system. Avoid recursive acquisition when validating/loading under that claim. Inventory/resolver policy must remain truthful.

Keep URLs/FDs/CoreML/vendor objects in Infrastructure. Revalidate ownership at SDK I/O/await boundaries; a replaced path cannot become trusted by recapturing a new snapshot. Model/cache writes must not corrupt the authoritative install, and no SDK cleanup may delete session data or user model sources. Release only the owning attempt's lease/resources exactly once after actual backend work settles. A failed/cancelled load must permit retry after cleanup, without allowing an old callback/unload to affect the new backend.

## 6. Adapter contracts and controlled SDK backend

Implement a production `WhisperKitSTTEngine` (name may follow existing conventions) and a **narrow Infrastructure-internal backend seam** for real SDK calls plus deterministic fault/callback tests. The real adapter must call the pinned SDK; tests must exercise its production orchestration, not a second fake-engine implementation. Vendor imports/types, CoreML configuration, tokenizer tokens and NSError stay behind the seam. New serializable crossing values are Codable/Sendable.

- Explicit load validates requested engine revision, exact installed model revision/checksum, format/quantization and effective compute settings. Unknown/contradictory settings fail with typed errors; do not silently load another model or ignore options. Record resolved compute/prewarm/decode choices in benchmark provenance.
- Start freezes the exact model/session/options/language configuration. No model switch while a session is active. New sessions reset language/context/sequence state. Wrong session, nonincreasing sequence, unsupported format and overflow must reject before mutating accepted work.
- Advertise only supported capabilities. Prefer existing canonical 16 kHz mono Float32 input for the backend. Unsupported caller formats may be rejected consistently; do not advertise all T05 capture formats or perform a new live-audio pipeline. The benchmark can explicitly decode/resample once before feeding identical canonical PCM to either future backend.
- Preserve the T11 bounded FIFO and `backlogFull` behavior. Every accepted request gets one retained terminal (final/failed/cancelled), increasing revisions and the original immutable context. A rejected request gets a typed throw, not a leaked feed or backend work. Do not run multiple decodes against an unsafely shared SDK instance or bypass queued work on callback completion.
- Partial hypotheses are replacement snapshots, coalesced/bounded by the existing feed. SDK token callbacks are not canonical transcript appends. `partialResults=false` suppresses publication while still processing detection/finality correctly; it must not turn a successful request into `invalidResponse`. Silent audio may validly produce an empty final. Do not fabricate text or partials to satisfy a latency metric.
- `end()` stops new admission and drains accepted work before settling session state. `cancel()` cancels the session; feed withdrawal cancels only its own request and preserves others' FIFO order. `unload()` joins preparation/decoding/cleanup and releases the model. Control-caller cancellation must not abandon engine-owned cleanup. Concurrent end/cancel/unload must join rather than double-finish/release.
- Use operation generations/request ownership across every await and SDK callback. Load/decode completion, partial or cleanup from an old attempt cannot mutate a later session/model. Active cancellation must cooperate with the pinned SDK and await its actual task completion. If a Core ML step cannot be interrupted immediately, report that limit honestly and keep the engine/lease unavailable until it settles; early fake cleanup is invalid.
- Preserve first operational errors and distinct cleanup diagnostics internally/through framework-independent report values. Do not weaken existing `STTResponse` validation or expose an NSError to accommodate bad SDK output. Failed preparation/inference and cancellation need meaningful typed mappings and subsequent reuse tests.

## 7. Language, context and time mapping

Korean/English use transcription, not translation. Force the selected language consistently while allowing the model to retain spoken English terms in Korean speech. Accuracy of code-switching is measured later; do not promise exact spelling.

Automatic mode detects at session start from the first suitable inference audio, then pins that valid language for the session. Silence may leave detection undecided; never fabricate a Korean/English default from a missing SDK result. Once pinned, later requests must not re-detect/change it. Detection remains effective when partial publication is disabled. Reject unsupported/contradictory detection safely; old callbacks cannot overwrite a new session's detection.

The current request's `context` is identity/media timing, **not a text prompt**, and currently has no text-context field. This Task explicitly authorizes the smallest backward-compatible optional framework-independent decoding-hints value (e.g. `decodingHints.promptText`) on `STTInferenceRequest` to support T14's context requirement. Default absent/empty hints preserve old callers and decode old JSON. Bound text size on init/decode and document token-budget behavior. Keep `STTRequestContext` identity semantics and T02 session-file schemas unchanged. Do not introduce vendor token IDs, arbitrary option dictionaries or unbounded history. Map hints to the pinned tokenizer/decoding API in Infrastructure and test mapping/reset/overflow behavior; T18 will decide how live context is supplied.

WhisperKit intervals may be relative to the input window. Map them to `request.context.mediaStart` **exactly once**, including nonzero offsets. Use checked conversion/rounding for seconds→milliseconds; reject NaN, infinity, materially negative/out-of-range/reversed output. Document any small rounding/padding tolerance at actual audio boundaries. Produce valid sorted nonoverlapping segments within the request bounds without silently dropping/reordering recognized text. When timestamps are disabled, define a truthful whole-window text representation rather than invented fine timestamps. Enforce existing response size bounds with typed failure when output is unusable.

## 8. Reusable developer benchmark and real inference evidence

Add one explicit developer harness/CLI or separate shared real-model benchmark scheme. It must invoke **this adapter through `STTEngine`**, not just call the upstream CLI. Keep real assets/benchmark execution out of default app startup and routine CI; a separate opt-in invocation is acceptable, a skipped/default-passing placeholder is not. Document exact build/bootstrap/run commands and required paths. Do not create a broad product import/benchmark UI.

Create an engine-neutral Codable/Sendable input/result format reusable by T15. Use one deterministic canonical PCM representation, fixed ≤30-second request windows and an explicit request/context plan. Record the decoded samples' checksum, format/frame count/duration, source-file checksum and case ID so T15 can prove identical input. Decode/resample only once; don't compare different SDK file decoders or independently chosen chunk boundaries. No live VAD/overlap algorithm now.

Export versioned JSON plus a readable transcript/timing view (TXT/MD or CSV where useful) to an explicitly supplied disposable/ignored output directory. Preserve existing output unless overwrite is explicitly requested. Reports include:

- App/OS/hardware, exact engine package revision, installed model/tokenizer identity/checksum, variant/precision and effective compute/prewarm/decoding settings; input/context/window plan and warm-up/repetition policy.
- Separate model/prewarm load time, queue delay, inference/final elapsed time and first-partial latency when actually observed. Use a monotonic clock. Distinguish window-processing latency from real microphone utterance-end latency, which T14 cannot establish.
- **RTF = inference processing seconds / input audio seconds**, with load/warm-up inclusions explicitly stated. Keep per-case/repetition values and aggregate rules. Don't invert the ratio or silently count warm-up as measured throughput.
- Memory baseline and observed peak/physical footprint using a documented platform method and sampling policy; process-wide/sampling limitations must be explicit. Missing/unavailable metrics are null/diagnosed, never fabricated zero. Bound sampler/tasks and stop/join them on all paths.
- Text, valid session-relative segments, detected language, terminal failures/cancellation and warnings. Successful metrics cannot hide missing terminal results or failed cases. Failed runs preserve reviewable diagnostics and do not claim accuracy/performance success.

For the real local run, use one short, nonprivate speech input with known generation/provenance (locally generated speech using an already installed voice is acceptable). Generate or use a clearly redistributable small fixture; no user lecture sample is required in T14. Do not download voices implicitly. Run the same input at least twice after a documented warm-up, through load/start/infer/end and unload/reload, with actual nonempty speech text, bounded timestamps and provenance/metric exports. Do not require byte-identical transcript output from hardware to prove repetition; record any differences. Demonstrate a real active-decode cancellation and subsequent fresh inference where feasible, alongside deterministic cancellation tests.

Repeat actual load/inference with networking denied and a fresh isolated SDK/model cache; all required model/tokenizer assets must come from the verified install. Test a missing tokenizer/model component and prove a local typed failure without fallback requests. An empty network spy plus a fake backend is not proof of real offline inference. Use a documented OS/process denial or comprehensive real-SDK transport interception; do not change the user's system-wide network settings or stop their unrelated apps. Record limitations honestly.

Real-lecture samples, three 10–15 minute comparisons, scoring/default selection and the RTF 0.83/live-latency gate remain T16/G2 or later. T14 records observed numbers and functional evidence; it must not mark performance targets passed from a short smoke input. It also must not declare completion from deterministic tests while omitting its required real run.

## 9. Acceptance matrix

Create `docs/T14_ACCEPTANCE.md`: **ID → exact automated selector or real command → fixture/gate/assertion → executed evidence**. State automated and real/manual status separately. Tests use tiny synthetic data, disposable roots and the production adapter/backend seam; weights and runtime reports are never Git fixtures.

| ID | Required proof |
| --- | --- |
| T14-01 | Exact open-source package revision and committed resolution; actual SDK product compiles/links on the supported target/CI. No floating dependency, Pro/cloud/server/TTS/diarization product or runtime dependency updater. License/provenance recorded. |
| T14-02 | Existing STTEngine/DTO/session schemas remain compatible. Optional text hints decode absent legacy input, validate init/decode bounds, round-trip and map through the production adapter. No vendor/URL/NSError boundary leaks. |
| T14-03 | Preparation/lifecycle success and failure, mismatched engine/model/settings, repeat load/unload, concurrent preparation and cancellation during load/start settle typed first errors and exactly-once resource release; reuse succeeds after completed cleanup. |
| T14-04 | Real model/tokenizer layout/identity validation and T12/T13 integration; corrupt/missing/incompatible assets cannot become usable. No false format success or local manifest/hash bypass; unknown schemas/other formats preserved. |
| T14-05 | Model-use lease survives load/inference/cancel/cleanup; same-key deletion/replacement is blocked or safely rejected. Await-time root/asset replacement cannot redirect SDK use or cleanup to unrelated data. Old cleanup cannot release a new lease. |
| T14-06 | Korean/English map to transcription and selected language. Automatic detection pins once, survives disabled partials, resets between sessions and rejects stale/contradictory results. No invented language on silence. |
| T14-07 | Prompt/context mapping has explicit token/text bounds, nil/reset semantics and no cross-request/session leakage. Temperature, timestamps, partial and compute options are applied or rejected truthfully, not ignored. |
| T14-08 | Nonzero media offset, rounding/padding edge, disabled timestamps, empty speech, NaN/reversed/overlapping/out-of-bounds/oversized backend results map to valid responses or typed failures without dishonest truncation. Offset is applied once. |
| T14-09 | FIFO/capacity/rejected admission, queued/active withdrawal, callback-before-subscription, repeated partials, disabled partials and final/error paths produce one retained terminal per accepted request. External callbacks cannot let new work overtake queued requests. |
| T14-10 | Deterministic cancellation/end/unload races, caller cancellation, delayed/duplicate/stale SDK callbacks and delayed cleanup prove worker join, first-cause preservation and no premature engine reuse. No continuation/task/lease leak on test failure. |
| T14-11 | Ordinary app construction/previews/catalog operations never construct/load/infer/download with SDK. Missing asset paths fail before any SDK network fallback; real denied-network load/inference evidence also exists, including tokenizer independence from global caches. |
| T14-12 | Engine-neutral benchmark input/PCM hash/window plan and report schema round-trip; latency/RTF/warm-up and memory accounting tested with injected clock/sampler/backend results. Input/output errors, cancellation and unavailable metrics are diagnosed without fake success or leaked sampler. |
| T14-13 | Explicit real harness loads the one verified large-v3 package, processes identical short speech repeatedly and after reload, exports actual text/segments/provenance/latency/RTF/memory, and records real offline execution. No mock/upstream-CLI-only substitute, no weights/runtime data committed. |
| T14-14 | All T05–T13 regressions retained, including 49 T13, 33 T12 and 35 T11 baseline selectors. Default full build/test has nonzero actual tests in both original targets and zero failures/skips; heavyweight real runs are separately invoked and truthfully evidenced. |
| T14-15 | Architecture/development/acceptance docs describe actual SDK pin, model/lease/offline/context/cancel rules and reproducible bootstrap/benchmark commands. Observed performance and remaining hardware/accuracy limits are separate; G1/G2 remain unpassed. |
| T14-16 | Task commit/push/final exact-SHA CI pass, tested executable tree matches committed inputs, status/checklist/dev/main unchanged, branch retained. No T15/T16/T17/T18 or recording/STT UI implementation. |

Race tests use acknowledged continuation/barrier handshakes, not sleep, yield/polling or arbitrary repeat quotas. Timeouts are watchdogs. Real benchmark sampling/timing may use a documented timer; it is not a deterministic race-test ordering mechanism. Always release held gates, await workers and stop metrics/backend resources on test failure. Don't modify old tests merely to hide a failure.

## 10. Work order, validation and Phase 1 handoff

Work through pinned dependency/API audit → optional hints and internal backend/format/use-lease boundaries → adapter lifecycle/FIFO/language/time mapping → deterministic contracts/faults → engine-neutral harness → explicit real package/bootstrap/offline run → docs/full validation. State ordinary implementation decisions and continue; don't end at a progress report because some acceptance remains unimplemented. No general engine plugin framework or product-default decision is needed.

Update `docs/ARCHITECTURE.md` when boundaries/interfaces materially change; update `docs/DEVELOPMENT.md` with verified package setup/resolution, exact focused/full and real-harness commands, asset/cache locations and manual limits. Keep `PROJECT_STATUS.md`, checklist and product decisions unchanged. Persist metadata/licenses/resolution/source/tests, not model bytes, real transcripts, private benchmark inputs/outputs, caches, logs, runtime stores or build artifacts. Extend ignore rules narrowly for new generated locations if needed.

After focused checks and actual inference pass, run full unsigned Debug arm64 validation from the final executable tree, for example:

```sh
t14_run="$(mktemp -d /private/tmp/stt-t14-validation.XXXXXX)"
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$t14_run/DerivedData" \
  -resultBundlePath "$t14_run/Full.xcresult" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path "$t14_run/Full.xcresult" --compact
xcrun xcresulttool get test-results tests --path "$t14_run/Full.xcresult" --compact
```

Record actual commands and unit/integration/T14 pass/fail/skip counts, required selectors, result paths and attributable warnings. Report upstream pinned-dependency warnings separately from new app warnings. Verify source/resource/scheme and Package.resolved membership. Use normal permitted Xcode/macOS execution when runner/testmanagerd/cache restrictions block tests; zero execution is not a pass. Real first model load may need a separate documented longer watchdog; do not raise all unit-test timeouts or hide a stuck SDK call.

Review complete task/staged diff, `git diff --check`, dependency/license/data scope, model/worker cleanup and requirement/assertion mapping. Stage only explicit T14 paths and this prompt; preserve unrelated files. Commit on `task/t14-whisperkit-adapter` with T14 in the message, e.g. `feat(stt): add pinned offline WhisperKit adapter and benchmark (T14)`. Confirm source/tests/configuration/experimental manifest and lockfiles match the tested tree; revalidate affected/full/real paths after relevant executable/model descriptor changes. Push only the task branch without force and confirm **that exact final commit's CI**. Prior dev/source CI is not evidence. Fix same-Task CI failures and repeat verification on the new SHA. No circular amendment to insert a commit's own future SHA is needed.

Report **`T14 — review ready`** only when deterministic acceptance, required real-model/offline/benchmark evidence, full validation, commit/push and final-SHA CI are all satisfied. If an actual unresolvable external prerequisite or unsafe product conflict prevents the real run or required work, preserve the branch and report **`T14 — blocked`** with concrete unmet IDs; do not reclassify real inference as optional to claim readiness. Pending G1/hardware/real-lecture comparisons explicitly outside T14 remain unverified.

Final report: starting dev/task/final SHA and exact CI URL/head/result; changed files; package/model/tokenizer pins and license/trust; context/language/options/time mappings; lease/FIFO/cancel/error ownership; exact test names/counts/commands/results; real assets/input/output paths and hashes, actual measured metrics/offline proof and limitations; deviations/manual risks; unchanged unrelated files/status/checklist/dev/main; G1 Unverified and no final engine/model selection. Official completion/integration and whether T15 is safe to start remain the coordinator's independent post-review decision. Keep the task branch available for that review and same-Task repairs.
