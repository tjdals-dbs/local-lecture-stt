# T15 — whisper.cpp experimental adapter on the shared benchmark

## 1. Assignment and authorization

Implement **T15 only** in `/Users/andyoon/stt`, in a **fresh implementation session**, using the user's retained implementation setting **Astra / high**. Previous chats are unnecessary. Do not switch models or spawn additional agents automatically.

T14 and its separately authorized dev integration have been independently verified. This prompt supplies the separate T15 assignment anticipated by `PROJECT_STATUS.md`. **G1 remains Unverified; G2 remains pending/unpassed.** G1's accepted deferral does not block this isolated adapter Task. Do not claim hardware, real-lecture accuracy or complete live STT verification.

Deliver **Phase 1: review-ready task branch**: implementation, meaningful automated tests, real installed-model inference/offline evidence, documentation, task commit/push and successful CI for the final commit. **No official Task completion, `PROJECT_STATUS.md` or plan-checklist changes, dev/main integration or push, task-branch deletion, release/tag, T16 comparison/selection or later Task implementation is authorized.** Independent coordinator review and a separate integration prompt follow.

## 2. Context and preflight

Read in order:

1. This prompt and `AGENTS.md`.
2. `PROJECT_STATUS.md`.
3. T15 in `IMPLEMENTATION_PLAN.md`; T11–T14 and T16–T18 only for dependencies and boundaries.
4. `MVP_SPEC.md` **9.1, 9.2, 17.1, 17.5**; **9.3, 9.4, 8.3, 15.1–15.4, 17.7** as needed for provenance, language, model authority and offline constraints.
5. Actual Git state/code and relevant architecture/development/acceptance sections.

Observed baseline at prompt creation, to recheck rather than assume:

```text
branch: dev
dev/origin/dev: 59690f3dee5e21330e3ac60646b3da51d0dbd433
main/origin/main: 38e126f92ac823d29306ea8c1f7703f7060a5818
latest integrated Task: T14
verified baseline: 423 passed (413 unit + 10 integration), zero failed/skipped
T14: 42 selectors (32 engine + 10 SDK boundary); T13: 49; T12: 33; T11: 35
dev CI: https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43621013039
```

Inspect status, branches, remotes and recent log before editing. Safely fetch/check latest dev and create **`task/t15-whisper-cpp-adapter`** from it. If dev moved, inspect/incorporate the new baseline safely. Preserve unrelated WIP/untracked files, especially `prompts/T09_FRESH_SESSION_DIAGNOSIS.md` and `prompts/T10_REVIEW_REPAIR.md`, untouched/unstaged/uncommitted. No destructive cleanup/reset/discard, stash, broad staging or force-push. This prompt may be untracked and is an in-scope T15 document.

Run one baseline full build/test before source edits and record actual counts. Historical 423-pass evidence is not a new execution. Read these existing implementations before introducing alternatives:

- `Application/STTEngine.swift`, `Domain/STTContracts.swift`, `FakeSTTEngine.swift` and their tests: immutable sessions/requests, owned bounded PCM, retained terminal feeds, FIFO/end/cancel/unload semantics. `STTDecodingHints` **already exists**; do not recreate it.
- `WhisperKitSTTEngine.swift`, `SDKWhisperKitBackend.swift` and T14 SDK-boundary tests: genuine SDK calls, checked language detection/context limits, generation guards and joined cleanup.
- T12/T13 `FileModelRepository`, `ModelPackageFiles`, `ModelUseLease`, model delivery/download services and validators: verified installation, pinned identity, claims, no-clobber publication, scope and lease ownership.
- `Domain/STTBenchmark.swift`, `Application/STTBenchmarkRunner.swift`, benchmark output, `tools/t14/BenchmarkMain.swift`, candidate/bootstrap metadata and `offline.sb`: the shared input/result schema and current CLI assumptions.
- Xcode project/shared scheme, root `Package.swift`, both committed package resolutions and `.github/workflows/macos-ci.yml`. Xcode uses explicit source/resource membership; the root Swift package currently builds the developer benchmark and includes Infrastructure sources.

## 3. Scope and deliverables

Implement a real whisper.cpp adapter behind `STTEngine`, a pinned native dependency/bridge, a real GGML candidate validator/install manifest, existing model-use lifetime protection, the same public input/output/language/context/cancellation contracts as T14, and shared benchmark support with actual local inference evidence. A small internal C/C++ or Swift bridge and deterministic native-backend seams are in scope.

