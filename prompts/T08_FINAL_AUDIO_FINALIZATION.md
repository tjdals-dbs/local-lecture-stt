# T08 실행 프롬프트 — 최종 오디오 마무리 파이프라인

## 0. 역할, 실행 설정, 제출 경계

당신은 `/Users/andyoon/stt`의 **T08만 담당하는 새 구현 세션**이다. 사용자 지정 실행 설정은 **gpt-5.6-terra / high**다. T07까지 통합된 최신 `dev`에서 시작하여 아래 세 작업 묶음을 순서대로 구현·검증하라. 각 묶음은 별도 Task가 아니며, 중간 진행 보고 뒤에도 같은 세션에서 계속한다.

이번 목표는 recovery MOV를 검증된 최종 `audio.m4a`로 만드는 실제 오디오 파이프라인과 안전한 재실행·정리 경계를 구현하고, **task branch commit·push·정확한 HEAD의 CI 성공까지 갖춘 `review ready` 후보**를 제출하는 것이다. 구현량이나 아직 작성하지 않은 테스트는 blocker가 아니다. 실제 권한 부족, 상충하는 새 제품 결정, 보존할 수 없는 데이터 위험이 있으면 안전 정지하고 구체적인 blocker를 보고한다.

- 브랜치: `task/t08-final-audio-finalization`
- 확인 당시 기준선: `dev = origin/dev = 178471ce00de7b7ca7ecc7dfc77c7e9b45bd9697`
- 기준선 검증: 전체 135개 테스트와 arm64 Debug 빌드, 해당 dev CI 성공
- main 기준선: `38e126f92ac823d29306ea8c1f7703f7060a5818`
- 위 SHA/테스트 수는 출발점 정보다. 실제 Git 상태와 이번 실행 결과를 다시 확인하라.

이 프롬프트는 T08 코드·테스트·관련 아키텍처/개발/acceptance 문서 및 task branch의 commit·push·CI만 허가한다. **`PROJECT_STATUS.md`, `IMPLEMENTATION_PLAN.md`, `MVP_SPEC.md`, `dev`, `main`, gate 상태는 변경하지 않는다.** PR, tag, release, task branch 삭제도 하지 않는다. 독립 검토 후 별도 통합 프롬프트가 있어야 Phase 2를 진행한다. T09 시작 시 복구, T10 앱 종료/잠자기 정책, T20 transcript 생성, STT, pause/resume, 완성형 세션 목록은 구현하지 않는다.

## 1. 가장 먼저 구분할 단계적 구현 범위

T08의 **오디오 단계 완료**와 MVP의 **세션 전체 마무리 완료**는 다르다. 이 구분은 제품 완료 조건을 낮추는 것이 아니라 T08/T20의 구현 순서를 명시하는 것이다.

| 경계 | T08에서 구현·실행할 것 | 아직 하면 안 되는 것 |
| --- | --- | --- |
| 필수 저장 | T07 capture stop → accepted PCM drain → writer finish → ended metadata/event 보존 | `stop()`이 긴 최종화까지 기다리도록 변경 |
| 오디오 마무리 | `.securing → .finalizing`, recovery MOV → staging M4A → 검증 → 최종 M4A 확정 | 확장자만 바꾼 MOV, 검증 전 최종 이름 공개 |
| checkpoint | `workingAudioSecured`, `finalM4ACreated`, `finalM4AVerified`까지 실제 순서대로 진행 | transcript/derived 단계 건너뛰기 또는 가짜 성공 처리 |
| 전체 완료 | 전체 완료 증거가 있을 때만 작동하는 recovery 정리 API와 검증 | T08 live 경로에서 빈 transcript/MD를 만들어 `completed` 또는 삭제를 정당화 |

T08 live 경로에서는 `audio.m4a`가 준비돼도 metadata는 `.finalizing`이고 기존 `captureOutcome`을 유지한다. 오디오 완료를 별도 result/snapshot으로 표시하며 `completed`, `metadataCompleted`, `catalogUpdated`, `recoveryDataRemoved`를 앞당기지 않는다. T20 이후의 전체 파이프라인이 transcript/파생 파일/최종 metadata/catalog를 실제로 끝낸 후 정리 API를 사용한다.

기존 T07 프롬프트와 `docs/ARCHITECTURE.md`에 있는 “T08이 finalizing → completed와 recovery 삭제를 담당한다”는 미래 설명은 위 두 경계로 구체화하라. 아키텍처 문서의 해당 설명은 고치되, T07 과거 제출 프롬프트나 제품 명세를 재작성하지 않는다. T08 삭제 범위가 없어지는 것은 아니다. **실제 안전 삭제 구현과 양성/음성 테스트까지 만들되, 아직 전체 완료 증거가 없는 live 오디오 경로에서는 실행하지 않는다.**

