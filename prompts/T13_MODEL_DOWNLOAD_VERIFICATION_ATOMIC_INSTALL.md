# T13 — explicit model downloads, resumable transfer and verified atomic installation

## 1. Assignment and authorization

Implement **T13 only** in `/Users/andyoon/stt`, in a fresh implementation session. Retain the user's current implementation setting: **Astra / high**. Previous chat history is unnecessary. Do not change models or spawn additional agents automatically.

The coordinator independently verified T12's implementation and dev integration. This is the separate T13 assignment anticipated by `PROJECT_STATUS.md`. **G1 remains Unverified** under the user's approved deferral; it is neither passed nor waived and does not block this assigned Task. Report an actual recorder defect if discovered, but do not expand into G1, recorder repairs or later Tasks without authorization.

Finish a **Phase 1 review-ready task branch**: implementation, meaningful tests, documentation, task commit/push and CI for the final task commit. **Do not** mark T13 officially complete, update `PROJECT_STATUS.md` or the implementation-plan checklist, integrate/push dev/main, delete the task branch, create a release/tag, or implement T14. Independent coordinator review and a separate integration instruction are required later.

## 2. Context and preflight

Read in order:

1. This prompt and `AGENTS.md`.
2. `PROJECT_STATUS.md`.
3. T13 in `IMPLEMENTATION_PLAN.md`; T12/T14 only for dependency boundaries.
4. `MVP_SPEC.md` **15.1, 15.2, 17.7**; **9.2, 12.5, 15.3, 15.4** only for installed-model and preservation constraints.
5. Actual Git state and relevant code; the T12 architecture/development/acceptance sections, including its three review repairs.

Observed baseline at prompt creation:

```text
branch: dev
dev/origin/dev: 1ff211ffbf73f7d35818a4f2e5d154c21fe5bb63
main/origin/main: 38e126f92ac823d29306ea8c1f7703f7060a5818
latest integrated Task: T12
coordinator's baseline validation: 332 passed (322 unit + 10 integration)
T12 selectors: 33; T11 selectors: 35
dev CI: https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43416397557
```

Inspect root, status, branches, remotes and recent log before editing. Safely fetch/check latest dev and use **`task/t13-model-download-install`**. If dev moved, inspect and retain its changes instead of discarding them or pinning an obsolete baseline. Preserve unrelated WIP/untracked files, especially `prompts/T09_FRESH_SESSION_DIAGNOSIS.md` and `prompts/T10_REVIEW_REPAIR.md`, untouched/unstaged/uncommitted. No reset/clean/discard, stash, broad staging or force-push.

No tracked WIP currently needs carrying. This prompt may be untracked and belongs in the eventual T13 commit. Run a baseline full build/test once before implementation and record actual counts; the historical 332 count is not a fresh execution.

Relevant implementation:

- `Domain/ModelPackage.swift`: validated version-1 descriptors/catalog/manifests, keys and stable payload checksum. The production catalog is deliberately empty.
- `Application/ModelRepository.swift`: URL-free Codable/Sendable payloads and typed repository outcomes.
- `Infrastructure/FileModelRepository.swift`: offline inventory, compatibility seam, per-store/key arbitration, pinned verification, local import and confirmed deletion.
- `Infrastructure/ModelPackageFiles.swift`: bounded copy/hash, descriptor ownership, no-follow traversal, fsync and no-clobber publication.
- `Infrastructure/SessionModelReferences.swift`: read-only authoritative references; not part of download storage.
- `Resources/model-catalog.json`, `LocalLectureSTTTests/ModelRepositoryTests.swift`, app entitlements, shared scheme and `.github/workflows/macos-ci.yml`.
- App construction currently creates no downloader. The existing entitlements have no outgoing-network permission. Preserve the recorder/lifecycle composition.

## 3. Deliverables and scope

Implement explicit catalog-driven download requests; disk-capacity assessment; real URLSession file-transfer Infrastructure; interruption/resume and explicit retry/cancel; private durable download state; integration with the T12 verification/atomic-install pipeline; offline/no-startup-network behavior; deterministic faults/races plus actual local HTTP transfer tests.

This Task implements the service/API for a later download button. **Do not build model-management UI**, choose a default model, download real weights, add WhisperKit/whisper.cpp, recognize their native formats, load/infer a model, wire STT to recording, change transcript/lifecycle behavior or implement T14/T15/T21. Add only the minimal production network-client entitlement needed for user-initiated model downloads. Do not disable Sandbox or add production server/broad ATS exceptions for tests.

