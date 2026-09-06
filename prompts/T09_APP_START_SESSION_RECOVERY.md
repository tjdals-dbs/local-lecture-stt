# T09 실행 프롬프트 — 앱 시작 시 세션 복구

## 0. 역할과 제출 경계

당신은 `/Users/andyoon/stt`의 **T09만 담당하는 새 구현 세션**이다. 실행 설정은 **GPT-5.6 Terra / high**다. 아래 A → B → C 묶음을 순서대로 구현하고 각각 테스트하되, 모두 하나의 T09다. 중간 진행 보고 뒤에도 같은 세션에서 계속한다.

목표는 앱 재실행 시 파일에서 미완료 세션을 발견하고, 오래된 녹음 상태를 안전하게 정리하며, T08 오디오 마무리를 자동 재개하는 것이다. 실제 파일·미디어·앱 연결 테스트와 task branch commit/push/정확한 HEAD CI까지 갖춘 `review ready` 후보를 제출하라.

- 브랜치: `task/t09-startup-session-recovery`
- 확인 당시 `dev = origin/dev = a081dbe1ba3ef998e921da629ea50cb3dc4b92f1`
- 기준선: T08 통합 완료, 전체 162개 테스트 및 exact-dev CI 성공
- 기준선 CI: https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/33739295207
- 보존할 `main`: `38e126f92ac823d29306ea8c1f7703f7060a5818`

위 정보는 확인 당시 기록이다. 실행 시 실제 Git 상태를 다시 확인한다. 구현량이나 아직 작성하지 않은 테스트는 blocker가 아니다. 실제 권한 부족, 제품 명세 충돌, 보존할 수 없는 데이터 위험이 있으면 안전 정지하고 구체적 근거와 권장 해결을 보고한다.

이번 프롬프트는 **T09 코드·테스트·관련 문서와 task branch commit/push/CI만 승인**한다. `PROJECT_STATUS.md`, `IMPLEMENTATION_PLAN.md` 체크리스트, `MVP_SPEC.md`, `dev`, `main`, gate 상태는 변경하지 않는다. PR/tag/release 생성, task branch 삭제, 공식 T09 완료 선언, dev 통합은 하지 않는다. 독립 검토 후 별도 통합 승인이 필요하다.

## 1. 먼저 읽고 고정할 컨텍스트

1. 이 프롬프트 전체와 `AGENTS.md`
2. `PROJECT_STATUS.md`
3. `IMPLEMENTATION_PLAN.md` T09, 경계 확인용 T08/T10/T20, 5장 Phase 1 Git 정책
4. `MVP_SPEC.md` 6.2, 11.3, 12.1~12.5, 13.1~13.4, 14장, 16장, 17.6
5. `docs/ARCHITECTURE.md` Storage/Catalog/T07/T08 부분, `docs/DEVELOPMENT.md` build/test/CI, `docs/T08_ACCEPTANCE.md`의 재실행·보존 조건
6. Git 상태와 다음 실제 코드. 전체 과거 프롬프트·명세를 반복해 읽지 않는다.

핵심 파일:

- `LocalLectureSTT/Domain/{SessionLifecycle,SessionDocuments,SessionEvents,FinalizationCheckpoint,SessionStorage}.swift`
- `LocalLectureSTT/Application/{StorageContracts,SessionCatalog,SessionCatalogReconciler,RecordingSessionCoordinator,AudioFinalization,AudioFinalizationCoordinator}.swift`
- `LocalLectureSTT/Infrastructure/{StorageRootManager,FileSessionRepository,SessionFileScanner,SQLiteSessionCatalogStore,FinalizationFileAccess,FileAudioFinalizer,AVFoundationAudioFinalization,JSONLWriter}.swift`
- `LocalLectureSTT/App/{LocalLectureSTTApp,CatalogStartupCoordinator}.swift`
- `LocalLectureSTT/Features/{MainWindowView,StorageRootViewModel,RecordingSessionViewModel}.swift`
- `LocalLectureSTTTests/{SessionCatalogTests,RecordingSessionCoordinatorTests,AudioRecorderTests,AudioFinalizationTests}.swift`
- `LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests.swift`
- `.github/workflows/macos-ci.yml` 및 shared scheme/project settings

먼저 status/branch/remotes/log를 확인하고 origin을 fetch하여 최신 dev에서 task branch를 만든다. 이 프롬프트만 untracked/modified라면 조정 세션이 만든 허가된 입력으로 보존하여 T09 commit에 포함한다. 다른 사용자 변경은 폐기하거나 자동 stash하지 않는다.