## 2. 필요한 컨텍스트와 기준선 확인

읽는 순서:

1. 이 프롬프트 전체와 `AGENTS.md`
2. `PROJECT_STATUS.md`
3. `IMPLEMENTATION_PLAN.md`의 T08, 경계 확인용 T07/T09/T10/T20, 5장 Phase 1 Git 정책
4. `MVP_SPEC.md` 6장, 11.1~11.3, 12.1~12.5, 14.1, 17.4
5. `docs/ARCHITECTURE.md`의 Domain/checkpoint, Storage, T06/T07 부분과 `docs/DEVELOPMENT.md`의 build/test/CI
6. Git 상태와 다음 실제 코드. 이미 읽은 전체 명세·모든 과거 프롬프트를 반복해서 읽지 않는다.

핵심 코드:

- `LocalLectureSTT/Domain/{FinalizationCheckpoint,SessionLifecycle,SessionDocuments,SessionStorage,SessionEvents}.swift`
- `LocalLectureSTT/Application/{RecordingSessionCoordinator,AudioRecorder,StorageContracts,SessionCatalog}.swift`
- `LocalLectureSTT/Infrastructure/{StorageRootManager,FileSessionRepository,AtomicFileWriter,AVFoundationAudioRecorder}.swift`
- `LocalLectureSTT/App/LocalLectureSTTApp.swift`
- `LocalLectureSTT/Features/{RecordingSessionViewModel,RecordingSessionView}.swift`
- `LocalLectureSTTTests/{RecordingSessionCoordinatorTests,AudioRecorderTests,DomainModelTests}.swift`
- `LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests.swift`
- `.github/workflows/macos-ci.yml`, `.gitignore`, shared scheme/project settings

특히 기준선의 다음 사실을 전제로 설계하라.

- T07 `stop()`의 `.secured`는 `SessionLocation`, metadata, recorder summary를 제공한다. 정상 metadata는 `.securing/.completed`이고 여기서 `.completed`는 **captureOutcome**이지 세션 status가 아니다.
- checkpoint는 연속 prefix만 허용한다. 마지막 완료 단계의 재적용만 no-op이고 더 이른 단계 재적용은 regression이다. 재시도는 완료 단계 호출을 건너뛰어야 하며 Domain 규칙을 느슨하게 바꾸지 않는다.
- `StorageRootManager.withAccess`의 closure는 동기식이다. async AVFoundation 작업은 `acquireWriteLease(to:)` 같은 장기 scope를 사용한다. callback이 끝나기 전에 scope를 닫지 않는다.
- 기존 T03 `StorageRootControlling` URL 선택 API는 명시적 예외다. T08에 새로 추가하는 Application 계약으로 URL/AVFoundation 타입을 확장하지 않는다.
- 기존 repository의 경로 구성/JSON decoding만으로 symlink 안전성 또는 읽은 document의 session ID 검증이 보장된다고 가정하지 않는다. T08의 실제 읽기·쓰기·정리 경계에서 검증한다.
- `AtomicFileWriter`의 일반 rename은 기존 destination을 교체한다. 최종 오디오 publication에는 그대로 적용하지 말고 **기존 canonical 파일을 덮어쓰지 않는 원자적 이동**을 구현한다.

먼저 status/branch/remotes/log를 확인하고 `origin`을 fetch하여 최신 dev에서 task branch를 만든다. 기준선 unsigned arm64 build/test를 실행한다. 이 프롬프트 파일만 조정 세션이 만든 untracked/modified 상태라면 허가된 T08 입력이다. 보존하여 task branch로 가져가고 T08 커밋에 포함하라. 다른 사용자 변경은 버리지 않는다.

## 3. 작업 묶음 A — 계약, 안전한 저장 경계, 실제 오디오 처리

### A1. 최소 Application 계약

다음 책임이 구분되는 최소 계약/타입을 만든다. 이름은 선택 가능하지만 `docs/T08_ACCEPTANCE.md`에 실제 이름을 기록한다.

- 명시적인 `SessionLocation`을 받는 오디오 최종화 요청과 재실행 요청
- 진행 상태 및 완료/실패 snapshot, 검증 보고서, 안정적인 typed error code
- 실제 export/remux 및 미디어 검증 경계
- 검증된 전체 마무리 증거를 요구하는 recovery-audio 정리 경계