No product model has been selected. Keep the production catalog empty unless separately authorized; do not invent model URLs, revisions, hashes or license claims. Test the complete pipeline with tiny generated packages and an injected nonempty catalog/format recognizer. `UnavailableModelFormatValidator` must continue reporting unvalidated/unavailable in live code; never replace it with an always-true default to produce a successful demo.

## 4. Catalog, boundaries and operation identity

Extend the fixed bundled catalog minimally with validated per-payload download locations, or a bundled delivery table referencing its exact descriptors. Keep existing descriptor/manifests, namespace mapping, `ModelIdentity.checksum` algorithm and old v1 decoding behavior compatible. Adding delivery metadata must not silently change installed package identity or local-import semantics. Document any backward-compatible optional catalog fields and test old/new/malformed/future decoding.

- Every downloadable entry references an exact engine/model/revision descriptor and has exactly one delivery mapping for each required payload path. Reject missing/duplicate/orphan mappings, unsafe paths, contradictory sizes/hashes and unsupported metadata. Checksums/lengths remain authoritative in the descriptor, not in an HTTP response or downloaded manifest.
- Production locations must be valid HTTPS URLs without embedded credentials; validate redirects without disabling TLS verification or permitting downgrade. Bind bytes to the catalog path, not Content-Disposition, redirected filenames or a server-provided install path. Public fixed resources suffice; do not build login/token/provider discovery or a general model-hub client.
- Accept download/start/resume/retry commands through exact catalog keys and opaque operation IDs. Do not expose a general arbitrary-URL download API in Application. Inject fixture catalog/endpoints for tests; HTTP loopback allowance is test configuration only.
- Boundary snapshots, progress, operation IDs, capacity assessments, failures and results are Codable/Sendable values; no URLSessionTask, URL/bookmark, NSError or engine-library types cross the new Application/Domain boundary. Opaque resume data and filesystem leases stay in Infrastructure/private storage.
- Correlate every callback with operation ID, attempt generation and payload identity. Publish bounded/coalesced progress separately from install readiness. Each accepted attempt has one terminal settlement; pause is an intermediate state. Late observers can obtain retained terminal state, and stale progress/completion cannot overwrite it or a newer attempt.

An explicit method call represents the later user's button action. Construction, previews, catalog loading, inventory, validation, session loading and reading pending-download metadata must not create/resume network tasks or perform HEAD/version/catalog requests. No automatic update, remote catalog check, telemetry or general automatic retry loop.

## 5. Capacity and private storage

Put temporary downloads, receipts and bounded operation/resume metadata in a dedicated app-owned Application Support download area, separate from visible installed namespaces and lecture roots. Resolve the live location lazily; inject disposable test roots. Preserve unknown/future/damaged operation records rather than deleting them on startup. Pending-state inspection is read-only and offline.

Before any transfer starts, calculate an overflow-checked requirement from expected payload lengths and the actual maximum simultaneous storage footprint, including any second copy made by the T12 installer, already retained bytes and a documented safety margin. Query capacity on the correct destination volume through a narrow injectable provider. Unknown/inaccessible capacity must not be treated as unlimited or zero needed bytes. Insufficient capacity returns a typed assessment/failure **before creating/resuming network tasks**. Repeat the relevant check on explicit resume/retry when remaining storage needs change.

Preflight is not a reservation: disk-full/write/fsync/move errors during download, manifest settlement and publication still need typed failure/cleanup handling. Never delete existing models/session data to make space. Use bounded file I/O for weights; no model-sized `Data(contentsOf:)` or `data(for:)` download-to-memory path.

## 6. URLSession transport and resume behavior

Provide a real `URLSessionDownloadTask`/delegate transport behind narrow seams. Support background configuration where applicable to this macOS target, plus an injectable ordinary session for deterministic local tests. Inspect the installed SDK and the Apple references below; do not copy iOS app-delegate assumptions into the macOS app.

Implementation points:

