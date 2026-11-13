# T12 — model repository, manifests, local import and deletion policy

## 1. Assignment and authorization

Implement **T12 only** in `/Users/andyoon/stt`, in a fresh implementation session. Session setting: **Astra / high**, retaining the user's current implementation setting. Previous conversation history is unnecessary; do not automatically switch models or spawn additional agents.

The user has approved moving on after T11's integration. This assignment is the separate T12 implementation instruction mentioned in the status document. **G1 remains Unverified**, under the user's decision to defer its manual checks while development proceeds. Do not treat that unverified gate as a T12 blocker or mark it passed. A demonstrated recorder defect remains a real issue to report, not something the deferral permits ignoring.

Deliver a **Phase 1 review-ready task branch**: implementation, meaningful automated tests, accurate docs, task commit/push and CI for the final commit. Do not mark T12 officially complete, update its checklist, merge/push dev/main, delete the task branch, create a release/tag, or implement T13. Those require later independent review and separate authorization.

## 2. Context and preflight

Read in order:

1. This assignment and `AGENTS.md`.
2. `PROJECT_STATUS.md`.
3. T12 in `IMPLEMENTATION_PLAN.md`, plus T13 only to understand the boundary.
4. `MVP_SPEC.md` **9.2, 9.3, 12.5, 15.1, 15.3, 15.4**. Read 15.2 only to align local verification/publication semantics with the future downloader.
5. Actual Git state and relevant code below; relevant architecture/development sections as needed.

Observed baseline at prompt creation:

```text
branch: dev
dev/origin/dev: c9f03f4ead5956cecfa50870ddd6ad87a443d622
main/origin/main: 38e126f92ac823d29306ea8c1f7703f7060a5818
latest integrated Task: T11
historical full validation: 299 tests, including 35 T11 tests
```

Verify repository root, status, remotes, recent log and live refs. Safely fetch/check latest dev, then use **`task/t12-model-repository`**. If dev moved, inspect the changes and preserve them; do not pin to an obsolete baseline or discard concurrent work. Preserve existing unrelated tracked/untracked files, including `prompts/T09_FRESH_SESSION_DIAGNOSIS.md` and `prompts/T10_REVIEW_REPAIR.md`, untouched/unstaged/uncommitted. No reset, clean, checkout-discard, stash, broad staging or force-push.

The worktree currently has no tracked WIP; this prompt may be untracked. Unlike the initial T11 handoff, no pre-existing planning-document changes need carrying: **leave `PROJECT_STATUS.md` and the implementation-plan checklist unchanged during Phase 1**.

Run and record a baseline build/test once before implementation, with real nonzero unit/integration counts. Historical counts are not a new execution.

Relevant existing code:

- Domain `Identifiers.swift`, `DomainPrimitives.swift`, `SessionDocuments.swift`: validated engine/model identities, schema policy and authoritative session model references.
- Domain `STTContracts.swift`: `STTModelConfiguration` and immutable model/session provenance.
- Application `STTEngine.swift`: load currently accepts value-only configuration; real model resolution belongs behind future Infrastructure adapters.
- Infrastructure `StorageRootManager.swift`: security-scope and active/historical session-root access patterns.
- Infrastructure `AtomicFileWriter.swift`, `FinalizationFileAccess.swift`: existing durability and pinned-identity patterns. These helpers have specific semantics; do not assume overwrite-style JSON rename is a no-clobber directory installer, or broaden session/recovery whitelists to model paths.
- Infrastructure `SessionFileScanner.swift` and Application storage/catalog contracts: session files are authoritative, SQLite is derived. Model-reference checks must not trigger recovery or rewrite sessions.
- Xcode project resources/source registration, existing Domain/filesystem test patterns.

## 3. Deliverables and Task boundary

Implement:

1. A fixed bundled model-catalog schema and installation manifest with validation/versioning.
2. A framework-independent `ModelRepository` contract with serializable Sendable values for inventory, validation, import result, model references and deletion decisions.
3. An app-owned model store under Sandbox Application Support, with engine/model/revision namespaces and revision coexistence.
4. Offline installed-model discovery/integrity/compatibility reporting.
5. Local-folder import by copying into the app store, verifying the copy, and publishing it safely.
6. Explicit permanent-deletion policy, session-reference warnings and confirmation.
7. Deterministic real-filesystem/fault tests and requirement/assertion documentation.