새 요청/result/progress/error payload는 Foundation 값 타입 기반 `Codable & Sendable`로 만들고 저장 대상의 version/session identity를 검증한다. `AVAsset`, `CMTime`, `CMSampleBuffer`, `URL`, file handle, security lease는 Infrastructure 안에 둔다. 새 package, FFmpeg 실행 파일, 네트워크 또는 범용 작업 엔진은 추가하지 않는다. macOS 15/arm64 기준을 높이지 않는다.

### A2. 파일 접근과 소유권

- 요청의 rootID/sessionID/folderName을 작업 전체에 고정한다. 사용자가 active root를 바꿔도 다른 root로 읽기·쓰기·삭제가 이동하지 않는다.
- session folder identity, metadata/checkpoint의 schema와 sessionId, root/session/recovery/대상 파일의 symlink 및 파일 종류를 확인한다. 깨진 symlink도 존재 충돌로 취급한다.
- `.recording/.paused/.preparing` 또는 `captureOutcome.inProgress/notStarted` 입력은 finalization 전에 거부한다. 정상 요청은 T07 resource settlement 뒤에만 전달한다. T09용 명시적 `.interrupted` 입력도 지원하되 앱 시작 시 이를 발견·자동 변환하는 기능은 만들지 않는다.
- async 처리와 cleanup이 끝날 때까지 scope/reader/exporter/writer를 유지하고 정확히 한 번 닫는다. 접근 실패에는 임의의 홈/현재 active root 경로로 fallback하지 않는다.
- 고정 staging 경로는 세션 폴더의 `audio.finalizing.m4a`, canonical은 `audio.m4a`다. source는 `recovery/audio.recovery.mov`다. staged/canonical 파일은 same-volume atomic publication을 전제로 한다.
- source는 읽기 전용이다. 실패한 staging/기존 canonical/손상 자료를 자동 삭제하지 않는다. 이전 staging이 불완전하거나 재사용 불가능하면 원본을 보존하는 충돌 없는 retained 경로로 옮긴 뒤 recovery에서 재생성할 수 있다. retained 파일은 자동 청소하지 않고 위치를 진단 결과로 남긴다. canonical `audio.m4a`는 자동 이동·교체하지 않는다.
- 처리 중 검증 대상이 다른 파일로 교체됐거나 source가 변경된 경우 publication/삭제를 중단한다. 조회 뒤 await가 있는 위치와 파괴적 동작 직전에 identity를 재검증한다.
- 전체 MOV/M4A/PCM을 `Data` 또는 배열로 한 번에 읽지 않는다. 변환·fingerprint·검증은 제한된 buffer로 streaming한다.

### A3. M4A 생성과 검증

기존 source는 AAC-LC, mono, 48 kHz, 목표 96 kbps다. 불필요한 손실 재인코딩 없이 AAC sample을 M4A 컨테이너로 재패키징하는 경로를 우선 사용한다. AVFoundation API 선택은 현재 SDK와 macOS 15 지원 범위를 확인한다. 지원하지 않는 입력/설정은 typed failure로 처리하고, 조용히 코덱·채널·샘플레이트를 바꾸지 않는다.

최소 검증:

1. 단순 확장자 변경이 아닌 실제 M4A 컨테이너이고, audio track 하나이며 video track이 없다.
2. AAC-LC/mono/48 kHz, 유효하고 유한한 양수 media duration이다. 목표 bitrate 96 kbps와 실제 평균 bitrate는 구분한다. 압축 오디오의 실제 평균 bitrate가 정확히 96,000이어야 한다고 잘못 assert하지 않는다.
3. 정상 세션은 source의 실제 미디어 길이를 T07의 durable duration과 비교한다. 최종 파일은 source의 실제 길이와 비교한다. 판정 tolerance는 공통 상수 **150 ms**로 고정하고 테스트에서 경계 밖 축약/늘어남을 거부한다. 정수 ms와 초 단위/CMTime 변환, AAC priming/edit-list 차이를 명시적으로 처리한다.
4. interrupted 입력은 오래된 metadata 길이를 복구 가능한 실제 길이로 위장하지 않는다. 읽을 수 있는 source의 실제 범위를 기준으로 final을 검증하고 outcome을 계속 interrupted로 보존한다. 읽기 실패/알 수 없는 손상은 성공으로 축소하지 않는다.
5. source 및 final의 sample timeline에 불연속/역행/잘림/중간 read error가 없는지 streaming으로 검사한다. `copyNextSampleBuffer() == nil`만으로 성공하지 말고 reader의 종료 상태와 error도 확인한다.
6. 최종 파일의 시작과 마지막 유효 구간을 각각 별도의 `AVAssetReader` PCM decode 경로로 실제 디코딩한다. nonempty sample/byte 수와 decoded time range를 확인한다. 전체를 처음부터 읽고 첫/마지막 compressed buffer만 봤다는 것을 end-seek PCM decode로 보고하지 않는다.
7. 기존 결과 재사용에는 source와 같은 미디어라는 근거가 필요하다. 같은 duration/format만으로는 부족하다. 예를 들어 순서가 보존된 compressed sample payload의 streaming digest 등으로 provenance를 확인하고, **같은 길이·형식이지만 다른 음성인 파일은 충돌로 보존**한다. fingerprint 비교는 raw container byte 동일성을 요구하는 것이 아니다.

