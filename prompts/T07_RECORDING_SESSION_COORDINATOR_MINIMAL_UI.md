# T07 실행 프롬프트 — 녹음 세션 coordinator와 최소 녹음 UI

## 역할

당신은 `/Users/andyoon/stt` 저장소의 **T07만 담당하는 새 구현 세션**이다. 최신 `dev`의 T01~T06 기반 위에 T03 `SessionRepository`, T04 `SessionCatalog`, T05 `MicrophoneCaptureController`, T06 `AudioRecorder`를 하나의 안전한 recording-session lifecycle로 조합하고, 사용자가 실제로 제목을 정해 녹음을 시작·종료하며 경과 시간과 입력 레벨을 볼 수 있는 최소 macOS SwiftUI 화면을 완성하라.

이 세션은 분석이나 중간 보고만 하고 멈추는 세션이 아니다. 아래 acceptance matrix를 같은 T07 세션에서 구현·검증하고, 실제 명세 충돌이나 복구 오디오를 보존할 수 없는 사용자 결정만 없다면 task branch commit·push·CI까지 끝내 **독립 검토 가능한 구현 후보**를 제출한다. 구현량, 아직 작성하지 않은 테스트, 실제 마이크를 쓸 수 없는 CI 환경은 그 자체로 blocker가 아니다.

이 프롬프트는 T07의 공식 완료 판정이나 `dev` 통합을 허가하지 않는다. task branch 제출 뒤 조정 세션이 acceptance matrix, diff, 테스트와 CI 근거를 독립 검토한다. 보완이 필요하면 같은 세션과 branch에서 계속 수정하고, 승인된 경우에만 조정 세션이 별도의 통합 프롬프트를 보낸다.

T07에서는 STT, 모델 설치/선택, 최종 `audio.m4a` 변환, 시작 시 복구, 잠자기·창·앱 종료 정책, pause/resume, 세션 목록과 완성형 transcript UI를 구현하지 않는다. 각각 T08 이후 범위다.

## 단계적 구현 해석 — 알려진 명세 충돌이 아님

T07은 전체 MVP의 중간 단계이므로 다음 차이는 의도된 Task 경계이며 안전 차단 사유가 아니다.

1. `MVP_SPEC.md` 4.4절의 전체 종료 흐름 중 T07은 capture 중단, 모든 accepted recording PCM drain, recovery MOV 정상 finish, `recordingEnded` event와 metadata 기록까지만 담당한다. 정상 종료 후 metadata는 `securing`/`completed captureOutcome`으로 남기고, T08이 `finalizing → completed`, `audio.m4a`, checkpoint와 recovery 삭제를 구현한다. T07에서 `completed`를 기록하거나 recovery MOV를 `audio.m4a`로 바꾸지 않는다.
2. 4.2절의 모델 준비·선택과 metadata의 engine/model identity는 T12~T17 및 T21 범위다. T07은 언어 모드를 기록할 수 있지만 engine, model, detected language는 `nil`로 보존한다. 가짜 모델, 임시 모델 ID, 모델이 설치된 것처럼 보이는 UI를 만들지 않는다.
3. T21은 세션 목록과 완성형 시작/모델 화면, T22는 완성형 활성 녹음/transcript 화면을 담당한다. T07은 실제 녹음 흐름을 수동 검증할 수 있는 최소 단일-window UI만 만든다.
4. T05 capture는 session 시작 후 input-level stream을 제공한다. T07은 녹음 시작 전 microphone permission 상태를 표시하고, 실제 live meter는 capture 시작 후 표시한다. 별도의 preview capture, discard-only audio session 또는 두 번째 AVAudioEngine을 만들지 않는다.
5. T07에서 STT consumer를 만들지 않는다. T05 `speechPCM`은 best-effort bounded stream이므로 구독하지 않아도 되며, 오디오 저장은 오직 loss-intolerant `recordingPCM`을 사용한다.
6. T07에서 pause UI/state를 노출하지 않는다. `recording ↔ paused`는 T24 범위다.

## 목표

성공 시 다음이 모두 참이어야 한다.

- 한 앱 인스턴스에서 capture/writer를 가진 recording session은 최대 하나다.
- 사용자가 명시적으로 시작 버튼을 누르기 전에는 microphone permission 요청, session folder 생성, capture start, writer start가 일어나지 않는다.
- title의 공백을 정리하고, 비어 있으면 사용자의 현재 time zone 기준 날짜와 시작 시각으로 결정론적인 자동 제목을 만든다.
- 새 session folder와 `metadata.json`을 먼저 만들고 `preparing`을 기록한 뒤 capture와 recovery writer를 준비한다.
- T05 `recordingPCM`의 모든 accepted chunk를 순서대로 T06 recorder에 전달한다. STT consumer 유무가 저장에 영향을 주지 않는다.
- 시작 성공은 capture와 writer가 준비되고 `recording` metadata 및 `recordingStarted` event가 안전하게 기록된 뒤에만 UI에 노출한다.
- recording 중 UI에 제목, 상태, 시작 시각, 경과 시간, microphone device, input level과 no-input warning, 종료 버튼이 표시된다.
- 사용자 종료는 새 input 차단 → capture stop → buffered recording PCM drain → recorder flush/stop → recovery MOV finish → ended event/metadata 순서를 지킨다.
- 정상 종료 결과는 `securing` metadata, `captureOutcome.completed`, 정확한 `recordingEndedAt`, T06 summary 기반 `activeDurationMs`와 audio description을 가진다.
- T07 종료 후 `recovery/audio.recovery.mov`는 남고 `audio.m4a`는 없다.
- capture/writer/storage terminal failure와 사용자 stop race가 session을 두 번 종료하거나 event/metadata를 성공처럼 중복 기록하지 않는다.
- 녹음 중 비정상 terminal failure는 가능한 recovery audio를 안전하게 닫고 session을 `interrupted`로 남긴다. 준비 단계 실패는 `error/notStarted`로 남긴다.
- metadata와 events 파일이 source of truth이며 SQLite catalog 실패가 오디오 녹음을 중단시키지 않는다.
- 실제 app composition이 live T03/T04/T05/T06 구현을 연결하지만 view/app construction만으로 side effect를 시작하지 않는다.
- 기존 T01~T06 테스트, unsigned arm64 Debug build와 전체 test suite가 통과한다.
- 구현과 문서가 task branch의 하나 이상의 T07 commit으로 보존되고 정확한 task commit의 CI가 성공한다.
- `PROJECT_STATUS.md` 완료 상태, 구현 계획 T07 checklist, `dev`와 `main`은 변경하지 않고 task branch를 독립 검토용으로 유지한다.