1. Receive download progress and task completion through one operation owner. HTTP error bodies can arrive as completed download files: reject unsuccessful response status, truncated/oversized bytes, move/write failures and invalid receipts before install. Handle error completion without a file, file receipt followed by error completion, duplicate/delayed callbacks and invalidation exactly once. A nil transport error alone is not installation success.
2. Preserve/open the temporary file **before the download delegate returns**. Scheduling an asynchronous Task that later uses the unretained temporary URL is invalid. Transfer the receipt into proven operation-owned storage without following/replacing unrelated paths, then hand an opaque receipt to asynchronous orchestration. No long hashing on the delegate queue.
3. Persist only bounded private resume metadata, operation/catalog fingerprint, completed payload ownership and task association. Treat Apple resume data as opaque and potentially unavailable/stale; do not manufacture or rewrite its internal plist/path fields. Revalidate retained completed files and exact catalog identity before reuse.
4. Give the controller a resumable-interruption/pause path distinct from explicit discard/cancel. For an eligible interruption, retain safe resume information and report resumable state. Resume/retry require an explicit command. If resume is unsupported, data is missing/invalid, a resource changed, or the OS rejects resumption, report the fallback truthfully and safely restart the affected file from byte zero within that explicit command. Do not append a full 200 response to a partial file or call a restart a successful byte-range resume. Bound fallback attempts; no infinite silent retry.
5. Background tasks may already represent the original explicit download. On an explicit reconnect/resume, reconcile stable session/task IDs before starting another task; do not create a duplicate transfer for a live task. Fresh launch/pending-list reads must not automatically create new requests. Document OS-managed continuation separately from application-initiated retry. This Task does not promise force-quit relaunch, lid-closed execution or a new app-exit policy.
6. Explicit cancel settles transport callbacks and removes only proven operation-owned disposable state, preserving installed models, other operations and unknown files. Preserve resumable state only when that outcome is explicitly reported; do not leak files while reporting clean cancellation. A paused/interrupted operation can be reconstructed by a fresh service instance from its private state and resumed only by an explicit command.

Choose one coherent transfer/resume design, not competing download frameworks. A non-background test session does not prove system-daemon/process-relaunch behavior. Conversely, a fake transport alone does not prove the actual URLSession adapter works.

Apple references (verify relevant SDK behavior during implementation):

