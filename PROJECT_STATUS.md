# Local Lecture STT Project Status

- Status document version: 1.0
- Last updated: 2026-09-03
- Specification baseline: `MVP_SPEC.md` 1.0, confirmed
- Implementation plan: `IMPLEMENTATION_PLAN.md` 1.3

## Current position

- Current milestone: M1 safe recorder
- Current Task: none in progress
- Next action: T08 final audio finalization pipeline
- Latest completed Task: T07 recording session coordinator and minimal recording UI
- Latest passed gate: T01 initial runnable baseline
- Application implementation: executable audio-recording SwiftUI flow through recovery-audio securing

## Repository state at this handoff

- Remote: private `origin` is connected to `https://github.com/tjdals-dbs/local-lecture-stt.git`
- GitHub default branch: `main`
- Local branch: `dev`
- Remote baseline: `origin/dev` contains the verified T07 integration; `origin/main` remains the verified T01 runnable baseline
- `dev` branch: verified through T07 recording coordinator/UI integration, tracked at `origin/dev`
- `main` branch: created and tracked at `origin/main`; it remains at the verified T01 baseline while `dev` has advanced through T06 hardening
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
| Session and context strategy | Confirmed | One Task per implementation session; coordinator session retained |

## Implementation Task status

T07 is complete on `dev`. The canonical checklist is in section 9 of `IMPLEMENTATION_PLAN.md`; T08 final audio finalization is next.

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

## T07 handoff

T07 is complete on `dev`. T08 can start in a new session from this verified integration baseline.

- `RecordingSessionCoordinator` is the serialized owner of the active location, capture, recorder, primary PCM pump, observers, first failure, and terminal settlement. It persists `preparing → recording` only after capture/writer readiness, drains all accepted primary PCM before recovery-writer finish, and leaves normal sessions at `.securing/.completed` for T08 rather than creating final audio.
- Controlled-gate tests cover writer-start stop/cancellation/capture races, pre-durable terminal persistence, secondary start-persistence faults, terminal-event failure, root changes, and prior-pump isolation. They retain the first typed failure, record terminal metadata/events exactly once where durable, preserve recovery artifacts, and block a new start until cleanup completes.
- `RecordingSessionFileIntegrationTests` connects production capture, repository, root manager, recorder, scanner, and catalog with 32 ordered synthetic mono 48 kHz chunks (65,536 frames). It decodes the recovery MOV, verifies `.securing/.completed` metadata and ordered events/catalog projection, and proves final audio/transcript/checkpoint artifacts are absent.
- The integrated unsigned arm64 Debug build and full suite passed with 135 tests. Task CI passed. A locally signed sandbox root, physical microphone/TCC, and hardware-route verification remain manual; forced-quit/power-loss recovery remains T09/T26 scope.

## Status update rules

Only after independent review approval, when a Task is successfully integrated into `dev`, update this file with:

- Current milestone and next Task
- Newly completed Task and concise outcome
- Verified build and test commands
- Material interfaces or architecture added
- New risks, blockers, or user decisions
- Gate readiness

Keep this file concise. Detailed product requirements belong in `MVP_SPEC.md`, Task scope belongs in `IMPLEMENTATION_PLAN.md`, and implemented structure belongs in `docs/ARCHITECTURE.md`.