오류는 source missing/unreadable, identity/schema/layout, export create/start/read/write/finish, invalid format/duration, decode, publication, persistence, disk-full, cancellation 등을 구분한다. 같은 최초 원인이 public result/snapshot에 남고, 나중 cleanup/persistence/diagnostic 오류는 별도 warning으로 남아야 한다.

## 4. 작업 묶음 B — checkpoint, 재실행, 조건부 recovery 정리

### B1. 순서와 durable 의미

다음 순서를 코드와 테스트에서 고정한다.

1. resource settlement 및 source/identity를 확인한다.
2. 없는 checkpoint를 초기화하고 `workingAudioSecured`를 durable하게 기록한다.
3. 기존 필드를 보존하여 metadata를 `.finalizing`으로 기록한다. title, times, IDs, language, engine/model, transcript summary, captureOutcome을 잃지 않는다.
4. staging M4A를 생성하고 exporter/writer 완료, 파일 close/flush를 확인한다.
5. `finalM4ACreated`를 durable하게 기록한다.
6. staging을 검증하고 canonical 경로에 no-clobber atomic publication 후 directory sync를 완료한다.
7. canonical 경로의 실제 파일을 다시 열어 검증된 파일과 동일하며 읽을 수 있음을 확인한 뒤 `finalM4AVerified`를 durable하게 기록한다.
8. 최종 오디오 description 등 필요한 metadata projection을 갱신하고 catalog를 best effort로 refresh한다. T08 live 경로는 `.finalizing`에 머물며 `audioReadyAwaitingRemainingFinalization`에 해당하는 결과를 반환한다.

checkpoint는 완료된 side effect의 기록이지 앞으로 할 일의 예약이 아니다. 필수 metadata/checkpoint write 실패를 성공으로 숨기지 않는다. 파일 publication 후 checkpoint write가 실패했다면 final/source 둘 다 남기고 실패와 실제 durable 위치를 보고한다. 이미 일어난 rename을 되돌리거나 파일을 지우지 않는다.

SQLite refresh 실패는 audio-ready 결과의 warning이며 오디오 결과를 롤백하지 않는다. 그러나 전체 완료 cleanup gate에서 필요한 catalog acknowledgment는 별도 충족해야 한다. 이 단계의 catalog refresh만으로 `catalogUpdated` checkpoint까지 건너뛰지 않는다.

`finalizationStepTransition` event를 기록한다면 checkpoint 저장 후 diagnostic으로 기록한다. event 실패가 checkpoint를 후퇴시키지 않으며 별도 warning으로 보인다. checkpoint 재실행마다 같은 완료 event를 재추가하지 않는다. 서로 다른 파일인 checkpoint/journal의 crash-atomic exactly-once를 주장하지 않는다. checkpoint가 authoritative이고 crash window의 diagnostic event 누락은 허용한다. 기존 recordingStarted/Ended를 재추가하지 않는다.

### B2. 재실행 판정표

재실행은 기존 checkpoint를 읽고 **이미 완료한 earlier step에 `markingCompleted`를 다시 호출하지 않는다.** 더 진행된 checkpoint를 3단계로 줄이거나 unknown schema를 현재 schema로 다시 쓰지 않는다. 이미 후속 파이프라인이 완료한 metadata를 다시 `.finalizing`으로 바꾸거나 transcript summary를 과거 값으로 덮지 않는다. 이 경우 오디오 재검증 결과만 반환하며 terminal metadata/checkpoint를 보존한다.

