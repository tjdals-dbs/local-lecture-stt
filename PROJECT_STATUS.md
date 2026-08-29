# Local Lecture STT Project Status

- Status document version: 1.0
- Last updated: 2026-08-30
- Specification baseline: `MVP_SPEC.md` 1.0, confirmed
- Implementation plan: `IMPLEMENTATION_PLAN.md` 1.2

## Current position

- Current milestone: M0 foundation
- Current Task: none in progress
- Next action: T01 macOS project and module boundaries
- Latest completed Task: V00 repository baseline
- Latest passed gate: none
- Application implementation: not started

## Repository state at this handoff

- Remote: `origin` is connected to `https://github.com/tjdals-dbs/local-lecture-stt.git`
- Local branch: `dev`
- Remote baseline: `origin/dev` V00 documentation baseline
- `dev` branch: created and tracked at `origin/dev`
- `main` branch: not created yet
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
| Session and context strategy | Confirmed | One Task per implementation session; coordinator session retained |

## Implementation Task status

No application implementation Tasks have started. V00 is complete; the canonical checklist is in section 9 of `IMPLEMENTATION_PLAN.md`.

## Gate status

| Gate | Status | Promotion |
| --- | --- | --- |
| T01 initial runnable baseline | Pending | First `main` creation |
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
- Repository visibility has not been recorded in project documents and does not block V00.
- There is no executable app yet, so `main` must not receive the documentation-only baseline.

## V00 handoff

V00 is complete. T01 can start from the latest `dev` baseline on a fresh `task/t01-*` branch.

- `dev` is the local and remote documentation baseline.
- `main` has not been created and must remain absent until T01 proves a runnable application baseline.
- No Xcode project or application source has been created.
- T01 should update this status document, the implementation-plan checklist, and the architecture/development documents when it integrates into `dev`.

## Status update rules

When a Task is successfully integrated into `dev`, update this file with:

- Current milestone and next Task
- Newly completed Task and concise outcome
- Verified build and test commands
- Material interfaces or architecture added
- New risks, blockers, or user decisions
- Gate readiness

Keep this file concise. Detailed product requirements belong in `MVP_SPEC.md`, Task scope belongs in `IMPLEMENTATION_PLAN.md`, and implemented structure belongs in `docs/ARCHITECTURE.md`.