Keep the adapter experimental and explicitly invoked. Ordinary app construction, recording and previews must not load/download/infer. No model UI, capture/STT wiring, T18 VAD/overlap/live transcript reconciliation, canonical transcript writes, product audio import, summaries, diarization or system audio. Do not select the product engine/model, remove WhisperKit or implement T16/T17 early. Developer-only model/PCM preparation is allowed and is not a new product workflow.

**Mocks alone, an upstream executable's output alone, conditional stubs, skipped missing-model tests or a wrapper that never calls the native library are insufficient.** The developer harness must exercise this adapter through `STTEngine`.

## 4. Pin and integrate the actual native dependency

Verify canonical upstream identity, license, macOS 15/arm64 compatibility and exact released source. At prompt preparation, upstream lists **v1.9.5**; treat it as a candidate to verify, not a floating latest requirement. Select one compatible release and record its tag plus full 40-hex source revision. Inspect the actual headers/implementation for that pin before designing the bridge.

Choose **one reproducible route** usable by both Xcode and the developer CLI: preferably an official release XCFramework through a small local SwiftPM wrapper with a fixed URL and verified SHA-256, if its macOS slice/Metal resources/C ABI are suitable; otherwise a minimal build from exact pinned source with documented fixed options. Do not assume the upstream repository itself exposes a consumable root Swift package. An upstream README's older binary-target example is not the current pin or checksum.

- Pin artifact URL/checksum, source revision, wrapper/build recipe and effective native engine identity. Preserve existing WhisperKit/transitive pins unless a demonstrated compatibility conflict requires an explained minimal change. Commit applicable package resolutions. No branch/latest dependency or runtime update checks.
- Compile/link the real library in the app/tests **and** CLI. CI must reproduce this without a developer's Homebrew paths, preinstalled local library or uncommitted build directory. Native library downloads/builds are distinct from model acquisition; default CI must not download weights or run large-model benchmarks.
- Use the ordinary Apple Silicon Metal/Accelerate route where supported. Do not add a separate Core ML encoder/conversion pipeline or extra model family. Record requested/effective acceleration, thread policy, precision and relevant build flags; do not label CPU fallback as verified Metal execution. Unsupported settings fail explicitly or have a documented visible fallback policy.
- Package all required native resources/metallib/shaders correctly for app and CLI. Source-tree-relative resources must not make a local build falsely pass. Run the real CLI from a working directory outside the repository. Keep generated native binaries, caches and build output ignored/outside Git; do not commit a built XCFramework or vendor the full upstream repository.

Primary references, to recheck at the chosen immutable revision and cite in implementation documentation:

