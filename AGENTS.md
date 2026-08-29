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

- A planning or review request does not authorize implementation.
- An implementation session is assigned exactly one `TNN` Task unless the user explicitly expands it.
- Finish implementation, same-Task fixes, tests, commit, and authorized `dev` integration for that Task in the same session.
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

When the task prompt authorizes commit, push, and integration:

1. Run the relevant local build and tests.
2. Review the complete task-branch diff and staged diff.
3. Commit with the Task ID in the message and push the task branch.
4. Confirm task-branch CI when CI exists.
5. If and only if every completion condition passes, squash merge locally into the latest `dev`.
6. Update `PROJECT_STATUS.md` and the implementation-plan checklist as part of the `dev` integration commit.
7. Re-run build and tests on merged `dev`, then push `dev` and confirm its CI.
8. Delete the task branch only after `dev` is safely pushed and verified.

If any completion condition is uncertain or failing, leave the work on the task branch, do not merge into `dev`, and report the blocker. V00 and `dev → main` gate promotions are special workflows defined by their own prompts.

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

- Task ID and completion status
- Branches and resulting `dev` commit, if integrated
- Changed files and key design decisions
- Tests and commands actually run, with results
- Any manual verification still required
- Deviations from the specification, if any
- Remaining risks or known issues
- Whether the next Task is safe to start
