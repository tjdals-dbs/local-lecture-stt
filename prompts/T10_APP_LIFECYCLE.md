# T10 — App Lifecycle, Sleep, Window, and Safe Termination

## 1. Task boundary

Implement only T10 in `/Users/andyoon/stt`.

The goal is to keep recording, audio finalization, and startup recovery owned by the application rather than a SwiftUI view, and to implement the confirmed macOS policies for idle sleep, system sleep/wake, window closing, automatic exit, and explicit app termination.

This prompt authorizes only a Phase 1 implementation candidate on the task branch. It authorizes implementation, same-Task fixes, tests, task-branch commit/push, and exact-head task CI. It does not authorize official Task completion, status/checklist updates, `dev` integration, `main` changes, branch deletion, G1 promotion, or T11 work.

Known starting point:

- Start from the latest `dev`.
- Expected current `dev` and `origin/dev`: `1001613c441bd91944a3f9f818cc99527bfcd204`.
- Expected commit: `feat(recovery): recover interrupted sessions at startup (T09)`.
- `main` and `origin/main` must remain at `38e126f92ac823d29306ea8c1f7703f7060a5818`.
- Current full-test baseline is 210 tests; this is historical context, not a substitute for rerunning the baseline.
- Use `task/t10-app-lifecycle`.
- Preserve the coordinator-owned untracked file `prompts/T09_FRESH_SESSION_DIAGNOSIS.md`. Never stage, commit, modify, move, or delete it.

Do not implement:

- Pause/resume UI or actual pause behavior
- STT engines, models, model management, or downloads
- Transcript generation, merging, editing, or derived TXT/MD files
- Session list/player UI
- Recovery-file deletion
- T11 or any later Task
- XPC or multiprocessing
- A new persistent database schema
- Network behavior, telemetry, crash upload, or model auto-update
- G1 promotion, release packaging, or distribution

The current app has no pause implementation. Do not add pause merely to satisfy T10. Keep lifecycle work classification extensible enough to add a paused capture later.

## 2. Required context and preflight

Read in this order before editing:

1. The current user instruction
2. `AGENTS.md`
3. `PROJECT_STATUS.md`
4. The T10 section in `IMPLEMENTATION_PLAN.md`
5. `MVP_SPEC.md` chapter 7 and the relevant parts of 17.4 and 17.6
6. The T07–T09 sections of `docs/ARCHITECTURE.md`
7. The current build, test, and manual procedures in `docs/DEVELOPMENT.md`
8. The actual T07–T09 coordinators, composition root, views, and tests involved
9. The current Git state

Before editing:

- Inspect `git status`, the current branch, remotes, and recent log.
- Run `git fetch origin` and verify the actual remote refs.
- If `origin/dev` is the expected SHA, start there.
- If `dev` advanced, inspect the change and use the latest safe `origin/dev`. If another Task has started or the baseline conflicts with T10, stop without overwriting it and report the conflict.
- Run the unsigned arm64 Debug baseline build and full test suite.
- Verify the xcresult has a nonzero test count, zero failures, and zero skipped tests.
- A `testmanagerd`/helper sandbox error, unknown result, or zero executed tests is an environment failure, not a pass. Rerun in a normal Xcode test environment.
- Create `task/t10-app-lifecycle` only after the baseline is understood.

Preserve unrelated changes and untracked files. Do not use destructive reset, clean, or checkout operations to discard work.

## 3. Non-negotiable safety rules

