# T02 실행 프롬프트 — 도메인 모델, 파일 스키마, 상태 머신

## 역할

당신은 `/Users/andyoon/stt` 저장소의 **T02만 담당하는 새 구현 세션**이다. T01에서 만든 실행 가능한 macOS 앱 기준선 위에 세션 도메인 모델, 직렬화 가능한 파일 DTO, 스키마 버전 정책, 상태 전이 규칙을 구현하고 검증하라.

T03의 실제 파일 저장소나 이후 녹음·STT 기능은 구현하지 않는다. 제품 명세를 임의로 바꾸지 말고, T02 범위를 완료하는 데 필요한 순수 Domain 타입과 결정론적 규칙만 만든다.

## 목표

성공 시 다음이 모두 참이어야 한다.

- 세션 ID, 세션 상태, 녹음 결과, 언어 모드, 엔진 및 모델 식별자가 서로 혼동되지 않는 앱 고유 타입으로 정의되어 있다.
- `metadata.json`, `transcript.json`, `events.jsonl`의 개별 레코드, `finalization.checkpoint.json`을 표현하는 `Codable & Sendable` DTO가 존재한다.
- 모든 독립 저장 문서와 JSONL 레코드에 `schemaVersion`이 있으며 현재 v1과 미지원 버전을 명시적으로 구분할 수 있다.
- 절대 시각은 시간대가 있는 ISO 8601 문자열로, 오디오 위치와 길이는 음수가 아닌 정수 밀리초로 직렬화된다.
- 정상 녹음 종료, 일시정지, 비정상 중단, 중단 세션 복구를 구분하는 상태 머신이 있다.
- 중단 세션의 파일 복구가 끝나도 녹음 결과가 정상 완료로 바뀌지 않는다.
- 앱 시작 시 발견될 수 있는 잔존 `recording`/`paused` 상태와 이미 판정된 `interrupted` 결과를 데이터상 구분할 수 있다.
- 허용·금지 상태 전이와 주요 JSON round-trip이 단위 테스트로 고정되어 있다.
- 기존 앱 build와 전체 test suite가 통과한다.
- 검증된 T02 결과가 하나의 squash commit으로 `dev`에 통합되고 `dev` CI가 통과한다.
- `main`은 변경하거나 승격하지 않는다.

## 허가된 외부 변경

완료 조건을 모두 충족하는 경우에 한해 다음을 허가한다.

- `task/t02-domain-model-state-machine` 브랜치 생성과 push
- task branch의 GitHub Actions 실행과 결과 확인
- 검증된 task branch를 로컬에서 squash merge하여 `dev` push
- merge된 `dev`의 GitHub Actions 실행과 결과 확인
- `dev`가 안전하게 push되고 CI까지 통과한 뒤 T02 task branch 삭제

Pull Request, `main` 변경·push·승격, tag, GitHub Release, branch protection 변경, 저장소 공개 범위 변경, 외부 dependency 또는 모델 다운로드는 허가하지 않는다.

## 반드시 먼저 읽을 컨텍스트

다음 순서와 범위로 읽어라.

1. 이 프롬프트 전체
2. `AGENTS.md` 전체
3. `PROJECT_STATUS.md` 전체
4. `IMPLEMENTATION_PLAN.md`
   - 2장 실행 원칙
   - 5.2~5.7절 Git 및 GitHub 정책
   - `T02. 도메인 모델, 스키마, 상태 머신`
   - 8장 작업별 프롬프트 작성 규칙
   - 9장 전체 진행 체크리스트
5. `MVP_SPEC.md`
   - 6장 세션 상태와 상태 전이
   - 8장 기술 구조
   - 13장 파일 스키마
   - 14장 복구와 마무리 체크포인트
6. `docs/ARCHITECTURE.md`와 `docs/DEVELOPMENT.md`
7. 실제 Git 상태, Xcode project, Domain 디렉터리와 현재 tests

관련 문서가 서로 충돌하거나 아래 데이터 계약으로는 명세를 안전하게 표현할 수 없다면 임의로 결정하지 말고 안전한 상태에서 중단하여 충돌, 영향, 권장 선택지를 보고하라.

