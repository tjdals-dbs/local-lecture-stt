# T11 — STTEngine contracts and a deterministic fake engine

## 1. Assignment, user decision, and submission boundary

Implement **T11 only** in `/Users/andyoon/stt`, starting from the latest safe `dev`. The user will run this prompt in a fresh local session; previous conversation history is unnecessary.

Session setting: **GPT-6 Astra / high**, continuing the user's most recently selected implementation setting. Do not switch models or create additional agents automatically.

User decision on **2026-11-13**: **leave G1 Unverified and proceed with T11**. Physical/long-recording checks are deferred. This is an explicit scheduling exception, not a G1 pass, exemption, or authorization to ignore a demonstrated recorder defect. Do not stop merely because G1 is unverified, and do not require a physical microphone/lid test to implement this isolated contract/fake-engine Task.

The result is a **Phase 1 review-ready task branch**: implement, test, review the diff, commit/push the task branch, and verify CI for its final commit. Official T11 completion, checklist updates, `dev` integration, `main` promotion, tags, and branch deletion require later independent review and separate authorization. Do not implement T12 or any other subsequent Task.

## 2. Load only the necessary context

Read in this order:

1. This assignment and `AGENTS.md`.
2. `PROJECT_STATUS.md`, including the 2026-11-13 G1 decision.
3. T11 and the G1 scheduling note in `IMPLEMENTATION_PLAN.md`.
4. `MVP_SPEC.md` sections **8.2, 8.3, and chapter 9**. Inspect an additional section only if a specific contract question requires it.
5. Current Git state and the relevant existing types/code/tests below.
6. Relevant `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT.md`, and logical `BOUNDARY.md` files.

Useful existing code:

- `LocalLectureSTT/Domain/Identifiers.swift`: `SessionID`, `EngineID`, `ModelID`, `EngineIdentity`, `ModelIdentity`, `LanguageCode`, `LanguageMode`.
- `LocalLectureSTT/Domain/DomainPrimitives.swift`: validated `MediaMilliseconds` and related primitives.
- `LocalLectureSTT/Domain/SessionDocuments.swift`: canonical `TranscriptSegment` and session metadata identity fields.
- `LocalLectureSTT/Application/MicrophoneCapture.swift`: owned Float32 interleaved `PCMChunk`/format and separate bounded recording/speech streams.
- Existing Domain tests for validated Codable decoding, shared test scheme, and Xcode source-file registration.

Do not reread all previous Task prompts or the full specification. T10 is already integrated; do not reopen its implementation without evidence of a regression relevant to T11.

## 3. Preflight and coordinator-owned planning edits

Observed baseline when this prompt was written:

- Local branch: `dev`.
- Local/remote `dev`: `73b4a7adaa16a2ff97ff8affda04fe3b99573b0c` (T10 integration).
- `main`: `38e126f92ac823d29306ea8c1f7703f7060a5818`.
- Recorded T10 integration validation: 264 passing tests; this is historical evidence, not a T11 test result.
- Unrelated untracked files: `prompts/T09_FRESH_SESSION_DIAGNOSIS.md` and `prompts/T10_REVIEW_REPAIR.md`; preserve both untouched and unstaged.
- Coordinator planning changes in `PROJECT_STATUS.md` and `IMPLEMENTATION_PLAN.md` explicitly record the approved G1 deferral/T11 authorization.

Before editing, inspect repository root, `git status`, branch, remotes, recent log, and complete existing diff. Fetch/check the latest `dev` safely, without overwriting user work. Use **`task/t11-stt-engine-contract`**. If an existing T11 branch/work is present, inspect it before continuing; do not replace it or discard work. Do not commit feature changes on `dev` or `main`.

**Narrow authorization for the pre-existing planning diff:** carry the coordinator's G1 scheduling changes into the T11 task branch and commit them unchanged with this prompt. They are authorized planning records, not implementation-session completion updates. Do not revert them to make the worktree clean, and do not treat their presence as an unrelated-dirty-worktree blocker.

At prompt creation the two complete file hashes were:

```text
PROJECT_STATUS.md      2c3af0f2225bad58ad99c9d11986fde8db2365ae5871181ec481d31d4ee1fb35
IMPLEMENTATION_PLAN.md 7bd6c99b69a31056e445b56ce1d3648966dba971ca55873d7a788d675ffb04fd
```