1. Preserving recoverable audio and existing session bytes is more important than termination convenience.
2. Sleep, wake, window, and AppKit delegate callbacks must not synchronously perform long file or media work.
3. Normal user Stop and sleep/quit interruption must be separate operations. An interruption must never be recorded as a normal completed capture.
4. A recording interrupted by system sleep or essential-save-and-quit remains `interrupted/interrupted` with a stable reason.
5. If a normal user Stop already owns the securing transition, a later sleep/quit event must not rewrite that settled capture outcome to interrupted.
6. Sleep/quit must not wait for full M4A export, future transcript merging, or derived-file generation.
7. Never regress a durable checkpoint or mark an incomplete step complete.
8. Cancellation and cleanup must not delete recovery MOV, staging, canonical, or damaged files by pathname.
9. Concurrent sleep/wake/quit/window callbacks must still produce exactly one terminal save, activity release, and termination reply per owned generation.
10. Recheck operation generation and ownership after every relevant `await`; stale callbacks must not affect a later recording or lifecycle generation.
11. A SwiftUI View, `.task`, or view-model observation task must never own the recording, finalization, recovery, or lifecycle lifetime.
12. Application and Domain boundaries must not expose `NSApplication`, `NSWorkspace`, `NSWindow`, `NSAlert`, AppKit notifications, IOKit objects, `URL`, `NSError`, or a ProcessInfo activity token.
13. Keep AppKit/macOS objects in App or Infrastructure adapters.
14. Transient lifecycle values should be appropriately `Sendable` and `Equatable`; do not create unnecessary persisted schemas for ephemeral state.
15. Keep App Sandbox enabled. Do not invoke `caffeinate` or any subprocess to control sleep.

## 4. Work package A — app-lifetime work and sleep assertion

Create one application-lifetime source of truth for work that affects sleep and termination. Safely extend `SessionActivityRegistry` or add a small, clearly owned application work registry. Do not infer lifecycle from unrelated ViewModel booleans.

It must distinguish at least:

- Recording preparation or active capture, which is not a finite background job
- Essential securing
- T08 finalization queue/worker work
- T09 discovery/recovery work
- Termination cleanup
- Settled success
- Failure, reauthorization, or another user-attention state

Preserve the existing T07 recording reservation through T08 resource settlement. The transition recording → securing → finalizing must not briefly release the sleep assertion.

Use `ProcessInfo.beginActivity`/`endActivity`, or an equivalent official macOS API, behind an adapter.

While relevant work is active, the semantics must be:

- Disable idle system sleep
- Disable automatic termination
- Disable sudden termination
- Do not disable idle display sleep

Explicitly verify that the adapter does not request `.idleDisplaySleepDisabled`. Do not copy raw framework bit values into the Application layer.

Required behavior:

- Acquire once when the first relevant work starts.
- Do not acquire duplicates for overlapping work.
- Release once only after the final owned resource has settled.
- Release correctly after failure, cancellation, or termination cleanup.
- A late completion from an old generation cannot release the current assertion.
- No token leak on termination.
- The activity reason contains no title, root path, microphone/device identifier, or other user data.
- Closing a view does not end work observation.
- Construction and SwiftUI previews do not start observers, assertions, disk access, microphone authorization, or termination requests.

## 5. Work package B — sleep and wake

Add a real macOS adapter for:

- `NSWorkspace.willSleepNotification`
- `NSWorkspace.didWakeNotification`
- `NSWorkspace.willPowerOffNotification`

Convert them to small semantic events before crossing into Application. Do not expose Notification/AppKit types.

### B1. Active recording on willSleep

`RecordingSessionCoordinating.stop()` means normal user Stop and must not be reused unchanged for sleep.

Add a separate interruption/essential-save operation with a typed reason that distinguishes at least system sleep and application quit.

For a live recording, willSleep must:

1. Coalesce duplicate delivery for the same sleep generation.
2. Append one `systemSleep` event when possible.
3. Stop accepting new PCM.
4. Drain already accepted primary PCM.
5. Flush/stop the recorder and settle its resources.
6. Preserve the recovery MOV.
7. Durably write metadata as `interrupted/interrupted`.
8. Refresh the rebuildable catalog best-effort without replacing the first save error.
9. Avoid starting or waiting for full T08 finalization.
10. Avoid synthesizing a completed capture or normal recording completion.

If a later event/catalog/cleanup operation also fails, preserve the first typed failure and keep later errors as warnings. Never delete existing bytes.

If sleep arrives during preparation, retain the existing T07 durability rule:

- Before durable recording start: `.error/.notStarted`
- After durable recording start: `.interrupted/.interrupted`

### B2. Sleep during securing/finalizing/recovery

- If normal user Stop already owns essential securing, join that settlement rather than starting a second terminal path.
- Preserve its normal capture outcome.
- Signal active T08/T09 work to quiesce/cancel without inventing a completed checkpoint.
- Trust only fully durable completed steps.
- Settle open readers, writers, and security scopes before a later recovery owner can act.
- Preserve T08 first-error, file-identity, no-clobber, and recovery-retention rules.
- Do not block the notification callback waiting for asynchronous cleanup.