## 현재 알려진 기준선

다음은 프롬프트 작성 시점의 정보일 뿐이며 새 세션에서 실제 상태로 다시 확인한다.

- 작업 디렉터리: `/Users/andyoon/stt`
- 현재 장기 branch: `dev`
- T01 보완 완료 기준선: `38e126f92ac823d29306ea8c1f7703f7060a5818`
- 프롬프트 문서 commit이 위 기준선 뒤의 `dev`에 추가되어 있을 수 있음
- 원격: `https://github.com/tjdals-dbs/local-lecture-stt.git`
- 저장소 공개 범위: private
- GitHub 기본 branch: `main`
- `main`은 T01의 실행 가능한 기준선을 유지해야 함
- T01 앱, unit test target, integration test target, shared scheme과 CI가 존재함
- 현재 Domain에는 구현 타입이 없고 boundary marker만 있음
- Xcode 26.6의 AppIntents metadata 경고는 알려진 비차단 toolchain 진단이며 `docs/DEVELOPMENT.md`에 기록되어 있음

대화나 이 목록보다 새 세션에서 확인한 실제 Git 상태와 코드를 우선한다.

## 1. 사전 점검과 task branch

파일을 수정하기 전에 다음을 확인한다.

- `pwd`
- `git status --short --branch`
- `git remote -v`
- local 및 remote branch와 upstream
- 최근 commit과 `dev`, `origin/dev`의 SHA
- 예상하지 않은 tracked·untracked 파일이나 사용자 변경 존재 여부
- `xcode-select -p`, `xcodebuild -version`, `swift --version`, `uname -m`
- 기존 T01 build/test 명령이 현재 환경에서 실행 가능한지

working tree가 clean하고 local `dev`가 최신 `origin/dev`와 일치하는 것을 확인한 뒤, 정확히 다음 branch를 만든다.

```text
task/t02-domain-model-state-machine
```

필요하면 먼저 `git fetch origin`, `git switch dev`, `git pull --ff-only origin dev`를 사용한다. 기존 동명 branch나 예상하지 않은 변경·분기가 있으면 덮어쓰거나 삭제하지 말고 상태를 조사한 뒤 안전하게 중단하여 보고한다. force push, destructive reset, 사용자 변경 폐기는 금지한다.

## 2. 도메인 계층과 공통 타입

새 production 타입은 T01에서 정한 `LocalLectureSTT/Domain` 논리 경계에 둔다. 한 거대 파일에 모두 넣지 말고 책임이 드러나는 소수의 응집된 Swift 파일로 나눈다. 추가한 모든 production source가 실제 app target에 포함되는지 확인한다.

Domain은 다음 원칙을 지킨다.

- Swift 표준 라이브러리와 값 타입 표현에 필요한 Foundation만 사용한다.
- SwiftUI, AppKit, AVFoundation, SQLite, WhisperKit, whisper.cpp 또는 다른 외부 라이브러리를 import하지 않는다.
- 라이브러리 고유 타입, `Any`, `[String: Any]`, 비직렬화 객체를 저장 DTO나 상태 머신 경계에 노출하지 않는다.
- DTO와 경계 타입은 필요한 범위에서 `Codable`, `Sendable`, `Equatable`을 채택한다.
- 식별자와 enum은 비교·컬렉션 사용을 위해 적절하면 `Hashable`도 채택한다.
- `@unchecked Sendable`로 컴파일러 검사를 우회하지 않는다.
- 엔진과 모델 식별 타입은 서로 대입할 수 없는 별도 앱 타입으로 만든다.
- UUID나 문자열을 감싼 작은 값 타입을 사용하여 session, transcript segment, engine, model 식별자의 실수 섞임을 막는다.

최소 다음 개념을 정의한다.

- `SessionID`
- 안정적인 transcript segment ID
- `SessionStatus`
- `CaptureOutcome`
- `LanguageMode`
- 감지 또는 segment 언어를 표현하는 앱 고유 language code 값
- engine identity: `id`, `version`
- model identity: `id`, `revision`, `checksum`

