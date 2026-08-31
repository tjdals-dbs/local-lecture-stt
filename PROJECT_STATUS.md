# Local Lecture STT Project Status

- Status document version: 1.0
- Last updated: 2026-08-31
- Specification baseline: `MVP_SPEC.md` 1.0, confirmed
- Implementation plan: `IMPLEMENTATION_PLAN.md` 1.2

## Current position

- Current milestone: M1 safe recorder
- Current Task: none in progress
- Next action: T07 recording session coordinator and minimal recording UI
- Latest completed Task: T06 recoverable fragmented audio writer
- Latest passed gate: T01 initial runnable baseline
- Application implementation: executable initial SwiftUI shell

## Repository state at this handoff

- Remote: private `origin` is connected to `https://github.com/tjdals-dbs/local-lecture-stt.git`
- GitHub default branch: `main`
- Local branch: `dev`
- Remote baseline: `origin/dev` contains the verified T05 integration; `origin/main` remains the verified T01 runnable baseline
- `dev` branch: T05 microphone capture integration branch, tracked at `origin/dev`
- `main` branch: created and tracked at `origin/main`; it remains at the verified T01 baseline while `dev` has advanced through T05
- `main` policy: only buildable and runnable verified versions
- `dev` policy: integration branch for completed Tasks
- Task policy: one fresh implementation session and one `task/tNN-*` branch per Task
- Pull Request policy: no PR for normal Tasks; verified local squash merge into `dev`

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
| T06 recoverable fragmented audio writer | Complete on `dev`; `main` remains on the verified T01 baseline | Framework-independent recorder contract, scoped write lease, stateful PCM conversion, AAC mono 48 kHz fragmented recovery MOV, active-prefix/read-decode test, 97 unit tests, 1 integration test, unsigned arm64 Debug build, and task/dev CI |
| Session and context strategy | Confirmed | One Task per implementation session; coordinator session retained |

## Implementation Task status

T06 is complete. The canonical checklist is in section 9 of `IMPLEMENTATION_PLAN.md`; T07 is ready to start on a fresh task branch.

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
- Each Task uses a fresh implementation session and stays in that session until the Task is completed or safely blocked.
- Same-Task fixes and CI failures remain in the same implementation session.
- A new implementation session starts for the next Task.
- G1~G4 should use a fresh validation session when practical.
- New implementation sessions load `AGENTS.md`, this status file, their Task section, and only the relevant specification sections.
- Conversations are not the source of project continuity; committed repository documents and Git state are.

## Known issues and blockers

- No current blocker.
- The app is intentionally unsigned for local and CI verification; a developer signing identity is required only for separately installed signed builds.

## T06 handoff

T06 is complete. T07 can start from the latest `dev` baseline on a fresh `task/t07-*` branch.

- `AudioRecorder` now exposes framework-free start/append/flush/stop, state, summary, stable failure code, and terminal event values. `AVFoundationAudioRecorder` is the serial owner of a persistent `AVAudioConverter` and audio-only `AVAssetWriter`; it produces `recovery/audio.recovery.mov` using AAC-LC mono 48 kHz/96 kbps with 1-second initial and 10-second subsequent fragments.
- `StorageRootManager.acquireWriteLease` retains security-scoped root access until async writer finish, closes it exactly once, validates the pre-existing non-symlink session/recovery layout, rejects collision, and preserves partial artifacts on any writer failure. Recorder tests prove a synthetic recording works without any speech/STT consumer, sequence violations fail without silent loss, existing bytes are preserved, active writer output opens in AVFoundation, and the completed MOV has fragment evidence and a decodable AAC track.
- The full suite now has 97 unit tests and 1 integration test (98 total). A locally signed sandbox root and physical microphone remain manual T07+ verification; forced-quit/power-loss recovery remains T09/T26 scope.

## Status update rules

When a Task is successfully integrated into `dev`, update this file with:

- Current milestone and next Task
- Newly completed Task and concise outcome
- Verified build and test commands
- Material interfaces or architecture added
- New risks, blockers, or user decisions
- Gate readiness

Keep this file concise. Detailed product requirements belong in `MVP_SPEC.md`, Task scope belongs in `IMPLEMENTATION_PLAN.md`, and implemented structure belongs in `docs/ARCHITECTURE.md`.