### B3. didWake

- Never restart capture automatically.
- Wait for the previous sleep generation's owned cleanup to settle before recovery begins.
- Reuse the existing application-owned T09 refresh/retry path.
- Resume `securing`/`finalizing` sessions from filesystem artifacts and the last durable checkpoint.
- Do not create a second finalizer or recovery implementation.
- Preserve T09 single-flight and current-process recording protection.
- Coalesce duplicate wake notifications and prevent busy-loop recovery.
- A stale wake callback cannot overwrite a new recording or a later sleep generation.
- Conservatively append `systemWake` where an identifiable interrupted session still exists. Event failure must not block recoverable audio work or replace the first error.
- If the process dies while asleep and cannot append a wake event, normal startup recovery remains the source of truth.

## 6. Work package C — window closing and automatic exit

Connect a real AppKit delegate bridge to the application composition.

The policy is:

1. Closing the final user window does not directly terminate the app.
2. It creates an in-memory, current-process-only auto-exit reservation.
3. It does not stop an active recording.
4. It does not cancel T08/T09 work merely because a View disappeared.
5. When there are no open user windows, no active/finite work remains, all relevant current work settled successfully, and no user-attention condition exists, request automatic termination exactly once.
6. If no work exists when the last window closes, the same policy may request termination immediately.
7. Finalization/save failure, reauthorization, or another explicit user-attention state blocks automatic exit.
8. Do not treat every harmless warning as a permanent blocker; model `requiresUserAttention` explicitly.
9. Reopening a window through the Dock or normal app activation cancels the reservation.
10. A late completion from the cancelled reservation generation cannot terminate the app.
11. Do not persist the reservation in UserDefaults, SQLite, or session files.
12. A new app launch always starts without an auto-exit reservation.
13. Main and Settings windows count as user windows. Document and test how transient/hidden framework windows and panels are excluded.
14. Immediately before calling the actual termination gateway, revalidate window generation, visible user-window count, work state, and attention state.
15. An automatic termination request must not be confused with an explicit user `⌘Q` and must not show a recording confirmation after work is already eligible to exit.

`applicationShouldTerminateAfterLastWindowClosed` must return the non-immediate-termination behavior and notify the lifecycle coordinator. Use the AppKit reopen callback or an equally reliable app-level event to cancel auto-exit when the user reopens the app.

## 7. Work package D — explicit app termination

Implement the AppKit termination contract correctly:

- Immediate safe exit maps to `.terminateNow`.
- Continue using the app maps to `.terminateCancel`.
- Asynchronous essential save/cleanup maps to `.terminateLater`.
- Every `.terminateLater` path eventually sends exactly one equivalent of `reply(toApplicationShouldTerminate:)` with true or false.

AppKit enums and objects stay in the adapter. Application returns semantic decisions/results.

### D1. No active work

- Terminate immediately.
- Do not show a confirmation or create disk writes.

### D2. Recording in progress

Offer exactly these actions:

- `계속 사용`
- `필수 저장 후 종료`

Closing a window must not show this dialog.

For `계속 사용` or dismiss:

- Cancel termination.
- Do not change recording state, events, metadata, files, or the activity assertion.

For `필수 저장 후 종료`:

1. Return terminate-later semantics.
2. Coalesce repeated requests into one quit attempt.
3. Stop accepting input.
4. Drain accepted PCM.
5. Flush/stop the recorder.
6. Preserve and durably settle recovery audio plus required metadata/events.
7. Record `interrupted/interrupted` with an application-quit stable reason, not completed.
8. Persist the available checkpoint/catalog state without fabricating later completion.
9. Quiesce/cancel app-owned T08/T09 work.
10. Wait only for owned reader/writer/security-scope cleanup.
11. Do not wait for final M4A export, transcript merge, derived files, or all later finalization.
12. Reply true exactly once only after essential save and resource settlement succeed.
13. Leave a state that the existing T09 startup recovery can resume.

STT does not exist yet. Do not create an empty transcript journal or placeholder. A narrow future participant boundary is allowed, but do not implement T11/T19/T20.

### D3. Already securing/finalizing

