import Foundation

enum UserIssueCode: String, Codable, Sendable, CaseIterable {
    case microphonePermission, microphoneRestricted, noInput, microphoneDisconnected, captureFailed
    case storageSelection, storagePermission, storageMissing, diskFull, storageWrite
    case modelMissing, modelCorrupt, modelIncompatible, modelBusy, modelTransfer, modelOperation, modelAccess, modelCapacity
    case engineInitialization, engineInference, speechDelayed, transcriptStorage, transcriptRepair, speechIncomplete
    case audioFinalization, sessionMissing, sessionCorrupt, catalog, busy, conflict, invalidTitle
    case interrupted, cancelled, playback, diagnosticStorage, diagnosticExport, unknown
}

enum IssueRecovery: String, Codable, Sendable {
    case retryAfterAction, preservedNeedsInspection, informational
    var label: String {
        switch self {
        case .retryAfterAction: "조치 후 재시도 가능"
        case .preservedNeedsInspection: "원본 보존 · 확인 필요"
        case .informational: "상태 안내"
        }
    }
}

/// One presentation contract for every surface. It never carries an Error's
/// description, a pathname, model prompt, session title or transcript text.
struct UserIssue: Sendable, Equatable, Identifiable {
    let code: UserIssueCode
    var id: UserIssueCode { code }
    var recovery: IssueRecovery {
        switch code {
        case .sessionMissing, .sessionCorrupt, .transcriptStorage, .speechIncomplete: .preservedNeedsInspection
        case .noInput, .speechDelayed, .interrupted, .cancelled, .busy: .informational
        default: .retryAfterAction
        }
    }
    var title: String { content.0 }
    var cause: String { content.1 }
    var action: String { content.2 }
    var message: String { "\(title)\n원인: \(cause)\n조치: \(action)\n\(recovery.label)" }
    private var content: (String, String, String) {
        switch code {
        case .microphonePermission: ("마이크 권한이 필요합니다", "앱에 마이크 접근이 허용되지 않았습니다.", "시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 이 앱을 허용한 뒤 다시 시작하세요.")
        case .microphoneRestricted: ("마이크 사용이 제한되었습니다", "시스템 정책으로 마이크 접근이 제한되어 있습니다.", "기기 관리 설정이나 관리자에게 마이크 사용 권한을 확인하세요.")
        case .noInput: ("마이크 입력이 감지되지 않습니다", "입력이 없거나 음량이 너무 작습니다. 진행 중인 녹음을 자동 중단하지는 않습니다.", "마이크 연결·음소거·입력 음량을 확인하고 입력 레벨이 움직이는지 확인하세요.")
        case .microphoneDisconnected: ("마이크 연결이 변경되었습니다", "사용 중인 입력 장치가 분리되거나 구성이 바뀌었습니다.", "마이크를 다시 연결하고 필수 저장이 끝난 뒤 새 녹음을 시작하세요. 기존 자료는 보존됩니다.")
        case .captureFailed: ("마이크 입력을 처리할 수 없습니다", "입력 장치 시작 또는 오디오 전달에 실패했습니다.", "마이크 권한과 연결을 확인하고 다른 녹음 앱을 닫은 뒤 다시 시작하세요.")
        case .storageSelection: ("저장 폴더가 필요합니다", "녹음을 보관할 폴더가 지정되지 않았습니다.", "설정에서 저장 폴더를 선택하세요.")
        case .storagePermission: ("저장 폴더 접근 권한이 필요합니다", "저장 폴더를 읽거나 쓸 수 없습니다.", "설정의 저장 폴더 재승인 또는 다시 선택을 사용하세요. 이전 세션은 복구 안내의 재승인을 사용하세요.")
        case .storageMissing: ("저장 폴더를 찾을 수 없습니다", "폴더가 이동되었거나 외장 저장 장치가 연결되지 않았습니다.", "원래 저장 장치를 연결한 뒤 같은 폴더를 재승인하세요.")
        case .diskFull: ("저장 공간이 부족합니다", "오디오 또는 파일을 쓸 여유 공간이 없습니다.", "다른 파일을 옮겨 공간을 확보한 뒤 복구·마무리를 재시도하세요. 세션의 복구 원본은 직접 지우지 마세요.")
        case .storageWrite: ("파일 저장에 실패했습니다", "파일 쓰기 또는 안전한 저장 확정에 실패했습니다.", "저장 장치 연결·쓰기 권한·여유 공간을 확인하고 재시도하세요. 기존 자료는 보존됩니다.")
        case .modelMissing: ("사용할 모델이 준비되지 않았습니다", "선택한 모델을 찾거나 열 수 없습니다.", "모델 관리에서 설치된 모델을 확인하거나 직접 가져오세요. 다운로드에는 인터넷이 필요합니다.")
        case .modelCorrupt: ("모델 파일 검증에 실패했습니다", "파일 크기 또는 체크섬이 기대한 모델과 다릅니다.", "모델 관리에서 원본 파일을 다시 가져오거나 다운로드하세요. 기존 모델은 자동 삭제하지 않습니다.")
        case .modelIncompatible: ("호환되지 않는 모델입니다", "모델 형식이나 설정이 현재 엔진에서 지원되지 않습니다.", "모델 관리에서 현재 엔진과 호환되는 모델을 선택하세요.")
        case .modelBusy: ("모델이 사용 중입니다", "녹음 또는 다른 모델 작업이 해당 모델을 사용하고 있습니다.", "작업이 끝난 뒤 모델 작업을 다시 시도하세요.")
        case .modelCapacity: ("모델 설치 공간을 확인하지 못했습니다", "모델 저장 장치의 사용 가능한 용량을 읽을 수 없습니다.", "저장 장치 연결과 접근 권한을 확인한 뒤 다시 가져오세요. 모델 파일 복사는 시작하지 않았습니다.")
        case .modelTransfer: ("모델 다운로드에 실패했습니다", "네트워크 또는 다운로드 파일 확인에 실패했습니다.", "인터넷 연결을 확인하고 모델 관리에서 재개·재시도하거나 파일을 직접 가져오세요.")
        case .modelOperation: ("모델 작업을 완료하지 못했습니다", "모델 설치·검증·삭제 상태를 확인할 수 없습니다.", "모델 관리 목록을 새로고침하고 파일 접근 권한과 저장 공간을 확인하세요.")
        case .modelAccess: ("모델 폴더에 접근할 수 없습니다", "선택한 모델 원본 또는 앱 모델 저장소의 접근 권한이 없습니다.", "모델 관리에서 원본 폴더를 다시 선택해 가져오세요. 앱 모델 저장소의 권한과 저장 장치 연결도 확인하세요.")
        case .engineInitialization: ("STT 엔진을 준비하지 못했습니다", "선택한 모델로 엔진을 초기화하거나 시작하지 못했습니다.", "모델 파일과 호환성을 확인하세요. 녹음이 진행 중이라면 오디오는 계속 저장됩니다.")
        case .engineInference: ("실시간 전사가 중단되었습니다", "STT 엔진이 음성을 처리하지 못했습니다. 오디오 저장은 계속됩니다.", "녹음을 마친 뒤 오디오와 모델 상태를 확인하세요. 누락 구간의 복구 상태를 확인하세요.")
        case .speechDelayed: ("실시간 전사 처리가 지연됩니다", "전사가 입력 속도를 따라가지 못하고 있습니다. 오디오 저장은 계속됩니다.", "잠시 기다리거나 다른 무거운 작업을 줄이세요. 녹음 종료는 계속 사용할 수 있습니다.")
        case .transcriptStorage: ("전사 기록을 저장하지 못했습니다", "전사 journal 또는 원본 기록의 저장·검증에 실패했습니다.", "저장 권한과 공간을 확인하세요. 오디오는 보존되며 기록 파일을 직접 덮어쓰지 말고 복구 안내를 확인하세요.")
        case .speechIncomplete: ("일부 전사가 완료되지 않았습니다", "오디오는 저장됐지만 복구 대기 또는 미복구 전사 구간이 남아 있습니다.", "세션 상세에서 누락 시간을 확인하세요. 복구 대기는 원래 모델을 확인한 뒤 마무리를 재시도할 수 있습니다. 한도에 도달한 미복구 구간은 자동 재시도하지 않습니다.")
        case .transcriptRepair: ("파생 문서 복구가 필요합니다", "원본 기록은 있으나 문서를 다시 생성해야 합니다.", "저장 폴더에 쓰기 권한을 허용한 뒤 문서 다시 생성 또는 마무리 재시도를 실행하세요.")
        case .audioFinalization: ("오디오 마무리에 실패했습니다", "최종 오디오 생성 또는 검증을 완료하지 못했습니다.", "저장 장치와 공간을 확인한 뒤 마무리 재시도를 실행하세요. 복구 원본은 보존됩니다.")
        case .sessionMissing: ("세션 파일이 없습니다", "필요한 오디오·기록·메타데이터 파일을 찾지 못했습니다.", "원래 폴더나 백업을 확인하세요. 남아 있는 파일은 자동 삭제하지 않습니다.")
        case .sessionCorrupt: ("세션 파일을 확인해야 합니다", "파일 내용·버전·세션 정보가 일치하지 않거나 손상되었습니다.", "남아 있는 원본을 보존하고 백업과 진단 코드를 확인하세요. 지원 버전이 다른 파일은 해당 버전의 앱으로 여세요.")
        case .catalog: ("세션 목록을 갱신하지 못했습니다", "파일을 기반으로 한 목록 읽기 또는 갱신에 실패했습니다.", "저장 폴더 접근 상태를 확인하고 목록 새로고침을 실행하세요. 세션 원본은 보존됩니다.")
        case .busy: ("다른 작업이 진행 중입니다", "같은 자료를 처리하는 작업이 아직 끝나지 않았습니다.", "현재 작업이 끝난 뒤 다시 시도하세요.")
        case .conflict: ("파일 상태가 변경되었습니다", "작업을 시작한 이후 자료가 바뀌었습니다.", "목록이나 세션을 다시 열어 최신 내용을 확인한 뒤 재시도하세요.")
        case .invalidTitle: ("제목을 확인하세요", "제목에 표시할 내용이 없습니다.", "공백이 아닌 제목을 입력하세요.")
        case .interrupted: ("녹음이 중단되었습니다", "잠자기 또는 앱 종료로 녹음이 중단되었습니다.", "복구 결과와 저장된 오디오를 확인하세요. 녹음은 자동 재개되지 않습니다.")
        case .cancelled: ("작업이 취소되었습니다", "사용자 요청 또는 종료 과정에서 작업이 취소되었습니다.", "필요하면 작업을 다시 시작하세요. 기존 자료는 유지됩니다.")
        case .playback: ("오디오를 재생할 수 없습니다", "오디오 파일 또는 재생 장치를 열 수 없습니다.", "파일 존재 여부와 출력 장치를 확인한 뒤 세션을 다시 여세요.")
        case .diagnosticStorage: ("진단 로그를 처리하지 못했습니다", "앱 진단 폴더의 접근 또는 쓰기에 실패했습니다.", "저장 공간과 앱 저장소 권한을 확인하고 설정에서 다시 시도하세요. 녹음과 전사는 계속 사용할 수 있습니다.")
        case .diagnosticExport: ("진단 로그를 내보내지 못했습니다", "선택한 위치에 새 진단 파일을 만들 수 없습니다.", "기존 파일과 겹치지 않는 이름과 쓰기 가능한 폴더를 선택하세요. 기존 파일은 덮어쓰지 않습니다.")
        case .unknown: ("작업을 완료하지 못했습니다", "예상하지 못한 오류가 발생했습니다.", "저장된 자료를 확인한 뒤 다시 시도하세요. 문제가 반복되면 설정에서 로컬 진단 로그를 확인하세요.")
        }
    }
}

