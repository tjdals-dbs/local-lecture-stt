import SwiftUI

struct ModelSelectionView: View {
    @ObservedObject var models: ModelManagementViewModel
    var body: some View {
        Picker("STT 모델", selection: Binding(get: { models.selectedKey }, set: { models.select($0) })) {
            if models.selectedKey == nil { Text("사용 가능한 모델 없음").tag(Optional<InstalledModelKey>.none) }
            ForEach(models.choices, id: \.key) { descriptor in
                Text("\(descriptor.engine.id.rawValue) · \(descriptor.variant)").tag(Optional(descriptor.key))
            }
        }
        .disabled(models.busy || models.recordingLocked)
        .accessibilityIdentifier("recording-model-selection")
        if let reason = models.blockingReason {
            Text(reason).foregroundStyle(.secondary).accessibilityIdentifier("model-start-blocker")
        }
    }
}

struct ModelManagementView: View {
    @ObservedObject var models: ModelManagementViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("STT 모델").font(.largeTitle.bold())
                Text("설치 후에는 인터넷 없이 사용할 수 있습니다. 다운로드는 아래 버튼을 누를 때만 시작됩니다.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("모델 폴더 가져오기") { Task { await models.importModel(nil) } }
                    Button("상태 다시 확인") { Task { await models.refresh() } }
                }.disabled(models.busy || models.recordingLocked)
                Text("설치 manifest가 있는 폴더를 가져오거나, 아래 모델의 ‘파일 폴더 선택’으로 가중치 폴더를 선택하세요. 원본은 유지하고 앱 저장소에 복사합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if let operation = models.operation { ProgressView(operation) }
                if let message = models.message { Text(message).textSelection(.enabled).accessibilityIdentifier("model-operation-message") }
                ForEach(models.pendingWarnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                ForEach(models.catalog, id: \.key) { descriptor in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(descriptor.engine.id.rawValue) · \(descriptor.variant)").font(.headline)
                            Text("\(Self.bytes(descriptor.files.reduce(0) { $0 + $1.byteCount })) · \(descriptor.licenseIdentifier)")
                            Text("버전 \(descriptor.model.revision)").font(.caption).textSelection(.enabled)
                            HStack {
                                Button("다운로드") { Task { await models.download(descriptor.key) } }
                                    .disabled(models.inventory.contains { $0.manifest?.descriptor.key == descriptor.key && $0.state == .usable })
                                Button("파일 폴더 선택") { Task { await models.importModel(descriptor) } }
                            }.disabled(models.busy || models.recordingLocked)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ForEach(models.downloads, id: \.id) { download in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(download.key.modelID.rawValue).font(.headline)
                            Text(Self.phase(download.phase))
                            ProgressView(value: Double(download.completedBytes), total: Double(max(1, download.totalBytes)))
                            Text("\(Self.bytes(download.completedBytes)) / \(Self.bytes(download.totalBytes))").font(.caption)
                            if let failure = download.failure { Text(ModelManagementViewModel.errorMessage(failure)).foregroundStyle(.orange) }
                            if let failure = download.resumeFailure { Text("재개 확인: \(ModelManagementViewModel.errorMessage(failure))").font(.caption) }
                            if download.restartedFromZero { Text("이어받기 조건이 달라 처음부터 다시 받았습니다.").font(.caption) }
                            HStack {
                                if download.phase == .transferring {
                                    downloadButton("일시정지", download, .pause)
                                }
                                if download.phase == .paused || (download.phase == .failed && download.resumable) {
                                    downloadButton("재개", download, .resume)
                                }
                                if download.phase == .failed { downloadButton("다시 시도", download, .retry) }
                                if download.phase != .installed && download.phase != .cancelled {
                                    downloadButton("다운로드 취소", download, .cancel)
                                }
                            }.disabled(models.operation != nil || models.recordingLocked || models.deletion != nil)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("설치된 모델").font(.title2)
                if models.inventory.isEmpty { Text(models.loaded ? "설치된 모델이 없습니다." : "모델 상태 확인 중…").foregroundStyle(.secondary) }
                ForEach(models.inventory, id: \.namespace) { entry in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.manifest.map { "\($0.descriptor.engine.id.rawValue) · \($0.descriptor.variant)" } ?? "확인할 수 없는 모델")
                                .font(.headline)
                            Text(Self.state(entry.state) + (entry.issue.map { " (\($0.rawValue))" } ?? ""))
                            if let manifest = entry.manifest {
                                Text("\(manifest.origin == .suppliedLocal ? "가져온 모델" : "다운로드한 모델") · \(manifest.descriptor.model.revision)").font(.caption)
                                HStack {
                                    Button("검증") { Task { await models.validate(manifest.descriptor.key) } }
                                    Button("삭제…", role: .destructive) { Task { await models.prepareDeletion(manifest.descriptor.key) } }
                                }.disabled(models.busy || models.recordingLocked)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: Binding(get: { models.deletion != nil }, set: { if !$0 { models.cancelDeletion() } })) {
            if let deletion = models.deletion { ModelDeletionView(models: models, assessment: deletion) }
        }
        .accessibilityIdentifier("model-management")
    }
    private func downloadButton(_ title: String, _ value: ModelDownloadSnapshot, _ action: ModelManagementViewModel.DownloadAction) -> some View {
        Button(title) { Task { await models.controlDownload(value.id, action: action) } }
    }
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    static func phase(_ value: ModelDownloadPhase) -> String {
        switch value {
        case .transferring: "다운로드 중"
        case .paused: "일시정지 · 재개하려면 버튼을 누르세요"
        case .installing: "검증 및 설치 중"
        case .installed: "설치 완료"
        case .failed: "다운로드 실패 · 자료 보존"
        case .cancelled: "다운로드 취소됨"
        }
    }
    static func state(_ value: ModelPackageState) -> String {
        switch value {
        case .usable: "검증 완료"
        case .corrupt: "손상됨 · 사용 불가"
        case .incompatible: "호환되지 않는 모델"
        case .unvalidated: "검증 필요"
        case .unsupportedSchema: "지원되지 않는 모델 정보"
        case .inaccessible: "모델 파일에 접근할 수 없음"
        }
    }
}

private struct ModelDeletionView: View {
    @ObservedObject var models: ModelManagementViewModel
    let assessment: ModelDeletionAssessment
    @State private var acknowledgeReferences = false
    @State private var acknowledgeIncomplete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("모델을 영구 삭제할까요?").font(.title2.bold())
            Text(assessment.key.modelID.rawValue)
            Text("모델 파일만 삭제합니다. 기존 녹음과 transcript는 유지됩니다.")
            if !assessment.references.sessions.isEmpty {
                Toggle("이 모델을 사용한 \(assessment.references.sessions.count)개 세션이 있음을 확인했습니다.", isOn: $acknowledgeReferences)
            }
            if !assessment.references.isComplete {
                Text("일부 저장 폴더를 확인하지 못해 참조 세션이 더 있을 수 있습니다.").foregroundStyle(.orange)
                ForEach(assessment.references.warnings, id: \.self) { Text($0).font(.caption) }
                Toggle("확인하지 못한 세션이 있을 수 있음을 이해했습니다.", isOn: $acknowledgeIncomplete)
            }
            HStack {
                Button("취소") { models.cancelDeletion() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("영구 삭제", role: .destructive) {
                    Task { await models.confirmDeletion(acknowledgeReferences: acknowledgeReferences, acknowledgeIncompleteCoverage: acknowledgeIncomplete) }
                }.disabled((!assessment.references.sessions.isEmpty && !acknowledgeReferences) || (!assessment.references.isComplete && !acknowledgeIncomplete))
            }.disabled(models.operation != nil)
        }.padding(24).frame(width: 460).interactiveDismissDisabled(models.operation != nil)
    }
}
