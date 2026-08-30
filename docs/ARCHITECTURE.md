# Architecture

## T02 domain model and lifecycle

`LocalLectureSTT`는 macOS 15 이상, arm64 전용 SwiftUI 앱 target 하나와 두 test target으로 시작한다.

```text
LocalLectureSTT (app)
├── App             composition root와 scene 진입점
├── Features        화면과 사용자 상호작용 단위
├── Application     use case와 orchestration의 예정 경계
├── Domain          프레임워크 비의존 타입과 규칙의 예정 경계
└── Infrastructure  외부 시스템 구현의 예정 경계

LocalLectureSTTTests             unit smoke test
LocalLectureSTTIntegrationTests  app module을 연결하는 integration smoke test
```

현재 경계는 하나의 app target 안에 있는 **논리적 경계**이며 compile-time module 분리는 아직 없다. `Domain`은 Foundation과 Swift 값 타입만 사용하며, 다음 T03 이후의 저장소·오디오·STT 구현에는 의존하지 않는다.

목표 의존 방향은 다음과 같다.

```text
App → Features → Application → Domain
App → Infrastructure → Application/Domain
Domain → 다른 앱 계층에 의존하지 않음
```

MVP는 단일 프로세스다. 이후 비동기 구성 요소는 XPC나 별도 프로세스로 이동할 수 있도록 경계를 유지하되, T02에서는 그 추상화나 XPC를 만들지 않는다. AppKit, IOKit, AVFoundation은 필요한 adapter 또는 Infrastructure에만 제한할 예정이다.

### Domain contracts

`SessionID`, `TranscriptSegmentID`, `SessionEventID`, engine/model ID와 언어 코드는 서로 대입할 수 없는 작은 값 타입이다. `EngineIdentity`와 `ModelIdentity`는 세션 재현에 필요한 version, revision, checksum을 함께 보존한다.

`AbsoluteTime`은 wall-clock `Date`를 밀리초 정밀도로 고정하고 시간대 포함 ISO 8601 문자열로 JSON에 기록한다. `MediaMilliseconds`, segment sequence와 segment count는 별도 음수 불가 정수 타입이므로 wall-clock 시간·초 단위 부동소수·미디어 위치가 섞이지 않는다.

모든 독립 저장 DTO(`SessionMetadataDocument`, `TranscriptDocument`, `TranscriptJournalRecord`, `SessionEventRecord`, `FinalizationCheckpointDocument`)는 정수 `schemaVersion`을 가진다. 중앙 `SchemaVersionPolicy`는 현재 v1만 허용하고 미래 버전을 조용히 현재 버전으로 해석하지 않는다. `TranscriptJournalRecord`는 `recovery/transcript.journal.jsonl`의 독립적인 한 레코드이며, 실제 JSONL append는 아직 구현하지 않는다.

`SessionLifecycle`은 현재 처리 상태와 녹음 결말인 `CaptureOutcome`을 분리한다. 정상 종료는 `recording/paused → securing → finalizing → completed`이며 securing부터 outcome이 `completed`다. 중단 복구는 `interrupted → securing/finalizing → interrupted`이고 outcome은 계속 `interrupted`여서 파일 복구 완료가 정상 녹음 완료로 바뀌지 않는다. 같은 상태 적용은 검증된 lifecycle의 no-op이고, 다른 모든 허용되지 않은 전이는 domain error다. 앱 시작 시 잔존한 `recording`/`paused` + `inProgress` 변환은 T09가 담당한다.

`FinalizationCheckpointDocument`는 명세의 여덟 단계가 앞 단계부터 순서대로 완료됐음을 보존한다. 마지막으로 완료된 단계의 재적용만 idempotent하며, 이미 완료한 더 이른 단계를 다시 적용하면 regression, 다음 단계를 건너뛰면 skipped error다. 비연속 저장 상태도 거부한다. 실제 JSONL append는 T03, 오디오 마무리와 checkpoint 실행은 T08/T09 범위다.

의도적으로 아직 구현하지 않은 항목은 persistence, 권한 요청, AVFoundation 마이크 캡처, STT 엔진 protocol과 모델 관리, 세션 UI 및 앱 생명주기 정책이다.