Out of scope: network transfers, URLSession/download resume, remote catalog refresh, automatic updates/default selection, production engine dependencies or model loading/inference, benchmark/model selection, model-management UI/file panels, live STT wiring, transcript work or changes to the recorder/lifecycle. Do not implement the T13 downloader, T14/T15 adapters or T21 UI early.

**Local-import publication is in scope:** private same-store staging, checksum/compatibility verification and atomic no-clobber publication are needed to avoid exposing a partial local copy. This is not authorization to implement T13's networking/resume/storage-space workflow. Make the minimum reusable local verification/publication seam that T13 can call later.

## 4. Domain and manifest design

Reuse `EngineIdentity`, `ModelIdentity`, `ModelID` and other existing identities instead of creating competing strings or altering T02 session schemas. New boundary DTOs must be Codable/Sendable and Equatable where useful; protocols, streams/operation handles and Infrastructure URL/FD/scope objects are not serialized payloads.

The new Application/Domain contract must not expose filesystem URL/bookmark bytes, AVFoundation, vendor types or NSError. Catalog download locations, if included for T13, are validated data strings only; no networking is introduced. Keep the existing T03 URL exception untouched.

Catalog and manifest must represent:

- Explicit schema version; reject unsupported future versions without rewriting or deleting their files.
- Engine identity/compatibility, model ID and exact revision, format/variant and relevant quantization/compute metadata.
- A complete payload file list with safe relative paths, expected byte counts and **SHA-256 per file**.
- License identifier plus supplied license text/reference sufficient for later display; retain its provenance. Do not fabricate license claims or fetch license text at runtime.
- Stable package identity/checksum usable in `ModelIdentity.checksum`, distinct from installation time, local absolute path and origin.
- Origin/trust provenance: bundled-catalog expected data versus explicitly supplied local-import metadata. A self-consistent imported manifest is not automatically a trusted catalog entry.

Define and document an unambiguous deterministic package-digest algorithm over the normalized, ordered payload description. Reordering a dictionary/file-list or copying the same bytes to another directory cannot change model identity. Exclude volatile installation fields and avoid a manifest hashing itself. Reject duplicate/conflicting identities or payload entries.

Validate through normal initializers **and decoded JSON**: sizes/overflow, required identity/revision/license fields, 64-hex SHA-256 digests, safe layout, duplicate/colliding paths, contradictory manifest/namespace/compatibility metadata, and schema version. Use sensible bounded parsing/manifest sizes; do not load arbitrary-length files into memory just to decode metadata.

### Catalog and import inputs before real model selection

No real product model/revision/checksum/license has been finalized. **Do not download weights, invent real checksums, or ship a synthetic model as a usable product entry.** A versioned empty production catalog bundled into the app is acceptable at T12; exercise nonempty catalogs using generated tiny test packages. Verify actual bundle resource membership/loading. Construction/previews must remain inert; catalog loading occurs only on an explicit repository/catalog operation.

Local import accepts an explicit descriptor from a catalog entry or supplied local-package manifest/metadata. Preserve uncatalogued local provenance rather than pretending every local model is catalog-listed. A bare unrecognized directory without enough identity/checksum/license/format information must return a typed unsupported/descriptor-required result; do not infer a trusted catalog identity from its name. Future engine adapters can recognize supported native formats. Do not require a real-model choice to finish synthetic repository tests.

Separate **declared compatibility** from actual format validation. Provide a narrow injectable offline validator seam usable by T14/T15; test both acceptance and rejection through it. An unknown format/engine or unavailable validator must not be silently accepted by an always-true production default. It is a typed unsupported/not-yet-validated outcome, not a fully verified usable model. No actual model instantiation is required in T12.

## 5. App-owned layout, inventory and validation

Choose and document a dedicated model directory under Sandbox Application Support, e.g. `LocalLectureSTT/Models`. Resolve its live URL lazily inside Infrastructure; inject a disposable store for tests. Do not use the user-selected lecture/session root or a real user's Application Support in tests.

Namespace installs by **engine/model/revision**. Treat raw identifiers as data, not pathname fragments. Support ordinary logical IDs containing slashes using a deterministic safe mapping; do not allow traversal or collapse distinct IDs. Consider case-insensitive macOS filesystem collisions. Store manifest identity and verify it matches the namespace; a display name/path is not authority.