기준선의 build/test를 실행·확인한 뒤, `docs/T09_ACCEPTANCE.md`에 이 문서의 acceptance ID → 실제 테스트 함수 → 핵심 assertion → 실행 결과를 연결하는 표를 만든다. 이 표는 검증 근거이며 공식 Task 상태 문서가 아니다.

## 2. T09와 후속 Task의 경계 — 구현 전에 적용

1. **오디오 복구 성공은 전체 세션 완료가 아니다.** T08 live 경로는 checkpoint 앞의 3단계까지만 수행하고 `.finalizing` 및 원래 captureOutcome을 보존한다. T09도 없는 transcript/파생 파일을 만들거나 4~8단계를 성공 처리하지 않는다.
2. 정상 `securing/finalizing` 세션은 `captureOutcome.completed`를 유지한다. 과거 `recording/paused`는 먼저 `.interrupted/.interrupted`를 durable하게 기록한다. 복구 후에도 정상 완료로 바꾸지 않는다.
3. 중단 세션의 오디오 작업 뒤 metadata가 T08 규칙에 따라 `.finalizing/.interrupted`에 머무는 것은 허용한다. UI/report는 **중단된 녹음의 오디오 복구**임을 명확히 표시하고, 전체 완료나 정상 녹음으로 표시하지 않는다. 이를 위해 metadata를 매번 interrupted ↔ finalizing으로 왕복시키지 않는다.
4. **T09 자동 복구에서는 recovery 오디오를 삭제하지 않는다.** 전체 완료 proof 발급·저장·자동 cleanup 연결은 후속 전체 파이프라인의 책임이다. T08의 기존 별도 삭제 API와 검증을 약화하지 않는다.
5. transcript journal/canonical/파생 파일은 읽기·보존 대상이다. compact, renderer, segment 보정, 모델 로딩, STT, 파일 가져오기는 구현하지 않는다.
6. 잠자기 방지, sleep/wake, 창 닫기/자동 종료, `⌘Q` 정책은 T10이다. 앱 시작의 작업 소유권과 명시적 취소/대기 경계까지만 제공한다. T21 전체 목록/재생 화면도 만들지 않는다.
7. 파일이 원본이고 SQLite는 파생 카탈로그다. DB 행이 없다고 세션을 놓치거나 DB 상태만으로 세션 파일을 덮어쓰지 않는다.

기존 타입명을 그대로 쓸 필요는 없지만 아래 동작·소유권·증거 조건은 지켜야 한다. 새 Application payload는 Foundation 기반 Codable/Sendable 값으로 만들고 URL/AVFoundation/SQLite/파일 핸들을 노출하지 않는다. 기존 T03 URL 선택 API 예외는 유지하며 전면 재설계하지 않는다.

## 3. 작업 묶음 A — 발견, 판정, 안전한 상태 정리

### A1. 파일 기반 발견과 root별 결과

- `StorageRootManager`의 active 및 historical root registry를 이용한다. 표시용 경로나 현재 active root를 다른 세션의 fallback 경로로 쓰지 않는다. 접근은 해당 rootID의 bookmark/scope로 수행한다.
- T04의 파일 스캐너/계약을 재사용하거나 필요한 작은 확장을 한다. catalog row 목록만 순회하는 복구는 금지한다. 최상위 세션 폴더를 대상으로 하고 무관한 하위 폴더를 재귀 탐색하지 않는다.
- 스캔은 read-only이며 discovery 중에 파일을 생성·수정하거나 마이크 권한창/폴더 선택창을 띄우지 않는다. 결과는 작은 location/metadata/checkpoint/파일 상태 값이며 오디오 내용을 담지 않는다.
- root 없음/재승인 필요/read-only/부분 열거 실패를 구분한다. read-only root는 읽을 수 있는 정보를 보여주되 변경하지 않는다. unavailable/partial root를 빈 정상 root로 처리하여 기존 catalog 항목을 missing으로 쓸어버리지 않는다.
- registry 손상/미래 schema처럼 안전한 root 목록을 얻을 수 없는 실패는 전체 실패로 보고한다. 개별 root나 세션의 오류는 격리하고 다른 안전한 세션은 계속 처리한다.
- folder의 short ID만 신뢰하지 말고 metadata의 전체 sessionId 및 checkpoint sessionId를 대조한다. 중복 sessionId와 위치 충돌은 관련 후보를 모두 격리하고 임의의 하나를 선택하지 않는다. T04의 duplicate/location-conflict 보호를 유지한다.
- DB reconcile/open 실패를 빈 성공으로 숨기지 않는다. 파일 발견·안전한 오디오 복구와 catalog refresh 실패는 분리한다. DB가 없거나 불능이어도 정체성이 확실한 파일 후보의 복구는 가능해야 하며, catalog 실패는 별도로 보고한다. 정체성 충돌이 해소되지 않는 후보는 변경하지 않는다.

