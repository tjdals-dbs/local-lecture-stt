import SwiftUI

struct RecordingSessionView: View {
    @ObservedObject var viewModel: RecordingSessionViewModel
    var activityOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if activityOnly {
                Text("백그라운드 작업").font(.title2.bold())
                if viewModel.backgroundWorkText == nil { Text("진행 중인 마무리 작업이 없습니다.") }
            } else {
                switch viewModel.displayState {
                case .configuration:
                    configurationView
                case .error where viewModel.snapshot.sessionID == nil:
                    configurationView
                case .preparing:
                    ProgressView("녹음을 안전하게 준비하는 중…")
                        .accessibilityIdentifier("recording-preparing")
                case .recording, .paused:
                    activeRecordingView
                case .securing:
                    ProgressView("안전하게 저장 중…")
                        .accessibilityIdentifier("recording-securing")
                case .secured:
                    resultView(
                        title: "녹음 종료 · 필수 저장 완료",
                        systemImage: "checkmark.shield",
                        detail: "전사와 파일 마무리 상태를 아래에서 확인하세요."
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
            }
            if let message = viewModel.lifecycleMessage {
                Text(message).accessibilityIdentifier("lifecycle-save-state")
            }
            ForEach(viewModel.snapshot.issues(includeSpeech: false)) { issue in
                IssueNoticeView(issue: issue)
                    .accessibilityIdentifier(issue.code == .noInput ? "recording-no-input-warning" : "recording-issue-\(issue.code.rawValue)")
            }
            if viewModel.snapshot.speech.phase != .idle {
                LiveTranscriptView(presentation: viewModel.transcript).equatable()
            }
            if !viewModel.finalizations.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.finalizations, id: \.generation) { value in
                            finalizationView(value)
                        }
                    }
                }.frame(maxHeight: activityOnly ? .infinity : 110)
            }
        }
        .padding(20)
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
                Text("진단 코드: \(failure.stableCode)").font(.caption)
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

    private func finalizationView(_ value: AudioFinalizationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("세션 \(value.location.folderName.rawValue)").font(.caption)
            if value.result == nil {
                ProgressView(RecordingSessionViewModel.finalizationText(value.phase))
            } else {
                Text(value.result?.permitsEssentialQuitAfterTranscriptFailure == true
                     ? "기록 마무리 실패 · 오디오 보존" : RecordingSessionViewModel.finalizationText(value.phase))
            }
            if let result = value.result {
                if let failure = result.failure { IssueNoticeView(issue: UserIssues.finalization(failure)) }
                if let failure = result.transcriptFailure {
                    IssueNoticeView(issue: UserIssues.transcript(failure.code))
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

    private var activeRecordingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(viewModel.snapshot.phase == .paused ? "일시정지" : "녹음 중",
                      systemImage: viewModel.snapshot.phase == .paused ? "pause.circle.fill" : "record.circle.fill")
                    .font(.headline).foregroundStyle(.red)
                Text(viewModel.elapsedText).monospacedDigit()
                    .accessibilityLabel("경과 시간 \(viewModel.elapsedText)")
                    .accessibilityIdentifier("recording-elapsed")
                Spacer()
                Button(viewModel.snapshot.phase == .paused ? "녹음 재개" : "일시정지") {
                    Task { await viewModel.togglePause() }
                }
                .disabled(!viewModel.actions.canPause && !viewModel.actions.canResume)
                .accessibilityIdentifier("recording-pause-resume")
                if viewModel.snapshot.pauseTransitionInFlight {
                    ProgressView().controlSize(.small).accessibilityLabel("녹음 상태 저장 중")
                }
                Button("녹음 종료") { Task { await viewModel.stopRecording() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.actions.canStop)
                    .accessibilityIdentifier("recording-stop")
            }
            Text(viewModel.snapshot.title ?? "").font(.title3).lineLimit(2)
                .accessibilityIdentifier("active-recording-title")
            HStack {
                Text(viewModel.snapshot.microphoneDisplayName ?? "마이크 확인 중").font(.caption)
                if let startedAt = viewModel.snapshot.recordingStartedAt?.value {
                    Text(startedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("녹음 시작 시각")
                }
                ProgressView(value: Double(viewModel.snapshot.normalizedInputLevel), total: 1)
                    .accessibilityLabel("마이크 입력 레벨")
                    .accessibilityValue("\(Int(viewModel.snapshot.normalizedInputLevel * 100)) 퍼센트")
                    .accessibilityIdentifier("recording-input-level")
            }

        }
    }

    private func resultView(title: String, systemImage: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline)
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
        if preview.noInput { IssueNoticeView(issue: .init(code: .noInput)) }
        else { Text(preview.status).font(.caption).foregroundStyle(.secondary) }
        Button(preview.active ? "입력 확인 중지" : "마이크 입력 확인") {
            Task { await toggle() }
        }.accessibilityIdentifier("microphone-preview")
    }
}