## 허가된 외부 변경

이 프롬프트는 다음 외부 변경만 허가한다. task commit과 push는 로컬 구현·검증·diff 조건을 충족한 뒤 수행하고, 그 정확한 commit의 task CI 성공까지 확인해야 독립 검토 후보가 된다.

- `task/t07-recording-session-coordinator-ui` 브랜치 생성과 push
- task branch의 GitHub Actions 실행과 결과 확인
- 같은 task branch에 T07 범위의 보완 commit을 추가하고 다시 push/CI 확인

이 프롬프트로는 `PROJECT_STATUS.md`의 T07 완료 기록, `IMPLEMENTATION_PLAN.md` T07 checklist 변경, `dev` merge/push, task branch 삭제를 허가하지 않는다. Pull Request, `main` 변경·push·승격, tag, GitHub Release, branch protection 변경, 저장소 공개 범위 변경, 외부 package/dependency 설치, 실제 사용자 session root 변경, 실제 강의 녹음을 자동 테스트에 사용하는 작업도 허가하지 않는다.

테스트는 임시 directory, synthetic PCM, fake permission/capture/recorder/catalog/time source를 사용한다. 생성한 `.mov`, session folder, DerivedData와 runtime Application Support 자료를 Git에 포함하지 않는다.

## 반드시 먼저 읽을 컨텍스트

다음 순서와 범위로 읽어라.

1. 이 프롬프트 전체
2. `AGENTS.md` 전체
3. `PROJECT_STATUS.md` 전체
4. `IMPLEMENTATION_PLAN.md`
   - 2장 실행 원칙
   - 5.2~5.7절 Git 및 GitHub 정책
   - T07 recording session coordinator와 최소 UI
   - T04, T05, T06 및 T08, T09, T10의 인접 경계
   - T21, T22, T24, T25의 후속 UI/오류/pause 경계
   - 8장 작업별 프롬프트 작성 규칙
   - 9장 전체 진행 체크리스트
5. `MVP_SPEC.md`
   - 3.1~3.3절 중 T07 녹음·레벨·시작/종료와 제외 입력
   - 4.2~4.4절
   - 5.1~5.3절
   - 6.1, 6.2절
   - 8.1~8.3절
   - 10.1, 10.3절
   - 11.1~11.3절 중 T07/T08 경계
   - 12.1~12.5절
   - 13.1, 13.2, 13.4절
   - 14.1, 14.2절은 T08/T09 경계를 구분하기 위해서만 확인
   - 16.1, 16.2절
   - 17.4절의 필수 저장 목표
   - 18장 개인정보와 로컬 event 원칙
6. `docs/ARCHITECTURE.md`와 `docs/DEVELOPMENT.md`
7. 실제 Git 상태와 다음 코드
   - `Domain/SessionLifecycle.swift`
   - `Domain/SessionDocuments.swift`
   - `Domain/SessionEvents.swift`
   - `Domain/SessionStorage.swift`
   - `Application/StorageContracts.swift`
   - `Infrastructure/FileSessionRepository.swift`
   - `Application/SessionCatalog*.swift`
   - `App/CatalogStartupCoordinator.swift`
   - `Application/MicrophoneCapture.swift`
   - `Application/InputSignalMonitor.swift`
   - `Infrastructure/AVFoundationMicrophoneCapture.swift`
   - `Application/AudioRecorder.swift`
   - `Infrastructure/AVFoundationAudioRecorder.swift`
   - `App/LocalLectureSTTApp.swift`
   - `Features/MainWindowView.swift`
   - `Features/StorageRootViewModel.swift`
   - T03~T06 관련 tests
   - `LocalLectureSTT.xcodeproj/project.pbxproj`
   - `.github/workflows/macos-ci.yml`
   - `.gitignore`

관련 문서가 충돌하거나 accepted PCM을 버리지 않고는 구현할 수 없는 문제, recovery file을 덮어쓰거나 조기 scope release를 피할 수 없는 문제가 발견되면 임의로 완화하지 말고 안전한 상태에서 중단하여 충돌, 데이터 위험과 권장 해결안을 보고하라. 위의 “단계적 구현 해석”에 이미 명시된 차이, 아직 acceptance test가 없다는 사실, 구현량이 많다는 사실은 blocker가 아니다.

## 현재 알려진 기준선

다음은 프롬프트 작성 전 기준이며 새 세션에서 실제 상태로 다시 확인한다.

- 작업 디렉터리: `/Users/andyoon/stt`
- 장기 branch: `dev`
- T06 hardening 통합 commit: `ba9d705796cbd8dcb2ee886250a1c29e2513879a`
- 이 프롬프트 문서 commit이 위 T06 commit 뒤의 `dev`에 추가되어 있을 수 있다.
- `origin/main`: `38e126f92ac823d29306ea8c1f7703f7060a5818`; T07에서 변경하지 않는다.
- baseline은 unit test 114개와 integration test 1개, 전체 115개다.
- app target은 macOS 15+, arm64, Swift 6, App Sandbox를 사용하는 단일 프로세스 SwiftUI 앱이다.
- 외부 Swift Package dependency는 없으며 T07도 새 dependency를 추가하지 않는다.
- T03 session file이 authoritative이고 T04 SQLite catalog는 rebuildable이다.
- T05 `CaptureHandle.recordingPCM`은 bounded loss-intolerant primary stream이고 `speechPCM`은 best-effort다.
- T05 capture construction/status lookup은 permission prompt를 띄우지 않는다. 실제 요청은 명시적인 사용자 action 뒤에만 수행해야 한다.
- T06 recorder는 start/append/flush/stop, typed state/error/event, exact-once cleanup과 late-subscriber-safe terminal event를 제공한다.
- T06 정상 stop 결과는 `recovery/audio.recovery.mov`와 `AudioRecorderSummary`이며 final `.m4a`를 만들지 않는다.
- 현재 app은 storage root와 catalog만 compose하고 capture/recorder를 시작하지 않는다.
- Xcode 26.6 AppIntents metadata skipped 및 `linkd.autoShortcut` 진단은 build/test 성공을 바꾸지 않는 알려진 toolchain/runtime 진단이다.