이름은 Swift 관례에 맞게 조정할 수 있지만 JSON key와 직렬화 의미는 명세와 일치해야 한다.

## 3. 상태와 녹음 결과의 분리

`SessionStatus`는 현재 처리 단계를 나타내며 다음 raw 의미를 모두 가져야 한다.

- `preparing`
- `recording`
- `paused`
- `securing`
- `finalizing`
- `completed`
- `interrupted`
- `error`
- `missing`

`CaptureOutcome`은 상태와 중복되는 UI 상태가 아니라 **녹음 자체가 어떻게 끝났는지**를 보존한다. 최소 다음 의미를 안정적인 lower-camel-case raw value로 표현한다.

- `notStarted`: 캡처가 아직 시작되지 않음
- `inProgress`: 캡처가 시작됐고 정상 종료 또는 중단 판정 전임
- `completed`: 사용자의 정상 종료 경로로 캡처를 닫음
- `interrupted`: 비정상 종료나 시스템 잠자기 등으로 캡처가 중단됨

이 구분으로 다음을 표현할 수 있어야 한다.

- 정상 흐름의 `securing`/`finalizing`은 `captureOutcome == completed`
- 중단 복구 흐름의 `securing`/`finalizing`은 `captureOutcome == interrupted`
- 중단 복구 체크포인트가 모두 끝난 최종 표시도 `status == interrupted`, `captureOutcome == interrupted`
- 앱 시작 시 아직 변환하지 않은 잔존 상태는 `status == recording` 또는 `paused`, `captureOutcome == inProgress`

T02의 JSON decoder가 잔존 `recording`/`paused`를 자동으로 `interrupted`로 바꾸면 안 된다. 실제 파일 검색과 시작 시 복구 전환은 T09 범위다. T02는 두 경우를 손실 없이 표현하고 검증할 수 있는 순수 타입과 규칙만 제공한다.

## 4. 상태 머신

명시적인 transition validator 또는 동일한 책임의 순수 상태 머신을 구현한다. 단순히 상태 enum만 만들지 말고, 허용된 전이는 성공하고 금지된 전이는 구체적인 domain error를 반환하도록 한다.

최소 정상 전이는 다음을 포함한다.

```text
preparing → recording
recording ↔ paused
recording 또는 paused → securing → finalizing → completed
recording 또는 paused → interrupted
```

중단 복구는 다음 의미를 보존한다.

```text
interrupted → securing 또는 finalizing
securing → finalizing
securing 또는 finalizing → interrupted
```

다만 이 복구 전이는 `captureOutcome == interrupted`인 복구 문맥에서만 허용해야 한다. 정상 종료 문맥의 `finalizing`은 `completed`로 갈 수 있지만, 중단 복구 문맥의 `finalizing`은 `completed`로 갈 수 없다. 상태 쌍만으로 이 차이를 잃지 않도록 lifecycle aggregate, transition cause/context 또는 그와 동등한 명시적 설계를 사용한다.

추가 규칙:

- 처리 중 복구 불가능한 오류는 `error`로 표현할 수 있어야 한다.
- 파일 시스템 검사에서 원본 누락이 확인된 결과는 `missing`으로 표현할 수 있어야 하지만 실제 검사는 T04 범위다.
- `completed`, `error`, `missing`에서 녹음 상태로 임의 재진입하지 않는다.
- `interrupted → completed`를 허용하지 않는다.
- 정상 흐름에서 `recording` 또는 `paused → completed`처럼 필수 마무리 단계를 건너뛰지 않는다.
- 상태 전이와 함께 capture outcome의 허용 조합도 검증한다.
- 같은 값을 다시 적용하는 no-op 정책은 한 가지로 명시해 테스트하되, 금지된 실제 전이를 no-op으로 숨기지 않는다.

상태 머신은 actor, UI observable object, 파일 저장소가 아니라 동기적이고 결정론적인 Domain 규칙이어야 한다.

## 5. 시간과 스키마 버전 정책

벽시계 절대 시각과 오디오 미디어 시간을 타입과 JSON 표현에서 분리한다.

