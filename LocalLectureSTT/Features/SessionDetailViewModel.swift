import Foundation
import SwiftUI

@MainActor
final class SessionDetailViewModel: ObservableObject, LifecycleAuxiliaryWorking {
    @Published private(set) var item: SessionCatalogItem?
    @Published private(set) var document: SessionDetailDocument?
    @Published private(set) var playback = SessionPlaybackSnapshot()
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var editingSegment: TranscriptSegment?
    @Published private(set) var editingTitle = false
    @Published var draft = ""
    @Published var deletion: SessionLocation?
    private let store: any SessionDetailStoring
    private let player: any SessionPlaybackControlling
    private let authority: LifecycleWorkAuthority?
    private let changed: @MainActor () async -> Void
    private let diagnostics: any DiagnosticRecording
    private var operation: Task<Void, Never>?
    private var playbackObservation: Task<Void, Never>?
    private var lease: UUID?
    private var quiescing = false
    private var attention = false
    private var observers: [UUID: AsyncStream<LifecycleAuxiliarySnapshot>.Continuation] = [:]

    init(store: any SessionDetailStoring, player: any SessionPlaybackControlling,
         authority: LifecycleWorkAuthority? = nil, changed: @escaping @MainActor () async -> Void = {},
         diagnostics: any DiagnosticRecording = NoopDiagnosticRecorder()) {
        self.store = store; self.player = player; self.authority = authority; self.changed = changed
        self.diagnostics = diagnostics
    }
    static var preview: SessionDetailViewModel {
        .init(store: UnavailableSessionDetailStore(), player: UnavailableSessionPlayback())
    }
    var location: SessionLocation? {
        item.map { .init(rootID: $0.rootID, sessionID: $0.sessionID, folderName: $0.folderName) }
    }
    var hasDraft: Bool { editingSegment != nil || editingTitle }
    var canEdit: Bool { document?.editable == true && !busy && !quiescing && !hasDraft }
    func startObserving() {
        guard playbackObservation == nil else { return }
        playbackObservation = Task { [weak self, player] in
            for await value in player.snapshots() {
                guard let self, !Task.isCancelled else { return }
                self.playback = value
                if let failure = value.failure {
                    let invalidation = self.authority?.admit()
                    self.attention = true
                    let issue = UserIssues.detail(failure)
                    self.message = issue.message + " (\(failure.rawValue))"
                    self.diagnostics.issue(issue, source: .sessionDetail, sessionID: self.item?.sessionID)
                    if let invalidation { self.authority?.release(invalidation) }
                }
                self.publishWork()
            }
        }
    }
    @discardableResult func select(_ item: SessionCatalogItem) async -> Bool {
        guard !busy, !quiescing, !hasDraft else { return false }
        startObserving()
        await perform {
            await self.player.close()
            self.playback = .init(); self.item = item; self.document = nil; self.deletion = nil
            guard let location = self.location else { return }
            self.document = try await self.store.load(location)
            for value in self.document?.issues ?? [] {
                self.diagnostics.issue(UserIssues.artifact(value), source: .sessionDetail, sessionID: location.sessionID)
            }
        }
        return self.item?.sessionID == item.sessionID
    }
    func refresh() async {
        guard let item, !hasDraft else { return }
        await select(item)
    }
    func edit(_ segment: TranscriptSegment) {
        guard canEdit, document?.transcript?.segments.contains(segment) == true else { return }
        editingSegment = segment; draft = segment.text; message = nil; publishWork()
    }
    func rename() {
        guard canEdit, let title = document?.metadata?.title else { return }
        editingTitle = true; draft = title; message = nil; publishWork()
    }
    func cancelEdit() async {
        guard !busy else { return }
        let failedSave = attention
        editingSegment = nil; editingTitle = false; draft = ""; message = nil; attention = false; publishWork()
        // Cancelling the draft cannot undo a canonical/metadata write that
        // succeeded before an export failed. Show the durable state again.
        if failedSave, let location {
            await perform {
                self.document = try await self.store.load(location)
                self.attention = true
                self.message = "초안을 취소하고 저장된 내용을 다시 읽었습니다. 이미 저장된 변경은 유지됩니다. 파생 문서는 ‘문서 다시 생성’으로 복구할 수 있습니다."
            }
        }
    }
    func save(duringQuiesce: Bool = false) async {
        guard let location, hasDraft else { return }
        let segment = editingSegment; let text = draft
        let title = document?.metadata?.title
        await perform(duringQuiesce: duringQuiesce) {
            await self.player.close(); self.playback = .init()
            if let segment {
                if text != segment.text {
                    try await self.store.updateText(location, segment: segment.id, expected: segment.text, text: text)
                }
            } else if let title {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { throw DomainValidationError.emptyValue(field: "title") }
                if value != title { try await self.store.updateTitle(location, expected: title, title: value) }
            }
            self.document = try await self.store.load(location)
            self.editingSegment = nil; self.editingTitle = false; self.draft = ""
            await self.changed()
        }
    }
    func regenerate() async {
        guard canEdit, let location else { return }
        await perform {
            await self.player.close(); self.playback = .init()
            try await self.store.regenerate(location)
            self.document = try await self.store.load(location)
            await self.changed()
        }
    }
    func togglePlayback() async {
        guard !busy, !quiescing, let location else { return }
        if playback.phase == .playing { player.pause(); return }
        await perform {
            if [.idle, .failed].contains(self.playback.phase) { try await self.player.open(location) }
            try await self.player.play()
        }
    }
    func seek(_ milliseconds: Int64) async {
        guard let location else { return }
        await perform {
            if [.idle, .failed].contains(self.playback.phase) { try await self.player.open(location) }
            try await self.player.seek(to: milliseconds)
        }
    }
    func stopPlayback() async {
        await operation?.value
        await perform { await self.player.close(); self.playback = .init() }
    }
    func reveal(_ file: SessionDetailFile) async {
        guard let location else { return }
        await perform { try await self.store.reveal(file, at: location) }
    }
    func requestDeletion() {
        guard !busy, !hasDraft, !quiescing else { return }
        deletion = location
    }
    func confirmDeletion(_ target: SessionLocation) async {
        guard target == location, !hasDraft else { return }
        deletion = nil
        await perform {
            await self.player.close(); self.playback = .init()
            let result = try await self.store.trash(target)
            self.item = nil; self.document = nil
            self.message = result.catalogWarning ? "휴지통으로 이동했습니다. 목록 갱신에는 실패했습니다." : "세션을 휴지통으로 이동했습니다. Finder에서 복구할 수 있습니다."
            await self.changed()
        }
    }
    private func perform(duringQuiesce: Bool = false, _ body: @escaping @MainActor () async throws -> Void) async {
        guard !busy, !quiescing || duringQuiesce else { return }
        busy = true; message = nil; attention = false; publishWork()
        let task = Task { @MainActor in
            do { try await body() }
            catch {
                let invalidation = self.authority?.admit()
                self.attention = true
                let issue = UserIssues.error(error)
                self.message = issue.message + " (\(SessionDetailDiagnostics.code(error)))"
                self.diagnostics.issue(issue, source: .sessionDetail, sessionID: self.item?.sessionID)
                if let invalidation { self.authority?.release(invalidation) }
            }
            self.busy = false; self.operation = nil; self.publishWork()
        }
        operation = task
        await task.value
    }
    func quiesce() async {
        guard currentWork().active else { return }
        quiescing = true; publishWork()
        await operation?.value
        if hasDraft { await save(duringQuiesce: true) }
        await player.close(); playback = .init()
        quiescing = false; publishWork()
    }
    func currentWork() -> LifecycleAuxiliarySnapshot {
        .init(active: busy || quiescing || hasDraft || [.loading, .paused, .playing].contains(playback.phase),
              requiresAttention: hasDraft || attention)
    }
    func workSnapshots() -> AsyncStream<LifecycleAuxiliarySnapshot> {
        let id = UUID(); let pair = AsyncStream<LifecycleAuxiliarySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation; pair.continuation.yield(currentWork())
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.observers[id] = nil } }
        return pair.stream
    }
    private func publishWork() {
        let value = currentWork()
        if value.active, lease == nil { lease = authority?.admit() }
        if !value.active, let lease { authority?.release(lease); self.lease = nil }
        observers.values.forEach { $0.yield(value) }
    }
}