대화나 이 목록보다 새 세션에서 확인한 실제 Git 상태, code, build/test 결과를 우선한다.

## 1. 사전 점검과 task branch

파일을 수정하기 전에 다음을 확인한다.

- `pwd`
- `git status --short --branch`
- `git remote -v`
- local/remote branch와 upstream
- 최근 commit과 `dev`, `origin/dev`, `main`, `origin/main` SHA
- 예상하지 않은 tracked/untracked file 또는 사용자 변경
- Xcode, Swift, macOS와 host architecture
- baseline unsigned arm64 Debug build와 전체 tests

`origin/dev`를 fetch하고 local `dev`가 최신인지 확인한다. working tree가 안전하고 기준선이 통과하면 다음 branch를 만든다.

```text
task/t07-recording-session-coordinator-ui
```

기존 사용자 변경, 녹음 파일 또는 runtime 자료가 있으면 삭제·reset·checkout으로 버리지 않는다. 기준선 문제가 있으면 T07 변경과 섞지 말고 원인을 분리한다.

## 2. Application 경계와 coordinator 소유권

### 2.1 framework-independent 계약

Application 계층에 `RecordingSessionCoordinator` 또는 동등한 actor와 필요한 Sendable value/protocol을 둔다. 이름은 기존 style에 맞게 조정할 수 있지만 다음 경계는 지킨다.

- coordinator public/input value에는 AVFoundation, AVFAudio, CoreAudio, AppKit, SwiftUI, `URL`, `NSError`가 없다.
- `SessionLocation`, `SessionMetadataDocument`, `SessionEventRecord`, `CaptureHandle`, `PCMChunk`, `AudioRecorderSummary` 같은 기존 pure app/domain value를 재사용한다.
- T05 concrete controller를 fake로 대체할 수 있는 최소 `MicrophoneCapturing` 또는 동등한 protocol을 정의한다. `start`, `stop`, current lifecycle의 기존 의미를 바꾸지 않는다.
- recorder는 session마다 factory/provider로 생성하거나 recorder-per-session ownership을 명확히 한다. coordinator가 previous session event/callback을 새 session에 연결하지 않는다.
- narrow storage-root availability checker, permission authorizer, session repository, catalog refresh, wall clock, monotonic clock/ticker, app/OS version provider를 주입 가능하게 한다. Root checker는 directory-selection `URL` API를 새 coordinator 경계로 확대하지 않는다.
- fault test를 위해 범용 plugin framework를 만들지 않는다.
- payload가 coordinator 경계를 지나면 기존 요구에 맞게 `Sendable`이며, persistence 대상은 기존 Codable domain type을 사용한다.

### 2.2 coordinator가 단독 소유할 상태

하나의 serialized owner가 최소 다음을 함께 소유한다.

- session operation/generation token
- current `SessionLocation`과 normalized title/language
- persisted metadata snapshot/lifecycle
- capture handle와 expected capture generation
- current recorder
- recording PCM pump task
- capture event, recorder event, input-level observer task
- user stop/abnormal stop reason
- one in-flight terminal/settlement task
- recording start wall-clock와 monotonic 기준
- latest UI level/no-input/error state
- last known safe media position/recorder summary

actor reentrancy 때문에 start/stop/terminal callback이 섞이지 않게 operation gate, attempt token 또는 동등한 구조를 사용한다. 한 session의 settle이 끝나기 전 새 session resource를 열지 않는다. 이전 session의 task/event가 새 session metadata, UI, recorder 또는 catalog를 바꾸지 못한다.

### 2.3 observable UI state

Features의 `@MainActor` view model은 coordinator의 framework-free snapshot/event stream을 구독한다. 장시간 audio pump를 SwiftUI `.task` lifetime에 직접 매달지 않는다. view가 사라지거나 다시 그려져도 coordinator-owned recording은 임의로 취소되지 않는다.

UI snapshot은 최소 다음 의미를 표현한다.

- idle/configuring
- preparing
- recording
- securing/stop in progress
- secured awaiting T08 finalization
- interrupted/error with stable code
- session ID/title/status/start time/elapsed active duration
- active microphone display name
- normalized input level와 no-input state
- start/stop action availability

`secured awaiting finalization`은 coordinator UI phase 이름일 수 있지만 persisted `SessionStatus`는 반드시 `.securing`이어야 한다. UI가 이를 `completed`로 표시하지 않는다.

## 3. session configuration, title과 metadata

### 3.1 시작 입력

최소 configuration은 다음을 가진다.

- 사용자 입력 title
- language mode (`korean`, `english`, `automatic`)
- 사용자의 현재 `TimeZone`

기본 language는 주 사용 목적에 맞게 `.korean`으로 한다. 녹음 중에는 title/language 변경 UI를 비활성화하거나 숨긴다. 모델/engine 선택 value나 UI를 만들지 않는다.

### 3.2 title 규칙

- 앞뒤 whitespace/newline을 제거한다.
- trim 결과가 비어 있으면 `createdAt`과 주입된 user time zone으로 자동 제목을 만든다.
- 자동 제목 형식은 locale 변화에 흔들리지 않는 고정 형식으로 정하고 문서화한다. 예: `yyyy-MM-dd HH:mm 녹음`.
- folder name은 기존 `SessionFolderName` 규칙을 사용하고 title을 넣거나 title 변경으로 rename하지 않는다.
- 동일 시각 title 충돌은 session UUID/folder ID가 해결하며 기존 folder를 덮어쓰지 않는다.

### 3.3 metadata 내용

T07에서 생성하는 metadata는 기존 `SessionMetadataDocument` schema를 그대로 사용한다.

- `sessionId`, title, created/started/ended/lastUpdated time
- lifecycle status/capture outcome
- active duration
- selected language mode
- `detectedLanguage = nil`
- `engine = nil`, `model = nil`
- transcript segment count 0
- recovery AAC target/actual summary에 맞는 audio description
- 실제 app version과 OS version을 testable provider를 통해 기록