| 디스크 상태 | 요구 동작 |
| --- | --- |
| checkpoint 없음, source 유효 | 처음부터 진행; 불완전 staging은 보존 후 재생성 가능 |
| workingAudioSecured, staging 생성 도중 중단 | source에서 다시 만들거나 동일 source의 완성 staging을 검증해 재사용 |
| staging 생성 완료, created checkpoint 저장 전 중단 | 실제 완성도/동일 source 검증 후 created 기록; 존재만 보고 성공하지 않음 |
| finalM4ACreated, staging 존재 | 재검증 후 publication; export를 불필요하게 반복하지 않음 |
| finalM4ACreated 이하, canonical 존재, staging 없음 | rename 뒤 checkpoint 전 중단일 수 있음; source와 provenance/미디어를 검증해 채택하고 남은 순서만 진행 |
| canonical과 staging 모두 존재 | canonical이 source와 일치하면 이를 우선 검증·채택하고 staging은 보존; canonical이 다르거나 증거가 불명확하면 충돌 |
| finalM4AVerified 이상, canonical 유효 | 재검증 후 오디오 단계 no-op; checkpoint bytes/updatedAt을 불필요하게 다시 쓰지 않음; 누락된 T08 projection만 재시도 |
| checkpoint가 있다고 주장하는 canonical이 누락/손상/다른 내용 | typed inconsistency/conflict; checkpoint 후퇴, canonical 덮어쓰기, recovery 삭제 금지 |
| canonical은 존재하지만 다른 source이거나 provenance 불명 | 충돌로 보존; 재생 가능하다는 이유만으로 채택 금지 |
| checkpoint corrupt/future schema/다른 sessionId | bytes 그대로 보존, typed error; 초기화/덮어쓰기 금지 |
| source 없음, 이전 완료 증거도 없음 | missing source; 임의 staging을 원본으로 승격 금지 |

각 durable side effect 전후에 중단시켜 새 finalizer 인스턴스로 이어서 실행하는 테스트를 만든다. T09의 자동 스캔은 만들지 않지만 T09가 같은 API로 재개할 수 있어야 한다.

### B3. recovery-audio 삭제 gate

실제 삭제 구현은 오디오 최종화 함수와 분리한다. 다음 조건을 모두 검증한 뒤에만 정확한 `recovery/audio.recovery.mov` 하나를 제거할 수 있다.

- 같은 session/root의 checkpoint가 `catalogUpdated`까지 연속적으로 완료됨
- 현재 `audio.m4a`가 유효하고 최종 검증/소스 identity 증거와 일치함
- canonical transcript 및 `.txt`/`.md`의 전체 파이프라인 검증 증거가 현재 파일들과 일치함
- metadata가 해당 captureOutcome에 맞는 전체 terminal 상태이고 sessionId/파일 내용이 완료 증거와 일치함
- catalog 반영 성공 증거가 있음
- cleanup 직전에도 source/final/필수 파일이 교체되거나 변경되지 않았음

checkpoint 숫자, 파일 존재 여부, 호출자가 전달한 `true` 하나만으로 삭제를 허용하지 않는다. 미래 전체 파이프라인이 제공할 typed completion evidence/verification 경계를 두되 현재 파일의 identity/digest와 대조하라. generation 이후 변조된 proof도 거부해야 한다. T08은 transcript renderer/compactor를 만들지 않고, cleanup 양성 테스트에서만 유효한 합성 완료 파일/증거를 fixture로 만든다.

- T08 live audio-only 경로에는 전체 완료 증거가 없으므로 recovery 삭제 횟수는 항상 0이다.
- transcript journal, checkpoint, events, retained staging, 세션 폴더, 다른 세션의 파일을 삭제하지 않는다. 이 단계에서 `recoveryDataRemoved`는 명세가 정한 recovery **오디오** 제거 완료를 기록한다.
- 삭제 성공 후 `recoveryDataRemoved` checkpoint를 기록한다. 삭제 직후 checkpoint write 실패 시 final/나머지 자료를 보존하고 실패를 보고한다. 재시도는 source 부재만으로 실패하거나 다시 삭제하지 않고, 전체 완료 증거를 다시 확인한 뒤 누락된 마지막 checkpoint를 기록한다.
- 이미 recoveryDataRemoved까지 끝난 입력은 검증 후 no-op이다. 예전 단계를 다시 mark하여 배열 범위를 벗어나거나 regression을 만들지 않는다.
- 삭제 이전 취소/검증 실패는 source를 보존한다. 삭제 commit point 이후 도착한 취소는 실제 삭제 사실을 숨기거나 파일이 복원됐다고 보고하지 않는다. 해당 결과를 동일 작업의 모든 waiter에 일관되게 전달한다.

## 5. 작업 묶음 C — lifecycle, T07 연결, 관찰 가능한 최소 UI

### C1. 단일 소유자와 경합