### A2. 판정표

상태는 오래된 스캔 값이 아니라 **실제 처리 직전에 다시 확인한 파일**로 판정한다. 현재 프로세스의 활성 세션 제외는 C1을 따른다.

| 입력 상태 | T09 동작 |
| --- | --- |
| 과거 recording 또는 paused / inProgress | metadata를 interrupted/interrupted로 안전하게 기록한 후 읽을 수 있는 recovery의 오디오 마무리 재개 |
| securing 또는 finalizing / completed | 원래 정상 captureOutcome을 보존하여 T08 재개 |
| interrupted 또는 securing/finalizing / interrupted | interrupted outcome을 보존하여 아직 필요한 오디오 단계 재개/검증 |
| preparing / notStarted | 미완료 준비로 진단하고 기존 허용 전이인 error/notStarted로 1회 정리한다. 정상 녹음/중단 녹음을 임의로 만들어내지 않는다. 잔존 자료는 보존하고 자동 마이크 재시작·오디오 승격은 하지 않는다 |
| terminal metadata와 catalogUpdated 이상 checkpoint가 일치 | 기본적으로 자동 복구 대상에서 제외한다. 완료 checkpoint와 일치하는 recovery 부재를 오류로 오인하지 않는다. 명백한 문서/필수 최종 오디오 충돌은 별도 진단하되 terminal metadata를 후퇴시키지 않는다 |
| 기존 error/missing | 진단·보존한다. 명시적 재검색으로 현재 파일 상태를 확인할 수 있지만, 이 Task에서 기존 error/missing metadata를 임의로 정상 상태로 되돌리지는 않는다. T09가 발생시킨 retryable 실패는 원래 metadata와 checkpoint를 보존하므로 해당 안전한 재시도와 구분한다 |
| metadata 누락/손상/future schema/ID 불일치 | 원문 그대로 보존하고 needs-attention 결과. 기본 metadata나 새 sessionId를 만들어 덮어쓰지 않는다 |
| checkpoint 손상/future schema/불연속 prefix/다른 sessionId | 원문 그대로 보존하고 typed error. checkpoint 없음과 다르게 취급한다 |
| source 없음, 임의 staging만 존재 | missing source로 보존. staging을 recovery 원본으로 승격하지 않는다 |

`preparing` 정리의 stable diagnostic code도 정해 테스트와 문서에 적는다. Domain의 `SessionLifecycle`이 금지한 상태 조합이나 전이를 느슨하게 만들어 편법으로 통과시키지 않는다. metadata가 completed라고만 적혀 있고 이를 뒷받침할 metadataCompleted checkpoint가 없는 등 명백한 모순은 자동 성공 대신 needs-attention으로 보존한다.

### A3. metadata 정리의 durable 의미

- interrupted 전환 write가 성공하기 전에 T08을 호출하지 않는다. write/flush/rename 실패를 잡아서 복구 성공이나 queued로 표시하지 않는다.
- 제목, ID, 생성/기록 시각, 언어, engine/model, transcript summary, app/OS 정보 등 무관한 필드를 보존한다. 알 수 없는 녹음 종료 시각을 앱 재실행 시각으로 채우지 않는다. 복구 시각은 별도의 event/report 시각이다.
- 오래된 `activeDurationMs`를 실제 복구 길이라고 주장하지 않는다. T08의 실제 media report를 별도로 표시한다. 이 Task에서 기존 duration/time 필드를 추측으로 재작성하지 않는다.
- 동일 목표 상태이면 metadata bytes와 lastUpdatedAt을 불필요하게 다시 쓰지 않는다. 중단 직후 재시작도 원래 captureOutcome과 이미 durable한 전환을 보존한다.
- 모든 변경은 root/session/file identity 재검사와 atomic write/flush를 거친다. 단순히 `FileSessionRepository`를 호출하면 symlink/교체 안전성이 자동 보장된다고 가정하지 않는다. T08의 pinned file access를 재사용/최소 일반화하거나 동등한 보호를 구현한다.
- recovery 디렉터리나 파일이 없다는 이유로 원본의 누락을 숨기는 빈 파일을 만들지 않는다. 진단용 접근은 미완료 레이아웃도 처리할 수 있어야 한다.