빈 문자열을 채우기 위해 임의의 model/engine/version을 꾸며내지 않는다. app version build setting이 없어 live provider가 비어 버린다면 project의 정상 version setting을 추가하거나 안정적인 fallback을 명확히 정의하고 테스트한다.

metadata 갱신은 기존 repository의 atomic JSON write를 사용한다. 같은 document를 별도 URL/file API로 우회 작성하지 않는다.

## 4. 명시적인 permission과 시작 transaction

사용자가 Start를 누른 한 operation의 순서는 다음 의미를 만족해야 한다. 세부 await 순서는 데이터 보존과 rollback을 더 안전하게 만드는 범위에서 조정할 수 있으나 테스트로 증명한다.

1. coordinator가 resource-active preparing/recording/stop-settlement operation이 없는지 원자적으로 확인한다. 이전 session이 이미 resource settlement를 끝내고 persisted `.securing` 상태로 T08을 기다리는 것만으로 새 audio resource start를 막지는 않는다.
2. 저장 루트가 사용 가능한지 확인한다. root가 없거나 재승인이 필요하면 session folder, permission prompt, capture/writer를 시작하지 않고 typed failure를 반환한다.
3. microphone authorization status를 확인한다.
   - `.notDetermined`일 때만 사용자 Start action 안에서 명시적으로 request한다.
   - denied/restricted/unavailable이면 folder/capture/writer를 시작하지 않고 stable error와 UI 안내를 낸다.
   - 이미 authorized면 불필요한 request를 반복하지 않는다.
4. session ID/createdAt/title을 확정하고 `SessionRepository.createSession`으로 fixed location을 만든다.
5. `preparing/notStarted` metadata를 즉시 atomic write한다.
6. T05 capture를 start하여 handle/generation/device를 얻는다.
7. 같은 location과 generation으로 새 T06 recorder를 start한다.
8. recorder start 성공 직후 `recordingPCM` pump와 level/capture/recorder observer를 시작한다. capture가 먼저 만든 accepted PCM은 bounded primary stream에서 순서대로 drain하며 몰래 버리지 않는다.
9. `recording/inProgress` metadata와 정확히 한 `recordingStarted` event를 persistence한다.
10. 위 필수 단계가 성공한 뒤에만 UI/coordinator start가 성공을 반환하고 elapsed timer를 recording state로 공개한다.

capture start와 writer start 사이에 PCM이 생길 수 있으므로 무시하거나 `speechPCM`으로 대체하지 않는다. 기존 T05 primary buffer가 overflow하면 `recordingBackpressure` terminal failure를 보존해야 하며 frame을 drop해 성공처럼 진행하지 않는다.

folder가 만들어진 뒤 어느 단계에서 실패하더라도 folder/recovery/metadata를 자동 삭제하지 않는다. 시작 전/중 실패 rollback은 열린 capture, recorder, observer와 scope를 안전하게 정리하고 가능한 `error/notStarted` metadata와 event를 best effort로 남긴다. 원래 오류를 cleanup 오류로 덮어쓰지 않는다.

## 5. recording PCM pump와 독립성

- `CaptureHandle.recordingPCM`을 exactly one consumer가 순차 iteration한다.
- 각 chunk를 같은 generation의 recorder `append`에 await한다. 별도 unbounded queue를 추가하지 않는다.
- append backpressure는 T05 primary stream의 bounded 의미와 연결된다.
- chunk order/generation 오류와 recording stream terminal error를 숨기지 않는다.
- `speechPCM`은 생성되더라도 drain하지 않는다. STT가 없어도 recording은 완전해야 한다.
- pump completion은 expected user stop과 unexpected capture terminal을 구분한다.
- user stop 전에 recording stream이 정상/오류로 끝나면 해당 session을 abnormal settlement로 보낸다.
- pump failure, capture event, recorder terminal event와 user stop이 동시에 발생해도 하나의 settlement 원인만 확정한다. recorder의 첫 typed error를 일반 cancellation/secondary cleanup error로 덮지 않는다.
- observer와 pump task는 session token을 확인하고 이전 session completion이 이후 session을 건드리지 않는다.

## 6. 정상 종료와 T08 handoff

사용자 Stop operation은 정확히 한 번 다음 순서를 보장한다.

1. 더 이상 start/stop을 중복 실행하지 못하게 coordinator/UI를 securing으로 전환한다.
2. expected user stop 표시를 먼저 세워 pump의 정상 stream completion이 abnormal failure로 오인되지 않게 한다.
3. capture intake를 닫고 capture를 stop한다.
4. recording PCM pump가 이미 accepted/buffered인 모든 chunk를 recorder에 append하고 끝날 때까지 기다린다. pump를 먼저 cancel하여 buffered PCM을 잃지 않는다.
5. recorder `flush` barrier와 `stop`을 실행한다. T06이 converter tail, writer finish와 security scope release를 완료할 때까지 기다린다.
6. T06 summary의 written frame/duration/output format을 검증하고 `activeDurationMs`와 audio metadata의 근거로 사용한다. wall-clock elapsed를 최종 media duration으로 저장하지 않는다.
7. `recordingEndedAt`을 기록하고 `recordingEnded` event를 정확히 한 번 append한다.
8. metadata를 `.securing`, `.completed` capture outcome, final active duration/audio description으로 atomic write한다.
9. catalog reconciliation/refresh를 요청한다.
10. observer/task/resource를 끝내고 T08이 받을 수 있는 framework-free secured-session result를 반환한다.

정상 stop 성공 뒤 recovery MOV는 남고 `audio.m4a`, canonical transcript, derived txt/md, finalization checkpoint는 만들지 않는다. UI는 “완료”가 아니라 “안전 저장 완료 · 마무리 대기”와 같은 T07 phase 의미를 표시한다.

T07의 secured result는 T08이 location, metadata와 recovery summary를 이어받기 쉬운 구조여야 하지만 T08 finalizer contract나 checkpoint pipeline을 선행 구현하지 않는다.

zero-sample stop, recorder finish 실패, buffered pump 실패를 정상 securing으로 보고하지 않는다. partial artifact와 last durable metadata를 보존하고 typed abnormal result를 낸다.