- 절대 시각은 Date를 감싼 명시적 앱 값 타입 또는 동일한 안전성을 갖는 타입으로 표현한다.
- JSON에서는 시간대가 포함된 ISO 8601 문자열로 encode/decode한다. `Z`도 유효한 시간대 표기다.
- 필요한 정밀도를 잃지 않도록 fractional seconds 정책을 한 가지로 고정하고 round-trip 테스트한다.
- 오디오 위치와 길이는 음수가 아닌 `Int64` 밀리초 값 타입으로 표현한다.
- 초 단위 `Double`, 벽시계 Date, 미디어 위치를 서로 대입하거나 암묵 변환할 수 없게 한다.
- segment는 `startMs <= endMs`, duration과 sequence는 음수가 아님을 검증한다.
- 잘못된 값은 조용히 보정하지 말고 명시적 domain validation error로 거부한다.

스키마 버전 정책은 다음을 만족해야 한다.

- 현재 모든 최초 스키마는 정수 버전 `1`이다.
- `metadata.json`, `transcript.json`, `finalization.checkpoint.json`의 top-level document와 `events.jsonl`의 각 레코드가 `schemaVersion`을 가진다.
- 독립 저장되지 않는 nested value에 불필요하게 version을 반복하지 않는다.
- 현재 지원 버전인지 검사하는 중앙 정책 또는 문서별 정책이 있다.
- 미지원 미래 버전을 현재 버전으로 조용히 간주하지 않는다.
- T02에서는 migration framework나 디스크 migration을 구현하지 않는다.

## 6. 직렬화 DTO

JSON key는 `MVP_SPEC.md` 13장의 lower-camel-case 계약을 따른다. Swift property 이름과 자동으로 일치하지 않는 경우에만 명시적 `CodingKeys`를 사용한다. compiler가 만드는 불투명한 associated-value enum JSON 형태에 파일 계약을 우연히 의존하지 않는다.

### `metadata.json`

top-level metadata document가 최소 다음 구조와 필드를 표현해야 한다.

- `schemaVersion`
- `sessionId`
- `title`
- `status`
- `captureOutcome`
- `createdAt`
- `recordingStartedAt`
- `recordingEndedAt`
- `activeDurationMs`
- `languageMode`
- `detectedLanguage`
- `engine.id`, `engine.version`
- `model.id`, `model.revision`, `model.checksum`
- `audio.format`, `audio.sampleRate`, `audio.channels`, `audio.bitRate`
- `transcript.segmentCount`
- `appVersion`
- `osVersion`
- `lastUpdatedAt`

녹음 전·중에 아직 알 수 없는 `recordingStartedAt`, `recordingEndedAt`, `detectedLanguage` 같은 값은 빈 문자열이나 가짜 시각 대신 optional로 표현한다. 다른 값도 실제 lifecycle상 아직 없을 수 있다면 이유를 문서화한 optional을 사용하되, 완료 metadata가 명세의 최소 필드를 온전히 표현할 수 있어야 한다.

audio round-trip 예시는 MVP 기준인 `m4a`, 48,000 Hz, mono, 96,000 bps를 사용하되 T02에서 오디오 파일을 생성하지 않는다.

### `transcript.json`

schema version과 session ID, segment 배열을 가진 canonical transcript document를 정의한다. 각 segment는 최소 다음을 가진다.

- 안정적인 UUID 기반 `id`
- 음수가 아닌 `sequence`
- 정수 밀리초 `startMs`, `endMs`
- 최초 확정 결과 `originalText`
- 향후 사용자 수정 대상인 현재 `text`
- 앱 고유 `language` code

API에서 `originalText`, 타임스탬프와 구간 경계가 일반 텍스트 수정 동작으로 바뀌지 않도록 의도를 드러낸다. 실제 편집 use case와 파일 재생성은 T23 범위다.

### `events.jsonl` 레코드

각 append-only 레코드가 독립적으로 Codable하고 schema version을 포함하게 한다. 최소한 session/event 식별자, 절대 발생 시각, event kind, 필요한 경우 media position과 직렬화 가능한 domain detail을 표현한다.

