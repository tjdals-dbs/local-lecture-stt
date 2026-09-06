# Local Lecture STT Project Status

- Status document version: 1.0
- Last updated: 2026-09-06
- Specification baseline: `MVP_SPEC.md` 1.0, confirmed
- Implementation plan: `IMPLEMENTATION_PLAN.md` 1.3

## Current position

- Current milestone: M1 safe recorder
- Current Task: none in progress
- Next action: T10 app lifecycle; await a separate implementation prompt
- Latest completed Task: T09 app-start session recovery
- Latest passed gate: T01 initial runnable baseline
- Application implementation: recording, app-owned final M4A generation, verification and resumable audio checkpoints, plus filesystem-authoritative startup/root-change session recovery; STT/transcript finalization remains unimplemented

## Repository state at this handoff

- Remote: private `origin` is connected to `https://github.com/tjdals-dbs/local-lecture-stt.git`
- GitHub default branch: `main`
- Local branch: `dev`
- Approved T09 source: `2f2cc0aad72ff883f4c1c2c1cde3d73ecc77872f`, independently reviewed and explicitly authorized for Phase 2 integration
- `dev` branch: T09 is squash-integrated from the approved source; exact integration SHA, local results, and exact-head CI are recorded in the Phase 2 handoff
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
| Session and context strategy | Confirmed | One Task per implementation session; coordinator session retained |

## Implementation Task status

T09 is integrated into `dev`. The canonical checklist is in section 9 of `IMPLEMENTATION_PLAN.md`; T10 app lifecycle is next and remains unstarted. G1 remains pending.

## Gate status

| Gate | Status | Promotion |
| --- | --- | --- |
| T01 initial runnable baseline | Passed | First `main` created from verified `dev` |
| G1 safe recorder | Pending | `v0.1.0-alpha.1` |
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
- New implementation sessions load `AGENTS.md`, this status file, their Task section, and only the relevant specification sections.
- Conversations are not the source of project continuity; committed repository documents and Git state are.

## Known issues and blockers

- No current blocker.
- The app is intentionally unsigned for local and CI verification; a developer signing identity is required only for separately installed signed builds.

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

## Status update rules

Only after independent review approval, when a Task is successfully integrated into `dev`, update this file with:

- Current milestone and next Task
- Newly completed Task and concise outcome
- Verified build and test commands
- Material interfaces or architecture added
- New risks, blockers, or user decisions
- Gate readiness

Keep this file concise. Detailed product requirements belong in `MVP_SPEC.md`, Task scope belongs in `IMPLEMENTATION_PLAN.md`, and implemented structure belongs in `docs/ARCHITECTURE.md`.