## 4. 작업 묶음 B — T08 재개와 실제 미디어 복구

### B1. 한 개의 기존 최종화 큐 사용

- T07 정상 종료와 T09 복구는 **동일한 app-owned `AudioFinalizationCoordinator`**에 제출한다. 복구 전용 두 번째 heavy export 큐나 별도 AVAssetWriter 파이프라인을 만들지 않는다.
- `(rootID, sessionID, folder identity)`가 고정된 요청만 제출한다. 중복 시작/재검색/재시도는 동일 세션의 진행 중 작업에 합류한다. T08의 기존 `retry: false`는 settled 결과도 재사용하므로, 실제 실패 후 명시적 재시도가 필요한 경우 `retry: true`를 올바르게 연결한다.
- export 시작·종료 및 cleanup이 끝나기 전에 같은 세션의 metadata 정리/재시도를 겹치지 않는다. 현재 최종화 작업이 있는지 한 번 조회한 뒤 await를 거쳐 무조건 파일을 쓰는 패턴은 금지한다. C1의 공통 소유권 또는 동등한 직렬화로 보호한다.
- 필요한 최소한의 T08/T07 연결 변경은 허용하지만 기존 media 검증·no-clobber publication·보존·first-error 규칙과 회귀 테스트를 유지한다. T09를 위해 독립된 느슨한 finalizer를 복제하지 않는다.

### B2. checkpoint별 재개 정책

다음 표의 **모든 행을 새 root manager/repository/catalog/finalizer/recovery coordinator 인스턴스**로 재개하는 테스트에 연결한다. 이전 객체의 메모리 cache가 성공 근거가 되어서는 안 된다.

| 디스크 상태 | 요구 결과 |
| --- | --- |
| checkpoint 없음 또는 빈 prefix, 유효 source | 오디오 단계 시작; interrupted 전환이 필요한 경우 먼저 durable하게 처리 |
| workingAudioSecured, 없거나 불완전한 staging | source에서 재개. 불완전 staging은 T08의 retained 정책으로 보존 |
| 완성 staging, created 기록 전 | source와의 provenance/완성도 확인 후 채택; 존재만으로 성공하지 않음 |
| finalM4ACreated, staging 존재 | 재검증·publication; 불필요한 재export 없음 |
| publication 뒤 verified 기록 전, canonical 존재 | 같은 source인지 검증하고 남은 단계만 진행 |
| canonical과 staging 모두 존재 | T08의 canonical 우선 검증·충돌 보존 정책 유지 |
| finalM4AVerified(prefix 3), canonical 유효 | 오디오 재검증/no-op 및 누락된 T08 projection만 재개. 오디오 성공과 전체 완료를 구분하여 waiting-for-remaining 유지 |
| prefix 4/5/6/7 | 후속 완료 step 및 metadata를 보존. 4/5의 미완료 세션은 가능한 오디오 재검증만 하고 remaining-work를 보고한다. 6의 terminal metadata는 catalog refresh를 수행할 수 있지만 checkpoint 7을 대신 mark하지 않는다. 7의 일치하는 terminal 세션은 자동 audio 재작업에서 제외한다. T20 단계·전체 완료·cleanup을 대신 실행하지 않음 |
| prefix 8, terminal metadata, 유효 final, source 없음 | 정상적인 정리 완료일 수 있다. 자동 변환 대상에서 제외하며 missing source로 실패시키거나 이전 step을 다시 mark하지 않음 |
| verified 이상인데 canonical 누락/손상/다른 음성 | typed inconsistency/conflict, 기존 bytes/source 보존; checkpoint 후퇴나 canonical 덮어쓰기 금지 |
| source 없고 검증 가능한 기존 전체 완료 근거도 없음 | missing/needs-attention. 성공 proof를 합성하거나 staging으로 원본을 대체하지 않음 |

4~8단계 fixture는 이미 저장돼 있는 후속 데이터에 대한 호환성·보존 테스트다. 그 단계의 기능을 새로 구현하라는 요구가 아니다. source 없는 완료 세션을 제외하는 판정과, 새로운 오디오 재검증 성공을 주장하는 것은 다르다. T08에서 source 없는 재검증에 필요한 sealed proof를 T09가 임의로 발급하지 않는다.

### B3. 정상 종료 파일만으로 복구를 증명하지 말 것