- Join an in-flight normal essential settlement.
- Do not rewrite a normal user Stop outcome as interrupted.
- Preserve completed durable checkpoints.
- Signal long-running finalization to quiesce and wait for cleanup, not export completion.
- Terminate only after owned resources settle.
- Ensure a fresh T09 service can resume the remaining work after relaunch.

### D4. Failure and reentrancy

- If essential save cannot establish a recoverable state, do not falsely reply true.
- Cancel termination, preserve bytes, and surface a user-attention state.
- Preserve the first typed error; append event/catalog/cleanup failures as warnings.
- Repeated Cmd-Q, menu Quit, and Dock Quit during one attempt must not duplicate the dialog, save, cancellation, assertion release, or reply.
- Generation guards must stop an old reply from terminating a later active state.
- Cancellation or adapter teardown must not leave a terminate-later request permanently unresolved.
- `willPowerOff`/logout must never wait for full finalization. Perform essential save and resource settlement only.
- The two-second essential-save limit is a product performance target. Use deterministic gates to prove that full finalization is not awaited; do not rely only on a flaky wall-clock assertion.

## 8. Minimal UI

Do not redesign the app.

Add only the UI needed for:

- The recording quit decision
- Essential-save progress
- Termination cancelled because essential save failed
- Recording interrupted by sleep
- A state requiring user attention that prevents automatic exit

The user-choice presenter must be behind a test seam so unit tests do not show a real modal dialog.

The actual application composition must own the lifecycle coordinator and macOS adapters. SwiftUI preview or View construction must remain free of observers, assertions, disk access, microphone prompts, and termination requests.

## 9. Acceptance matrix

Create `docs/T10_ACCEPTANCE.md`. Connect every row to real test functions, fixtures, assertions, commands, and results. Names or fake call counts alone are insufficient.

| ID | Required verification |
| --- | --- |
| A01 | Application lifecycle contracts expose no AppKit/IOKit/URL/NSError/ProcessInfo token; relevant values are Sendable/Equatable; construction and previews have no system, disk, microphone, or network effects. |
| A02 | Recording, securing, finalizing, and recovery acquire sleep/automatic/sudden-termination protection once and release it once after final resource settlement; overlaps, failures, and cancellations leak nothing. |
| A03 | The production adapter disables idle system sleep but does not disable display sleep; no `caffeinate` or subprocess exists. |
| A04 | Recording → securing → finalization and recovery ownership transitions have no assertion gap; stale completion cannot release a newer generation's assertion. |
| B01 | willSleep during active recording performs an interrupted durable save, with one systemSleep event, input stop, PCM drain, writer flush/stop, metadata ordering, and exact-once terminal effects. |
| B02 | Sleep injected before and after durable recording start yields `.error/.notStarted` and `.interrupted/.interrupted` respectively, with the first reason preserved. |
| B03 | Normal Stop securing racing with sleep keeps the normal capture outcome and one settlement. |
| B04 | Sleep during finalization/recovery quiesces current work and preserves files/checkpoints; wake waits cleanup and resumes through the shared T09 owner without restarting recording. |
| B05 | Duplicate, reordered, and stale sleep/wake events across multiple cycles cannot affect later recording or multiply events/recovery passes. |
| B06 | A production repository/audio-writer integration records synthetic PCM, interrupts it through the sleep path, retains a readable recovery MOV, writes interrupted metadata/events, and creates no premature `audio.m4a` or transcript placeholder. |
| C01 | Closing the main window while recording leaves capture, PCM/file progress, and app-owned observation running; close and explicit quit use distinct paths. |
| C02 | With no user windows, successful finite-work settlement requests automatic termination exactly once; failure/user-attention does not. |
| C03 | Reopen immediately before automatic termination cancels the reservation; late completion/request cannot terminate the reopened app. |
| C04 | Main plus Settings close order, Dock reopen, and transient/hidden-window filtering follow the documented last-user-window policy. |
| C05 | Auto-exit reservation is never persisted and is absent in a fresh application-lifecycle owner. |
| D01 | Explicit quit with no work terminates immediately without confirmation/save/terminate-later reply. |
| D02 | `계속 사용` cancels termination without mutating recording, files, events, or assertions. |
| D03 | `필수 저장 후 종료` follows terminate-later → interrupted essential save → cleanup → one true reply, while a blocked long finalization does not block termination. |
| D04 | Essential-save failure replies false/cancels termination, preserves original bytes and first error, and separates later warnings. |
| D05 | Quit during finalization preserves completed checkpoint and resources, does not wait for full export, and a fresh T09 service resumes it. |
| D06 | Concurrent/repeated quit produces exactly one confirmation, save, quiesce, activity release, and termination reply; cleanup must settle before a new attempt. |
| D07 | Power-off/logout semantics avoid waiting for long finalization and retain recoverable state. |
| E01 | `LocalLectureSTTApp` actually composes the app-lifetime owner, delegate bridge, workspace observer, and ProcessInfo adapter; View `.task` cancellation does not own them. |
| E02 | Existing T07 normal/abnormal settlement, T08 finalization, and T09 startup/root-change recovery retain ownership, first-error, identity, no-clobber, and file-preservation behavior. |
| E03 | Full Debug build/test and the final exact-head task CI succeed with real nonzero test counts and zero failures/skips. |

