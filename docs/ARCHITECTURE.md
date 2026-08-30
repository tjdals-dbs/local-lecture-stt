# Architecture

## T03 storage root and session repository

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

현재 경계는 하나의 app target 안에 있는 **논리적 경계**이며 compile-time module 분리는 아직 없다. `Domain`은 Foundation과 Swift 값 타입만 사용하며, 저장소·오디오·STT 구현에는 의존하지 않는다.

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

### Storage roots

`StorageRootID`는 UUID 기반의 안정적인 앱 고유 식별자다. `Infrastructure/StorageRootManager` actor는 Application Support의 `LocalLectureSTT/Storage/storage-roots.json`에 schema v1 registry를 atomic JSON으로 저장한다. Registry는 active root와 historical root의 app-scoped bookmark, 표시용 이름·경로와 관리 시각을 보존한다. 표시 경로는 UI 안내용일 뿐 접근 권한으로 사용하지 않는다.

`FoundationSecurityScopedBookmarkCodec`은 `.withSecurityScope` bookmark를 만들고 resolve한다. 매 repository operation은 manager의 lexical `withAccess` 내부에서 resolved URL을 사용한다. 성공한 start는 operation의 성공·실패 모두에서 한 번 stop된다. resolve/start 실패는 UI에 `reauthorizationRequired`로 전달되며 stale bookmark는 같은 root ID의 bookmark를 atomic하게 교체한다.

`Features/StorageRootViewModel`은 AppKit `NSOpenPanel` adapter를 분리해 명시적인 선택·변경·재승인 버튼만 제공한다. 앱 시작 시 active root 복원을 시도하지만 panel을 자동으로 열지 않는다. 테스트용 view construction은 in-memory preview controller를 사용하므로 Application Support나 panel을 건드리지 않는다.

### Session files

`FileSessionRepository` actor는 active 또는 historical root의 scoped operation에서만 session files를 읽고 쓴다. `SessionFolderName`은 주입된 time zone으로 `YYYYMMDD-HHMMSS_<8-char-lowercase-id>`를 만들며 제목과 무관하다. 새 session은 폴더와 `recovery/`만 만들고, 기존 이름은 collision으로 거부하며 자동 정리하지 않는다.

`SessionArtifact`만이 파일 경로를 만들며 canonical/recovery source와 derived artifact를 명시적으로 분류한다.

```text
metadata.json                         authoritative/recovery
audio.m4a                             authoritative/recovery
transcript.json                       authoritative/recovery
events.jsonl                          authoritative/recovery
recovery/audio.recovery.mov           authoritative/recovery
recovery/transcript.journal.jsonl     authoritative/recovery
recovery/finalization.checkpoint.json authoritative/recovery
transcript.txt, transcript.md         derived
```

`AtomicFileWriter`는 same-directory exclusive temp file → write → `synchronize()` → close → POSIX atomic rename → directory sync 순서로 JSON을 교체한다. rename 전 실패는 기존 destination을 건드리지 않으며 writer가 소유한 temp만 best-effort로 제거한다. `JSONLWriter`는 repository actor의 직렬화 안에서 완전히 encoded 된 단일 JSON line과 LF를 append하고 flush한다. append 실패 뒤의 possible partial trailing record를 복구하는 일은 T20/T26 범위다.

의도적으로 아직 구현하지 않은 항목은 SQLite catalog, 실제 audio 생성·검사, recording lifecycle, STT, journal compact, derived file rendering, session recovery와 전체 세션 UI다.