Capture and inspect this planning diff before implementation. If these versions are still present, preserve them byte-for-byte through Phase 1. If documents have since legitimately evolved, inspect the new changes and preserve unrelated work; do not overwrite them to match old hashes. This authorization covers only the supplied G1 scheduling decision. **Do not mark T11 complete, check its checklist box, or alter gate results.** The original Phase 1 restrictions otherwise remain in force.

Run the existing baseline build/test once, verify actual nonzero test counts, and record the result before implementation. If a baseline problem occurs, distinguish a code failure from Xcode runner restrictions. An ordinary design choice within this Task does not require another user confirmation.

## 4. Scope and architecture

Deliver:

1. A small library-independent `STTEngine` protocol and semantic lifecycle.
2. Serializable, Sendable engine capabilities, model/session configuration, inference request, partial/final response, identity, and typed failure payloads.
3. A reusable actor-based fake implementing that **same** protocol, with deterministic scripted results, controllable delay/failure/cancellation, and bounded pending work.
4. Tests that prove the contracts and race behavior through the protocol.
5. Requirement/assertion evidence and accurate architecture/development documentation.

Suggested placement, adapting names to actual conventions:

- Foundation-only value types in Domain; orchestration protocol in Application.
- `FakeSTTEngine` in an appropriate Infrastructure/STT location so later adapter/coordinator tests can reuse it. It may compile in the app target but must not be constructed or started by live app composition.
- Manual scheduler/test probes in the narrowest appropriate support location; do not create a general scheduling framework.
- `STTEngineTests.swift` / `FakeSTTEngineTests.swift` in the existing unit target, with actual project source membership.

Out of scope: real WhisperKit/whisper.cpp/Qwen dependencies, model downloads or installation, model selection/benchmarks, actual inference, microphone consumption, resampling/VAD, transcript reconciliation/persistence, recording/UI integration, XPC implementation, plugins, extra processes, or new global singletons. The recent discussion of other models did not select a new product model or authorize additional adapters. The boundary should support future engines without exposing any vendor's types.

Preserve the existing T02 persisted schemas and T05–T10 behavior. Do not make the recorder wait for a fake engine, wire fake results into the UI, write placeholder transcripts, or claim STT is now operational.

## 5. Contract requirements

### 5.1 Boundary and identity

- `STTEngine` itself is Sendable; its payload values are **Codable, Sendable, and Equatable** where meaningful. Protocol existential, stream, task, actor, and scheduler handles are control-plane objects, not serialized payloads.
- No WhisperKit/whisper.cpp/MLX, AVFoundation, Core Audio, AppKit, raw pointer, buffer reference, closure, `NSError`, or filesystem `URL` in the new request/result payloads. Do not redesign the existing documented T03 URL exception.
- Reuse existing engine/model/session/language/time identities instead of inventing parallel string-based domain identities. Include exact model revision/checksum and engine version in the immutable session configuration/result provenance.
- Model loading can accept a value-only model reference/configuration. Actual installed-model lookup, filesystem resolution, and verification belong to T12/adapters; the fake uses synthetic descriptors and never reads disk.
- Give sessions/operations/requests enough identity to associate every response with the accepted request and reject a delayed response after cancellation, end, unload, or a newer session. Do not serialize Task identities or continuations.
- Keep payloads suitable for a future request-based XPC transport without implementing XPC or prematurely introducing persisted schema migrations.

### 5.2 Capabilities and configuration

Represent at least supported input format(s), supported language modes/languages, partial-result support, and timestamp support. Capabilities must describe the implementation honestly; the fake's scripted feature support is not evidence that any real model supports it.

Session configuration pins engine identity, exact model identity, language mode (`korean`, `english`, `automatic`) and relevant value-only inference options. A Korean-mode request can still return English text embedded in its transcript; never translate or strip mixed-language text in the generic boundary. Automatic language mode must allow an initially unknown detected language.

A session uses exactly one model/engine configuration. Reject model/revision/options mutation while that session or its cleanup is active with a typed error, leaving the existing session intact. Ending the session and settling work permits an explicit new configuration; no automatic model switch/update exists.