- `(rootID, sessionID)`별 최종화는 single-flight다. 중복 요청은 같은 작업/result를 공유한다. 동일 세션에서 export/rename/cleanup이 겹치지 않는다.
- heavy export는 한 번에 하나만 실행한다. 여러 종료 결과가 생기면 app-owned serial pending queue에 location 같은 작은 값만 보관한다. PCM/미디어 전체나 길이에 비례하는 progress history를 보관하지 않는다.
- 각 작업은 attempt/generation과 정확한 location을 소유한다. 상태를 바꿀 수 있는 await 뒤마다 소유권을 재검증한다. 이전 callback, queue completion, cleanup이 다음 세션의 파일·scope·UI를 건드리지 못한다.
- caller/view observation task 취소는 app-owned 작업을 자동 취소하지 않는다. 명시적 작업 취소 API는 exporter/reader/writer cleanup과 scope release를 기다려야 한다. cleanup이 끝나기 전 같은 세션을 재시작하지 않는다.
- failure/cancel/completion 경합은 최초 원인, terminal result, finish 요청, scope release를 정확히 한 번 확정한다. 최초 failure 후 persistence까지 실패하는 조합도 포함한다. terminal snapshot은 늦은 구독자에게도 보인다.

### C2. App 연결과 필수 저장 API 분리

- app-scoped orchestration이 T07 `.secured` 결과를 받아 자동으로 T08에 한 번 제출한다. view `.task`나 view model의 임시 caller가 finalization의 lifetime owner가 되어서는 안 된다.
- T07 coordinator를 단독으로 호출하는 기존 테스트에서는 여전히 recovery만 생성되고 final M4A가 없어야 한다. 이 보장을 삭제하지 말고, 새 app-level 연결 테스트로 T08 자동 제출과 최종 파일 생성을 별도 증명한다.
- T07 `stop()`/동등한 필수 저장 API는 export, endpoint decode, 전체 finalization을 기다리지 않는다. 최종화가 gate에서 대기해도 stop 결과를 받을 수 있음을 테스트한다.
- 실제 integration에서는 essential-save 경과 시간과 audio-finalization 경과 시간을 별도로 측정한다. 필수 저장 2초 목표는 관측 결과로 보고하고, synthetic 측정을 실제 마이크/TCC 지연 검증으로 과장하지 않는다.
- T07 capture settlement 뒤 새 녹음을 시작할 수 있다. 이전 세션 finalization/경고가 새 recording snapshot을 덮지 않아야 한다. background finalization이 capture PCM path를 블로킹하거나 같은 actor에서 긴 동기 미디어 작업을 하지 않게 한다.
- 별도 finalization progress/result 또는 기다리기 API를 제공한다. T10에서 사용할 essential-save와 long-running-work 경계가 명확해야 하지만 T10 종료/잠자기 정책은 만들지 않는다.
- T07 abnormal result를 정상 `.secured`처럼 취급하지 않는다. 자동 손상 MOV 수리/잔존 세션 검색은 T09 범위다. T08의 explicit location API는 valid interrupted fixture를 지원한다.

### C3. 최소 UI

기존 recording 화면에 finalization 진행/오디오 준비 완료/실패·재시도 상태만 연결한다. 전체 목록/재생 UI는 추가하지 않는다.

- “안전하게 저장 중”과 “오디오 마무리 중”을 구분한다.
- 실제 백분율을 알 수 없으면 단계명/indeterminate progress를 사용한다. 임의의 100%나 가짜 남은 시간을 만들지 않는다.
- T08 성공 문구는 “오디오 파일 준비 완료 · 나머지 마무리 대기”처럼 전체 세션 완료와 구분한다. 아직 없는 STT가 처리 중이라고 표시하지 않는다.
- failure에는 source 보존, 재시도 가능 여부, 최초 stable code와 persistence warning을 구분해 보여준다.
- UI observation 중단/재구독에도 작업은 유지된다. active recording과 background finalization을 session identity로 분리한다.

## 6. Acceptance matrix — 코드와 assertion으로 모두 증명

시작할 때 `docs/T08_ACCEPTANCE.md`에 아래 ID, 실제 테스트 함수, 핵심 assertion, 명령/결과, 남은 수동 항목을 연결한 간결한 표를 만든다. 구현 중 비어 있는 행을 채우고 검토 후보 보고 전에 빠진 자동 조건이 없는지 확인한다. 테스트 이름만 적거나 fake 호출 1회만 세는 것은 실제 디스크/미디어 조건의 증명이 아니다.