- 실제 T06 writer가 녹음 중인 상태에서 확보한 **finish 이전 fragmented MOV snapshot**을 fixture로 사용한다. 최소 22초 synthetic 입력, 여러 완결 `moof`가 있는 active prefix를 확보하고 복사 시점 writer가 recording임을 assert한다. 기존 `AudioRecorderTests`의 active-prefix fixture를 참고하라.
- snapshot을 별도 복구 세션의 `recovery/audio.recovery.mov`로 배치하고, 오래된 recording/paused metadata와 새 서비스 인스턴스로 T09 전체 경로를 실행한다. 정상 `stop()`으로 끝낸 파일을 복사하여 비정상 종료 증거라고 부르지 않는다.
- 복구된 final은 AAC-LC/mono/48kHz, 연속 timeline, source의 실제 읽을 수 있는 길이와 150ms 이내 일치, 독립적인 시작/끝 PCM decode, 원래 interrupted outcome 및 원본 byte 보존을 확인한다.
- 입력 시간과 snapshot의 실제 복구 가능 시간·final 시간·손실 차이를 각각 보고한다. 완결 prefix 시험과 실제 전원 손실/프로세스 kill을 구분하며, 이 한 fixture로 모든 충돌에서 10초 손실 목표를 보장한다고 주장하지 않는다.
- 빈 MOV, header만 있는 파일, 잘린/손상된 마지막 fragment, 중간 sample read 실패를 별도로 시험한다. 읽을 수 있는 완결 prefix는 위 양성 시험으로 복구해야 한다. AVFoundation이 온전히 읽지 못한 임의 손상을 조용히 정상 완료로 축소하지 않는다. 임의 MOV 수리기나 원본 truncate/교체는 이 Task에서 만들지 않는다.
- 실제 미디어를 모두 Data/PCM 배열로 올리지 않는다. T08 streaming/버퍼 제한을 유지한다. 소규모 합성 fixture 외 실제 강의 자료·모델·네트워크는 사용하지 않는다.

### B4. 복구 사건과 오류 보존

- 정상적인 `events.jsonl`에 복구 시작/결과를 기존 event schema로 기록한다. `recoveryCompleted`의 detail에는 **오디오 복구 결과**와 remaining-work 여부를 명확히 두어 전체 세션 완료와 혼동하지 않게 한다. 과거 recordingStarted/Ended를 새로 만들지 않는다.
- 같은 입력의 재검색/재시작/no-op에서 같은 복구 사건을 계속 중복 append하지 않는다. 안정적인 episode/event 식별자와 기존 durable 기록 확인 또는 동등한 방식으로 진단 중복을 막는다. 메모리 Set만으로 앱 재시작 idempotence를 주장하지 않는다.
- event는 diagnostic이며 metadata/checkpoint를 대체하는 source of truth가 아니다. 이벤트가 빠져도 실제 미완료 파일 작업을 재개할 수 있어야 한다. 별도 파일 간 crash-atomic exactly-once를 주장하지 않는다.
- JSONL 확인도 streaming과 제한된 line buffer로 수행한다. 전체 강의 event/journal을 무제한 배열로 적재하거나 비정상적으로 긴 한 줄 때문에 메모리가 계속 증가하게 하지 않는다.
- events의 미완성 마지막 줄/손상/future schema/다른 sessionId를 만나면 원문을 자르거나 붙여서 유효한 줄처럼 만들지 않는다. 원문을 보존하고 해당 진단 append를 생략하며 warning을 보고하는 보수적 처리를 사용한다. 오디오 복구까지 불필요하게 막지 않는다. T09가 부르는 T08 diagnostic 경로도 손상 줄 뒤에 무조건 append하지 않도록 필요한 작은 seam/보호를 연결한다.
- transcript journal/canonical/파생 파일은 수정하지 않는다. 이 Task에서 모든 transcript 의미를 검사하거나 손상 줄을 복구하려 하지 않는다. symlink 등 안전하지 않은 레이아웃은 별도 오류로 처리한다.
- 최초 failure/cancellation과 이후 metadata/event/catalog/cleanup 실패를 분리한다. 같은 최초 stable code가 반환값·snapshot·재조회에 남고 후속 오류는 warning으로 남아야 한다. catalog refresh만 실패하면 오디오 성공을 롤백하거나 전체 성공으로 숨기지 않는다.

## 5. 작업 묶음 C — 앱 시작·재검색·현재 녹음의 공존

### C1. 작업 소유권과 검색 시점