- [Pausing and resuming downloads](https://developer.apple.com/documentation/foundation/pausing-and-resuming-downloads): resume tokens are optional and background transfers have system-managed resumption behavior.
- [Download completion temporary-file lifetime](https://developer.apple.com/documentation/foundation/urlsessiondownloaddelegate/urlsession(_:downloadtask:didfinishdownloadingto:)): the file must be secured before returning from the callback.
- [Background session configuration](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)): distinguish platform behavior and configuration identity from app policy.

## 7. Share T12 verification and publication, preserve ownership

Downloaded bytes must pass the **same real** full-file-set/size/SHA-256/declared-compatibility/offline-format checks and durable no-clobber installation as local imports. Mark catalog origin only for the exact trusted bundled descriptor. Missing format validation is a typed unavailable outcome, never installed/usable success. No archive extraction or online engine validation is required.

The existing public local-import API expects an external selected source and scope. It is acceptable and necessary to extract a **minimal internal shared installer/owned-staging entry point** from T12. Do not fake a user security-scope grant for an app-owned download, duplicate a second verification algorithm, or bypass the repository with a direct final-directory move. Existing T12 public behavior and safety tests must remain intact.

Define the publication commit point once. Keep original verification evidence across every await, including manifest write, transport cleanup and scope/lease release. Revalidate pinned identities and contents after suspension. Before publication, cancellation/failure yields no usable partial install. After successful no-clobber publication, cancellation/durability/cleanup warnings report the committed install truthfully and cannot delete it as temporary work.

Arbitrate download/local-import/validation/deletion for the same store/key through a shared ownership policy across service/repository instances. Do not accidentally acquire the same nonreentrant claim twice when the downloader calls the shared installer. Model claims and transport-task ownership survive awaits and necessary cleanup. An old callback, resume journal or cleanup cannot publish/remove a newer attempt, release its claim or mutate a sibling revision.

Retain all T12 guarantees: existing/corrupt/unknown same-key installs are not overwritten or automatically repaired; identical verified installed content may return idempotent success after revalidation; revisions coexist; defaults and session references are unchanged. On process interruption, a final revision and stale download journal must reconcile conservatively on explicit retry, without republishing or deleting the committed model.

All recursive removal requires proven operation ownership and pinned no-follow identity. A lexical prefix check is insufficient. Test replacement of download/staging roots, nested payload paths and final install target around awaits. Unknown symlinks, special files, swapped directories and cleanup failure leave diagnosed preserved remnants, not broad cleanup of a download/model/session root. Retain first error separately from cleanup error.

## 8. Acceptance matrix

Create `docs/T13_ACCEPTANCE.md`: **ID → exact test function → fixture/gate/assertion → actual executed result**. Tiny generated packages only. Exercise production services/adapters through injected seams rather than a parallel toy implementation. Cover these cases, combining related assertions where that keeps the suite clearer:

| ID | Required proof |
| --- | --- |
| T13-01 | Old T12 catalog/manifests and namespace/package digests stay compatible. New delivery DTOs decode/round-trip correctly; malformed/future/duplicate/missing mappings and invalid URLs/paths fail. Production catalog remains empty; real bundle membership is tested. |
| T13-02 | Construction/previews and catalog/inventory/validation/pending-list operations make zero transport/session/task/network requests. Only explicit start/resume/retry can initiate transfer. Offline T12 inventory/validation and existing app construction still work. |
| T13-03 | Capacity rejection occurs before network start; exact boundary, unknown/unavailable capacity, sum/footprint overflow, retained-byte resume accounting and injected mid-transfer disk-full are tested. No deletion of installed/session data. |
| T13-04 | Genuine URLSession download against a controlled local HTTP server receives a generated multi-file nested package and installs it through the real T12 pipeline; source server can then disappear and a fresh repository validates/resolves the app-owned copy offline. Check actual final bytes and identity, not just status/progress. |
| T13-05 | Controlled resumable interruption preserves state and explicit resume reuses earlier progress without duplicate tasks. Use actual URLSession/local-server range or resumed-offset evidence for at least one successful resume, plus deterministic service tests across a fresh instance. Nil/corrupt/stale resume data, changed resource and server non-support have truthful bounded restart/error behavior. A full restart alone does not satisfy the successful-resume case. |
| T13-06 | The actual background configuration/factory and session/task association are exercised through testable seams; reconnect finds an existing task instead of starting another. Pending reads stay inert. OS daemon/process-termination behavior has a reproducible separately labeled manual procedure, not a fake automated pass. |
| T13-07 | Temporary receipt survives callback return; HTTP 404/500, error without receipt, receipt then error, truncated/oversized/wrong checksum, format rejection/unavailable validator, move/write/fsync faults and redirect-policy rejection cannot publish an install. Header/progress/manifest claims cannot bypass destination-byte validation. |
| T13-08 | Cancellation at request creation, active transfer, pending receipt, verification, manifest write, prepublication and postpublication has exact terminal/cleanup ownership. Late observer sees terminal result. Retained callbacks cannot revive an old generation. Postcommit cancellation/failure preserves the committed model and reports its warning. |
| T13-09 | Duplicate same-key download, download versus local import/deletion, cancel-then-retry and old cleanup versus new attempt are ordered by acknowledged gates. No duplicate final publication, claim/lease leak or stale release; unrelated revisions remain intact. |
| T13-10 | Download root/staging/payload/final-target replacement around I/O/awaits cannot touch unrelated sentinels. Collision, failed cleanup and retained/unknown/future operation state preserve existing installs and source/session files. Only proven owned temporary data is removed. |
| T13-11 | Completed payloads and catalog fingerprint are rechecked after interruption; partial files/journals never appear as installed models. A fresh service plus committed install/stale journal reconciles idempotently on explicit retry, offline existing-model use still works, and revisions/defaults remain unchanged. |
| T13-12 | Real transport and deterministic fault suites use bounded progress and exactly one terminal per attempt despite duplicate/out-of-order callbacks. Foundation cancellation/error information maps to typed failures without erasing first cause or cleanup diagnostics. Resources/tasks/servers are joined on all test paths. |
| T13-13 | All 33 T12 selectors, including its three review regressions, and existing T05–T11 regressions remain enabled and pass. No new engine dependency, real weights, model UI, recorder/STT wiring, automatic update or T14 work. Network-client entitlement is minimal; production TLS/Sandbox policy is retained. |
| T13-14 | Full arm64 Debug build/test executes both targets with nonzero counts and zero failures/skips; final task SHA CI succeeds. Status/checklist/dev/main remain unchanged, task branch remains available, and G1 remains Unverified. Actual commands/counts/results and manual limitations are recorded. |

For deterministic tests use acknowledged continuation/barrier/server handshakes, not `Task.sleep`, yield loops, polling or arbitrary repeat quotas. A timeout is a failure watchdog only. A local HTTP fixture must acknowledge request/range/body delivery and interruption conditions; close/join server workers/tasks on test failure. Do not depend on internet availability, production CDNs or system-daemon scheduling in CI. Do not claim a URLProtocol fake tests background URLSession. A small loopback fixture and an injectable normal session may test the same production transport delegate without weakening production HTTPS policy.

Preserve these T12 regression selectors explicitly:

```text
ModelRepositoryTests/testReviewPayloadMutationAfterVerificationMustNotPublishSuccess
ModelRepositoryTests/testReviewIdempotentResultMustRevalidateAfterScopeRelease
ModelRepositoryTests/testReviewFutureManifestSchemaMustBeReportedWithoutV1Fields
```

## 9. Work order, documents and local validation

Work through delivery schema and operation/capacity contracts → shared T12 install seam → real transport/receipt ownership → resume/private state → cancellation/concurrency → actual HTTP integration and fault tests → documentation/full validation. State important implementation assumptions briefly and proceed. Ordinary design choices, incomplete tests or implementation difficulty are work to finish, not reasons to end at a progress report. Do not grow this into a general provider/plugin/job system.

Update `docs/ARCHITECTURE.md` with actual delivery authority, no-network admission, transport and ownership boundaries, resume/fallback semantics, capacity formula, shared installer commit point and retained-state policy. Update `docs/DEVELOPMENT.md` with actual focused/full commands, entitlement changes, fixture requirements and a Pending manual signed-Sandbox/background interruption/relaunch procedure. Distinguish test-proven resumability from remaining OS/hardware checks and real-model inference. Do not claim the whole 17.7 offline MVP suite has passed before those later features exist.

Run the relevant focused suites while developing, then one full validation on the final executable tree. Example:

```sh
t13_run="$(mktemp -d /private/tmp/stt-t13-validation.XXXXXX)"
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$t13_run/DerivedData" \
  -resultBundlePath "$t13_run/Full.xcresult" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path "$t13_run/Full.xcresult" --compact
xcrun xcresulttool get test-results tests --path "$t13_run/Full.xcresult" --compact
```

Use unique result paths; verify real unit/integration/T13 counts, required regressions, zero failures/unexpected failures/skips, bundle/test membership and no new attributable compiler warnings. Do not copy baseline counts or infer correctness from exit code alone. Runner/testmanagerd/cache restrictions require the permitted normal Xcode/approval path; zero execution is not a pass. Keep failed attempts visible and fix same-Task failures. Do not disable tests or rewrite legacy assertions merely to hide a failure.

## 10. Phase 1 commit, push and final handoff

1. Review the complete task diff, staged diff, `git diff --check`, acceptance assertions, cleanup ownership and scope. Stage explicit T13 source/test/resource/project/entitlement/doc paths and this prompt only. Preserve unrelated files. Never commit model weights, real media/transcripts, resume data, runtime journals/DBs, download/staging roots, logs, secrets or build artifacts.
2. Commit only on `task/t13-model-download-install`, with T13 in the message, e.g. `feat(models): add explicit resumable downloads and verified install (T13)`.
3. Confirm the committed source/tests/configuration match the tested tree. Executable changes require affected/full revalidation; do not reuse stale results. Supporting evidence documentation does not require a circular future-SHA amendment.
4. Push only the task branch without force. Verify CI for **the exact final commit**; prior source/dev green runs are insufficient. Fix same-Task failures, commit/push and verify the new SHA if necessary.
5. Leave the task branch for independent review. No official completion/status/checklist update, dev/main integration, branch deletion, release or T14 work.

Report **`T13 — review ready`** only after every automated acceptance, local validation, commit/push and final-commit CI passes. Manual checks explicitly separated above remain Pending. If a real unsafe product conflict, conflicting user work or unresolvable external prerequisite prevents completion, report **`T13 — blocked`** with the concrete cause/unmet IDs and preserve work. Do not call missing implementation/testing a completed candidate.

Final report: starting dev, task branch/final SHA; exact CI URL/head/result; changed files/design decisions; catalog compatibility and capacity formula; real transport/resume evidence and fallback limits; commit/cancel/cleanup/claim ownership; ID-to-test/assertion mapping; exact commands/result paths and actual unit/integration/T13 pass/fail/skip counts; new/manual risks and any deviations; unchanged unrelated files/status/checklist/dev/main; G1 Unverified and no actual inference. Official completion/integration and whether T14 is safe to start remain the coordinator's independent post-review decision.