### 5.3 Owned audio and timestamps

- Requests own their sample data. Do not pass an engine an AVAudioPCMBuffer, pointer, capture stream, or mutable shared storage.
- Existing capture `PCMChunk` and its format are **not Codable**. Do not blindly expose them across the new serializable boundary or retrofit the entire capture pipeline. Introduce the minimum validated inference-audio value, reusing primitives where suitable.
- Document supported sample rate/channel/layout and sample count/duration consistency. A canonical mono Float32 format is sufficient; no audio conversion implementation is required here. Reject unsupported formats explicitly.
- Validate finite positive sample rate, finite samples, matching frame/channel/sample counts, nonnegative time, safe arithmetic, and supported request size. A malformed input must not corrupt lifecycle/queue state.
- Requests carry their session-relative media start and extent. Response segment times use an explicitly documented **session-relative media time** basis, not wall-clock `Date`. Adapters will map native offsets into that basis.
- Reject reversed or out-of-request segment bounds and invalid revisions/order. Test a nonzero request start so a missing offset cannot pass unnoticed. Use declared sample/time rounding, rather than brittle floating-point equality.
- Engine hypotheses are not canonical `TranscriptSegment`s: final means **this inference request is final**, not that T18/T19 reconciled it or T20 persisted it. Do not add editing/canonical/journal behavior to engine results.
- Each partial response clearly replaces or revises the prior hypothesis for the same request; document this as a full snapshot or an equally unambiguous rule. Revisions increase and finality cannot be reversed.

Custom decoding must enforce the same invariants as normal initialization. A round-trip test alone cannot detect synthesized-decoder validation bypasses. Include intentionally malformed JSON decoding tests, using no real lecture material.

### 5.4 Errors and event delivery

Use stable typed error codes for invalid lifecycle/configuration/input, unsupported capability/model, busy/session mismatch, backlog full, load/inference failure, cancellation, and cleanup as actually needed. Retain the first operational cause and distinguish intentional cancellation from operational failure; diagnostics must not replace the first cause or expose arbitrary framework errors.

Choose and document a single termination convention. A suitable contract is: admission/control failures throw a typed engine error before a request is accepted; an accepted request gets a stream of value-only events with **one terminal final/failed/cancelled event**, then stream completion. If another shape is chosen, it must prove the same guarantees without duplicate terminal channels.

- A consumer subscribing after an eagerly completed accepted request must still observe its terminal result. Do not use an unbuffered global broadcaster that silently loses it.
- Document the single-consumer/multiple-consumer policy. Cancellation of one consumer/request must not silently cancel unrelated accepted requests or another session.
- Bound queued requests and event retention, or coalesce partial snapshots while retaining terminal evidence. Do not create an unbounded stream/history to solve delivery.
- End/cancel/unload must settle owned workers/continuations and event streams. A withdrawn consumer cannot be forced to receive more events, but its request must still settle and free owned capacity.

## 6. Lifecycle, bounded work, and ownership

Before coding, write a concise transition table in the acceptance/design document covering load, start, submit, finish/end, cancel, unload, failure, and retry. Choose safe behavior for duplicate end/cancel/unload and test it; do not silently use undefined no-ops for invalid transitions.

Minimum behavior:

- A new engine has no loaded model/session and causes no I/O or background work at construction.
- Start/infer before required preparation is rejected. One active session is allowed; a second start cannot replace it.
- Use one serial worker/FIFO request order for the fake, with a small configurable bounded pending queue. Specify whether capacity includes the active request; test that exact boundary.
- A full queue rejects the new request explicitly without silently dropping accepted work. After completion or queued cancellation, capacity becomes usable again.
- Normal end stops new admissions and settles accepted work under the documented graceful policy. Explicit session cancellation aborts pending/active requests and waits for their owned settlement. Unload safely joins/cancels active work before releasing the loaded state.
- After cancel/end/unload returns, no old callback may publish into or clear the state of a newer session/model/request. An actor alone does not guarantee this across awaits; use operation identity/generation and ownership checks.
- Do not admit a new session/model while old cleanup is unresolved. Caller cancellation and queued/active cancellation must not strand a waiter, lose the first error, double-finish a stream, or leak a queue slot.
- A failed load/start leaves a documented retryable settled state. Repeated load/start/infer/end/unload cycles must work on the same fake instance.