Inventory is filesystem/manifest-derived and works fully offline. Distinguish at least:

- Verified/usable package.
- Corrupt/missing payload or checksum mismatch.
- Engine/format incompatible or validation unavailable.
- Unsupported manifest schema and inaccessible storage where applicable.

Only a fully verified package may be returned as usable/resolvable. Missing empty store may mean no installed models; unreadable store/enumeration failure must not masquerade as a successful empty inventory. Staging/incomplete installs are never usable models. Listing/validation must not auto-delete, overwrite, redownload or auto-upgrade damaged/unknown packages.

Compute file digests incrementally with bounded buffers and cooperative cancellation; do not read model-sized weights with `Data(contentsOf:)`. Revalidate the actual stored bytes, not merely the manifest's declarations or stale cached success. Allow no real engine/file types to escape the repository boundary. A later adapter can resolve an installed key through an Infrastructure-only seam; do not change or activate STTEngine in this Task.

## 6. Safe local import

The source is read-only and never becomes a runtime dependency:

1. Accept an explicit import source through a narrow Infrastructure registration/access adapter. Application receives an opaque source identity, not an arbitrary URL or bookmark. A test/live access seam is sufficient; do not add a file picker/UI now or register the source as a lecture storage root.
2. Acquire only necessary source permission. Every successful security-scope acquisition is released exactly once on success, rejection, cancellation or failure. Source access must not be required after a successful import or persisted for future inference.
3. Create a private, operation-owned staging directory inside the app store/on the destination volume. Never copy directly into the visible final revision path.
4. Copy the described payload files, supporting nested native model-package directories. Reject unsafe/ambiguous layout: absolute or dot/dot-dot paths, empty components, reserved manifest/staging paths, duplicate/case-colliding entries, symlinks in any traversed component, and special files. Do not follow source links outside the selected directory or preserve external hard-link dependencies; the installed payload must be an independent copy.
5. Validate the **copied bytes**, full expected file set/lengths/SHA-256, declared compatibility, and supplied format validation. A directory existing or a manifest saying verified is insufficient.
6. Write and durably settle the installation manifest, then atomically publish the complete directory with **no replacement of an existing install**. Never expose a selectable install between copying and verification. Reuse this local primitive later for T13; no downloader now.
7. Return stable installed identity/provenance and release resources. Remove/make unavailable the source folder in an automated test and prove a fresh repository resolves/revalidates only the app-owned copy.

For the same engine/model/revision tuple:

- Identical verified bytes may yield an explicit already-installed/idempotent result after checking the existing package.
- Different content/checksum or an existing corrupt/unknown package is a collision/conflict: preserve the existing package and source, report clearly, and never repair/replace it automatically.
- A new revision installs beside the old one. No default model changes automatically. Imported and catalog-origin packages can coexist.

Account for source/destination replacement while I/O is suspended. Pin/revalidate directory/file ownership at the relevant open/copy/publish/remove boundaries; a lexical string prefix or one preflight URL check is insufficient. A replacement may cause safe failure or continued use of a genuinely pinned original, but must never redirect copying/deletion to unrelated replacement paths. Use narrow file-operation/validator/scope seams and deterministic gates to prove this; do not modify the old recorder/finalizer safety rules.

Serialize or explicitly arbitrate conflicting import/validation/delete operations for one install key. Actor reentrancy across awaits must not allow a stale callback/cleanup to remove a newer install or release another operation's scope. Race tests must cover duplicate imports and import versus delete. Unrelated revision files remain intact.

Cancellation/failure before publication leaves no usable partial install and preserves source/existing packages. Cleanup may remove **only proven operation-owned staging**; do not recursively delete a store root, source, unknown staging or another operation's data. Retain an explicit diagnostic/incomplete state if safe cleanup cannot be established. After publication, result/cancellation handling must truthfully reflect the committed install rather than deleting it as if it were temporary. Test that commit boundary.

## 7. Permanent deletion with explicit confirmation

Deletion is a two-step contract for later UI, not an unconditional `remove(modelID:)`:

1. Prepare a bounded deletion assessment for one exact installed revision: package identity/fingerprint, referencing session identities/count, and incomplete/unavailable reference-scan warnings.
2. Require an explicit confirmation tied to that assessment/target before removal. Cancellation or missing confirmation changes no files. Referenced sessions and uncertain coverage require explicit acknowledgment, not an implicit empty-reference assumption.