| ID | 필수 자동 검증 |
| --- | --- |
| A01 | 새 DTO Codable/Sendable round-trip, framework/URL-free 경계, construction만으로 파일/마이크/최종화 side effect 없음 |
| A02 | 정상 T07 결과부터 final M4A까지 production repository/root/audio backend 연결; closed recovery를 입력으로 사용 |
| A03 | M4A/AAC-LC/mono/48kHz, 실제 duration, sample timeline 및 독립적인 first/end PCM decode; 잘못된 container/track/format/zero duration/150ms 밖 길이/중간 read error 거부 |
| A04 | 기존 staging/canonical, 동일 format·duration의 다른 미디어, 경로 symlink, sessionId/future schema, source 없음/변경을 실제 임시 파일에서 검증; 기존 bytes 보존 |
| A05 | root 없음/재승인/read-only/작업 중 root 변경; 고정 location 사용과 scope acquire/release 정확한 횟수 |
| B01 | B1 순서 trace와 실제 checkpoint readback. 성공 시 prefix 3개, finalizing 및 원래 captureOutcome, final/source 존재, transcript/derived 미생성 |
| B02 | B2 모든 재실행 행. export 완료→checkpoint, validation→rename, rename→verified checkpoint, verified checkpoint→metadata 사이 failure를 주입하고 새 인스턴스로 재개 |
| B03 | export create/start/read/write/finish, disk-full, endpoint decode, flush/sync, rename, 각 checkpoint/metadata write 실패. 최초 오류와 추가 warning, 마지막 durable bytes/source 보존 |
| B04 | gate 중 최초 terminal/cancel 뒤 pending persistence도 실패하는 복합 경로. public result/snapshot/재조회 결과 일치; cleanup 전 재시작 금지 |
| B05 | full completion 없는 live 경로 삭제 0회. cleanup의 각 선행 조건 누락/오염/교체/잘못된 session은 삭제 0회. 실제 synthetic 완료 fixture는 지정 recovery 오디오만 1회 삭제 |
| B06 | 삭제 성공→마지막 checkpoint 실패→재시도, 이미 완료된 cleanup 재실행, 삭제 commit point 전/후 cancellation. 필수 결과는 보존되고 삭제/마지막 기록은 중복되지 않음 |
| C01 | 동일 세션 동시 요청 single-flight, 두 세션 순차 queue, cancel/finish race, 이전 callback/cleanup isolation, late subscriber 결과 보존 |
| C02 | finalizer gate가 막혀도 필수 stop 반환; capture settlement 후 새 녹음 허용; 이전 finalizer가 새 session UI/metadata에 영향 없음 |
| C03 | 단계별 최소 view model snapshot/action 매핑과 실패 재시도, observation cancel/re-subscribe로 backend가 취소되지 않음 |
| L01 | 실제 2시간 synthetic media finalization과 endpoint decode, duration/연속 sample coverage/소스 보존, 시간·메모리 관측 |
| R01 | 기존 T01~T07 전체 regression, Debug build, task HEAD CI, 범위/데이터 정책/Git 불변 조건 |

테스트 구성 권장: `LocalLectureSTTTests/AudioFinalizationTests`에 deterministic unit/fault/lifecycle tests, `LocalLectureSTTIntegrationTests/AudioFinalizationIntegrationTests`에 실제 filesystem/AVFoundation/장시간 tests. 다른 suite 이름을 쓰면 명령과 표를 실제 이름으로 갱신한다.

경합은 controlled continuation gate를 사용한다. 시간을 재는 테스트 외에는 `sleep`으로 순서를 맞추지 않는다. `await` 결과를 local 값에 받은 뒤 XCTest assertion을 수행한다. failure/release/취소 횟수와 파일 내용/state를 함께 assert한다. queue/old-callback 테스트는 이미 끝난 stream에 yield한 no-op을 증거로 쓰지 않는다.

### 6.1 실제 미디어 증거와 장시간 test

- 짧은 integration fixture는 서로 구분되는 시작/끝 신호와 비대칭 입력을 사용한다. source/final을 독립 reader로 열어 endpoint PCM이 실제 예상 구간인지 확인한다. 파일 존재나 asset.duration만 확인하는 테스트는 불충분하다.
- L01은 **7,200초의 실제 연속 오디오 sample**이 있는 synthetic recovery MOV를 사용한다. metadata/PTS 끝점만 2시간으로 늘리거나 중간 대부분이 빈 sparse timeline이면 불합격이다.
- fixture는 bounded chunk로 빠르게 생성한다. 유효하게 인코딩된 AAC packet의 반복·정확한 retiming을 사용할 수 있지만, 전체 sample coverage와 duration이 연속적임을 검사한다. fixture를 만드는 데 실제 2시간을 기다리지 않는다.
- production export/publication/validation/checkpoint 경로를 실행하고 final/source 길이 차이 <=150ms, 처음과 끝의 nonempty decoded PCM, checkpoint prefix, 소스 보존, 재실행 결과를 assert한다.
- fixture 생성 시간, 오디오 finalization 시간, 재검증 시간, peak memory 관측 방식을 분리해 기록한다. 제한된 buffer/high-water assertion으로 미디어 길이에 비례하는 메모리 축적이 없음을 보인다.
- 60초는 개발 기기에서 2시간 **전체 MVP 마무리**의 목표다. T08에서는 오디오 단계 시간을 따로 측정하고, transcript 미구현 상태에서 전체 마무리 목표를 통과했다고 주장하지 않는다. CI 속도 편차 때문에 안전성 assertion을 완화하거나 long test를 skip하지 않는다. 목표 초과는 수치/환경/병목을 보고하고 correctness 성공과 구분한다.
- long test도 기본 전체 test/CI 경로에서 실제 실행되게 한다. 생성 미디어/로그/xcresult는 임시 경로에만 두고 Git에 넣지 않는다.

