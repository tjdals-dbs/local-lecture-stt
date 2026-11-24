# T22 active recording and live transcript UI

Base: dev `198d1ef501da79af9109c27e82e111a4afc8a7e1`. Branch: `task/t22-active-recording-transcript-ui`. Scope: IMPLEMENTATION_PLAN T22; MVP_SPEC 3.1, 4.3, 5.2. The user authorized implementation, a separate read-only review, repairs, task tests/CI, dev integration tests/CI and branch cleanup on 2026-11-25. G1 remains unverified; main and T23/T24 are outside this authorization.

| Requirement | Evidence |
| --- | --- |
| Stable final text, identity, order and timestamps; overlapping/equal timestamps retained | `ActiveRecordingUITests.testAppendingAcrossPageBoundariesPreservesEarlierIdentityOrderAndOverlappingTimes` |
| Long history does not republish on partial updates | `testTenThousandFinalsAreUnchangedByOneThousandPartialUpdates`: 10,000 finals, 1,000 partial replacements, zero history/page publications; bounded 64-row pages |
| Partial → final, empty partial and reopening observation | `testPartialToFinalTransitionAndLateSubscriberKeepDurableFinals` |
| No old-session text leaks into a new recording | `testNewSessionWithSameFinalCountClearsOldContentAndResetsFollowSignal` |
| Manual scroll takes priority, explicit Latest and bottom restore following | `testUserScrollSuspendsFollowingUntilBottomOrExplicitLatest`; native gesture procedure below |
| Nonblocking STT failure, journal warning, backlog and discontinuity | `testNoticesDoNotInvalidateFinalOrPartialContent` |
| Elapsed/level updates do not republish history; read-only configuration and Stop still available during STT/journal failure and no-input | `testMeterAndElapsedUpdatesDoNotInvalidateTranscriptAndStopSurvivesSTTFailure` |
| Finalization/remaining STT and observation lifetime | `testFinishingAndObservationRestartPreserveFinalsWithoutOwningRecording`; full existing T07/T08/T19/T20 tests |
| Visible final/partial labels, read-only selectable text, stop above scroll area, all background finalizations with retry diagnostics | SwiftUI source review and manual procedure in DEVELOPMENT |

Automated presentation tests verify publisher isolation, content and action routing, not actual frame rate, native gesture behavior or real lecture inference performance. The append-only contract comes from `LiveSTTCoordinator` publishing each segment only after journal append. This UI never changes canonical files or claims the G1 hardware gate. Exact test counts, frozen-source review and CI evidence are recorded after execution, not inferred from this matrix.

See [development procedure](DEVELOPMENT.md#t22-active-recording-and-transcript-verification).

Background regression coverage: `testBackgroundSummaryKeepsEarlierFailureVisibleBesideAnotherSession` checks that a later pending session cannot hide an earlier failure. `testRetryPreservesReadOnlyVerificationOperationAndSeparateJobIdentity` drives the real finalization coordinator through both resume and verification retries, preserving operation/location and distinct generation IDs.

## Local candidate validation

`FullFinal.xcresult` passed **548 XCTest (529 unit + 19 integration)**, zero failures/skips, after the arm64 unsigned Debug build. `Repeated.xcresult` passed all 10 `ActiveRecordingUITests` × 10 iterations (**100 executions**). SwiftPM benchmark compilation and the four Python comparison tests passed. The meter test observes 100 distinct input levels as elapsed time changes; none republishes transcript history. Exact commands and manual limitations are in DEVELOPMENT.

Earlier checks caught Swift 6 isolated Equatable declarations, test-fixture language construction and the old T07 pending-finalization text expectation. They were corrected before this final run. Background review also found session-ID collisions between resume/verification rows and operation loss during retry; generation IDs and the real-queue regression above cover the repaired behavior.

Release build and `tools/verify_product_engine.py` passed: native engine linkage, bundle contents and the pinned product catalog are preserved. Candidate CI and the separate frozen-source review remain prerequisites for integration; their actual evidence is recorded at integration.

## CI toolchain compatibility repair

Initial candidate `57f78cf` passed the local Swift 6.3 checks above, but [CI 45451593261](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45451593261) failed its build on Xcode 16.4 / Swift 6.1.2: isolated Equatable conformances require newer compiler syntax. The repair compares immutable `ObjectIdentifier` values in nonisolated equality operators; observed state remains main-actor owned. Segment rows compare immutable Sendable segment values. No runtime isolation check is suppressed, CI/deployment requirements are unchanged, and the repaired source requires fresh full tests/Release/CI and a separate diff review before integration.

The repaired source passed `CompatibleFull.xcresult`: **548 tests, zero failures/skips**; `CompatibleRepeated.xcresult`: **100 T22 executions, zero failures/skips**; and the Release build/product-engine verification in `CompatibleRelease.log`. The final source commit's CI and read-only review are recorded by the integration handoff.

## Separate frozen-source review and dev integration

The read-only review of `c3d7da78be0263802c342573bd4b0ce192d80165` checked the acceptance matrix, full task diff, append-only durable-final producer, view observation/identity boundaries, deferred-scroll intent check, recorder action independence and background retry routing. No blocking source or automated-acceptance finding remains. [Exact-source CI 45452433075](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/45452433075) passed on the existing Xcode 16.4 / Swift 6.1.2 runner. Application, Domain, Infrastructure, dependencies and canonical-file semantics are unchanged.

The approved source is squash-integrated onto the rechecked dev base `198d1ef501da79af9109c27e82e111a4afc8a7e1` under the explicit continuous-work authorization. Only status/checklist and this evidence differ from the reviewed tree. Validation on the committed dev uses `/private/tmp/stt-t22-work/CommittedDev.xcresult`, then SwiftPM/Python/Release checks and exact-dev CI. The delivery records their actual results and branch cleanup after execution. G1 and main remain unchanged; manual limitations above still apply.