This bounded queue is solely a fake engine's reproducible workload/backlog mechanism. Do not implement the live capture-to-STT backlog controller, transcript journal queue, or T19 coordinator early.

## 7. Deterministic fake scenarios

Provide a small scenario/script representation for:

- Successful load/start and request processing.
- Several partial snapshots followed by a final response with known Korean/English text, language metadata, identities, and timestamp bounds.
- A delayed active request plus queued requests so tests can hold/release processing and observe FIFO/backlog without wall-clock sleeps.
- Typed load/start/inference failures, including a failure after partial output.
- Queued cancellation, active cancellation, end/unload during blocked work, and a delayed old completion after a new operation is possible.

Drive delays with an injected manual/virtual scheduler or equivalent explicit barriers. Advancing logical time must make due events observable through an acknowledgment, not rely on repeated `Task.yield`, polling, or `Task.sleep`. Define ordering for equal deadlines and make script times relative to an explicit processing/session origin. Queued requests must not accidentally consume their processing delay before starting.

Use explicit/injected identifiers and times in determinism tests. Identical scripts, inputs, IDs, and scheduler advances must produce equal event sequences. Do not use random text, wall-clock `Date()`, real model files, microphone permission, network, or real user storage. Constructor/preview tests must not activate the fake automatically.

If a real-time convenience scheduler is useful, keep it optional and outside the payload contract; it is not a substitute for deterministic tests. Prefer the smallest reusable seam over a general simulator or plugin framework.

## 8. Required automated acceptance

Create `docs/T11_ACCEPTANCE.md` with each ID mapped to actual test functions, fixture/barrier, exact assertions, and execution evidence. Do not claim a row from a method name, comment, or generic green suite alone.

| ID | Required observable proof |
| --- | --- |
| T11-01 | The fake is used through `any STTEngine`; compile-time Codable/Sendable coverage and round-trips preserve every boundary payload/identity; new contracts expose no vendor/framework objects. |
| T11-02 | Invalid initializer **and malformed decoded** configuration/audio/time/response values are rejected; overflow/nonfinite/mismatched samples cannot enter accepted work or change active state. |
| T11-03 | Capability/language handling rejects unsupported requests and preserves Korean text with embedded English, automatic-mode unknown/detected language, and configured provenance. |
| T11-04 | Lifecycle transition tests cover infer/start before load, duplicate/concurrent start, failed preparation retry, normal end, cancellation, unload and repeated cycles with no residual owned work. |
| T11-05 | Mid-session model ID/revision/checksum/configuration changes are rejected without changing that session; after settled end, a new session can explicitly use another model. |
| T11-06 | Scripted partials revise one request in order, final occurs once, and no later partial/terminal is accepted. Nonzero request media offsets and result bounds follow the documented time basis. |
| T11-07 | Manual time/barriers prove output is absent before its due boundary and exact afterward; the same script runs yield equal events without sleeping or scheduler luck. |
| T11-08 | Full bounded queue rejects only the new request; accepted work remains FIFO; queued cancellation frees capacity; completion/end leaves no pending worker/continuation. Assert order, capacity, identities and output, not just call counts. |
| T11-09 | Cancelling queued/active work, withdrawing a consumer and cancelling during load/cleanup settle ownership; new admission is held/rejected until settlement. Exactly one terminal outcome survives cancellation-vs-final/failure races. |
| T11-10 | A held old response/cleanup cannot affect a newer request/session/model after retry. Inject the stale completion at an acknowledged boundary and assert newer identity/output remain unchanged. |
| T11-11 | An eagerly completed request retains its terminal evidence for a late subscriber; operational failure after partials preserves the first typed cause; no stream or cancellation hangs. |
| T11-12 | No fake composition, real inference dependency, network/disk/microphone access, capture behavior change, or transcript placeholder is introduced. Full existing unit/integration suite and final-commit task CI pass. G1 remains unverified and T11 remains unchecked. |

Exercise errors/cancellation through the same fake worker and lifecycle used by success tests; a second independent toy implementation is not proof. Tests use bounded watchdog timeouts and release all held gates/tasks on failure. Await actor values into locals before XCTest assertions.