## 7. 실행 순서, 검증 명령, commit

순서대로 진행하며 각 단계에서 관련 테스트를 추가한다.

1. 기준선과 contract/storage/media 처리(A)를 구현·검증한다.
2. checkpoint/resume/cleanup(B)을 구현하고 각 commit window의 actual-file fault tests를 통과시킨다.
3. app ownership/T07/최소 UI 연결(C), production integration 및 2시간 fixture를 완성한다.
4. acceptance 표의 모든 자동 행을 assertion과 현재 실행 결과로 채운다. 새 deterministic lifecycle/복합 실패 테스트들을 20회 반복한다. long-media 테스트를 20회 반복할 필요는 없다.
5. 전체 build/test, diff review 후 task branch commit·push·정확한 HEAD CI를 완료한다.

기본 명령(derived data 경로는 테스트 작업 전용으로 사용):

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T08-DerivedData \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T08-DerivedData \
  CODE_SIGNING_ALLOWED=NO test

# 실제 race test들의 identifier를 명시하여 별도로 20회 반복하라.
# -only-testing:<target>/<suite>/<method> -test-iterations 20

git diff --check
git diff --stat origin/dev...HEAD
git diff --cached
```

테스트 러너/xcresult 접근 sandbox 오류는 환경 실패와 구현 실패를 구분해 필요한 권한으로 재실행한다. 0 tests/result unknown은 통과가 아니다. 기존 assertion을 삭제하거나 무의미하게 tolerance/timeout을 넓혀 통과시키지 않는다.

`docs/ARCHITECTURE.md`에는 실제 책임/파일/단계 경계, `docs/DEVELOPMENT.md`에는 재현 명령/long-media 생성·측정/수동 검증을 기록한다. unsigned synthetic evidence는 실제 microphone/TCC/sandbox, 앱 강제 종료·sleep·전원 상실 검증과 구분한다. 이번에는 실사용 녹음이나 사용자의 저장 루트에 접근하지 않는다.

커밋은 A/B/C의 의미 있는 검증 단위 또는 최종 하나로 나눌 수 있지만 테스트 실패 중인 임시 코드를 review-ready 후보로 제출하지 않는다. `T08`을 포함한 메시지를 사용하고 in-scope paths만 stage한다. 다운로드 모델, 녹음, runtime DB, media fixture 결과, 로그, 빌드 산출물은 포함하지 않는다.

모든 자동 acceptance 조건과 task CI 성공 후에도 완료 상태 문서/체크리스트를 바꾸지 않는다. `dev`/`main`은 시작 때 SHA 그대로여야 하며 task branch를 유지한다. 명시적 Phase 2 승인 전 merge/push/dev integration을 진행하지 않는다.

## 8. 최종 보고 형식

다음 정보를 실제 결과로 보고한다.

1. `T08 — review ready` 또는 `T08 — blocked`와 이유
2. task branch/commit, 시작 dev SHA, exact-head CI URL/결과
3. 구현 파일과 핵심 선택: remux 방식, 검증/provenance, checkpoint publication 의미, cleanup gate, 작업 lifetime owner
4. `docs/T08_ACCEPTANCE.md` 링크와 각 acceptance 그룹의 실제 test 함수/핵심 assertion
5. 실행한 대상/반복/전체 build/test 명령과 테스트 수·결과
6. L01 실제 source/final duration, 연속 sample 근거, 첫/끝 decode 증거, 측정 시간·메모리 및 목표와의 차이
7. recovery 삭제를 허용/거부한 증거, live audio-only 경로의 recovery 보존
8. 남은 수동 검증, 명세 편차 또는 알려진 위험
9. PROJECT_STATUS/IMPLEMENTATION_PLAN/dev/main 미변경, task branch 유지 여부
10. 다음 Task 시작 여부는 조정 세션의 독립 검토 및 별도 통합 후 결정됨을 명시

분석만 끝내거나 일부 테스트만 추가한 상태를 review ready라고 부르지 않는다. 반대로 남은 일이 명확하고 실행 가능한 T08 구현/테스트/CI라면 중간 현황 보고에서 멈추지 말고 계속 수행하라.
