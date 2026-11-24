import SwiftUI

struct RecordingSessionView: View {
    @ObservedObject var viewModel: RecordingSessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch viewModel.displayState {
            case .configuration:
                configurationView
            case .error where viewModel.snapshot.sessionID == nil:
                configurationView
            case .preparing:
                ProgressView("녹음을 안전하게 준비하는 중…")
                    .accessibilityIdentifier("recording-preparing")
            case .recording:
                activeRecordingView
            case .securing:
                ProgressView("안전하게 저장 중…")
                    .accessibilityIdentifier("recording-securing")
            case .secured:
                resultView(
                    title: "복구 오디오 저장 완료 · 마무리 대기",
                    systemImage: "checkmark.shield",
                    detail: "복구 원본을 보존하며 오디오 마무리를 진행합니다."
                )
            case .interrupted:
                resultView(
                    title: "녹음이 중단되었습니다",
                    systemImage: "exclamationmark.triangle",
                    detail: "복구 가능한 자료는 삭제하지 않고 세션 폴더에 보존했습니다."
                )
            case .error:
                resultView(
                    title: "녹음을 시작하지 못했습니다",
                    systemImage: "xmark.octagon",
                    detail: "생성된 세션 자료가 있다면 그대로 보존했습니다."
                )
            }
            if let message = viewModel.lifecycleMessage {
                Text(message).accessibilityIdentifier("lifecycle-save-state")
            }
            if viewModel.snapshot.speech.phase != .idle {
                speechView
            }
            if let value = viewModel.finalizations.last {
                VStack(alignment: .leading, spacing: 6) {
                    Text("세션 \(value.location.folderName.rawValue)").font(.caption)
                    if value.result == nil {
                        ProgressView(RecordingSessionViewModel.finalizationText(value.phase))
                    } else {
                        Text(value.result?.permitsEssentialQuitAfterTranscriptFailure == true
                             ? "기록 마무리 실패 · 오디오 보존" : RecordingSessionViewModel.finalizationText(value.phase))
                    }
                    if let result = value.result {
                        if let failure = result.failure { Text("오류: \(failure.rawValue)").monospaced() }
                        if let failure = result.transcriptFailure {
                            Text(failure.code == .repairRequired ? "기록 파일을 복구하려면 저장 폴더의 쓰기 권한이 필요합니다." :
                                 "기록 오류: \(failure.code.rawValue)" + (failure.line.map { " · journal \($0)번째 줄" } ?? ""))
                                .font(.caption)
                        }
                        ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                            Text("추가 경고: \(warning)").font(.caption)
                        }
                        if result.canRetry {
                            Button("마무리 재시도") { Task { await viewModel.retryFinalization(value) } }
                        }
                    }
                }
                .accessibilityIdentifier("audio-finalization-state")
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("recording-session-content")
    }

    private var configurationView: some View {
        Form {
            TextField("제목 (비우면 날짜와 시각 사용)", text: $viewModel.title)
                .disabled(!viewModel.actions.canEditConfiguration)
                .accessibilityIdentifier("recording-title")

            Picker("언어", selection: $viewModel.languageMode) {
                Text("한국어").tag(LanguageMode.korean)
                Text("영어").tag(LanguageMode.english)
                Text("자동").tag(LanguageMode.automatic)
            }
            .pickerStyle(.segmented)
            .disabled(!viewModel.actions.canEditConfiguration)
            .accessibilityIdentifier("recording-language")

            if let models = viewModel.models {
                ModelSelectionView(models: models)
            } else if let modelName = viewModel.modelName {
                LabeledContent("기본 STT 모델", value: modelName)
                    .accessibilityIdentifier("recording-model")
            }
            LabeledContent("마이크 권한", value: viewModel.permissionText)
                .accessibilityIdentifier("microphone-permission-status")
            if let preview = viewModel.microphonePreview {
                MicrophonePreviewView(preview: preview, toggle: { await viewModel.toggleMicrophonePreview() })
            }

            if let failure = viewModel.snapshot.failure {
                if case .speechModel = failure {
                    Text("기본 STT 모델을 열 수 없습니다. 모델 설치와 파일 상태를 확인하세요.")
                }
                Label(failure.stableCode, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("recording-error-code")
            }

            Button("녹음 시작") {
                Task { await viewModel.startRecording() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.actions.canStart)
            .accessibilityIdentifier("recording-start")
        }
        .formStyle(.grouped)
    }

    private var speechView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("실시간 전사").font(.headline)
            if viewModel.snapshot.speech.phase == .finishing {
                ProgressView("남은 발화를 전사하는 중…")
            }
            if let code = viewModel.snapshot.speech.failure {
                Text("전사가 중단되었습니다 (\(code.rawValue)). 녹음 오디오는 계속 보존됩니다.")
                    .foregroundStyle(.orange)
            }
            if let warning = viewModel.snapshot.speech.storageWarning {
                Text("전사 저장 경고: \(warning)").foregroundStyle(.orange)
            }
            if viewModel.snapshot.speech.degraded {
                Text("전사가 밀려 임시 갱신을 줄였습니다 · 대기 \(viewModel.snapshot.speech.pendingFinals)구간")
                    .foregroundStyle(.secondary)
            }
            if viewModel.snapshot.speech.inputDiscontinuities > 0 {
                Text("일부 전사 입력이 누락되었습니다. 녹음 파일은 별도로 저장됩니다.")
                    .foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.snapshot.speech.finals, id: \.id) { segment in
                        HStack(alignment: .top) {
                            Text(Self.speechTimestamp(segment.startMs.rawValue)).monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(segment.text).textSelection(.enabled)
                        }
                    }
                    if let partial = viewModel.snapshot.speech.partial, !partial.isEmpty {
                        Text(partial).italic().foregroundStyle(.secondary)
                            .accessibilityLabel("임시 전사: \(partial)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 100, maxHeight: 260)
        }
        .accessibilityIdentifier("live-transcript")
    }

    private static func speechTimestamp(_ ms: Int64) -> String {
        String(format: "%02lld:%02lld:%02lld", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1_000) % 60)
    }

    private var activeRecordingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("녹음 중", systemImage: "record.circle.fill")
                .font(.title2.bold())
                .foregroundStyle(.red)

            Text(viewModel.snapshot.title ?? "")
                .font(.title3)
                .accessibilityIdentifier("active-recording-title")

            LabeledContent("경과 시간", value: viewModel.elapsedText)
                .monospacedDigit()
                .accessibilityIdentifier("recording-elapsed")

            if let startedAt = viewModel.snapshot.recordingStartedAt?.value {
                LabeledContent("시작 시각") {
                    Text(startedAt, style: .time)
                }
            }
            LabeledContent("마이크", value: viewModel.snapshot.microphoneDisplayName ?? "확인 중")

            ProgressView(value: Double(viewModel.snapshot.normalizedInputLevel), total: 1) {
                Text("입력 레벨")
            }
            .accessibilityLabel("마이크 입력 레벨")
            .accessibilityValue("\(Int(viewModel.snapshot.normalizedInputLevel * 100)) 퍼센트")
            .accessibilityIdentifier("recording-input-level")

            if viewModel.snapshot.noInputWarning {
                Label("마이크 입력이 감지되지 않습니다. 녹음은 계속됩니다.", systemImage: "waveform.slash")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("recording-no-input-warning")
            }

            Button("녹음 종료") {
                Task { await viewModel.stopRecording() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.actions.canStop)
            .accessibilityIdentifier("recording-stop")
        }
    }

    private func resultView(title: String, systemImage: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            VStack(spacing: 8) {
                if let sessionTitle = viewModel.snapshot.title { Text(sessionTitle) }
                Text("녹음 길이 \(viewModel.elapsedText)")
                Text(detail)
                if let failure = viewModel.snapshot.failure {
                    Text(failure.stableCode).monospaced()
                }
                if let warning = viewModel.snapshot.persistenceWarningCode {
                    Text("저장 경고: \(warning)").monospaced()
                }
                if let warning = viewModel.snapshot.catalogWarningCode {
                    Text("목록 갱신 경고: \(warning.rawValue)").monospaced()
                }
            }
        } actions: {
            Button("새 녹음 준비") {
                Task { await viewModel.beginAnotherRecording() }
            }
            .disabled(!viewModel.actions.canReset)
            .accessibilityIdentifier("recording-reset")
        }
    }
}

private struct MicrophonePreviewView: View {
    @ObservedObject var preview: MicrophonePreviewViewModel
    let toggle: () async -> Void
    var body: some View {
        LabeledContent("마이크", value: preview.name)
        ProgressView(value: preview.level, total: 1).accessibilityLabel("시작 전 마이크 입력 레벨")
        Text(preview.noInput ? "마이크 입력이 감지되지 않습니다. 연결과 음소거 상태를 확인하세요." : preview.status)
            .font(.caption).foregroundStyle(preview.noInput ? .orange : .secondary)
        Button(preview.active ? "입력 확인 중지" : "마이크 입력 확인") {
            Task { await toggle() }
        }.accessibilityIdentifier("microphone-preview")
    }
}