- backend recovery coordinator는 app lifetime에 하나이며 start/refresh/retry와 관찰 snapshot을 제공한다. View `.task`는 시작 신호/관찰만 하고 복구 작업의 lifetime owner가 되지 않는다. 생성자/preview만으로 디스크 변경이나 마이크 시작을 하지 않는다.
- 최초 discovery/classification을 current-process recording 시작과 조정한다. 안전한 후보 집합을 확보하기까지 짧은 준비 gate를 두거나 동등한 소유권 방식을 사용한다. **오래 걸리는 media 복구가 끝날 때까지 새 녹음을 막지는 않는다.**
- 이 보호는 UI 버튼 비활성화뿐 아니라 실제 app-level Start API에도 적용한다. 기존 T07 standalone 계약/테스트와 필수 저장 지연 보장은 유지한다.
- 현재 프로세스에서 생성·소유한 준비/녹음/일시정지/필수 저장 세션은 과거 중단 세션으로 판정하지 않는다. 최초 startup뿐 아니라 root 변경·재승인·수동 재검색·실패 재시도에도 적용한다.
- 공통 reservation/세션 활동 소유권 또는 동등한 원자적 검증을 사용한다. `currentSnapshot()` 한 번 확인 → await → 파일 변경 같은 TOCTOU 보호 부족을 남기지 않는다. T07이 폴더를 생성하는 중인 구간부터 resource settlement까지 보호하고, T08 진행 중 세션에도 중복 metadata write를 하지 않는다.
- root 변경/재승인 중 이미 시작한 작업은 원래 location을 유지한다. 새 root는 후속 discovery로 반영한다. discovery 중 refresh 요청은 병합하되 마지막 요청을 유실하지 않는다. T04 `refreshPending`의 보장을 유지한다.
- 같은 세션은 single-flight, 여러 세션의 heavy media는 T08 단일 큐로 직렬 처리한다. 메모리에 보관하는 것은 작은 후보·최신 결과이며 오디오나 끝없이 누적되는 progress history가 아니다.
- 자동 시작/재검색은 같은 실패를 busy-loop로 재시도하지 않는다. 실패 후 사용자 재시도나 root 재승인 등 명시적 재평가 계기를 사용한다. prefix 3에서 후속 작업을 기다리는 정상 상태 때문에 스스로 새 복구 pass를 계속 만들지 않는다.
- generation/ownership을 관련 await 뒤에 검사한다. 늦은 scan/result/callback/cleanup이 다음 pass나 새 recording snapshot을 덮지 못한다.
- view 관찰 취소는 backend를 취소하지 않는다. 명시적 복구 취소는 자신이 소유한 작업만 취소하고 자원·scope settlement까지 기다린다. 다른 정상 녹음/최종화를 취소하지 않는다. 정리 전 같은 작업 재시작을 허용하지 않는다.

### C2. App 연결, catalog, 최소 UI

- `LocalLectureSTTApp`, 기존 `CatalogStartupCoordinator`, root-change callback에 실제 recovery 서비스를 연결한다. 테스트에서만 호출 가능한 서비스로 끝내지 않는다. T04 catalog 시작/갱신과 T09 시작/갱신을 한 흐름으로 조정하고 중복 스캔·자동 refresh 피드백 루프를 피한다.
- 파일 상태 전환과 T08 결과 이후 catalog를 다시 대조한다. T04의 unavailable/partial/conflict 보호를 유지한다. 오디오 복구 오류를 metadata 손상이라고 덮어쓰거나 파일이 없는 가짜 metadata/catalog row를 생성하지 않는다.
- catalog의 파일-presence 의미와 T09의 media-recovery 결과는 구분한다. metadata만 정상이라고 모든 오디오가 정상이라고 표시하지 말고, 복구 report의 세션별 missing/error/warning을 UI에 전달한다. 이를 위해 SQLite를 복구의 원본 상태 저장소로 바꾸지 않는다.
- 기존 화면에 복구 확인 중/오디오 복구 중/오디오 준비 및 나머지 마무리 대기/중단 녹음의 복구 결과/일부 실패·재승인·재시도 정보를 간결히 제공한다. 전체 세션 목록·플레이어·디자인 개편은 하지 않는다.
- 모든 실패 항목을 식별할 수 있고, 재시도 가능한 항목에는 재시도 동작을 제공해야 한다. 마지막 세션 하나만 보여 다른 복구 실패를 숨기지 않는다. 실패 location/rootID와 stable code, 원본 보존 여부, warning을 구분한다. 재시도 불가능한 항목에는 원인과 필요한 사용자 조치를 안내하고 자동 재시도를 활성화하지 않는다.
- discovery 완료와 모든 queued audio 작업의 완료를 다른 상태로 표현한다. late subscriber/관찰 재시작도 최신 결과를 받는다. 현재 녹음 UI와 과거 복구 상태는 session identity로 분리한다.
- 복구 때문에 마이크 권한 요청·모델 설치·네트워크 접속을 하지 않는다. 파일 복구와 새 녹음 경로의 독립성을 실제 App composition 테스트로 증명한다.