Implement a read-only reference-checking adapter over authoritative session metadata in registered active/historical roots, with narrow injection for deterministic tests. Reuse safe root access/patterns where applicable, but do not run T09 recovery, rewrite metadata, create roots, or use SQLite as the sole authority. An unavailable historical root, malformed metadata or scan failure must be visible as incomplete coverage. It must not become a false assertion that no sessions reference the model.

Match engine/model/exact revision (and relevant identity evidence), not display names. Session metadata without any model because STT is not installed yet is a legitimate nonreference. After warned-and-confirmed deletion, existing session audio/transcripts/metadata/catalog remain unchanged and readable; deleting a model is not deleting a session.

Revalidate target/assessment ownership immediately before permanent removal and after relevant awaits. A stale confirmation cannot delete a newer/replaced package, sibling revision or symlink target. Concurrent operation conflicts return a typed busy/stale result instead of deleting by an old pathname. Reject storage/source paths outside the app-owned model namespace. Test deletion failure/partial removal honestly; do not report success while expected files remain, and preserve/diagnose unsafe remnants without broad cleanup.

Actual alerts/confirmation UI and engine-active usage integration are later Tasks. T12 implements and tests the confirmation/reference policy and repository-operation ownership; it must not wire a model engine into recording merely to demonstrate deletion.

## 8. Acceptance and meaningful tests

Create `docs/T12_ACCEPTANCE.md` with ID → exact test function → actual fixture/gate/assertion → executed evidence. Use tiny generated files/directories and disposable roots; no downloaded model weights, lecture data, runtime DBs/bookmarks, user storage or large fixtures in Git. Test production repository operations through injected dependencies, not a second toy installer.

| ID | Required proof |
| --- | --- |
| T12-01 | Manifest/catalog/boundary DTOs round-trip with Codable/Sendable coverage; malformed/future schemas and invalid digests/paths/sizes/duplicates fail validation on decode as well as initialization. Existing T02/T11 identity/schema contracts remain compatible. |
| T12-02 | Fixed catalog is actually loaded from an app bundle resource offline, contains no fabricated real/synthetic production model, and cannot trigger network/default updates. Construction/previews have no filesystem/scope/network effects. |
| T12-03 | Safe namespace mapping preserves slash-containing logical IDs, avoids traversal/case collisions, and checks manifest/path identity. Distinct engines/models/revisions cannot overwrite each other. |
| T12-04 | Valid, corrupt/missing, incompatible/unvalidated, unsupported-schema and inaccessible inventory outcomes differ; staging is excluded and unknown/damaged packages are preserved. Missing store versus unreadable store differ. |
| T12-05 | Real local import copies nested payloads, verifies destination files/digests and validator outcome, publishes only after success; a fresh repository works after the source is absent. Scope acquisitions/releases balance exactly once. |
| T12-06 | Same verified package is idempotent; changed same-tuple content conflicts; new revisions and different origins coexist. Original bytes/default selection remain unchanged. Package checksum stays stable across path relocation and manifest ordering. |
| T12-07 | Independent known-answer/chunked SHA checks plus changed destination bytes, missing file, length/hash mismatch and incompatible-format faults reject usability. A manifest claiming success cannot bypass revalidation. Large-file processing uses bounded chunks. |
| T12-08 | Reject path escape, nested/root symlinks, special files, colliding/reserved names; deterministic source/store/target replacement during copy/publication/deletion cannot read/delete unrelated sentinel files. |
| T12-09 | Inject copy/hash/manifest-write/flush/publish/scope/cleanup failures and cancellation before/during verification and immediately around publication. First cause is retained; source/old installs/siblings survive; no usable partial install or leaked lease. Committed publication is reported truthfully. |
| T12-10 | Concurrent same-key import and import/delete conflicts, failed-operation retry and stale cleanup are controlled by acknowledged gates. Exactly one committed install; no newer package or scope is touched by an old operation. |
| T12-11 | Read-only reference scan finds exact model references across active/historical session files even when catalog data is absent/stale. Unavailable/corrupt roots yield explicit incomplete coverage. No session/recovery/catalog mutation occurs. |
| T12-12 | Missing/cancelled confirmation performs no delete; known references/unknown coverage are warned and explicitly acknowledged. Valid confirmed deletion removes only its pinned revision; stale/replaced target, failure/partial removal and sibling/session preservation are tested. |
| T12-13 | No real model dependency/download/engine load/UI/recorder wiring, no actual user data, no T13 work, G1 remains unverified and T12 unchecked. Full build/test and CI for the final task commit succeed with real nonzero executions. |