enum UserIssues {
    static func storage(_ c: StorageErrorCode) -> UserIssue {
        let code: UserIssueCode
        switch c {
        case .noActiveRoot: code = .storageSelection
        case .reauthorizationRequired, .securityScopeAccessFailed, .bookmarkCreateFailed, .bookmarkResolveFailed,
             .bookmarkRefreshFailed, .rootNotWritable: code = .storagePermission
        case .rootMissing, .rootNotDirectory: code = .storageMissing
        case .artifactMissing: code = .sessionMissing
        case .registryCorrupt, .registryUnsupported, .jsonDecodeFailed, .documentCorrupt, .documentUnsupported, .sessionIDMismatch: code = .sessionCorrupt
        default: code = .storageWrite
        }
        return .init(code: code)
    }
    static func capture(_ c: CaptureErrorCode) -> UserIssue {
        switch c {
        case .permissionNotDetermined, .permissionDenied, .permissionUnavailable: .init(code: .microphonePermission)
        case .permissionRestricted: .init(code: .microphoneRestricted)
        case .noCurrentInputDevice, .activeDeviceDisconnected, .inputRouteChanged, .engineConfigurationChanged: .init(code: .microphoneDisconnected)
        case .alreadyRunning: .init(code: .busy)
        case .startInterrupted: .init(code: .cancelled)
        default: .init(code: .captureFailed)
        }
    }
    static func recorder(_ c: AudioRecorderErrorCode) -> UserIssue {
        switch c {
        case .diskFull: .init(code: .diskFull)
        case .storageAccess, .storageReauthorizationRequired, .storageRootNotWritable: .init(code: .storagePermission)
        case .storageRootUnavailable, .storageRootMissing: .init(code: .storageMissing)
        case .cancelled: .init(code: .cancelled)
        case .alreadyStarted, .invalidLifecycle: .init(code: .busy)
        case .unsafeSessionLayout, .recoveryArtifactExists: .init(code: .sessionCorrupt)
        default: .init(code: .storageWrite)
        }
    }
    static func recording(_ c: RecordingSessionFailure) -> UserIssue {
        switch c {
        case let .storageRoot(c), let .persistence(c): storage(c)
        case let .capture(c): capture(c)
        case let .recorder(c): recorder(c)
        case .permission(.restricted): .init(code: .microphoneRestricted)
        case .permission: .init(code: .microphonePermission)
        case let .speechModel(c): speech(c)
        case .busy: .init(code: .busy)
        case .cancelled: .init(code: .cancelled)
        case .interrupted: .init(code: .interrupted)
        case .recordingStreamEnded: .init(code: .captureFailed)
        default: .init(code: .storageWrite)
        }
    }
    static func speech(_ c: STTErrorCode) -> UserIssue {
        switch c {
        case .unsupportedModel, .unsupportedCapability, .invalidConfiguration: .init(code: .modelIncompatible)
        case .loadFailed, .startFailed: .init(code: .engineInitialization)
        case .backlogFull: .init(code: .speechDelayed)
        case .cancelled: .init(code: .cancelled)
        default: .init(code: .engineInference)
        }
    }
    static func finalization(_ c: AudioFinalizationCode) -> UserIssue {
        switch c {
        case .diskFull: .init(code: .diskFull)
        case .storageAccess, .reauthorizationRequired, .rootNotWritable: .init(code: .storagePermission)
        case .rootMissing: .init(code: .storageMissing)
        case .sourceMissing: .init(code: .sessionMissing)
        case .unsupportedSchema, .corruptDocument, .unsafeLayout, .checkpointInconsistent, .canonicalConflict: .init(code: .sessionCorrupt)
        case .cancelled: .init(code: .cancelled)
        case .transcript: .init(code: .transcriptStorage)
        default: .init(code: .audioFinalization)
        }
    }
    static func transcript(_ c: TranscriptFailureCode) -> UserIssue {
        switch c {
        case .speechIncomplete: .init(code: .speechIncomplete)
        case .repairRequired: .init(code: .transcriptRepair)
        case .busy, .notFinalized: .init(code: .busy)
        case .editConflict: .init(code: .conflict)
        case .catalog: .init(code: .catalog)
        case .missingCanonical, .segmentMissing: .init(code: .sessionMissing)
        default: .init(code: .transcriptStorage)
        }
    }
    static func model(_ c: ModelRepositoryCode) -> UserIssue {
        switch c {
        case .insufficientCapacity: .init(code: .diskFull)
        case .capacityUnknown: .init(code: .modelCapacity)
        case .capacityOverflow: .init(code: .modelIncompatible)
        case .integrityMismatch, .hashFailed: .init(code: .modelCorrupt)
        case .incompatible, .unsupportedSchema, .invalidDescriptor, .validationUnavailable: .init(code: .modelIncompatible)
        case .busy: .init(code: .modelBusy)
        case .scopeDenied: .init(code: .modelAccess)
        case .sourceUnavailable, .descriptorRequired: .init(code: .modelMissing)
        case .staleAssessment, .identityChanged: .init(code: .conflict)
        case .cancelled: .init(code: .cancelled)
        default: .init(code: .modelOperation)
        }
    }
    static func download(_ c: ModelDownloadFailure) -> UserIssue {
        if let cause = c.repository { return model(cause.cause) }
        let code: UserIssueCode = switch c.code {
        case .insufficientCapacity: .diskFull
        case .diskWrite, .journal: .storageWrite
        case .cancelled: .cancelled
        case .busy, .invalidState: .busy
        case .byteCount: .modelCorrupt
        default: .modelTransfer
        }
        return .init(code: code)
    }
    static func detail(_ c: SessionDetailFailure) -> UserIssue {
        let code: UserIssueCode = switch c {
        case .busy, .notFinalized: .busy
        case .conflict, .identityChanged: .conflict
        case .cancelled: .cancelled
        case .unavailable: .sessionMissing
        default: .playback
        }
        return .init(code: code)
    }
    static func artifact(_ value: SessionDetailIssue) -> UserIssue {
        if value.code == "missing" { return .init(code: .sessionMissing) }
        let code = value.code.split(separator: ".").last.map(String.init) ?? ""
        if let storageCode = StorageErrorCode(rawValue: code) { return storage(storageCode) }
        if let transcriptCode = TranscriptFailureCode(rawValue: code) { return transcript(transcriptCode) }
        return .init(code: .sessionCorrupt)
    }
    static func recovery(_ issue: SessionRecoveryIssue) -> UserIssue? {
        switch issue.code {
        case .rootUnavailable, .rootReadOnly: .init(code: .storagePermission)
        case .metadataMissing, .missingRecoverySource: .init(code: .sessionMissing)
        case .metadataCorrupt, .metadataUnsupported, .checkpointCorrupt, .checkpointUnsupported,
             .checkpointSessionMismatch, .checkpointInconsistent, .sessionIDMismatch,
             .duplicateSession, .unsafeLayout, .terminalInconsistent: .init(code: .sessionCorrupt)
        case .finalizationFailed: .init(code: .audioFinalization)
        case .transcriptFinalizationFailed: .init(code: issue.warning == "transcript.repairRequired" ? .transcriptRepair : .transcriptStorage)
        case .catalogRefreshFailed: .init(code: .catalog)
        case .cancelled: .init(code: .cancelled)
        default: nil
        }
    }
    static func error(_ e: Error) -> UserIssue {
        switch e {
        case let e as StorageError: storage(e.code)
        case let e as CaptureError: capture(e.code)
        case let e as AudioRecorderError: recorder(e.code)
        case let e as RecordingSessionFailure: recording(e)
        case let e as STTEngineError: speech(e.code)
        case let e as AudioFinalizationCode: finalization(e)
        case let e as TranscriptFailure: transcript(e.code)
        case let e as ModelDownloadFailure: download(e)
        case let e as ModelOperationFailure: model(e.cause)
        case let e as ModelRepositoryCode: model(e)
        case is CatalogError: .init(code: .catalog)
        case is DomainValidationError: .init(code: .invalidTitle)
        case let e as SessionDetailFailure: detail(e)
        case is CancellationError: .init(code: .cancelled)
        default: .init(code: .unknown)
        }
    }
}

extension RecordingSessionSnapshot {
    func issues(includeSpeech: Bool = true) -> [UserIssue] {
        var values: [UserIssue] = []
        if let failure { values.append(UserIssues.recording(failure)) }
        if noInputWarning { values.append(.init(code: .noInput)) }
        if persistenceWarningCode != nil { values.append(.init(code: .storageWrite)) }
        if catalogWarningCode != nil { values.append(.init(code: .catalog)) }
        if includeSpeech {
            if let failure = speech.failure { values.append(UserIssues.speech(failure)) }
            if speech.storageWarning != nil { values.append(.init(code: .transcriptStorage)) }
            if speech.degraded { values.append(.init(code: .speechDelayed)) }
        }
        var seen: Set<UserIssueCode> = []
        return values.filter { seen.insert($0.code).inserted }
    }
}