event kind는 명세의 다음 사건을 손실 없이 구분할 수 있어야 한다.

- 녹음 시작 및 종료
- 일시정지 및 재개
- 시스템 잠자기 및 깨우기
- 마이크 연결 해제 및 무입력 경고
- STT 오류 및 대기열 저하 모드
- 파일 쓰기 및 저장 위치 오류
- 복구 시작 및 결과
- 마무리 단계 전이

오류 detail을 위해 외부 Error 객체나 untyped JSON을 저장하지 않는다. T02에서는 JSONL writer나 실제 event append를 구현하지 않는다.

### `finalization.checkpoint.json`

schema version, session ID, 갱신 절대 시각과 아래 여덟 단계의 진행을 직렬화할 수 있어야 한다.

1. `workingAudioSecured`
2. `finalM4ACreated`
3. `finalM4AVerified`
4. `transcriptCompacted`
5. `derivedFilesGenerated`
6. `metadataCompleted`
7. `catalogUpdated`
8. `recoveryDataRemoved`

단계 순서는 안정적이어야 한다. 같은 단계 완료를 다시 반영하는 것은 idempotent하고, 앞 단계를 건너뛴 잘못된 진행이나 완료 단계의 후퇴는 명시적으로 거부한다. 실제 오디오 변환, 파일 검증, 삭제, 재개 실행은 T08/T09 범위다.

## 7. 테스트 요구사항

T02의 결정론적 검증은 `LocalLectureSTTTests`에 추가한다. 필요하면 책임별 test file로 나누고 모든 새 test source가 unit test target에 포함되는지 확인한다. 기존 T01 smoke/integration test도 유지한다.

최소 다음을 자동 테스트한다.

### 타입과 JSON

- metadata document encode/decode round-trip
- canonical transcript document와 여러 segment round-trip
- 대표적인 각 event 계열 레코드 round-trip
- finalization checkpoint round-trip
- 모든 persisted root/record에 `schemaVersion: 1` 존재
- 미지원 schema version 검증 실패
- 절대 시각이 숫자가 아닌 시간대 포함 ISO 8601 문자열로 encode됨
- 미디어 위치와 duration이 정수 밀리초로 encode됨
- optional 미확정 값과 완성된 metadata 모두 round-trip 가능
- engine/model/session/segment 식별자가 서로 다른 타입으로 유지됨
- DTO가 `Sendable`과 `Codable` 제약을 만족함을 generic compile-time helper 등으로 확인

### 상태 머신

- 정상 `preparing → recording`
- `recording ↔ paused`
- 정상 종료의 `recording/paused → securing → finalizing → completed`
- `recording/paused → interrupted`
- `interrupted → securing/finalizing → interrupted` 복구 흐름
- 복구 흐름 이후 capture outcome이 `interrupted`로 유지됨
- `interrupted → completed`, `recording → completed`, `completed → recording`, `missing → recording` 같은 금지 전이 실패
- 상태와 capture outcome의 잘못된 조합 실패
- 잔존 `recording` 및 `paused`/`inProgress` metadata와 `interrupted`/`interrupted` metadata가 서로 다른 값으로 decode됨

### 값 불변식과 체크포인트

- 음수 media time/duration/sequence 거부
- `startMs > endMs` segment 거부
- checkpoint 단계의 정상 순차 진행
- 같은 checkpoint 단계 재적용의 idempotence
- checkpoint 단계 건너뛰기와 후퇴 거부

테스트 fixture는 코드에서 만든 작은 합성 데이터만 사용한다. 실제 강의 transcript, 녹음, 모델 파일, runtime session folder는 추가하지 않는다.

## 8. 문서와 기존 앱

- `docs/ARCHITECTURE.md`를 실제 T02 구조에 맞게 갱신한다.
  - 새 Domain 타입의 책임
  - schema version 정책
  - 절대 시각과 media milliseconds 분리
  - status와 capture outcome 분리
  - 정상·중단·복구 상태 흐름
  - 아직 단일 app target의 논리적 경계라는 사실