## 6. Acceptance matrix — 실제 assertion으로 채울 것

아래 행은 모두 필수다. 테스트 이름 나열, fake 호출 횟수, UI 문자열만으로 파일/미디어 안전성을 대신하지 않는다. 각 행에 actual fixture, 핵심 assertion, 명령/결과를 연결하라.

| ID | 검증할 내용 |
| --- | --- |
| A01 | 새 payload Codable/Sendable round-trip, framework/URL-free Application 경계, construction/preview의 디스크·마이크·네트워크 side effect 없음 |
| A02 | 실제 active/historical root 파일 발견, DB 삭제/빈 DB에서도 발견, 무관한 폴더 제외, 잘못된 folder/ID 및 중복 session/location 변경 0회 |
| A03 | root 없음/재승인/read-only/부분 scan/registry 실패 구분; 다른 정상 root는 계속, 기존 catalog rows 보존 |
| A04 | recording/paused → interrupted durable 전환, 정상 securing outcome 보존, preparing 정책, metadata 모든 무관한 필드 및 반복 시 bytes 보존 |
| A05 | metadata/checkpoint missing/corrupt/future/schema/ID/불연속 prefix와 symlink·깨진 symlink·파일 종류 충돌; 원문 보존, typed result |
| B01 | B2 모든 행: checkpoint 없음/0~8, staging/canonical 조합. 새 서비스 인스턴스로 재실행, step 후퇴/중복 export/허위 후속 완료/자동 삭제 없음 |
| B02 | 실제 finish 이전 multi-moof snapshot → 새 앱 서비스 → final M4A. PCM first/end decode, media duration/연속성/provenance, interrupted outcome 및 source bytes 보존 |
| B03 | 빈/header-only/잘린 fragment/중간 read 오류/동일 길이 다른 음성 canonical. 손상·충돌 원본 보존과 다른 세션의 복구 지속 |
| B04 | interrupted metadata write 전후, export/flush/publication/checkpoint/projection 전후 failure 후 새 인스턴스 재개. 실패 write 뒤 finalizer 제출 0회, 필요한 durable 작업만 재시도 |
| B05 | recovery event 정상 기록·새 인스턴스/no-op 중복 방지, 손상/미완성 events bytes 보존 및 warning, transcript/journal/derived 미수정 |
| B06 | 첫 오류/취소 뒤 metadata·diagnostic·catalog·cleanup도 실패하는 조합. result/snapshot/재조회 첫 code 일치, warning 보존, resources/scope 정확히 한 번 release |
| C01 | 두 startup/refresh/retry가 같은 세션에 동시에 도착해도 single-flight; 두 세션은 shared T08 큐; root-change pending 유실 없음 |
| C02 | discovery와 실제 새 T07 preparing/start/stop이 경합, recording 중 재승인/재검색, 이미 진행 중인 T08과 재검색. 현재 세션 metadata/events/audio가 recovery에 의해 변경되지 않음 |
| C03 | 복구 media gate가 막힌 상태에서 새 녹음 시작·필수 저장 가능. 이전 pass/callback이 새 recording 결과를 덮지 않음 |
| C04 | 관찰 취소/재구독/늦은 구독, 명시적 취소와 cleanup gate, cleanup 전 retry 금지, 다른 세션 작업은 계속 |
| C05 | 실제 app-start 및 root-change 연결, 파일 변경 후 실제 SQLite readback, 일부 실패 UI 전체 식별·재시도·재승인 mapping, waiting-for-remaining과 전체 완료 구분 |
| R01 | 기존 162개를 포함한 전체 회귀, T08 2시간 미디어·경로 교체·terminal revalidation 보호 유지, Debug build 및 exact task HEAD CI |

결정론적 경합은 continuation/barrier gate로 순서를 만든다. `sleep`으로 운 좋게 재현하지 않는다. 미디어 fixture의 실제 writer flush 준비를 기다리는 bounded polling은 일반 actor 경합 테스트와 구분하고 timeout/실패 근거를 둔다. XCTest assertion 전에 await 값을 local로 받는다.

최소 반복 검증: C01 startup 중복/root refresh, C02 active recording 보호, C03 과거 recovery와 새 recording, C04 취소/late callback, B06 복합 오류에서 대표 테스트를 선택해 **각 20회** 실행한다. 실제 함수명·선택 수·총 실행 수를 보고한다. 기존 T08 반복 테스트는 변경된 소유권/cleanup 경계에 해당하면 함께 실행한다.