- [Official releases and artifacts](https://github.com/ggml-org/whisper.cpp/releases).
- [Public C API at v1.9.5](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/include/whisper.h).
- [Native inference implementation at v1.9.5](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/src/whisper.cpp).
- [Official build and Apple packaging guidance](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/README.md).
- [Model format/acquisition documentation](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/models/README.md) and [official converted model repository](https://huggingface.co/ggerganov/whisper.cpp).

## 5. One real candidate package and verified model lifetime

Prepare **one non-quantized large-v3 GGML candidate**, compatible with the chosen pin, normally `ggml-large-v3.bin`. Verify the actual architecture/precision/format; do not assume GGUF or reuse/rename T14 Core ML bytes. Standard mixed F16/F32 storage should be described accurately. No silent substitution of tiny/base/medium/turbo/quantized weights to finish faster. Record timings honestly even when they miss the provisional targets.

This assignment authorizes **one explicit developer bootstrap** to obtain that candidate and required license/metadata if no matching verified local package exists. Use ignored/disposable storage outside Git, public authoritative immutable metadata and the existing T12/T13 verified import/download path. Do not request credentials or add SDK/runtime automatic downloads. Reuse a verified candidate when available; no model collection or conversion project.

Commit a fixed experimental descriptor/delivery catalog and reproducible bootstrap instructions with source revision, exact file size/SHA-256, format/precision and license provenance. Keep the production catalog empty and T14's candidate unchanged. The native candidate and WhisperKit candidate must coexist under distinct identities. A 40-hex checksum in an upstream model table is **not** a SHA-256: obtain the actual published LFS/file SHA-256 or explicitly document the checksum's acquisition/trust provenance without mislabeling it. Do not invent expected values after an arbitrary untrusted download.

Implement a strict whisper.cpp-specific `OfflineModelFormatValidating` path, selected explicitly by engine/format. Keep the existing WhisperKit validator strict. Validate manifest/checksum, bounded native header/architecture/type information, required layout and compatibility; a matching extension or magic alone is insufficient. Reject malformed/truncated/unsupported content before handing it to an assert-prone native parser. Stream hashes/reads rather than copying several GB into a Swift `Data`. Verify which tokenizer/vocabulary data is embedded or separately required by the actual format; no dependency on a global WhisperKit tokenizer cache.

Reuse `ModelUseLease` and repository claims. Hold the verified installation through allocation, actual native load/decode, cancellation, callback settlement and final cleanup; prevent same-key delete/replace until release. Failed/cancelled loads must release exactly once after real work settles and then allow retry. A path-based loader must preserve the original trusted identity through actual I/O; use pinned file/loader support where required by the existing ownership policy. Never recapture a replacement path as a new trusted baseline. Do not modify installed weights or delete user sources/T14 installations/session data. No recursive claim acquisition during validation/load.

## 6. Native boundary, memory ownership and cancellation

Keep all native pointers, C structs/enums, callbacks, library imports and unsafe resource handles in Infrastructure or its internal bridge. Existing Domain/Application payloads remain framework-independent, Codable and Sendable. Give whisper.cpp its own truthful engine identity/revision/format/settings; do not impersonate WhisperKit to bypass its checks. A small shared orchestration extraction is allowed only when necessary and regression-tested; do not broadly rewrite the approved T14 adapter.

Use one owned native context/state with serialized access on an appropriate native executor. Synchronous C inference must not block MainActor or monopolize Swift's cooperative executor merely because it sits inside an `async` function. Verify thread-safety of the pinned API; do not run concurrent calls against one context. Avoid process-global mutable callbacks that couple adapters.

Make ownership explicit and testable:

- PCM buffers, prompt tokens, strings and callback user-data remain owned until the native function and every callback using them have finished. Do not let `withCString`/buffer pointers escape their valid scope, pass actor-isolated state unsafely to a foreign thread or send borrowed C strings/pointers through an asynchronous actor hop. Copy response text/times into owned values while valid.
- Allocate/free native context/state and callback boxes exactly once, including partial initialization failure. A Swift task's cancellation/continuation return is **not** proof that C work stopped. Retain userdata/context/model lease until actual return and join callback-consumer cleanup before publishing terminal settlement or enabling reuse.
- Use a thread-safe operation-owned cancellation flag and the pinned native abort/encoder hooks as supported. Check their actual Boolean polarity and return-code behavior. Do not read `Task.isCancelled` from a foreign callback as the cancellation mechanism. An abort may require interpretation beyond a nonzero return code; cancellation must not become a successful empty transcript.
- Distinguish requested cancellation from allocation/decode/language/response errors and preserve the first operational error plus cleanup diagnostics. If a GPU/native step only stops at a later checkpoint, measure/document that limit and wait safely. Do not claim instant interruption, free early, or create artificial partials/delays to demonstrate cancellation.
- Callback delivery is bounded and ordered. Native segment callbacks may supply provisional request snapshots, but progress/hints/control tokens are not recognized text. Accumulate the complete replacement hypothesis rather than publishing only the latest segment. Terminal publication waits for all owned callback processing; stale-generation callbacks cannot mutate a new request/session, while their resources still live until the old call settles.

Add a narrow production native-backend seam for deterministic faults/held completion, not a second implementation used only by tests. Include model-free tests against the **linked real C ABI** where practical (default parameters, language/token API availability and bridge parameter layout/callback wiring). A fake seam alone does not prove the C bridge passes options or retains pointers correctly; real model evidence must exercise that bridge too.

## 7. Public contracts, language, context and timestamps

Preserve T11/T14 behavior: immutable model/session/options; canonical owned 16 kHz mono Float32 input within existing bounds; checked sequence/session validation before mutation; a bounded FIFO (default pending capacity 2), typed `backlogFull`, one retained terminal per accepted request and no work/feed for rejected admission. Advertise only implemented capabilities. Never relax response validation to accommodate native output.

`end()` closes admission and drains accepted work; `cancel()` cancels the session; feed withdrawal cancels only that request and preserves the remaining FIFO. `unload()` joins loading/decode/callback/cleanup work before releasing resources. Concurrent end/cancel/unload, cancellation of their callers and held cleanup must join the engine-owned operation rather than double-free, abandon a lease, permit early start/load or strand a waiter. Guard every asynchronous/native completion by operation generation/request identity. Tests must include the T14-style end–unload and cancel–unload cleanup overlaps, with control-caller cancellation.

Korean/English select transcription (`translate=false`) and the selected language consistently. Automatic mode must use checked native detection evidence on the first suitable request, pin a valid language for the session and reset only for the next session. Negative detection results/invalid IDs cannot become English success; silence may remain undecided. Detection must work with partial publication disabled. **At v1.9.5, `detect_language=true` can return after detection without transcription**; verify your pinned implementation and do not treat detection-only success as completed recognition. Detection work belongs in reported inference time.

Reuse `STTDecodingHints.promptText` (already bounded to 4096 UTF-8 bytes, optional/backward-compatible). Map it using the native tokenizer with checked capacity/return conventions and the actual model's context budget. Reject oversized hints explicitly before decode; do not silently truncate/drop the prompt. T14's 111-token limit is SDK-specific, not a universal whisper.cpp constant. Test the chosen native boundary, multibyte text, absent/empty hints and two consecutive requests/sessions. Clear implicit native history so previous recognized text/prompts cannot leak into a new request with absent hints. No hidden cross-request history, vendor token IDs in Domain or arbitrary option dictionaries.

Map temperature/timestamps/compute settings to actual native parameters; record decoding strategy/fallback policy and reject unsupported values instead of silently ignoring them. Validate native integer conversions, sample counts/thread limits and bounds. Preserve `partialResults=false`, valid empty final results and current aggregate response limits.

Verify native timestamp units at the chosen revision and convert with checked arithmetic/rounding to session-media milliseconds, adding `request.context.mediaStart` **once**. Test a nonzero offset, boundaries, overflow, negative/reversed/out-of-range times and any documented small padding tolerance. Preserve text order and valid nonoverlapping intervals without silently discarding text. With timestamps disabled, use the existing truthful whole-window representation. Native segment granularity is acceptable for this interval adapter; sentence reconciliation is later T18 work.

## 8. Shared benchmark and real offline inference

Reuse **`STTBenchmarkInput` / `STTBenchmarkReport` and `STTBenchmarkRunner`**. Do not fork a whisper.cpp-specific schema or duplicate the benchmark logic. Minimally extend the CLI's engine/validator factory and accurate provenance where currently hardcoded to WhisperKit; preserve existing T14 `prepare/import/run/cancel` invocations and report decoding. No second executable main accidentally included by the root package. Existing format versions may change only if necessary with explicit compatibility tests, not for an engine-name field already present.

T14's canonical reusable input was verified present when this prompt was prepared:

```text
/private/tmp/stt-t14-assets/input.json
caseID: local-samantha-v1
PCM: 112640 frames, mono Float32, 16000 Hz, 7.040 seconds
pcmSHA256: 319c127d3e77fc3d425cd93a78d6df167e3c6fdfc9daa8ea26748a1aace42a88
sourceSHA256: a851e66db61c798f7ea34c1cc775a78fc078d4b202cd45a0260670cd5a662424
mediaStart: 5000 ms; mediaEnd: 12040 ms
```

Reuse the **actual serialized samples**, validating the canonical little-endian Float32 digest, not just the case name/duration. If this temporary file is gone, T14's preserved reports also embed the full input; search the documented evidence directories and hash-check a recovered copy. Independent reports were `/private/tmp/stt-t14-independent.zMaYO3/AutomaticOffline/report.json` and `CancelReuseOffline/report.json`. If no exact copy survives, prepare one new non-private synthetic input and run **both** adapters on that identical input, clearly labeling the new case. Regenerating TTS and claiming the old input hash is invalid. Do not commit audio/PCM/report assets.

Use identical PCM/windows/hints/language/temperature where comparable, with explicitly recorded backend-specific decoding/compute settings. Preserve T14's original settings when reusing its evidence. Execute engines sequentially with cleanup between them; different model-package hashes are expected because formats differ. Record one warmup and at least two measured successful whisper.cpp repetitions, monotonic load/preparation/queue/infer/final/first-partial timing, RTF (`infer / input duration`), memory and actual transcript/timestamps in the shared JSON plus readable output. Report missing metrics as unavailable, not invented zeroes. Native segment-callback first partial and WhisperKit token-callback first partial have different granularity; document this and do not present them as identical token latency.

Retain the existing physical-footprint measurement definition and its limitations, including incomplete attribution of GPU/ANE allocations. Do not replace it with a differently defined metric while calling the reports directly comparable. The one small synthetic smoke is not the T16 lecture comparison, an accuracy score or a G2/performance pass.

Required **actual** evidence through this adapter:

1. Explicitly bootstrap/import the real candidate using the verified repository. Repeated normal inference must yield nonempty speech text, valid intervals and truthful model/native/input/settings provenance.
2. Repeat installed-model inference under process-scoped **OS network denial** and fresh disposable user/cache roots. Reuse/adapt `tools/t14/offline.sb`; do not change the user's network configuration or real home/cache. Native model/vocabulary/resources must be sufficient offline, including automatic language detection.
3. Cancel while the real native inference call is active, observe its cooperative abort/settlement, join cleanup and successfully run a fresh request/session afterward. Queued cancellation or cancellation after native return is insufficient. A narrow developer-only acknowledged entry/abort observation is acceptable; do not fabricate text or sleep to force a race. If the shared short sample finishes before cancellation, use a separately labeled non-private cancellation input with its own hash. Report checkpoint-limited cancellation honestly.
4. Missing/truncated/corrupt asset cases must fail locally with typed errors, no downloader/network fallback and no deletion of originals. Separate disposable copies from the good installation. Execute a real inference from a non-repository working directory to prove native resources are packaged correctly.
5. Preserve existing WhisperKit adapter tests and old CLI invocation behavior. If shared executable/orchestration/runner behavior changes, rerun at least one short real WhisperKit case with its verified T14 package and the same input/settings. Reuse the existing installed T14 package rather than downloading it again. No comparison winner is required.

Default CI stays weight-free but compiles/links the actual native bridge and tests its deterministic contracts. Keep real evidence outside Git; commit reproducible commands, pins, case hashes and concise results in acceptance docs. Explicit real-model runs are mandatory for review-ready, not a manual item deferred merely because default CI excludes weights.

## 9. Acceptance matrix — trace requirements to assertions

Create `docs/T15_ACCEPTANCE.md` mapping each row to exact test selectors/assertions, production code and actual result/evidence locations. Mark failures/missing work truthfully. Comments, scenario names, a skipped test or a green aggregate count do not establish the assertion.

| ID | Required evidence |
| --- | --- |
| A01 | Exact source/artifact pin/checksum/license; actual C ABI compiled and linked by both Xcode and CLI; native resources independent of repository CWD. |
| A02 | Existing Codable/Sendable contract and old benchmark/CLI compatibility; no vendor/C/unsafe handle escapes Infrastructure. Own truthful engine identity and capability/settings validation. |
| A03 | Real native-format/header/architecture/precision validation plus existing hash/install policy; malformed/truncated/unsupported packages rejected; T14 package remains usable and production catalog remains empty. |
| A04 | Successful/failed/cancelled native creation; exact-once context/state/userdata cleanup; leased model cannot be deleted during load/decode/held cleanup and becomes available only afterward. Original trusted identity is preserved. |
| A05 | Production bridge passes real native parameter/callback layout and owned PCM/prompt/string lifetimes correctly; model-free linked-ABI tests plus real-model bridge evidence, not only mock option inspection. |
| A06 | Active native cancellation observed; return/abort/error mapping preserves first failure; callback work and lease release joined; cancelled control caller cannot abandon cleanup; later successful reuse. |
| A07 | ko/en transcribe mapping, checked automatic detection/pinning/reset, silent/invalid/negative detection, partials disabled and detection-only API trap. No fabricated language fallback. |
| A08 | Optional hints absent/empty/multibyte/boundary/overbudget; actual native token-capacity semantics and no silent suffix loss/history leakage across requests or sessions. |
| A09 | Actual native timestamp units and nonzero media offset exactly once; ordering/bounds/overflow/disabled timestamps/response-size error handling. Replacement snapshots retain all recognized segments. |
| A10 | Bounded FIFO/backlog, rejected admission, wrong session/sequence, retained exact-once final/failed/cancelled terminal, latest partial, no-partials/empty final and stale callbacks. |
| A11 | Queued/active withdrawal affects only its request; end drains; cancel/unload overlap; held load/decode/callback/cleanup gates prohibit premature reuse/free and settle every waiter exactly once. |
| A12 | Native parameter mapping for temperature/timestamps/compute/threads, checked conversions and unsupported options; actual requested/effective settings in reports. No app-start/previews/network activation. |
| A13 | Same canonical PCM hash/windows and shared result schema/RTF/memory method; output preservation; warmup versus measured separation; old T14 CLI and affected shared-runner paths verified. |
| A14 | Real large-v3 normal repeated inference, OS-denied offline/fresh-cache auto-language run, active native cancellation/reuse, local missing/corrupt negatives and packaged native resources. Commands and actual reports recorded. |
| A15 | Full current build/test and targeted native-adapter tests pass with actual nonzero counts; preserve T11/T12/T13/T14 regressions. Genuine real-model evidence is separate from weight-free automated CI. |
| A16 | Architecture/development/acceptance/license records accurate; final task commit pushed and exact-commit CI succeeds; protected status/checklist/dev/main untouched; no gate/default-selection/completion claim. |

Use acknowledged deterministic barriers for load/decode/callback/native-return/cleanup races. Await the actual acknowledgement before advancing the test. `Task.sleep`, busy polling, arbitrary yields, high retry quotas or success after a timeout are not evidence; a watchdog may only fail a hung test. Do not weaken/delete existing tests or add tests that merely mirror helper implementations. Native safety assertions must exercise the same bridge/orchestration used in real execution.

## 10. Documentation and verification

Update only relevant parts of `docs/ARCHITECTURE.md` for the actual bridge/executor, resource ownership/cancellation, model/vocabulary trust, validator composition, language/context/time mapping and shared benchmark selection. Update `docs/DEVELOPMENT.md` with verified dependency/build/bootstrap/import/run/offline/cancel commands, pin/resource prerequisites and manual limits. Record licenses/third-party notices for committed wrapper/native dependency and model metadata as appropriate. Do not copy the entire spec into these docs or rewrite historical T14 results as T15 measurements.

Use a unique validation directory outside Git, e.g. `mktemp -d /private/tmp/stt-t15-validation.XXXXXX`, and preserve evidence paths. Adapt package-resolution steps to the new committed pin; do not blindly reuse a T14 cache or disable resolution before the new dependency has been resolved. The representative full verification command is:

```sh
t15_validation_dir="$(mktemp -d /private/tmp/stt-t15-validation.XXXXXX)"
xcodebuild \
  -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$t15_validation_dir/DerivedData" \
  -resultBundlePath "$t15_validation_dir/Full.xcresult" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
```

Record the expanded validation path; use a fresh result bundle for each execution. Build the root benchmark with a unique `swift build --scratch-path ...` path, then run documented old/new CLI commands. Inspect `xcresulttool` summary **and test tree** for actual unit/integration/new-adapter/T14/T13/T12/T11 pass/fail/skip counts, rather than copying the baseline count. A command exiting successfully with zero selected tests is not a pass. Run the full suite after final source changes; rerun affected checks after any later repair. If unrelated baseline tests fail, preserve the failure and diagnose without silently disabling/changing their behavior.

Do not add model downloads to CI. If needed, minimally extend CI to build the real native-enabled CLI in addition to the existing app/test checks. Confirm both build routes and pinned artifacts work cleanly, including shader/resource membership. Do not introduce broad CI/recorder refactors.

## 11. Phase 1 delivery and final report

Work autonomously through ordinary implementation/debugging/test failures. Incomplete tests/docs or an untried native integration route are work to finish, not a reason to stop with another progress-only report. If a genuine external blocker or specification conflict prevents safe progress, preserve work and report the exact evidence plus recommended resolution under `AGENTS.md`; do not claim review-ready or ask to change already-authorized scope merely because the Task is substantial.

Before commit, review the complete branch diff and explicit staged diff. Stage only T15 source/tests/bridge/package/project/CI/metadata/docs and this prompt. Do not stage historical untracked prompts, real weights/media/PCM/transcripts/reports, runtime stores/DBs/caches/logs/build artifacts or secrets. Verify `PROJECT_STATUS.md`, the plan checklist, dev and main remain unchanged. Commit with T15 in the message, push **only** the task branch and verify successful CI for the **final exact SHA**. Any fix requires a new final-SHA validation/CI check; an earlier green run is insufficient. Keep the branch available for independent review; do not merge/delete it or create a PR.

Report **T15 — review ready** only after all required evidence passes; otherwise **blocked**, with the actual unmet condition. Include branch/final SHA/exact CI link, changed files/design decisions, native source/artifact pin and checksum, model revision/format/checksum/license, canonical PCM hash/settings, exact test commands/counts, real offline/cancellation/reuse report paths and measured results, deviations/known limits and any manual checks still pending. Distinguish deterministic tests, actual native inference, short-smoke performance and unperformed hardware/lecture checks. G1 stays Unverified; G2 and default engine/model selection stay pending. Whether T16 is safe to start remains the coordinator's post-review decision.