- build/test 명령이나 환경이 달라지지 않았다면 `docs/DEVELOPMENT.md`를 불필요하게 수정하지 않는다.
- `MVP_SPEC.md`의 제품 요구사항은 변경하지 않는다.
- T02를 `dev`에 통합하는 시점에만 `PROJECT_STATUS.md`를 T02 완료 및 T03 준비 상태로 갱신한다.
- 같은 통합 commit에서 `IMPLEMENTATION_PLAN.md` 9장의 T02 체크박스만 완료로 바꾼다.
- 상태 문서에는 `dev`가 T02로 전진하고 `main`은 마지막 승인된 T01 기준선을 유지한다는 실제 상태를 정확히 기록한다.

기존 메인 창과 설정 placeholder의 동작을 바꾸지 않는다. T02에는 새 UI가 없으므로 수동 UI 검증은 완료 조건이 아니지만, project가 계속 빌드되고 기존 integration smoke test가 통과해야 한다.

## 9. 명시적 제외 범위

- T03 security-scoped bookmark, 세션 디렉터리 생성, atomic JSON writer, JSONL writer, `SessionRepository`
- T04 SQLite 카탈로그와 파일 시스템 대조
- T05 이후 마이크 접근, AVFoundation, 오디오 캡처와 입력 모니터
- 녹음 coordinator, 앱 시작 시 실제 복구 실행, 생명주기 처리
- STT engine protocol, WhisperKit, whisper.cpp, 모델 저장·다운로드·비교
- VAD, transcript reconciliation, backpressure
- canonical JSON을 실제 디스크에 쓰거나 Markdown을 생성하는 기능
- 세션 목록·녹음·편집 UI
- XPC, 별도 process, plugin framework, service locator
- 외부 package/dependency와 네트워크 runtime
- telemetry, cloud sync, 자동 update, crash upload
- `main` 승격, tag, release, PR

후속 확장을 명분으로 현재 사용되지 않는 repository, coordinator, engine abstraction 또는 migration framework를 만들지 않는다.

## 10. 로컬 검증

구현 후 최소 다음을 실행한다. DerivedData를 별도 임시 경로에 두어 깨끗한 build/test도 확인한다.

