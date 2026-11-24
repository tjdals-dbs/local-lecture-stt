# Local Lecture STT Project Status

- Status document version: 1.0
- Last updated: 2026-11-25
- Specification baseline: `MVP_SPEC.md` 1.0, confirmed
- Implementation plan: `IMPLEMENTATION_PLAN.md` 1.4

## Current position

- Current milestone: M4 product UI. M3 real-time STT and canonical transcript tasks are complete.
- Next Task: T21 session list, new recording and model management UI.
- Latest completed Task: T20 canonical transcript and derived text/Markdown files, independently reviewed and squash-integrated into dev.
- Latest passed gate: G2 engine and model selection, approved on 2026-11-15 at dev `f6ba18d`
- The recording app uses pinned whisper.cpp with verified non-quantized large-v3. After capture and speech settlement, it compacts the journal to canonical JSON, generates TXT/Markdown, and completes metadata/catalog publication. T18 segment order and times are preserved; healthy completed sessions verify on read-only roots, while missing/stale exports require repair. Text-only editing is available through the repository API; model management UI is T21 and playback/editing UI is T23. [Architecture](docs/ARCHITECTURE.md#t20-canonical-transcript-and-derived-files) · [Engine and model decision](docs/T16_ENGINE_MODEL_DECISION.md)

## Repository state at this handoff

- Remote: private `origin` is connected to `https://github.com/tjdals-dbs/local-lecture-stt.git`
- GitHub default branch: `main`
- Approved T20 source on `task/t20-canonical-transcript`: `51a452d4bf323d42f6c6c758ae949cfe0436d99c`. The user accepted the independent review and authorized Phase 2 integration on 2026-11-25 with G1 unverified.
- `dev` integration base: `672688b8ca4cbb659f8f189419350398048bd937` (T19). The delivery handoff identifies the resulting T20 integration commit, its local validation, its exact-commit CI and branch cleanup.
- `main` and `origin/main`: preserved at the verified T01 baseline `38e126f92ac823d29306ea8c1f7703f7060a5818`
- `main` policy: only buildable and runnable verified versions
- `dev` policy: integration branch for completed Tasks
- Task policy: one fresh implementation session and one `task/tNN-*` branch per Task; the same session handles review fixes and later authorized integration
- Review policy: implementation sessions stop at a task-branch CI-backed review candidate; this coordinator independently approves before any completion status or `dev` integration
- Pull Request policy: no PR for normal Tasks; independently reviewed work is locally squash merged into `dev` only through a separate integration prompt

The actual Git status and remote state must be rechecked at the start of every task. This snapshot is informational and must not override Git.

## Completed work

| Work item | Result | Verification |
| --- | --- | --- |
| Product and technical specification | Confirmed in `MVP_SPEC.md` | User approved specification 1.0 |
| Implementation breakdown and priorities | Defined in `IMPLEMENTATION_PLAN.md` | T01~T27 and G1~G4 documented |
| Repository remote | Created and connected by user | Local `origin` inspected |
| V00 repository baseline | Complete on `dev` | Approved files, ignore policy, and `origin/dev` verified |
| T01 macOS project and module boundaries | Complete on `dev`; first `main` baseline created from the same verified commit | Xcode 26.6 unsigned arm64 Debug build, two smoke tests, manual app launch, and `task/**`/`dev`/`main` CI |
| T02 domain model, schemas, and state machine | Complete on `dev`; `main` remains on the verified T01 baseline | Domain DTO and transcript journal round-trips, lifecycle/checkpoint rules, unsigned arm64 Debug build, 17 unit tests, integration smoke test, and task/dev CI |
| T03 file repository and root folder permission | Complete on `dev`; `main` remains on the verified T01 baseline | Bookmark registry/access lifecycle, active/historical root catalog, session layout, atomic JSON, JSONL append, 38 unit tests, integration smoke test, unsigned arm64 Debug build, and task/dev CI |
| T04 SQLite session catalog and filesystem reconciliation | Complete on `dev`; `main` remains on the verified T01 baseline | SQLite v1 schema/index validation, file-authoritative rebuild/reconciliation, unavailable-root and conflict preservation, corrupt-sidecar quarantine, 76 unit tests, integration smoke test, unsigned arm64 Debug build, and task/dev CI |
| T05 microphone capture and input signal monitor | Complete on `dev`; `main` remains on the verified T01 baseline | Typed permission/capture contracts, owned Float32 PCM, bounded recording/STT fan-out, race-safe lifecycle, throttled input level/no-input monitoring, active-device failure handling, 95 unit tests, 1 integration test, unsigned arm64 Debug build, and task/dev CI |
| T06 recoverable fragmented audio writer | Complete and audit-hardened on `dev`; `main` remains on the verified T01 baseline | Shared production/fault seams, operation ownership and exact-once terminal cleanup, stateful multi-format/downmix conversion, 22-second AAC mono 48 kHz fragmented recovery MOV with active-prefix and completed-file sample decode, 114 unit tests, 1 integration test, unsigned arm64 Debug build, and task/dev CI |
| T07 recording session coordinator and minimal recording UI | Complete on `dev`; `main` remains on the verified T01 baseline | One-session coordinator ownership, metadata/event journal lifecycle, bounded primary PCM drain, minimal recording UI, and production synthetic recovery-MOV integration. Unsigned arm64 Debug build and 135 unit/integration tests passed; the approved task CI passed. |
| T08 final audio finalization pipeline | Complete on `dev` through separately authorized squash integration | Approved candidate: unsigned arm64 Debug build, 162 tests including 2-hour AAC, 11 related tests × 20 iterations (220 executions), and exact-task CI passed; independently confirmed by the coordinator. Integration-SHA validation is separate. |
| T09 app-start session recovery | Complete on `dev` through separately authorized squash integration | Filesystem-authoritative startup/root-change discovery, interrupted recovery transitions, shared T08 finalization ownership, terminal canonical/source revalidation across await boundaries, catalog/UI refresh, and recoverable-file preservation. Exact integration validation is recorded in the Phase 2 handoff. |
| T10 app lifecycle | Complete on `dev` through separately authorized squash integration | App-owned work admission/activity, sleep/power-off/wake settlement, close/reopen reservations, safe quit replies, required-save failure evidence, pending-discovery-start cancellation and rejected automatic-exit retry. Approved candidate: 264 tests and 8 × 20 repetitions passed; merged-dev validation is recorded below and in the exact-SHA Phase 2 handoff. |
| T11 STTEngine contracts and deterministic fake | Complete on `dev` through independently reviewed, separately authorized squash integration | Framework-independent Codable/Sendable payloads, immutable model/session provenance, bounded FIFO/terminal ownership and acknowledged logical time. Approved source: 299 tests including 35 T11 selectors and exact-task CI passed. New integration-commit validation is recorded in the Phase 2 handoff. |
| T12 model repository, manifests and local import | Complete on dev through user-accepted review and separately authorized squash integration | Value-only schema/provenance, offline inventory and format-validation policy, pinned/no-clobber verified import, exact-once scopes, session-reference assessment and confirmed deletion. Approved source/re-review: 332 tests (322 unit + 10 integration), including 33 T12 and 35 T11 selectors; exact-source CI passed. New dev commit verification is recorded in the Phase 2 handoff. |
| T13 explicit model downloads and verified atomic installation | Complete on dev through user-accepted review and separately authorized squash integration | Capacity admission, real URLSession receipts/range resume, private durable state, shared verification/publication, exact task cancellation and pinned cleanup. Approved source/re-review: 381 tests (371 unit + 10 integration), including 49 T13, 33 T12 and 35 T11 selectors; all five review repairs and exact-source CI passed. Committed-dev verification is recorded in the Phase 2 handoff. |
| T14 experimental WhisperKit adapter and developer benchmark | Complete on dev through independently reviewed, separately authorized squash integration | Approved source: 423 tests (413 unit + 10 integration), including 42 T14, 49 T13, 33 T12 and 35 T11; actual large-v3 offline repetition/cancel/context/negative evidence and exact-source CI passed. Committed-dev validation is separate and recorded in the Phase 2 handoff. |
| T15 experimental whisper.cpp adapter | Complete on dev through independently reviewed, separately authorized squash integration | Approved source passed 432 tests and task CI. The coordinator reproduced installed large-v3 automatic transcription and active cancellation/reuse under OS network denial. [Integration evidence](docs/T15_ACCEPTANCE.md#phase-2-dev-integration) |
| T16 lecture comparison and user decision | Complete on dev. The user selected whisper.cpp with non-quantized large-v3. | Independent review reproduced three 10-minute excerpts and verified 360 window identities across four candidates. The selected pair returned 90 nonempty finals in 90 windows. [Decision and measurements](docs/T16_ENGINE_MODEL_DECISION.md) |
| T17 product engine and session metadata | Complete on dev. The Release app ships whisper.cpp and the recording path persists the selected model and settings. | Candidate review verified the Release bundle, an installed large-v3 recording, recovery and older metadata. [Validation procedure](docs/DEVELOPMENT.md#t17-product-engine-verification) |
| T18 VAD, utterance segmentation and transcript reconciliation | Complete on dev through independently reviewed, separately authorized squash integration. | Candidate review passed 469 XCTest, four Python tests and 526 additional text/timing combinations. VAD fixtures and recovery-audio decoding verify segmentation and recording independence. [Implementation and checks](docs/DEVELOPMENT.md#t18-segmentation-and-overlap-checks) |
| T19 real-time STT coordinator and backpressure | Complete on dev through independently reviewed, separately authorized squash integration. | Approved source/re-review passed 497 tests and three independent persistence/termination probes. Bounded inference, durable journal publication, recording isolation and safe quit/automatic-exit policy are verified. [Acceptance](docs/T19_ACCEPTANCE.md) |
| T20 canonical transcript and derived text/Markdown files | Complete on dev through independently reviewed, separately authorized squash integration. | Approved source and independent re-review passed 519 tests, two additional permission-acquisition probes and exact-source CI. Strict journal replay, preserved overlap times/text edits, read-only verification and repair-required recovery are verified. [Acceptance](docs/T20_ACCEPTANCE.md) |
| Session and context strategy | Confirmed | One Task per implementation session; coordinator session retained |

## Implementation Task status

Section 9 of `IMPLEMENTATION_PLAN.md` records completion through T20. T21 is next. G1 remains **Unverified**. G2 passed on 2026-11-15.

## Gate status

| Gate | Status | Promotion |
| --- | --- | --- |
| T01 initial runnable baseline | Passed | First `main` created from verified `dev` |
| G1 safe recorder | Unverified; manual validation deferred by user on 2026-11-13 | `v0.1.0-alpha.1` (not authorized) |
| G2 engine and model selection | Passed for T17. Four candidates compared on three lectures. User selected whisper.cpp + non-quantized large-v3. [Evidence](docs/T16_ENGINE_MODEL_DECISION.md) | No main promotion or release tag authorized |
| G3 feature complete | Pending | `v0.1.0-beta.1` |
| G4 MVP complete | Pending | `v0.1.0` |

## Confirmed workflow decisions

- The coordinator manages specifications, plans, prompts and gate decisions. For T17 through T20 the user assigned implementation to the coordinator session and separately authorized dev integration after review.
- Each Task uses a fresh implementation session and stays in that session through implementation, review fixes, and any later authorized integration, or until safely blocked.
- The initial implementation prompt ends after task-branch commit/push/CI with `review ready`; it does not authorize official completion, status/checklist updates, `dev` integration, or branch deletion.
- This coordinator independently verifies the acceptance matrix, diff, tests, and CI. A completion message or green CI by itself is not sufficient.
- Same-Task review fixes and CI failures remain in the same implementation session and task branch.
- After independent approval, this coordinator sends a separate integration prompt to that same session; only then may it update completion status, squash merge into `dev`, verify/push `dev`, and delete the task branch.
- A new implementation session starts for the next Task.
- G1~G4 should use a fresh validation session when practical.
- User decision, 2026-11-13: G1's unverified hardware checks do not block the assigned T11 contract/fake-engine work. Keep G1 unverified and preserve automated recorder/lifecycle regressions. Diagnose later STT problems by comparing current-code recording without STT, isolated inference on the same audio, and combined operation; a G1 pass alone does not prove a defect belongs exclusively to STT.
- New implementation sessions load `AGENTS.md`, this status file, their Task section, and only the relevant specification sections.
- Conversations are not the source of project continuity; committed repository documents and Git state are.

## Known issues and blockers

- No current blocker.
- The app is intentionally unsigned for local and CI verification; a developer signing identity is required only for separately installed signed builds.
- G1 hardware/long-recording validation remains deferred and unverified. The user separately authorized T19 integration on 2026-11-24 without changing that gate. Real lecture accuracy and sustained live-STT performance remain later validation work.

## T08 handoff

- Live finalization creates and verifies AAC-LC mono 48 kHz `audio.m4a` through checkpoint prefix 3 (`workingAudioSecured`, `finalM4ACreated`, `finalM4AVerified`). Metadata remains `finalizing` with its original capture outcome, and recovery audio is preserved. T07 essential save returns without waiting for this app-owned work; another recording can start.
- Recovery-audio deletion is a separate implemented and tested API requiring verified whole-session completion evidence. T08 does not implement STT, canonical transcript generation, derived TXT/MD generation, or the complete remaining-finalization pipeline. Already-terminal sessions return an explicit audio-revalidation result without rewriting metadata/checkpoints or deleting recovery.
- Media processing checks pinned directory/file ownership inside framework await and writer I/O boundaries. Independent review regression tests verify no output in a replaced session directory, original/replacement file preservation, exactly-once cleanup/scope release, and completed-session result/snapshot/UI mapping.
- Approved candidate `de7cf16b193942c836aa64f230f5d1a911740fad`: full build/test **162 passed**, related tests **11 × 20 = 220 passed**, and [exact-task CI passed](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/33730646383). These are candidate results, independently confirmed by the coordinator; they do not stand in for validation of the new squash commit. For targeted/full validation of the squash commit, consult its exact-SHA integration report and GitHub Actions result.
- [T08 acceptance](docs/T08_ACCEPTANCE.md) is the historical Phase 1 requirement/assertion record; its Phase 1 restrictions are superseded only by the explicit T08 integration authorization. [Architecture](docs/ARCHITECTURE.md#t08-final-audio-and-application-lifetime) records the implemented boundaries, and [Development](docs/DEVELOPMENT.md#manual-t08-check-pending) records the pending manual procedure.
- Physical microphone/TCC, signed Sandbox/bookmark and hardware-route verification remain manual and unperformed. Forced termination, window/quit/sleep and power-loss validation remain manual or later T10/T26 work. No G1 pass is claimed.

## T09 handoff

- T09 discovers active and historical roots from filesystem artifacts rather than catalog rows, conservatively interrupts durable `recording/paused` sessions, resumes eligible T08 work through the shared queue, and reports unsafe/missing artifacts without deleting them.
- Completed terminal sessions receive read-only canonical media and source-provenance verification. Source observation is held as absent or fingerprinted-present through canonical awaits and read-lease release; prefix-8 canonical-only success requires durable recovery removal plus stable source absence.
- Recovery refreshes the rebuildable catalog and UI report after file work. Historical-root reauthorization stays a root notice/action and cannot overwrite same-root session results, first error, warnings, or live recording controls.
- The approved candidate `2f2cc0aad72ff883f4c1c2c1cde3d73ecc77872f` passed 210 unsigned arm64 Debug tests, 10 representative tests × 20 runs, and [exact-task CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/33988096036). The actual `dev` squash SHA, post-squash tests, and exact-head CI are recorded in this integration handoff.
- T09 does not delete recovery data, generate transcripts or derived files, or implement T10 lifecycle. Physical microphone/TCC, actual process kill, sleep/wake, power loss, window close, and app quit remain manual or T10/T26 scope. No G1 pass is claimed.

## T10 handoff

- Approved source: `68b9fa076de3a9ac01dbfc5e5e97ef85876a4f80`. Independent review re-ran the full unsigned arm64 Debug build/test (264 passes), eight representative tests ×20 (160 successful executions), and two original diagnostic assertions on a production-identical temporary copy (2 passes). [Exact task-head CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43237239197) passed. These are source-candidate results, not a substitute for merged-dev validation.
- One shared admission/activity authority owns recording preparation, securing, T08/T09 work and cleanup. Normal Stop is joined through the T08 handoff; sleep/quit interruption retains recoverable audio and actual durability evidence. Pending starts waiting for T09 discovery are invalidated before cancellation releases them; rejected automatic-exit dispatches release only their own reservation claim and safely re-evaluate.
- Merged-dev validation on 2026-11-12: unsigned arm64 Debug build succeeded; **264 passed (254 unit + 10 integration), 0 failed, 0 skipped**, structurally verified in `/private/tmp/stt-t10-integration.27iLjC/MergedTree.xcresult`. Command: `xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t10-integration.27iLjC/DerivedData -resultBundlePath /private/tmp/stt-t10-integration.27iLjC/MergedTree.xcresult CODE_SIGNING_ALLOWED=NO build test`. Final committed-HEAD local verification (`CommittedHead.xcresult` in the same directory) and exact-head dev CI are reported in the Phase 2 task handoff; no self-referential SHA amendment is required.
- [Acceptance and assertions](docs/T10_ACCEPTANCE.md), [architecture](docs/ARCHITECTURE.md#t10-app-lifetime-and-lifecycle-policy), and [development/manual procedures](docs/DEVELOPMENT.md#t10-lifecycle-verification) describe the implemented boundaries. STT/transcript generation and recovery-file deletion remain outside T10.
- Physical microphone/TCC, signed sandbox/bookmark access, lid, real window/quit UX, logout, process kill and power loss remain Manual/Pending. G1 is not passed by this integration; `main` stays at the T01 baseline. The later user decision on 2026-11-13 authorizes T11 while leaving G1 unverified.

## T11 handoff

- Approved source: `ad9888e2b67b49c89f22759dccfa1b8ce83843e3`; starting dev/origin/dev: `73b4a7adaa16a2ff97ff8affda04fe3b99573b0c`. Latest dev was unchanged, so no integration-preparation commit or source conflict resolution was needed. [Separate Phase 2 authorization](prompts/T11_DEV_INTEGRATION.md) permits this squash integration, completion records and verified task-branch cleanup.
- The approved candidate passed 299 tests (289 unit + 10 integration), including all 35 T11 selectors and four FIFO callback/drain regressions, plus [exact-source CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43349002465). These are source results, not a substitute for the committed dev result.
- One immutable engine/model/language/options configuration owns each session. Owned audio and response payloads are Codable/Sendable; hypotheses use session-relative media time and one terminal per accepted request. All admissions enter one bounded FIFO; accepted early final/failed callbacks promote its head and settle waiting end operations through the same nonrecursive driver. [Acceptance](docs/T11_ACCEPTANCE.md) and [architecture](docs/ARCHITECTURE.md#t11-engine-contracts-and-deterministic-fake) contain the assertions and implemented boundaries.
- Integration verification runs on the actual committed dev HEAD with `xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t11-integration.0PZz4D/DerivedData -resultBundlePath /private/tmp/stt-t11-integration.0PZz4D/CommittedHead.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO build test`. The Phase 2 final handoff records its actual target/T11 pass/fail/skip counts, integration SHA, exact-head dev CI and cleanup outcome; those checks are required before push/cleanup. No self-referential SHA amendment is required.
- G1 hardware/long-recording, physical microphone/TCC, signed Sandbox/bookmark, lid, process-kill and power-loss checks remain Manual/Unverified. Actual model inference, model installation, live capture/STT integration and transcript finalization are not implemented. T12 awaits a new prompt; main stays at the T01 baseline and no release tag is authorized.

## T12 handoff

- Approved source: `4beac0c5ccd2ba8f067de6629dbc8b72e9bed2f7`; starting/latest dev was unchanged at `c9f03f4ead5956cecfa50870ddd6ad87a443d622`. The user accepted the three-finding re-review and separately authorized local squash integration, status/checklist updates, verified dev push/CI and task-branch deletion on 2026-11-13. No task-branch preparation commit or conflict resolution was needed. [Exact-source CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43414298791) passed; re-review also executed 332 tests (322 unit + 10 integration), including all 33 T12 and 35 T11 selectors. These are source results, not a substitute for the dev commit's verification.
- The repository uses a bundled empty production catalog, validated version-1 manifests, hashed engine/model/revision namespaces, bounded SHA-256 revalidation, pinned local-copy staging and no-clobber publication. Verification evidence survives the manifest-write await; idempotent imports revalidate after scope release; unknown schemas are classified before v1 layout parsing. Permanent deletion requires a current reference assessment and explicit acknowledgments. Session files remain authoritative and unchanged. The default format validator reports unavailable; no actual model inference or network/model UI is activated.
- Committed dev verification runs with `xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t12-integration.QDPdUo/DerivedData -resultBundlePath /private/tmp/stt-t12-integration.QDPdUo/CommittedHead.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO build test`. The Phase 2 final handoff records actual target/T12 pass/fail/skip counts, integration SHA, exact-head dev CI and cleanup outcome. No amendment to insert the commit's own future SHA is required.
- [T12 acceptance and review repairs](docs/T12_ACCEPTANCE.md#same-task-review-repair--three-findings), [architecture](docs/ARCHITECTURE.md#t12-offline-model-repository) and [development/manual checks](docs/DEVELOPMENT.md#t12-model-repository-verification) describe the implemented scope. Historical Phase 1 restrictions are superseded only by this separate integration authorization. Signed-Sandbox/source-scope checks remain manual; the earlier recorder-test scheduling-sensitive failure remains documented, with no recorder code/test changes. G1, main and T13 implementation are unchanged; no gate promotion or release is authorized.

## T13 handoff

- Approved source: `c7d323c01ecb322b1b855b9b0d740a371148b661`; starting/latest fetched `dev` and `origin/dev` were unchanged at `1ff211ffbf73f7d35818a4f2e5d154c21fe5bb63`. The user accepted re-review of all five findings and separately authorized squash integration, status/checklist updates, committed-dev build/test, push/exact-head CI and subsequent task-branch deletion on 2026-11-14. No source conflict resolution or task-branch preparation commit was needed. [Exact-source CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43454318690) passed; the read-only re-review executed 381 tests (371 unit + 10 integration), including all 49 T13, 33 T12 and 35 T11 selectors, with zero failures/skips. These source results do not substitute for committed-dev verification.
- Explicit commands own catalog-bound operations. Capacity is checked as `3S − C + 16 MiB` before uncommitted transfer; URLSession receipts are opened during the delegate callback, Apple resume data stays opaque, and completed payloads/catalog identity are revalidated before reuse. Shared T12 claims and pinned no-follow ownership cover transfer, verification, atomic publication and cleanup. Fresh cancellation joins the exact retained task; partial-copy resume preserves completed siblings; public retry reconciles the original operation. Verified final installations take precedence over disposable remnants/capacity, and postcommit cancellation preserves installed truth with a warning.
- Committed-dev verification runs with `xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t13-integration.fYtZLB/DerivedData -resultBundlePath /private/tmp/stt-t13-integration.fYtZLB/CommittedHead.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO build test`. The Phase 2 final handoff records actual unit/integration/T13/T12/T11 pass/fail/skip counts, integration SHA, exact-head dev CI, local/origin agreement and branch cleanup. No amendment to insert the commit's own future SHA is required.
- [T13 acceptance and all five repairs](docs/T13_ACCEPTANCE.md), [architecture](docs/ARCHITECTURE.md) and [development/manual procedure](docs/DEVELOPMENT.md#t13-download-verification) record the implemented scope. Historical Phase 1 restrictions are superseded only by this separate integration authorization. The production catalog remains empty and the live format recognizer remains unavailable. Signed-Sandbox/background-daemon/process-relaunch/lid/power checks and real inference remain Pending/Unverified; automated ordinary-session range resume is not proof of daemon behavior or the full MVP 17.7 suite. G1 stays Unverified, main stays at the T01 baseline, and T14 awaits a new prompt.

## T14 handoff

- Approved source: `b4551c21324e76952f07cc4fd3b85a24e2594492`; starting/latest fetched dev was unchanged at `1724853e1d1942c7f32c0b8d998177d76d2f7c2c`. [Separate Phase 2 authorization](prompts/T14_DEV_INTEGRATION.md) on 2026-11-15 permits this squash integration, completion records, committed-dev validation/push/CI and subsequent verified task-branch deletion. No preparation commit or conflict resolution was needed.
- The coordinator independently verified 423 tests (413 unit + 10 integration), including all 42 T14 (32 engine + 10 SDK boundary), 49 T13, 33 T12 and 35 T11, with zero failures/skips; [exact-source CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43571116655) passed. Source result: `/private/tmp/stt-t14-independent.zMaYO3/Full.xcresult`; actual `AutomaticOffline` and `CancelReuseOffline` reports in that directory cover installed-model inference under OS network denial and fresh user/cache roots. These are source results, not new dev results.
- OSS WhisperKit v1.1.1 is pinned at `1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`; one non-quantized Float16 large-v3 candidate uses Core ML revision `0f63a7800b00dd0226abd051b906c246e1907482`, with the tokenizer/package identities in [acceptance](docs/T14_ACCEPTANCE.md#pins-trust-and-license-audit). The developer catalog is fixed and separate from the empty production catalog; ordinary app construction does not load/download/infer. No product engine/model choice or updater is added.
- Repaired contracts: at most 111 prompt tokens reach actual SDK prefill without suffix loss, context/control tokens cannot masquerade as transcript partials, explicit checked detection cannot turn an error into English success, and end/cancel join owning cleanup through lease release despite control-caller cancellation. [Architecture](docs/ARCHITECTURE.md#t14-experimental-whisperkit-adapter-and-developer-benchmark) and [repair evidence](docs/T14_ACCEPTANCE.md#same-task-review-repair--three-findings) describe FIFO, time mapping, ownership and actual SDK-boundary/held-cleanup regressions.
- Integration preserves all 89 approved executable/test/project/package/catalog/bootstrap/offline-profile input hashes, so the reviewed real-model/offline evidence is reused without another model acquisition/inference run. Committed dev verification uses `xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t14-work/DerivedData -resultBundlePath /private/tmp/stt-t14-integration.WeavII/CommittedHead.xcresult -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -test-timeouts-enabled YES -default-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO build test`, plus `swift build --scratch-path /private/tmp/stt-t14-repair.RpKBXk/CLIBuild --disable-automatic-resolution`. Actual committed-dev counts, SHA, exact-head CI and cleanup outcome are recorded in the Phase 2 final handoff, without self-referential amendments.
- [Development](docs/DEVELOPMENT.md#t14-same-task-review-repairs) retains reproducible commands. Short synthetic-speech RTF around 0.43 does not pass a performance/accuracy gate. The 111-token repeated-word stress input produces repetition, roughly 7 s first partial and RTF around 1.74. G1 physical microphone/TCC/signed-Sandbox/bookmark/lid/power/long-recording checks remain Unverified; G2/real-lecture comparisons remain unpassed. Main stays at T01, T15 awaits a separate prompt, and live STT/transcript finalization remain unimplemented.

## T15 handoff

- Approved source `6a5f0dde8e35423ecd8d4ab918cb73f5ea556def` passed 432 tests (422 unit and 10 integration), including 9 native adapter tests. The coordinator independently verified the same selectors and actual offline automatic transcription, native abort and same-engine reuse. [Source CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43625949746) · [Integration authorization](prompts/T15_DEV_INTEGRATION.md)
- The v1.9.5/b5454 XCFramework uses source `d1be6fde11ac6e0407606b4e42fe72d34add8037` and reports ABI `1.9.5-dev`. The non-quantized GGML large-v3 candidate uses revision `5359861c739e955e79d9a303bcbc70fb988958b1`. One serial queue owns the native context and verifies a model-sized temporary snapshot. Cancellation holds the model lease through native return and callback settlement. Automatic detection pins a checked language, hints use a 223-token budget, and checked 10 ms segment ticks receive the session offset once. [Architecture](docs/ARCHITECTURE.md#t15-experimental-whispercpp-adapter)
- Execution inputs match the approved source. Phase 2 reuses its real-model evidence and runs the full unsigned arm64 suite and CLI build on committed dev before push and exact-SHA CI. The short synthetic case leaves lecture accuracy, long-running live STT and G1 hardware/lifecycle checks open. [Acceptance and evidence](docs/T15_ACCEPTANCE.md#phase-2-dev-integration) · [Development commands](docs/DEVELOPMENT.md#t15-native-benchmark)

## T16 handoff

- The approved source passed 423 unit and 10 integration tests, four Python comparison tests and the SwiftPM benchmark build. The Phase 2 delivery handoff reports the validation run on the committed dev SHA. [Approved source CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43706895281) · [Integration authorization and commands](prompts/T16_DEV_INTEGRATION.md)
- Eight of the twelve candidate/lecture runs returned finals for every window. Each of the other four runs had one `invalidResponse`. Korean accuracy, English terminology and hallucination/repetition/omission have no human scores. The integration preserves the reviewed engine code, model manifests, dependency pins and comparison tools, so the original measurements support the decision. [Decision](docs/T16_ENGINE_MODEL_DECISION.md) · [Reproduction and review](docs/DEVELOPMENT.md#t16-developer-lecture-comparison)

## T17 handoff

- Review of `05a6e5b` passed 426 unit tests, 10 integration tests and four Python comparison tests. A network-denied probe using the product factory and installed large-v3 produced a nonempty final transcript from synthetic speech. Review also verified the fixed default with a reordered catalog and decoded older session metadata. [Source CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43711967320)
- Phase 2 validates the committed dev build with the full unsigned arm64 suite using the installed model, the SwiftPM benchmark build, the Python tests and the Release bundle inspection. The G1 physical microphone, lifecycle and long-recording checks remain unverified. [Commands](docs/DEVELOPMENT.md#t17-product-engine-verification) · [Architecture](docs/ARCHITECTURE.md#t17-product-engine-and-session-provenance)

## T18 handoff

- The approved source `d0d9df6` implements the replaceable VAD, 300 ms prefix, 800 ms silence boundary, 20-second windows and one-second copied overlap. Reconciliation uses matched-word time coverage, preserves weakly overlapping and later repeated speech, handles detached/leading punctuation and preserves dotted terms. [Architecture](docs/ARCHITECTURE.md#t18-speech-segmentation-and-transcript-reconciliation)
- Independent review on 2026-11-24 passed 458 unit and 11 integration tests in the CI configuration, four Python tests and 526 additional combinations checking text, timing, sequence, retry and replay IDs. [Approved source CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/44094277667)
- The prior temporary installed-model directory is empty. The optional installed-model check reported `loadFailed`; ordinary CI configuration passed. The integration validates the committed dev SHA with Debug build/test, Release product-engine inspection, the SwiftPM benchmark build and Python tests. G1 physical microphone, lifecycle and long-recording verification remains unverified. T19 will connect capture to inference and transcript updates. [Commands](docs/DEVELOPMENT.md#t18-segmentation-and-overlap-checks)

## T19 handoff

- Approved source `ab0e902` connects capture to 16 kHz mono STT, bounded partial/final scheduling, session-pinned language/model, journal persistence and live transcript UI. The two lifecycle repairs preserve essential-save quit and inhibit automatic exit on speech/storage errors while allowing normal cancellation and delay. [Architecture](docs/ARCHITECTURE.md#t19-live-speech-coordination-and-backpressure)
- Independent review on 2026-11-24 passed 497 tests (480 unit, 17 integration; zero failures/skips), plus three disposable probes for journal/metadata writes during quit and STT-failure automatic exit. [Approved source CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45385706671) · [Acceptance](docs/T19_ACCEPTANCE.md)
- Phase 2 preserves the reviewed executable/test inputs and validates the committed dev SHA with the full unsigned arm64 Debug build/test, Release product-engine inspection, SwiftPM benchmark build and Python tests. The final handoff records the integration SHA, exact-commit CI and branch cleanup; candidate results do not replace integration validation. [Commands](docs/DEVELOPMENT.md#t19-live-stt-verification)
- At the T19 handoff, canonical transcript assembly, completion metadata and derived TXT/MD files were deferred to T20; T19 retained the journal and recoverable audio. The T20 handoff below supersedes that pending-work snapshot. G1 remains unverified.

## T20 handoff

- Approved source `51a452d` implements journal compaction, canonical text-only edits, deterministic TXT/Markdown, ordered checkpoints and recovery/lifecycle integration. Overlap windows retain every T18 segment field; completed sessions require no file writes when validation succeeds. Missing/stale exports report required repair on read-only roots and resume after permission returns. [Architecture](docs/ARCHITECTURE.md#t20-canonical-transcript-and-derived-files)
- Independent re-review on 2026-11-25 passed 519 XCTest (500 unit + 19 integration, zero failures/skips), plus two temporary probes for cancellation/replacement during write-scope acquisition, concurrent admission and successful retry. [Approved source CI](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45429543015) · [Acceptance](docs/T20_ACCEPTANCE.md#phase-2-dev-integration)
- Phase 2 preserves the reviewed executable/test inputs. Committed-dev validation runs the full unsigned arm64 Debug build/test, Release product-engine inspection, SwiftPM benchmark build and four Python tests. The integration delivery records its actual SHA, local results, exact-commit CI and branch cleanup. [Commands](docs/DEVELOPMENT.md#t20-transcript-finalization-verification)
- G1 remains unverified; physical microphone/TCC, signed Sandbox, lid/process-kill/power-loss and long-recording checks are still pending. Recovery audio and journal remain retained. T21 is next and has not started; no main promotion or release tag is authorized.

## Status update rules

Coordinator-recorded user decisions about scheduling or gates may be documented before implementation. The 2026-11-13 G1 deferral is such a planning update, not a T11 completion claim. A T11 implementation session may carry and commit this pre-existing decision text unchanged, as explicitly authorized in its prompt, but may not mark T11 complete or modify the completion checklist in Phase 1.

Only after independent review approval, when a Task is successfully integrated into `dev`, update this file with:

- Current milestone and next Task
- Newly completed Task and concise outcome
- Verified build and test commands
- Material interfaces or architecture added
- New risks, blockers, or user decisions
- Gate readiness

Keep this file concise. Detailed product requirements belong in `MVP_SPEC.md`, Task scope belongs in `IMPLEMENTATION_PLAN.md`, and implemented structure belongs in `docs/ARCHITECTURE.md`.