실제 디스크와 production StorageRootManager/FileSessionRepository/SQLite/AudioFinalizationCoordinator를 연결한 integration test를 포함한다. fake-only 테스트로 app wiring과 디스크 복구를 입증했다고 하지 않는다. fixture의 원본 파일은 비교 후 테스트 소유 임시 디렉터리만 정리한다.

## 7. 구현 순서와 검증 명령

- A: discovery/판정/보존 metadata 전환과 A01~A05를 먼저 만든다.
- B: T08 재개, actual fragmented snapshot, durable crash windows, event/error 검증을 붙인다.
- C: startup/root refresh/recording 보호와 최소 UI를 연결하고 경합·실제 app integration을 검증한다.
- 각 묶음에서 테스트를 통과시킨 뒤 다음으로 간다. 함수/파일 이름을 일찍 acceptance 표에 고정하여 누락을 추적한다. 의미 없는 전면 리팩터링이나 새 영속 schema는 피한다. 새 지원 타입이 필요하면 실제 책임과 호환성을 문서화한다.

권장 suite는 `LocalLectureSTTTests/SessionRecoveryTests`, `LocalLectureSTTIntegrationTests/SessionRecoveryIntegrationTests`다. 다른 이름을 선택하면 문서·명령을 실제 이름으로 바꾼다. 공유 scheme/CI에서 빠지지 않도록 project membership을 확인한다.

```sh
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T09-DerivedData \
  CODE_SIGNING_ALLOWED=NO build test
```

targeted 및 반복 검증은 같은 build 설정에 실제 `-only-testing:` 항목과 `-test-iterations 20`을 사용한다. baseline 숫자를 최종 통과 수로 복사하지 않는다. xcresult에서 실제 테스트 수·failure·skip을 확인하고 0개/불명/환경 실패를 성공이라고 하지 않는다. 현재 로컬 SDK뿐 아니라 기존 macOS 15 CI/Swift 6 toolchain에서 컴파일되는지 확인한다. 최소 OS/아키텍처/Swift 언어 설정을 낮추거나 바꿔서 통과시키지 않는다.

`docs/ARCHITECTURE.md`에 실제 recovery와 공통 작업 소유권, startup/root-change 흐름, T08/T20 경계를 갱신한다. `docs/DEVELOPMENT.md`에는 실제 명령과 disposable root에서의 수동 강제 종료→재실행/권한 복원 확인 절차를 추가한다. 실행하지 않은 실제 마이크/TCC/Sandbox/kill/power-loss/덮개 닫기를 통과했다고 쓰지 않는다. T10/T26 검증을 이번 자동 테스트의 성과로 포함하지 않는다.

## 8. 제출과 Git

1. acceptance 표의 모든 자동 조건과 실제 assertion을 대조한다. 남은 구현·테스트가 있으면 같은 Task 안에서 계속한다.
2. 전체 task diff 및 staged diff를 검토하고 in-scope 파일만 명시적으로 stage한다. 다운로드 모델·실제 녹음·런타임 DB·bookmark·로그·xcresult·빌드 산출물을 commit하지 않는다.
3. Task ID를 포함해 논리적으로 commit한다. 예: `feat(recovery): resume interrupted sessions on startup (T09)`.
4. task branch만 push하고, **최종 HEAD와 일치하는 CI**가 성공할 때까지 확인한다. 중간 커밋의 green CI로 대체하지 않는다. CI 수정도 같은 T09 안에서 처리하고 최종 상태를 다시 검증한다.
5. `PROJECT_STATUS.md`, 계획 체크리스트, `dev`, `main`은 그대로 두고 task branch를 보존한다. 공식 완료·통합·다음 Task 시작은 하지 않는다.

최종 보고:

- `T09 — review ready` 또는 실제 차단 사유가 있는 `blocked`
- task branch/최종 SHA와 exact-head CI URL/결과
- 변경 파일과 핵심 경계/판정 정책
- acceptance ID별 근거, 실제 명령/통과 수, 20회 반복 총수
- finish 이전 snapshot의 입력/복구 가능/final 길이, decode 및 원본 보존 결과
- 남은 수동 검증, 명세 이탈 여부, 알려진 위험
- 공식 T09 완료와 T10 착수 가능 여부는 조정 세션의 독립 검토 및 별도 통합 후 결정된다는 점

상태 보고만 한 뒤 작업을 멈추지 말고, 실제 blocker가 없다면 task commit/push/최종 CI까지 끝낸 검토 후보를 제출하라.