## 7. abnormal termination과 오류 우선순위

### 7.1 recording 전 실패

- root/permission 실패: 가능하면 session folder를 만들기 전에 종료한다.
- folder/preparing metadata 이후 capture/writer/start-event 실패: capture와 writer를 정리하고 session 자료를 보존한다.
- durable metadata 갱신이 가능하면 `.error/.notStarted`를 기록한다.
- 실패 metadata/event write까지 실패하면 마지막으로 성공한 file bytes를 그대로 두고 UI에 원래 오류와 persistence 오류를 구분해 전달한다.

### 7.2 recording 중 실패

다음은 모두 session-wide abnormal settlement를 시작한다.

- capture `recordingBackpressure`
- active microphone disconnect/route/configuration/runtime terminal failure
- recording PCM stream throw 또는 예상하지 않은 finish
- recorder conversion/readiness/append/flush/finish/storage/disk-full/cancellation terminal failure
- 필수 recording metadata write failure

recording이 정상 사용자 stop으로 끝나지 못하면 가능한 capture input을 닫고 buffered PCM을 drain하며 recorder를 best-effort stop/cleanup한다. recoverable file을 삭제하지 않고 metadata를 가능한 한 `.interrupted/.interrupted`로 기록한다. T06 writer 자체가 이미 failed라 summary가 없으면 recorder terminal event의 media position 또는 마지막 검증 가능한 safe position을 사용하고 이를 과장하지 않는다.

준비 단계 실패만 `.error/notStarted`다. recording이 시작된 뒤의 비정상 중단을 단순 `.error`로 바꾸어 T09 recovery 대상에서 숨기지 않는다. UI는 interrupted status와 stable root/capture/recorder error code를 함께 보여줄 수 있다.

### 7.3 persistence와 catalog 우선순위

- session metadata와 recovery audio가 SQLite보다 우선한다.
- catalog reconcile 실패는 warning/UI 상태로 남기되 active recording, safe stop 또는 recovery file을 실패시키지 않는다.
- `recordingStarted`, `recordingEnded`와 lifecycle metadata는 필수 session history다. 필수 write 실패를 성공처럼 반환하지 않는다.
- no-input warning 같은 diagnostic event append 실패만으로 recorder를 즉시 중단하지 않는다. audio를 계속 우선하고 persistence warning을 노출한다.
- recorder terminal event는 T06이 제공한 `SessionEventKind`, stable code와 media position을 한 SessionEventRecord로 변환한다. append/stop에서 같은 원인을 다시 관찰해 중복 journal line을 만들지 않는다.
- metadata/event 저장 실패를 기록하려고 같은 실패 파일에 무한 재귀 append하지 않는다.

## 8. session event mapping

최소 다음 event를 existing `SessionEventRecord` schema로 기록한다.

- 정상 start: `.recordingStarted`, media position 0
- 정상 stop: `.recordingEnded`, final media duration
- no-input 상태 진입: `.noInputWarning`, 당시 media position; 같은 no-input episode에서 한 번
- active device disconnect 또는 route loss: `.microphoneDisconnected`와 capture code
- T06 recorder terminal event: 제공된 `.fileWriteError` 또는 `.storageAccessError`, recorder code와 media position
- 기타 abnormal capture end: `.recordingEnded`에 stable capture detail code를 넣거나 기존 schema에 맞는 가장 구체적인 event를 사용

event의 `occurredAt`, event ID, session ID와 media position은 coordinator가 조합한다. PCM sample, 실제 root path, full NSError, 실제 녹음 내용은 message/log에 넣지 않는다. T25의 사용자 문구/범용 진단 로그를 선행 구현하지 않는다.

## 9. elapsed time, input level과 UI 업데이트

- UI elapsed는 injected monotonic clock/ticker를 사용한다. `Date` 차이만 사용해 clock adjustment에 흔들리지 않는다.
- no pause인 T07에서는 recording state 진입부터 securing 요청 전까지 증가한다.
- UI tick은 적절히 throttle하여 초당 수십 번 전체 view를 재생성하지 않는다. 표시 정밀도는 초 단위면 충분하다.
- final persisted `activeDurationMs`는 T06 summary를 사용하므로 UI elapsed와 작은 차이가 있을 수 있다.
- input meter는 T05 `normalizedLevel`을 0...1 범위로 표시한다.
- generation이 다른 stale sample은 무시한다.
- `.noInput`은 눈에 띄는 warning을 표시하지만 recording을 자동으로 멈추지 않는다.
- `.active` 또는 새 session이 warning을 해제한다.
- input-level UI 지연이나 main actor rendering이 recording PCM pump를 막지 않는다.

## 10. 최소 SwiftUI 화면과 live composition

### 10.1 저장 루트 상태 유지

현재 no-root, reauthorization, root failure UI를 보존한다. root가 available일 때만 recording content를 보여주고 Start를 활성화한다. root picker와 recording start가 동시에 session 상태를 망가뜨리지 않게 한다. 녹음 중 저장 root 변경 UI 정책의 전체 구현은 T10/T21 범위지만 active session의 fixed `SessionLocation.rootID`가 다른 root로 redirect되면 안 된다.

### 10.2 최소 시작 화면

- title text field
- Korean/English/Automatic language picker
- microphone permission status
- “녹음 시작” button
- preparing progress와 stable error code/간단한 사용자 안내

모델 선택, 모델 다운로드, session list는 표시하지 않는다. T07 개발 단계에서 모델이 없다는 이유로 audio-only Start를 막지 않는다.

### 10.3 최소 활성 화면

- normalized/auto title
- `녹음 중` status
- recording started time
- `HH:MM:SS` elapsed time
- active microphone display name
- accessible input-level indicator
- no-input warning
- “녹음 종료” button

pause/resume, transcript placeholder, fake STT text, model-changing control을 추가하지 않는다.

### 10.4 securing/result 화면

- Stop 중에는 button을 중복 실행하지 못하게 하고 `안전하게 저장 중`을 표시한다.
- 성공하면 persisted `.securing`과 일치하는 “복구 오디오 저장 완료 · 마무리 대기” 상태와 title/duration을 표시한다.
- T08 미구현 때문에 이를 최종 완료라고 표시하지 않는다.
- 실패/중단이면 stable error와 recovery data가 보존됐음을 과장 없이 표시한다.
- resource settlement가 끝난 뒤 새 recording configuration으로 돌아갈 수 있어야 한다. 이전 securing session을 자동 finalization하거나 삭제하지 않는다.

