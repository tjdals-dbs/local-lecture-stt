# Local Lecture STT Repository Instructions

## 1. Context loading

Start every task by reading, in this order:

1. The current user/task prompt
2. `PROJECT_STATUS.md`
3. The assigned Task section in `IMPLEMENTATION_PLAN.md`
4. Only the relevant sections of `MVP_SPEC.md` named by the task prompt
5. The current Git state and the actual code involved in the task

Do not reread the full specification and implementation plan on every task unless a conflict or missing requirement makes that necessary. Treat actual code and test results as the source of truth for what has already been implemented.

## 2. Document authority

- `MVP_SPEC.md` defines product behavior and non-negotiable technical requirements.
- `IMPLEMENTATION_PLAN.md` defines Task scope, order, dependencies, gates, and Git workflow.
- `PROJECT_STATUS.md` records current progress, the next Task, known issues, and the latest handoff.
- `docs/ARCHITECTURE.md`, once created, describes the architecture that actually exists.
- `docs/DEVELOPMENT.md`, once created, contains the verified build and test commands.

If these disagree, do not silently choose one. Preserve data, stop at a safe point, and report the conflict with a recommended resolution. Do not change product behavior without explicit user approval.

## 3. Session scope

### Explicit continuous-work authorization

On 2026-11-25 the user separately authorized the same continuous cycle for T22: implementation, separate read-only review, same-Task repairs, full tests and exact-commit task CI, then dev integration, full integration validation/CI and branch cleanup. No further integration prompt is required for T22 after those checks pass. Completion/checklist updates still wait until integration. G1 remains unverified, main unchanged, and T23 or later Tasks are not authorized.

On 2026-11-25 the user authorized T21 in this coordinator session from implementation through review, same-Task fixes, task CI, dev integration and branch cleanup without another permission round. For this authorization, the separate integration-prompt requirements below are replaced by a separate read-only review pass against the acceptance matrix and final diff. All other verification, scope and Git gates remain mandatory. Record review evidence before integration; do not mark completion before integration. Stop only for an unresolved product decision or a required check that cannot be completed. G1 remains unverified and main is unchanged. This does not authorize T22 or later Tasks.

- A planning or review request does not authorize implementation.
- An implementation session is assigned exactly one `TNN` Task unless the user explicitly expands it.
- Finish implementation, same-Task fixes, tests, task-branch commit/push/CI, and any later authorized `dev` integration for that Task in the same session.
- The initial implementation prompt ends at a review-ready task branch. It does not authorize official Task completion, status/checklist completion, `dev` integration, or task-branch deletion.
- The coordinator session independently reviews the task branch. Only a later explicit integration prompt issued after that review authorizes status/checklist updates and `dev` integration.
- Do not implement the next Task early.
- Do not implement post-MVP features merely because an interface could support them.
- Gate verification sessions are read-only unless the user separately authorizes a fix.

## 4. Product safety invariants

- Preserving recoverable audio is more important than STT availability or derived files.
- Session files are authoritative; SQLite is a rebuildable catalog.
- `transcript.json` is canonical; `.txt` and `.md` are derived.
- Never delete damaged, missing, or partially recoverable session data automatically.
- Recording must not depend on STT keeping up.
- After a model is installed, all MVP runtime behavior must work without network access.
- Never add model auto-update, telemetry, cloud sync, or automatic crash upload.
- Keep engine boundaries free of WhisperKit or whisper.cpp library types.
- Keep payloads crossing engine and orchestration boundaries Codable and Sendable where specified.

## 5. Git workflow

Before editing:

- Inspect `git status`, the current branch, configured remotes, and recent log.
- Preserve unrelated user changes and existing untracked files.
- Never use destructive cleanup, reset, or checkout commands to discard work.

For normal `TNN` implementation:

- Start from the latest `dev`.
- Use only `task/tNN-short-description` for the assigned Task.
- Stage only in-scope paths.
- Do not create feature commits directly on `main` or `dev`.
- Do not force-push `main`, `dev`, or a shared task branch.
- Pull Requests are not used for normal Tasks.

Normal `TNN` work uses two phases.

Phase 1 — implementation candidate:

1. Run the relevant local build and tests.
2. Review the complete task-branch diff and staged diff.
3. Commit with the Task ID in the message and push the task branch.
4. Confirm task-branch CI when CI exists.
5. Report either `review ready` or `blocked`; do not call the Task officially complete.
6. Leave `PROJECT_STATUS.md`, the implementation-plan checklist, `dev`, and `main` unchanged, and keep the task branch available for independent review and same-Task fixes.

The coordinator then reviews the acceptance matrix, diff, tests, and CI independently. A green implementation report or task CI alone is not approval.

Phase 2 — explicitly authorized integration:

1. Continue in the same implementation session and task branch after receiving a separate integration prompt.
2. Recheck the latest `dev`; if it changed, safely incorporate it and repeat affected validation and task CI before integration.
3. Update `PROJECT_STATUS.md` and the implementation-plan checklist as part of the `dev` integration commit.
4. Squash merge locally into the latest `dev` only when every reviewed completion condition still passes.
5. Re-run build and tests on merged `dev`, then push `dev` and confirm its exact-commit CI.
6. Delete the task branch only after `dev` is safely pushed and verified.

Without a separate integration prompt, or if any completion condition is uncertain or failing, leave the work on the task branch, do not update completion status, do not merge into `dev`, and report the blocker. V00 and `dev → main` gate promotions are special workflows defined by their own prompts.

## 6. Repository data policy

Never commit:

- Downloaded or converted model weights
- Lecture recordings or real transcripts
- Session roots, recovery folders, `.m4a`, or recovery `.mov` files
- Runtime SQLite databases
- Application Support contents or security-scoped bookmark data
- Logs, crash dumps, temporary downloads, or staging directories
- Credentials, signing secrets, certificates, or provisioning secrets
- Built `.app`, `.dmg`, or release `.zip` artifacts

Commit `Package.resolved`, source, tests, shared schemes, entitlements, manifests, checksums, license documents, and small redistributable test fixtures. Prefer generated synthetic fixtures over real lecture material.

## 7. Verification and documentation

- Add automated tests for deterministic behavior and a reproducible manual procedure for hardware or lifecycle behavior that cannot be automated reliably.
- Do not claim tests passed unless they were actually run in the current repository state.
- Record exact commands and outcomes.
- Update `docs/ARCHITECTURE.md` when module boundaries, data flow, or public interfaces materially change.
- Update `docs/DEVELOPMENT.md` when setup, build, test, CI, or dependency commands change.
- Keep context documents concise; link to code and canonical specifications instead of duplicating them.

## 8. Required final report

Every implementation session must report:

- Task ID and phase status: `review ready`, `blocked`, or `integrated` only after explicit authorization
- Task branch and commit; resulting `dev` commit only when separately authorized and integrated
- Changed files and key design decisions
- Tests and commands actually run, with results
- Any manual verification still required
- Deviations from the specification, if any
- Remaining risks or known issues
- Whether the next Task is safe to start; a phase-1 candidate must state that this remains the coordinator's post-review decision