private struct UnavailableSessionDetailStore: SessionDetailStoring {
    func load(_ location: SessionLocation) async throws -> SessionDetailDocument { throw SessionDetailFailure.unavailable }
    func updateText(_ location: SessionLocation, segment: TranscriptSegmentID, expected: String, text: String) async throws { throw SessionDetailFailure.unavailable }
    func updateTitle(_ location: SessionLocation, expected: String, title: String) async throws { throw SessionDetailFailure.unavailable }
    func regenerate(_ location: SessionLocation) async throws { throw SessionDetailFailure.unavailable }
    func reveal(_ file: SessionDetailFile, at location: SessionLocation) async throws { throw SessionDetailFailure.unavailable }
    func trash(_ location: SessionLocation) async throws -> SessionTrashResult { throw SessionDetailFailure.unavailable }
}
@MainActor private final class UnavailableSessionPlayback: SessionPlaybackControlling {
    func snapshots() -> AsyncStream<SessionPlaybackSnapshot> { AsyncStream { $0.yield(.init()); $0.finish() } }
    func open(_ location: SessionLocation) async throws { throw SessionDetailFailure.unavailable }
    func play() async throws { throw SessionDetailFailure.unavailable }
    func pause() {}
    func seek(to milliseconds: Int64) async throws { throw SessionDetailFailure.unavailable }
    func close() async {}
}