### 10.5 app composition

`LocalLectureSTTApp`은 하나의 `StorageRootManager` 인스턴스를 repository, catalog, recorder factory와 공유하고 다음 live 구현을 조합한다.

- `AVFoundationMicrophonePermissionAuthorizer`
- `AVAudioEngineMicrophoneDriver`
- `InputSignalMonitor`
- `MicrophoneCaptureController`
- `FileSessionRepository`
- session-per-recording `AVFoundationAudioRecorder`
- existing `SessionCataloging`
- T07 coordinator/view model

App/View/ViewModel/coordinator construction과 app launch는 permission request, capture start, session folder creation, writer start를 하지 않는다. 오직 명시적인 Start action만 시작한다.

## 11. 명시적 제외 범위

다음은 T07에서 구현하지 않는다.

- T08 final m4a conversion, validation, atomic rename, checkpoint
- T09 app-start recovery scan과 자동 재개
- T10 sleep assertion, lid/window/quit lifecycle와 auto-quit
- T11 이후 STTEngine, model, VAD, transcript
- T12/T13 model repository/download/import
- T14/T15 engine dependency
- T17 production model selection
- T20 transcript compact/derived files
- T21 session list와 model management/full start UI
- T22 partial/final transcript와 완성형 active UI
- T23 playback/edit/Finder/trash
- T24 pause/resume
- T25 통합 오류 문구와 diagnostic logger
- T26 process-kill/fault recovery harness
- system audio, USB selection/automatic fallback, network, telemetry, crash upload

T08을 쉽게 만들겠다는 이유로 finalizer/checkpoint API 전체를 만들거나, T21/T22를 쉽게 만들겠다는 이유로 session list/transcript UI를 선행 구현하지 않는다.

## 12. 자동 acceptance matrix

구현 전에 아래 항목을 실제 test 이름 또는 검증 방법에 매핑하고 모두 끝날 때까지 같은 T07 세션에서 계속 작업한다.

### 12.1 Application 계약과 side effect

1. coordinator/capture factory/result/snapshot이 framework-independent Sendable value/protocol이다.
2. Application/Domain에 AVFoundation/AppKit/SwiftUI/URL/NSError가 새로 누출되지 않는다. 기존 T03 directory-selection URL 예외는 확대하지 않는다.
3. app/view/view-model/coordinator construction과 initial restore가 permission request, capture, writer, folder 생성 side effect를 만들지 않는다.
4. Start user action에서만 permission request와 resource start가 발생한다.
5. T08 이후 type/file/UI가 선행 구현되지 않았다.

### 12.2 permission, configuration과 title

1. no root/reapproval required에서 start가 거부되고 permission/folder/capture/writer count가 0이다.
2. not-determined는 explicit start에서 request 1회, authorized는 request 0회다.
3. denied/restricted/unavailable가 구분되고 session folder가 생기지 않는다.
4. title trim과 explicit title 보존이 정확하다.
5. 빈 title은 injected time/timezone에서 deterministic auto title이 된다.
6. language mode가 metadata에 기록되고 engine/model/detectedLanguage는 nil이다.
7. app/OS version과 initial transcript count 0, audio target description이 schema-valid하다.

### 12.3 정상 start와 PCM 전달

1. create folder → preparing metadata → capture start → recorder start → pump → recording metadata/event의 필수 순서가 증명된다.
2. 시작 성공 전 UI는 recording을 표시하지 않는다.
3. capture가 recorder start 전에 yield한 buffered chunks도 sequence 그대로 append된다.
4. 여러 irregular PCM chunk가 정확히 한 recording consumer를 통해 recorder에 전달된다.
5. speech/STT consumer가 없어도 모든 recording chunk가 저장된다.
6. concurrent start N개에서 folder/capture/recorder가 각각 하나만 열린다.
7. active recording 중 두 번째 start는 stable busy error이며 기존 session을 바꾸지 않는다.

### 12.4 정상 stop와 securing metadata

1. stop ordering이 capture intake close → buffered pump drain → recorder flush/stop → ended event/metadata다.
2. stop 직전 buffered chunk까지 recorder append에 포함된다.
3. repeated/concurrent stop이 capture stop, recorder stop, `recordingEnded`, metadata terminal update를 중복하지 않는다.
4. final active duration은 recorder summary이며 monotonic UI timer 값을 잘못 저장하지 않는다.
5. metadata가 `.securing/.completed`, started/ended time, audio description을 가진다.
6. recovery MOV는 남고 final m4a/checkpoint/transcript/derived files는 없다.
7. stop 성공 후 live task/scope가 남지 않고 새 session을 시작할 수 있다.

### 12.5 fault와 rollback

1. session create/preparing metadata/capture start/recorder start/recording metadata/start-event fault 각각이 원래 typed error를 보존한다.
2. folder가 이미 생성된 이후 실패하면 자동 삭제하지 않는다.
3. start rollback이 capture/recorder를 정확히 한 번 정리한다.
4. PCM append/stream failure, backpressure, microphone disconnect, recorder event와 user stop race가 one settlement만 실행한다.
5. recording 중 abnormal failure는 가능한 writer stop 후 `.interrupted`를 기록하며 recovery bytes를 삭제하지 않는다.
6. zero-sample stop과 recorder finish failure를 normal securing으로 보고하지 않는다.
7. metadata/event failure가 false success를 만들지 않고 last durable bytes를 보존한다.
8. catalog failure는 warning이지만 recording PCM이나 safe stop을 중단하지 않는다.
9. first error가 cleanup/cancellation/secondary observer error에 덮이지 않는다.

### 12.6 events, level과 stale task