## 10. Deterministic test requirements

Use controllable continuation/barrier gates for concurrency. Do not use `Task.sleep` to make actor races merely likely.

Cover these races:

- Sleep versus normal Stop
- Sleep versus recorder flush failure
- Sleep cleanup versus wake
- Wake recovery versus new recording start
- Last-window close versus finalization completion
- Auto-exit decision versus reopen
- Continue-using decision versus active capture
- Repeated quit versus delayed essential save
- Essential-save success versus a late failure callback
- Finalization cancellation settlement versus termination reply
- Old lifecycle-generation completion versus a new recording

Await actor values into local variables before XCTest assertions. Do not reenter async actors while holding synchronous locks.

Choose representative tests for all of the following and run each 20 times:

1. Activity assertion acquire/release and generation
2. Recording sleep interruption exact-once
3. Sleep cleanup → wake recovery ordering
4. Window close → finite completion → auto-exit
5. Close/reopen/late-completion race
6. Repeated quit → essential save → exact-one reply
7. Finalization cancellation/cleanup → quit reply
8. Essential-save first-error and later-warning preservation

Report exact test identifiers, selected-test count, iterations, and total executions. Eight tests × 20 means the xcresult must show 160 executions.

Use only disposable roots and generated synthetic PCM/media. Do not use or commit real recordings, transcripts, model data, bookmarks, runtime DBs, or user Application Support data.

Tests for the AppKit adapter must inject a termination/reply gateway and must never terminate the test process. Verify coordinator state, ordering, file results, and stale-callback rejection in addition to call counts.

## 11. Recommended architecture boundary

Names may change to match the repository, but keep these responsibilities separated.

Application:

- Lifecycle policy/state machine
- Semantic power/window/termination events
- Active, finite, and user-attention work snapshot
- Interruption and essential-save orchestration
- Generation, single-flight, and exact-once reply rules
- macOS-framework-independent protocols

App/Infrastructure:

- `NSApplicationDelegate` bridge
- `NSWorkspace` notification adapter
- ProcessInfo activity adapter
- User-window/reopen observation
- Actual terminate request/reply
- Actual confirmation presenter

Existing coordinators:

- `RecordingSessionCoordinator`: separate normal Stop from typed interruption while retaining the current single-flight and first-error policy.
- `RecordingFinalizationCoordinator`: submit only normal secured Stop to T08; do not enqueue full finalization for an interrupted result.
- `AudioFinalizationCoordinator`: add only the minimum app-owned quiesce/settlement seam needed by T10, preserving active/pending jobs and cleanup semantics.
- `SessionRecoveryCoordinator`: reuse its existing wake refresh/retry flow; do not create another recovery owner.
- `SessionActivityRegistry`: preserve T07/T08/T09 mutual exclusion and the ownership interval through final settlement.

Compose one lifetime in `LocalLectureSTTApp`. Do not add a global mutable singleton, XPC, or another process.

## 12. Documentation

Update `docs/ARCHITECTURE.md` with:

- The T10 app-lifetime owner and adapter boundary
- Activity/work sources
- Normal Stop versus interruption
- Sleep → quiesce → wake → T09 resume flow
- Last-window auto-exit reservation and reopen generation
- Explicit quit terminate-later/reply flow
- The T11/T20/T26 boundaries

