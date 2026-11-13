# Local Lecture STT Project Status

- Status document version: 1.0
- Last updated: 2026-11-13
- Specification baseline: `MVP_SPEC.md` 1.0, confirmed
- Implementation plan: `IMPLEMENTATION_PLAN.md` 1.4

## Current position

- Current milestone: M2 models and engines; M1/G1 hardware validation remains unverified
- Current Task: none in progress; T12 squash-integrated into dev after user-accepted review and separate integration authorization
- Next action: T13 remains the next planned Task; await a separate implementation prompt
- Latest completed Task: T12 model repository, manifests and local import (through separately authorized dev integration)
- Latest passed gate: T01 initial runnable baseline
- Application implementation: recording, app-owned final M4A generation and recovery, lifecycle policy, framework-independent STTEngine contracts/fake, and an offline model repository with manifests, verified local import and confirmed deletion. Real model format recognizers/inference, live STT wiring and transcript finalization remain unimplemented.

## Repository state at this handoff

- Remote: private `origin` is connected to `https://github.com/tjdals-dbs/local-lecture-stt.git`
- GitHub default branch: `main`
- Local branch: `dev`
- Approved T12 source: `4beac0c5ccd2ba8f067de6629dbc8b72e9bed2f7`, including all three repository review repairs; the user accepted re-review and explicitly authorized Phase 2 integration on 2026-11-13
- `dev` branch: T12 is squash-integrated from the approved source onto `c9f03f4ead5956cecfa50870ddd6ad87a443d622`; final integration SHA, committed-HEAD validation and exact-head CI linkage are recorded in the Phase 2 task handoff
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
| Session and context strategy | Confirmed | One Task per implementation session; coordinator session retained |

## Implementation Task status

T12 is integrated into `dev` after review accepted by the user and separate Phase 2 authorization on 2026-11-13. Only T12's completion checkbox is newly checked in section 9 of `IMPLEMENTATION_PLAN.md`. T13 remains unstarted and requires a separate implementation prompt. G1 remains **Unverified**, not passed or waived; no `dev → main` promotion, release or later Task implementation is authorized.

## Gate status

| Gate | Status | Promotion |
| --- | --- | --- |
| T01 initial runnable baseline | Passed | First `main` created from verified `dev` |
| G1 safe recorder | Unverified; manual validation deferred by user on 2026-11-13 | `v0.1.0-alpha.1` (not authorized) |
| G2 engine and model selection | Pending | `v0.1.0-alpha.2` |
| G3 feature complete | Pending | `v0.1.0-beta.1` |
| G4 MVP complete | Pending | `v0.1.0` |

## Confirmed workflow decisions

- The coordinator session writes specifications, plans, prompts, and gate decisions but does not implement the app.
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
- G1 hardware/long-recording validation is deferred and remains an explicit verification gap, not a known passing result or a T11 blocker under the user's 2026-11-13 scheduling decision.

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