1. recordingStarted/recordingEnded가 정상 session에 각각 한 줄이고 session/event IDs가 정확하다.
2. no-input 한 episode가 UI warning과 event 한 개를 만들지만 recorder는 계속 append한다.
3. microphone disconnect와 recorder file/storage event mapping이 stable code/media position을 보존한다.
4. same writer failure를 append throw와 event stream에서 보아도 journal line/settlement가 중복되지 않는다.
5. stale generation level sample과 previous session terminal event가 새 UI/metadata를 바꾸지 않는다.
6. view disappearance/cancelled UI task가 active recording pump를 자동 취소하지 않는다.
7. elapsed tick과 level UI가 audio append backpressure path를 막지 않는다.

### 12.7 실제 file-authoritative integration

temporary root와 synthetic capture driver를 사용하되 production `MicrophoneCaptureController`, `FileSessionRepository`, `StorageRootManager`, `AVFoundationAudioRecorder`를 연결한 통합 test를 만든다.

1. 실제 Start action으로 session folder와 preparing/recording metadata가 생긴다.
2. synthetic driver가 여러 PCM chunks를 T05 callback으로 전달한다.
3. STT/speech consumer 없이 coordinator가 T06 recorder에 모두 전달한다.
4. Stop 뒤 실제 `recovery/audio.recovery.mov`가 존재하고 AVFoundation으로 audio track을 읽을 수 있다.
5. metadata는 `.securing/.completed`, 정확한 title/language/start/end/duration/audio description이다.
6. events JSONL은 recordingStarted와 recordingEnded를 순서대로 decode한다.
7. `audio.m4a`, transcript, derived files, checkpoint는 없다.
8. catalog reconcile 뒤 item title/duration/status가 metadata와 일치한다.
9. temp root/bookmark access start/stop이 균형을 이루고 사용자 root를 건드리지 않는다.

실제 microphone/TCC를 자동 test에서 사용하지 않는다. synthetic integration은 arbitrary sleep 대신 controlled callback/gate와 bounded timeout을 사용한다.

### 12.8 최소 UI

1. root unavailable/reauthorization UI가 유지된다.
2. available root의 idle 화면에 title/language/permission/start가 있다.
3. recording 화면에 elapsed/level/device/status/stop이 있고 pause/model/transcript control은 없다.
4. no-input warning은 접근 가능한 label/state로 노출된다.
5. stop 중 중복 action이 disabled된다.
6. secured 결과를 completed로 잘못 표시하지 않는다.
7. view model fake coordinator test가 state/action mapping과 no-side-effect construction을 검증한다.

## 13. race와 cancellation test 원칙

- fake capture/recorder/repository는 controlled continuation/gate로 원하는 await 지점에서 멈출 수 있어야 한다.
- 임의의 긴 `sleep`으로 race 순서를 추측하지 않는다.
- start 중 stop/cancel, writer start 중 capture terminal, pump append 중 user stop, recorder event와 append throw 동시 도착, stop 중 second start를 검증한다.
- 동일 lifecycle/race test를 완료 판단 전에 여러 번 실행해 flake가 없는지 확인한다.
- test hang에는 bounded timeout과 cleanup이 있어야 한다.
- assertion을 삭제하거나 tolerance/timeout을 의미 없게 넓혀 통과시키지 않는다.

## 14. 수동 검증

T07에는 실제 사용 가능한 UI가 생기므로 `docs/DEVELOPMENT.md`에 locally signed opt-in 절차를 추가한다. 자동 test 대신 성공했다고 주장하지 말고 실제 수행 여부를 구분한다.

절차는 disposable empty root만 사용한다.

1. 동일한 local signing identity로 app을 실행하고 disposable root를 선택한다.
2. title과 language를 정하고 Start를 누른다.
3. 첫 요청에서만 microphone permission prompt가 나타나는지 확인한다.
4. 20초 이상 말하며 device name, elapsed와 input level이 변하는지 확인한다.
5. 5초 이상 조용히 있어 no-input warning이 보이되 녹음이 계속되는지 확인한다.
6. 다시 말해 warning이 해제되는지 확인한다.
7. Stop 후 UI가 final completed가 아니라 securing/마무리 대기로 표시되는지 확인한다.
8. session folder의 `metadata.json`, `events.jsonl`, `recovery/audio.recovery.mov`를 확인하고 `audio.m4a`가 없음을 확인한다.
9. recovery MOV를 QuickTime/AVFoundation으로 열어 본다.

실제 mic check를 수행하지 않았다면 최종 보고에 “manual verification pending”으로 남긴다. microphone permission reset, 실제 사용자 root 변경, 실제 강의 녹음은 자동으로 수행하지 않는다.

## 15. 문서와 project file

구현에 맞춰 필요한 경우 다음을 갱신한다.

- `Application/BOUNDARY.md`: coordinator contract와 pure state/event 경계
- `Infrastructure/BOUNDARY.md`: live capture/recorder/session repository composition
- `docs/ARCHITECTURE.md`: start/stop data flow, source-of-truth ordering, terminal settlement와 T08 handoff
- `docs/DEVELOPMENT.md`: T07 synthetic tests와 signed manual procedure
- `LocalLectureSTT.xcodeproj/project.pbxproj`: 새 source/test files와 app version setting

`docs/ARCHITECTURE.md`, `docs/DEVELOPMENT.md`와 boundary 문서는 구현 후보의 실제 구조와 검증 방법이므로 task branch에서 함께 갱신한다. 반면 `PROJECT_STATUS.md`의 T07 완료 기록과 `IMPLEMENTATION_PLAN.md`의 T07 checklist `[x]`는 조정 세션의 독립 검토 승인 후 별도 통합 프롬프트에서만 갱신한다. 이 구현 프롬프트에서는 두 완료 상태 문서를 변경하지 않는다.

문서가 실제 구현보다 넓은 기능을 주장하지 않게 한다. T07에서 actual microphone, signed sandbox, finalization, app-close/sleep recovery를 자동 검증했다고 쓰지 않는다.

## 16. build와 test

최소 다음 unsigned arm64 Debug 명령을 실제로 실행한다.

```sh
xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T07-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

```sh
xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T07-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

구현 중 새 T07 tests를 targeted 실행해도 되지만 완료 판단 전에는 전체 suite를 실행한다. race tests는 반복 실행한다. app code가 실제 live dependencies를 compose하는 integration/build를 통과해야 한다.

## 17. Git과 CI workflow

로컬 구현·검증·diff 조건을 만족하면 다음 순서로 task branch 후보를 제출한다. task CI까지 성공해야 18장의 독립 검토 제출 조건이 완성된다.