## 9. Validation and documentation

During implementation run focused tests after each coherent change. After all executable changes, run the complete unsigned arm64 Debug build/test once with isolated output paths, for example:

```sh
t11_run="$(mktemp -d /private/tmp/stt-t11-validation.XXXXXX)"
xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$t11_run/DerivedData" \
  -resultBundlePath "$t11_run/Full.xcresult" \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test

xcrun xcresulttool get test-results summary --path "$t11_run/Full.xcresult" --compact
xcrun xcresulttool get test-results tests --path "$t11_run/Full.xcresult" --compact
```

Use exact existing/new selectors for focused runs and fresh result names. Confirm successful build, nonzero executed tests in **both targets**, all new tests included in the shared scheme, zero failures/unexpected failures/skips, and no new attributable compiler warnings. The historical 264 is not a required final count; report the actual result.

Xcode helper `testmanagerd` sandbox failures, inaccessible result caches, unknown counts, and zero executions are environment failures, not passes. Retry using the permitted normal macOS Xcode/approval path; do not disable/skip tests or claim a blocked runner proves correctness.

Concurrency proof comes from explicit gates/scheduler acknowledgments. T10's eight-tests-times-twenty requirement does **not** carry over to T11. Re-run targeted races as needed after a failure/change and report actual repetitions; do not repeat the entire suite without a changed tree or unresolved concern.

Update `docs/ARCHITECTURE.md` with actual contract shapes, value/control-plane boundary, lifecycle table, time basis, model pinning, event/terminal policy, fake scheduling/backlog ownership and future adapter/T19 seams. Update `docs/DEVELOPMENT.md` with real targeted/full commands and fake scenario use. The new acceptance document records automated evidence; physical G1 remains unverified and is not a T11 submission requirement.

## 10. Diff review, commit, push, CI

Continue through Phase 1 submission after local acceptance succeeds:

1. Inspect the full task-branch diff, working diff, `git diff --check`, and staged diff. Preserve unrelated work and confirm no generated/runtime/user data is staged.
2. Stage explicit T11 source/test/project/doc paths, this prompt, and **only the pre-authorized unchanged coordinator planning edits** from section 3. Do not alter status/checklist to claim T11 completion.
3. Commit on `task/t11-stt-engine-contract`, including T11 in the message, e.g. `feat(stt): add engine contracts and deterministic fake (T11)`.
4. Ensure the committed source/tests/configuration match the locally tested executable tree. Documentation-only additions may be identified as such; executable changes require affected and full validation again.
5. Push only the task branch without force. Verify a successful GitHub Actions run whose `headSha` equals the final task commit, including actual build/test job execution. CI is checked after commit/push; it is not a circular prerequisite for creating that commit.
6. Repair same-Task CI failures, rerun affected validation, push, and check the new final commit. Do not use an older commit or `dev` run as evidence. Do not amend just to write a commit's own future SHA/CI link into a document.
7. Stop with the branch available for independent review. Do not merge/push `dev`/`main`, delete the branch, change G1 results, check T11 complete, or begin T12.

Keep making progress through implementation/test failures within this Task. A real product conflict, unresolvable external dependency/runner issue, conflicting concurrent work, or an unsafe action requiring new authority can justify `blocked`; unfinished ordinary work alone does not.

## 11. Final handoff

Report **`T11 — review ready`** only when all local acceptance, commit/push, and CI for that final commit succeed. Otherwise report **`T11 — blocked`** with the exact cause and unmet IDs; preserve all work.

Include:

- Starting `dev`, branch, final task commit, CI URL/run ID/head SHA/result, and unchanged `main`/`dev` refs.
- Changed files and concise contract/lifecycle/time/terminal/model-pinning/queue design.
- `T11-01`–`T11-12` → real test/assertion mapping or acceptance-document link, exact commands/result paths, actual unit/integration pass/fail/skip counts, and any targeted repetitions.
- Confirmation that the coordinator G1 decision was carried unchanged, T11's checklist remains unchecked, and the two unrelated prompts were preserved.
- Deviations/remaining risks and explicit boundaries: no actual STT/model integration; G1 physical checks still **Unverified**.
- Official T11 completion, integration and next-Task readiness remain the coordinator's independent post-review decision.