Use deterministic continuation/barrier handshakes for race and cancellation order, not `Task.sleep`, yield loops or polling. A bounded timeout is a failure watchdog only. Release held resources/join tasks on failure. Await actor values into locals before XCTest assertions. Do not add arbitrary repeated-run quotas; repeat targeted cases when a failure/change warrants it.

## 9. Implementation order and verification

Work through schema/namespace → production inventory/hash → staged local copy/validation/publication → reference assessment/confirmed deletion → faults/races → full validation/documentation. Briefly state important assumptions and continue ordinary implementation without waiting for confirmation. Keep narrow reusable boundaries; do not implement a general plugin/transaction system or expand to subsequent Tasks.

Update `docs/ARCHITECTURE.md` with actual catalog/manifest authority, namespace/hash algorithm, import source access, verification/publication commit point, outcome/cleanup ownership, reference/deletion policy and T13/adapter seams. Update `docs/DEVELOPMENT.md` with actual focused/full commands and a future manual signed-Sandbox folder-access procedure. No physical G1/model benchmark is required or claimed.

After focused checks pass, run full unsigned Debug arm64 build/test from the final executable tree, for example:

```sh
t12_run="$(mktemp -d /private/tmp/stt-t12-validation.XXXXXX)"
xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$t12_run/DerivedData" \
  -resultBundlePath "$t12_run/Full.xcresult" \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path "$t12_run/Full.xcresult" --compact
xcrun xcresulttool get test-results tests --path "$t12_run/Full.xcresult" --compact
```

Use unique result names for focused/full runs. Verify build success, no new attributable compiler warnings, nonzero actual tests in both targets, all new tests/resources in the shared scheme/bundle, existing T05–T11 tests retained, and zero failures/unexpected failures/skips. Do not copy the historical 299 count or infer correctness from process exit alone.

If testmanagerd or xcresult cache restrictions prevent execution/inspection, use the permitted normal macOS Xcode/approval path. Runner failure, unknown counts and zero executions are not passes. Do not disable tests or treat a pending physical G1 check as a T12 failure.

## 10. Phase 1 commit, push and handoff

1. Review full task diff and staged diff, `git diff --check`, scope, no-clobber/data preservation and acceptance assertions.
2. Stage explicit T12 source/test/project/resource/doc paths and this prompt only. Leave status/checklist/dev/main and unrelated prompts unchanged. Commit only manifests/catalog/license/test metadata and tiny redistributable fixtures; no weights or runtime stores.
3. Commit on `task/t12-model-repository` with T12 in the message, e.g. `feat(models): add offline repository manifests and local import (T12)`.
4. Verify committed source/tests/configuration equal the tested executable tree. Re-run affected/full validation after executable changes; supporting evidence docs do not justify reusing stale source results.
5. Push only the task branch without force and confirm CI for **that exact final commit**. An earlier task/dev CI is not evidence. CI naturally follows commit/push; do not require a future green CI before the commit can exist or amend merely to insert its own future SHA.
6. Repair same-Task CI failures and revalidate the new final SHA. Keep the branch for independent review; no dev integration, completion/checklist update, cleanup or T13 implementation.

Continue through ordinary implementation/test failures to a reviewable candidate. A real product conflict, unsafe data choice, conflicting concurrent work or unresolvable external/tooling prerequisite may justify `blocked`; missing implementation/tests alone are work to finish. Preserve all recoverable work if blocked.

Report **`T12 — review ready`** only after all acceptance, local validation, commit/push and final-commit CI pass; otherwise **`T12 — blocked`** with concrete causes and unmet IDs.

Final report must include starting dev/branch/final SHA; CI URL/run/head/result; changed files and schema/namespace/hash/trust/compatibility decisions; import/commit/cancel/delete ownership; ID-to-test/assertion evidence; exact commands/result paths and actual unit/integration pass/fail/skip counts; unresolved manual signed-Sandbox checks/risks/deviations; unchanged unrelated files/dev/main/status/checklist; G1 Unverified and no actual model inference. Official completion, integration and next-Task readiness remain the coordinator's independent post-review decision.
