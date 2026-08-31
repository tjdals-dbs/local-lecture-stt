# Local Lecture STT Project Status

- Status document version: 1.0
- Last updated: 2026-08-30
- Specification baseline: `MVP_SPEC.md` 1.0, confirmed
- Implementation plan: `IMPLEMENTATION_PLAN.md` 1.2

## Current position

- Current milestone: M0 foundation
- Current Task: none in progress
- Next action: T05 microphone capture and input signal monitor
- Latest completed Task: T04 SQLite session catalog and filesystem reconciliation
- Latest passed gate: T01 initial runnable baseline
- Application implementation: executable initial SwiftUI shell

## Repository state at this handoff

- Remote: private `origin` is connected to `https://github.com/tjdals-dbs/local-lecture-stt.git`
- GitHub default branch: `main`
- Local branch: `dev`
- Remote baseline: `origin/dev` contains the verified T04 integration; `origin/main` remains the verified T01 runnable baseline
- `dev` branch: T04 catalog integration branch, tracked at `origin/dev`
- `main` branch: created and tracked at `origin/main`; it remains at the verified T01 baseline while `dev` has advanced through T02
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
| T04 SQLite session catalog and filesystem reconciliation | Complete on `dev`; `main` remains on the verified T01 baseline | SQLite v1 schema/index validation, file-authoritative rebuild/reconciliation, unavailable-root and conflict preservation, corrupt-sidecar quarantine, 48 unit tests, integration smoke test, unsigned arm64 Debug build, and task/dev CI |
| Session and context strategy | Confirmed | One Task per implementation session; coordinator session retained |

## Implementation Task status

T04 is complete. The canonical checklist is in section 9 of `IMPLEMENTATION_PLAN.md`; T05 is ready to start on a fresh task branch.

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

## T04 handoff

T04 is complete. T05 can start from the latest `dev` baseline on a fresh `task/t05-*` branch.

- `dev` contains T03 file-authoritative session roots plus a rebuildable SQLite catalog at `Application Support/LocalLectureSTT/Catalog/session-catalog.sqlite3`; `main` remains at the verified T01 baseline.
- T04 adds URL-free catalog contracts, lexical read-only root scanning, explicit startup failures, complete-only missing sweeps, and catalog-preserving handling for unreadable, unavailable, duplicate, and location-conflict sessions. Ready startup calls reuse their completed report; only successful root change events trigger a new reconciliation. A malformed/corrupt v1 database is sidecar-first quarantined and rebuilt; a future schema is left byte-for-byte untouched.
- `LocalLectureSTTTests/SessionCatalogTests.swift` covers actual root-manager → scanner → reconciler → store rebuild, metadata updates, missing preservation, active/historical/unavailable roots, malformed metadata, transaction conflicts, schema/future/corrupt sidecar cases, quarantine faults, and startup coalescing. The unsigned CI does not prove signed sandbox bookmark persistence; the manual same-signed-build procedure remains in `docs/DEVELOPMENT.md`.
- T05 can add microphone capture without coupling recording correctness to this rebuildable derived catalog.

## Status update rules

When a Task is successfully integrated into `dev`, update this file with:

- Current milestone and next Task
- Newly completed Task and concise outcome
- Verified build and test commands
- Material interfaces or architecture added
- New risks, blockers, or user decisions
- Gate readiness

Keep this file concise. Detailed product requirements belong in `MVP_SPEC.md`, Task scope belongs in `IMPLEMENTATION_PLAN.md`, and implemented structure belongs in `docs/ARCHITECTURE.md`.