Update `docs/DEVELOPMENT.md` with actual targeted/full/repeated commands and a disposable-root manual procedure covering:

- Display sleep allowed while active work prevents user-idle system sleep
- Close the window during recording, reopen through Dock, and confirm recording continued
- Close the window during finalization and confirm process exits after successful settlement
- Recording `Cmd-Q → 계속 사용`
- Recording `Cmd-Q → 필수 저장 후 종료`, then relaunch/recovery
- Lid close during recording: interrupted, no automatic capture restart
- Lid close during finalization: wake and resume

Do not claim that physical TCC/microphone, lid close, logout, process kill, or power loss passed unless actually performed. Keep them explicitly manual/pending where applicable.

Create `docs/T10_ACCEPTANCE.md` with requirement-to-assertion traceability and the actual final results.

Do not modify `PROJECT_STATUS.md` or the `IMPLEMENTATION_PLAN.md` completion checklist in Phase 1.

## 13. Validation

Run the final full build/test from the task HEAD using an isolated path, for example:

```sh
xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T10-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build test
```

Use a unique xcresult path and verify:

- Build succeeded
- Test count is nonzero
- Zero failures
- Zero unexpected failures
- Zero skipped tests
- Existing baseline tests are still included
- New T10 tests actually run in the shared scheme and CI

Run the selected T10 races with real `-only-testing:` identifiers and `-test-iterations 20`.

Re-run relevant T07–T09 regressions for:

- Normal Stop completed outcome
- Abnormal interrupted outcome
- Essential-save PCM drain
- Finalization queue resource settlement
- Recovery/current-recording exclusion
- Wake recovery single-flight
- Canonical/recovery identity and no-clobber
- First-error preservation
- Exact-once security-scope release
- View observation cancellation not cancelling app-owned work

Do not copy historical pass counts into the final report.

## 14. Git and Phase 1 submission

Only after the complete acceptance matrix passes:

1. Review the entire task diff and staged diff.
2. Stage only T10 paths.
3. Keep `prompts/T09_FRESH_SESSION_DIAGNOSIS.md` untracked and untouched.
4. Do not commit generated media, logs, DerivedData, xcresult, runtime DB/bookmarks, `.app`, models, credentials, or user data.
5. Commit with T10 in the message. Recommended message:
   `feat(lifecycle): handle sleep windows and safe app termination (T10)`
6. Push only `task/t10-app-lifecycle`.
7. Confirm GitHub Actions for the exact final task HEAD SHA.
8. A green CI for an older commit is not sufficient.
9. Fix task CI failures in the same T10 session and repeat affected/full validation.
10. Do not merge or push `dev` or `main`.
11. Do not delete the task branch.
12. Do not update official Task status or checklist.
13. Do not start T11.

Do not stop after a progress report when no real product decision or external blocker exists. Resolve implementation issues within T10 and continue through commit, push, and exact-head CI. Stop only when proceeding would require changing confirmed product behavior, weakening data preservation, discarding user work, or expanding beyond T10 authority.

## 15. Required final report

Report `T10 — review ready` only if every mandatory automated condition passes. Otherwise report `blocked` and name every unmet acceptance ID.

The report must contain:

- Task branch and final commit SHA
- Exact-head CI URL, run ID, head SHA, and result
- Starting `dev` SHA
- Changed files
- App-lifetime ownership and adapter design
- Normal Stop versus sleep/quit interruption behavior
- Sleep/wake, close/reopen, and explicit-quit policy
- Acceptance ID → actual test/assertion mapping
- Full build/test commands and actual pass/fail/skip counts
- Repeated-test function names and total executions
- Real-file integration result and retained artifacts
- Confirmation that the coordinator-owned untracked file was preserved
- Remaining manual TCC/microphone/lid/logout/power-loss verification
- Specification deviations, if any
- Remaining risks
- Confirmation that `PROJECT_STATUS.md`, the checklist, `dev`, and `main` were unchanged
- A statement that official T10 completion and T11 readiness remain the coordinator's decision after independent review and separately authorized Phase 2 integration

If blocked, keep the task branch and all recoverable work. Do not delete anything or claim completion. Report the current branch/SHA, commit/push state, failing command and exact error, unmet acceptance IDs, and safe preserved state.
