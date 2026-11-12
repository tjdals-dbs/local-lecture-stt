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
            if let value = viewModel.finalizations.last {
                VStack(alignment: .leading, spacing: 6) {
                    Text("세션 \(value.location.folderName.rawValue)").font(.caption)
                    if value.result == nil {
                        ProgressView(RecordingSessionViewModel.finalizationText(value.phase))
                    } else {
                        Text(RecordingSessionViewModel.finalizationText(value.phase))
                    }
                    if let result = value.result {
                        if let failure = result.failure { Text("오류: \(failure.rawValue)").monospaced() }
                        ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                            Text("추가 경고: \(warning)").font(.caption)
                        }
                        if result.canRetry {
                            Button("오디오 마무리 재시도") { Task { await viewModel.retryFinalization(value) } }
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

            LabeledContent("마이크 권한", value: viewModel.permissionText)
                .accessibilityIdentifier("microphone-permission-status")

            if let failure = viewModel.snapshot.failure {
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