1. `git status`, task branch 전체 diff와 `git diff --check`를 검토한다.
2. 실제 recording/model/session data, DerivedData, `.mov`, SQLite, Application Support가 추적되지 않는지 확인한다.
3. T07 관련 경로만 명시적으로 stage한다.
4. staged diff를 다시 검토한다.
5. Task ID가 포함된 commit을 만든다. 예: `feat(recording): add session coordinator and minimal UI (T07)`.
6. `task/t07-recording-session-coordinator-ui`를 push한다.
7. 정확한 task commit의 GitHub Actions 성공을 확인한다.
8. task branch가 clean하고 local/remote task commit이 일치하는지 확인한다.
9. `PROJECT_STATUS.md` 완료 상태와 T07 checklist, `dev`, `main`이 기준선 그대로인지 확인한다.
10. task branch를 삭제하지 않고 독립 검토를 위해 유지한다.

정상 Task에는 PR을 만들지 않는다. `dev` 또는 `main`을 checkout하여 merge하거나 push하지 않는다.

task branch CI가 실패하면 검토 준비 완료로 보고하지 않는다. 같은 T07 세션과 branch에서 원인을 고치고 필요한 검증 단계를 반복한다. task branch CI가 성공해도 공식 T07 완료가 아니며, 조정 세션의 독립 검토 전에는 상태 문서나 `dev`를 변경하지 않는다.

독립 검토에서 보완 요청을 받으면 이 세션과 task branch를 그대로 유지하여 수정·재검증·commit·push·task CI를 반복한다. 독립 검토 승인 후 별도 통합 프롬프트를 받았을 때만 최신 `dev` 동기화, 필요 시 재검증, 상태 문서 갱신, squash merge, merge 후 build/test, `dev` push/CI와 task branch 삭제를 수행한다.

## 18. 독립 검토 제출 조건

다음이 모두 참일 때만 `T07 구현 후보: 검토 준비 완료`라고 보고한다. 이 표현은 공식 Task 완료나 `dev` 통합을 뜻하지 않는다.

- 2~10장의 coordinator ownership, start/stop ordering, metadata/event, UI와 failure 계약이 실제 구현에 존재한다.
- 12장 acceptance matrix가 빠짐없이 통과한다.
- 한 번에 active recording session이 하나다.
- explicit Start 전 permission/capture/writer/file side effect가 없다.
- 모든 accepted recording PCM이 T06 recorder로 순서대로 전달되고 STT가 없어도 저장된다.
- 정상 stop이 input close, buffered drain, writer finish와 scope release 뒤에 securing metadata를 기록한다.
- recovery MOV와 metadata/events가 실제 생성되고 final m4a는 없다.
- normal result는 `.securing/.completed`이고 T07이 `.completed`를 선행 기록하지 않는다.
- capture/writer/storage failure와 cancellation/race가 false success, double settlement, audio deletion을 만들지 않는다.
- abnormal active session은 recovery 대상으로 남도록 `.interrupted` 의미를 보존한다.
- metadata file이 authoritative이며 catalog failure가 recording을 막지 않는다.
- minimal UI가 title/language/start, elapsed/level/no-input/stop, securing/result를 실제 live coordinator에 연결한다.
- Application/Domain에 framework/URL 타입이 새로 누출되지 않는다.
- T08 이후 기능을 선행 구현하지 않았다.
- 전체 unit/integration tests와 unsigned arm64 Debug build가 통과한다.
- synthetic/수동 검증 절차와 CI 한계가 문서화됐다.
- 관련 architecture/development/boundary 문서가 task branch의 실제 구현과 일치한다.
- 정확한 task commit의 CI가 성공하고 local/remote task branch가 일치한다.
- `PROJECT_STATUS.md`의 T07 완료 상태, T07 checklist, `dev`와 `main`은 변경되지 않았다.
- task branch가 독립 검토와 같은 Task 보완을 위해 남아 있다.

항목 하나라도 불확실하면 검토 준비 완료라고 보고하지 않는다. 다만 구현 또는 테스트가 아직 덜 끝난 상태는 안전 차단 사유가 아니므로 같은 branch와 세션에서 계속 구현·검증한다. 실제 명세 충돌이나 데이터 안전 결정을 사용자에게 받아야 하는 경우에만 `차단`으로 보고한다.

## 19. 최종 보고 형식

최종 응답은 다음 순서로 구체적으로 보고한다.

1. `T07 구현 후보 상태`: 검토 준비 완료 또는 차단
2. branch와 commit
   - task commit SHA
   - local/remote task branch 일치 여부
   - `dev`와 `main`의 불변 SHA
3. 변경 파일과 핵심 설계
   - coordinator/application contracts와 operation ownership
   - permission 및 start transaction
   - recording PCM pump와 STT independence
   - stop/drain/recorder finish/securing ordering
   - metadata/event/catalog policy
   - minimal SwiftUI state/action mapping
4. acceptance matrix 결과
   - 12.1~12.8 그룹별 실제 test 이름과 결과
5. 실제 synthetic integration evidence
   - input chunk/frame count와 recorder append
   - recovery MOV format/duration/readability
   - metadata status/outcome/title/language/duration
   - events line/order
   - final m4a/checkpoint/transcript 부재
6. 실제 실행한 build/test 명령과 unit/integration test 수/결과
7. race test 반복 횟수와 결과
8. task branch CI run URL/결과
9. 수행한 수동 검증 또는 아직 필요한 절차
10. 명세 이탈 여부
11. 남은 위험과 known diagnostics
12. 조정 세션이 독립 검토할 때 특히 확인해야 할 항목

공식 `T07 완료`, T08 시작 가능, `dev` 통합 완료를 선언하지 않는다. 그것들은 조정 세션의 독립 검토와 별도 통합 프롬프트 이후에만 확정한다.

단순히 “테스트 통과”라고만 쓰지 말고, concurrent start, buffered drain, no-STT audio, exact-once settlement, metadata/event ordering, interrupted failure와 live file creation을 어떤 test가 증명했는지 연결한다. 실제 수행하지 않은 microphone/TCC/signed sandbox/window/sleep/finalization 검증을 성공했다고 주장하지 않는다.