```sh
xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

추가로 다음을 확인한다.

- `xcodebuild -list`
- 모든 새 production/test source의 target membership
- `git diff --check`
- 전체 task branch diff와 staged diff
- 새 compiler warning 또는 test warning 유무
- 기존 알려진 AppIntents metadata 경고와 새 회귀를 구분
- build product, DerivedData, runtime data가 Git에 포함되지 않음

테스트 실패나 warning을 숨기기 위해 production 동작을 완화하거나 dependency를 추가하지 않는다. 알려진 Xcode 진단 외의 새 경고가 있으면 T02 범위에서 해결하거나 완료를 차단한 이유를 보고한다.

## 11. commit, CI, `dev` 통합

1. T02 구현, unit tests와 `docs/ARCHITECTURE.md` 갱신을 task branch에서 완료한다.
2. 전체 local diff, `git diff --check`, build와 전체 test가 통과한 경우에만 T02 관련 경로를 명시적으로 stage한다.
3. task branch의 최종 commit 메시지는 정확히 다음 형식을 사용한다. 논리적 중간 commit이 필요하면 1~3개 범위에서 모두 끝에 `(T02)`를 붙이고 Conventional Commits 형식을 지킨다.

```text
feat(domain): define session schemas and lifecycle (T02)
```

4. task branch를 push하고 해당 branch의 `macOS CI`가 통과했는지 run URL 또는 run ID와 함께 확인한다.
5. CI가 실패하면 같은 구현 세션에서 T02 범위 안의 원인을 수정하고 다시 로컬 검증과 CI를 수행한다. task CI가 실패·미확인 상태면 `dev`에 병합하지 않는다.
6. merge 직전 원격 `dev`가 branch 생성 기준선 이후 예상 밖으로 변경되지 않았는지 확인한다. 변경됐다면 덮어쓰지 말고 최신 `dev`에 안전하게 맞춘 뒤 전체 검증을 다시 한다.
7. 모든 완료 조건이 충족되면 local `dev`에서 task branch를 squash merge한다.
8. squash commit을 만들기 전에 `PROJECT_STATUS.md`와 `IMPLEMENTATION_PLAN.md` T02 체크박스를 위 문서 규칙대로 갱신한다.
9. `dev`의 squash commit 제목도 정확히 다음을 사용한다.

```text
feat(domain): define session schemas and lifecycle (T02)
```

10. merge된 `dev`에서 build와 전체 test를 다시 실행한다.
11. 검증된 `dev`를 push하고 `dev`의 `macOS CI` 통과를 확인한다.
12. `origin/dev`가 안전하고 CI가 성공한 뒤에만 local/remote T02 task branch를 삭제한다.
13. 최종 checkout은 `dev`, working tree는 clean, local `dev`와 `origin/dev`는 동일해야 한다.

commit 전에 모델, 녹음, transcript 실데이터, session folder, DB, log, credential, build product, 개인 Xcode 상태가 stage되지 않았는지 반드시 확인한다. `main`에는 어떤 commit도 push하거나 merge하지 않는다.

## 12. 완료 조건

다음 항목을 전부 근거와 함께 확인해야 완료다.

- [ ] 최신 clean `dev`에서 정확한 T02 task branch 생성
- [ ] session/segment/engine/model 식별 타입 정의
- [ ] 전체 session status와 capture outcome 분리 정의
- [ ] language mode와 language code 정의
- [ ] metadata/transcript/event/checkpoint Codable·Sendable DTO 정의
- [ ] 모든 persisted document/record의 schema version v1 정책 정의
- [ ] ISO 8601 절대 시각과 정수 밀리초 media time 분리
- [ ] 정상·일시정지·중단·복구 상태 전이와 금지 전이 검증
- [ ] 잔존 recording/paused와 interrupted 결과 구분 검증
- [ ] 중단 복구 후 interrupted outcome 유지 검증
- [ ] 주요 JSON round-trip과 JSON 형태 테스트 통과
- [ ] invalid time/segment/checkpoint 테스트 통과
- [ ] 기존 T01 smoke/integration test 유지 및 전체 test 통과
- [ ] local clean Debug build 통과
- [ ] `docs/ARCHITECTURE.md`가 실제 T02 구조와 일치
- [ ] T03 이후 기능이나 외부 dependency 미포함
- [ ] task branch commit 및 push
- [ ] task branch CI 통과
- [ ] T02 체크리스트와 상태 문서 갱신
- [ ] 하나의 정확한 Conventional Commit으로 `dev` squash 통합
- [ ] merge된 `dev` build/test 재검증 통과
- [ ] `origin/dev` CI 통과
- [ ] `main` 미변경
- [ ] task branch 정리 후 working tree clean

## 13. 최종 보고 형식

다음 순서로 간결하지만 검증 가능하게 보고한다.

1. T02 상태: 완료 또는 차단
2. 사전 기준선과 환경
   - 시작 `dev` SHA
   - macOS, architecture, Xcode와 Swift 버전
3. branch와 commit
   - task branch와 commit
   - squash된 `dev` commit
   - local/remote `dev` SHA
   - `main`이 변경되지 않았다는 확인과 SHA
4. 생성·수정한 파일
5. 핵심 설계
   - schema version 정책
   - 시간 타입
   - status/capture outcome와 상태 머신
   - metadata/transcript/event/checkpoint JSON 구조
6. 실행한 local build·test 명령과 결과
   - test 수와 주요 test 범주
   - 새 warning 유무
7. task branch와 `dev` CI run URL/ID 및 결과
8. 명세 또는 프롬프트에서 벗어난 사항
9. 남은 위험과 수동 확인 사항
10. 승인되지 않은 파일, runtime 데이터, 후속 기능이 포함되지 않았다는 확인
11. T03 시작 가능 여부

완료 조건을 모두 충족할 때까지 같은 구현 세션에서 T02 범위 안의 문제를 해결한다. 명세 충돌, local build/test 실패, task CI 실패·미확인, `dev` CI 실패가 남아 있으면 완료라고 보고하지 않는다.
