# T05 실행 프롬프트 — 마이크 캡처와 입력 신호 모니터

## 역할

당신은 `/Users/andyoon/stt` 저장소의 **T05만 담당하는 새 구현 세션**이다. 최신 `dev`의 T01~T04 기반 위에, macOS 현재 시스템 입력 장치에서 PCM을 캡처하고 향후 오디오 저장 consumer와 STT consumer가 서로 막지 않고 독립적으로 받을 수 있는 오디오 전달 경계를 구현하라. 마이크 권한, 입력 레벨, 5초 무입력 경고와 활성 입력 장치 연결 해제도 typed state/event로 구분한다.

이 세션은 분석 보고만 하고 멈추는 세션이 아니다. 아래 acceptance matrix를 같은 T05 세션에서 구현·검증하고, 실제 충돌이나 사용자 결정이 필요한 데이터 안전 문제만 없다면 task branch commit·push·CI·`dev` 통합까지 끝낸다. 미구현 테스트 항목이나 시간이 걸리는 검증은 그 자체로 blocker가 아니므로 계속 작업한다.

T05에서는 세션 폴더 생성, 오디오 파일 기록, 녹음 coordinator, 최종 녹음 UI, VAD, STT, 모델 관리와 복구를 구현하지 않는다. 해당 범위는 각각 T06 이후 작업이다.

## 목표

성공 시 다음이 모두 참이어야 한다.

- 마이크 권한 상태 조회와 권한 요청이 교체 가능한 Application 계약으로 분리된다.
- 앱 또는 view 생성만으로 권한 팝업을 띄우거나 마이크를 시작하지 않는다.
- 권한 요청은 명시적인 호출에서만 발생하고 `notDetermined`, `authorized`, `denied`, `restricted`를 구분한다.
- live 구현은 macOS의 현재 시스템 입력 장치를 사용하며 `AVAudioEngine` input node tap으로 PCM을 캡처한다.
- `AVAudioEngine`, `AVAudioPCMBuffer`, `AVAudioFormat`, Core Audio ID와 Notification 타입은 Infrastructure 밖으로 노출하지 않는다.
- tap callback이 반환된 뒤에도 유효한 소유권 있는 `Sendable` PCM chunk가 Application 경계를 통과한다. AVFoundation buffer나 unsafe pointer의 수명을 외부로 넘기지 않는다.
- 캡처 PCM은 source sample rate와 channel 정보를 보존한다. T05에서 48kHz 저장 형식이나 16kHz STT 형식으로 변환하지 않는다.
- 오디오 저장용 전달 경로와 STT용 전달 경로는 독립된 buffering/lifetime을 가진다.
- 느리거나 읽지 않는 STT consumer가 저장 consumer의 순서, 완전성, 처리 속도 또는 capture callback을 막지 않는다.
- 저장 경로의 frame 유실은 조용히 무시하지 않는다. 저장용 buffer가 넘치면 typed terminal error를 발생시켜 후속 coordinator가 안전 중단을 선택할 수 있게 한다.
- STT 경로는 실시간성을 위해 제한된 backlog와 명시적인 drop/discontinuity 신호를 사용할 수 있지만, 그 drop이 저장 경로에는 영향을 주지 않는다.
- 입력 레벨은 PCM에서 계산되어 UI가 사용할 수 있는 제한된 빈도의 state stream으로 발행된다.
- 입력 시작 후 사실상 0인 신호가 5초 이어지거나 frame 자체가 오지 않는 경우 `noInput` 경고를 한 번 활성화하고, 캡처를 자동 중지하지 않는다.
- 신호가 회복되면 무입력 경고가 해제된다. 무입력 감지는 speech/VAD 판단과 분리된다.
- 캡처 시작 시 사용 중인 입력 장치를 식별하고, 그 장치가 사라지거나 macOS가 다른 기본 장치로 바꾼 경우 즉시 typed device event/error를 발행한다.
- 장치 해제 후 내장 마이크나 다른 장치로 자동 전환하지 않는다.
- 시작, 중지, 다시 시작을 반복해도 tap, engine, device observer와 stream continuation이 중복 등록되거나 남지 않는다.
- engine start 실패, tap 설치 후 실패와 중지 중 오류에서도 설치한 자원을 정확히 rollback한다.
- 실시간 callback은 파일 쓰기, STT, UI 갱신, 긴 lock, actor await 또는 buffer마다 무제한 `Task` 생성을 수행하지 않는다.
- deterministic test가 권한, lifecycle, fan-out, backpressure, level, 5초 무입력, 장치 해제와 cleanup을 검증한다.
- 기존 T01~T04 테스트, unsigned arm64 Debug build와 전체 test suite가 통과한다.
- 실제 마이크와 TCC는 CI에서 신뢰성 있게 검증할 수 없으므로, 합성 테스트와 별도로 재현 가능한 로컬 수동 검증 절차를 `docs/DEVELOPMENT.md`에 기록한다.
- 검증된 T05 결과가 하나의 squash commit으로 `dev`에 통합되고 task branch와 `dev` CI가 모두 통과한다.
- `main`은 변경하거나 승격하지 않는다.

## 허가된 외부 변경

완료 조건을 모두 충족하는 경우에 한해 다음을 허가한다.

- `task/t05-microphone-capture-monitor` 브랜치 생성과 push
- task branch의 GitHub Actions 실행과 결과 확인
- 검증된 task branch를 로컬에서 squash merge하여 `dev` push
- merge된 `dev`의 GitHub Actions 실행과 결과 확인
- `origin/dev`가 안전하고 CI까지 통과한 뒤 T05 task branch 삭제

Pull Request, `main` 변경·push·승격, tag, GitHub Release, branch protection 변경, 저장소 공개 범위 변경, 외부 dependency 설치, 실제 강의 녹음이나 실제 사용자 세션 root 변경은 허가하지 않는다.

테스트는 합성 PCM과 fake permission/engine/device source를 기본으로 사용한다. 실제 마이크 검증을 위해 TCC 데이터베이스를 자동 초기화하거나 System Settings를 자동 조작하지 않는다. 실제 음성, 녹음 파일, 장치 식별자, 로그와 개인 데이터를 Git에 포함하지 않는다.

## 반드시 먼저 읽을 컨텍스트

다음 순서와 범위로 읽어라.

1. 이 프롬프트 전체
2. `AGENTS.md` 전체
3. `PROJECT_STATUS.md` 전체
4. `IMPLEMENTATION_PLAN.md`
   - 2장 실행 원칙
   - 5.2~5.7절 Git 및 GitHub 정책
   - T05 마이크 캡처와 입력 신호 모니터
   - T06과 T07의 경계
   - T11, T18, T19의 경계
   - 8장 작업별 프롬프트 작성 규칙
   - 9장 전체 진행 체크리스트
5. `MVP_SPEC.md`
   - 3.1절 포함 기능 중 마이크, 입력 레벨, 무입력, 오류
   - 3.2절 MVP 입력 범위
   - 4.2, 4.3절 중 입력 확인과 저장/STT 우선순위
   - 8.1~8.3절 중 AVFoundation, 단일 프로세스와 교체 가능한 경계
   - 10.1절 오디오와 STT의 분리
   - 10.3절 VAD와 입력 감지
   - 16.1, 16.2절 마이크 오류와 안전 우선순위
   - 17.2, 17.3절 중 장시간 안정성과 메모리 방향만 확인
   - 18장 개인정보와 진단 로그 방향
6. `docs/ARCHITECTURE.md`와 `docs/DEVELOPMENT.md`
7. 실제 Git 상태와 다음 코드
   - `App/LocalLectureSTTApp.swift`
   - `Features/MainWindowView.swift`
   - `Application/BOUNDARY.md`
   - `Infrastructure/BOUNDARY.md`
   - 기존 Application protocol과 error/value 타입의 작성 방식
   - `LocalLectureSTTTests`와 `LocalLectureSTTIntegrationTests`의 주입·동시성 테스트 방식
   - `LocalLectureSTT.xcodeproj/project.pbxproj`
   - `LocalLectureSTT/App/LocalLectureSTT.entitlements`
   - `.gitignore`

관련 문서가 서로 충돌하거나 오디오 frame 유실을 숨기지 않고는 구현할 수 없는 문제가 발견되면 임의로 완화하지 말고 안전한 상태에서 중단하여 충돌, 데이터 위험과 권장 해결안을 보고하라. 단순히 acceptance test가 아직 없거나 구현량이 많다는 이유로 중단하지 않는다.

## 현재 알려진 기준선

다음은 프롬프트 작성 시점의 정보이며 새 세션에서 실제 상태로 다시 확인한다.

- 작업 디렉터리: `/Users/andyoon/stt`
- 장기 branch: `dev`
- T04 최신 통합 commit: `6659e6dfa039fa498896c36c04d1596e8bffcc1d`
- 이 프롬프트 문서 commit이 위 T04 commit 뒤의 `dev`에 추가되어 있을 수 있다.
- `origin/dev`는 새 구현 세션 시작 전에 fetch하여 확인한다.
- `origin/main`은 T01 실행 기준선 `38e126f92ac823d29306ea8c1f7703f7060a5818`이며 T05에서 변경하지 않는다.
- app target은 macOS 15+, arm64, Swift 6, App Sandbox를 사용하는 단일 프로세스 SwiftUI 앱이다.
- 외부 Swift Package dependency는 없다.
- app target에는 이미 `NSMicrophoneUsageDescription`과 `com.apple.security.device.audio-input` entitlement가 있다. 이를 중복하거나 약화하지 말고 실제 project 설정을 다시 확인한다.
- T04 기준 실제 자동 검증은 unit test 76개와 integration test 1개다.
- `PROJECT_STATUS.md`의 T04 verification 행에 `48 unit tests`라고 남은 것은 이미 확인된 문서 숫자 누락이다. 이것은 제품 명세 충돌이나 구현 blocker가 아니며, T05를 `dev`에 통합하면서 실제 최종 test count로 갱신한다.
- 현재 앱은 storage root와 catalog startup만 compose하며 마이크를 만들거나 시작하지 않는다.
- T07이 최종 녹음 UI와 입력 레벨 표시를 담당한다. T05는 실제 capture adapter와 UI가 구독할 수 있는 state contract까지만 만든다.
- Xcode 26.6의 AppIntents metadata skipped 메시지는 알려진 비차단 toolchain 진단이다.

대화나 이 목록보다 새 세션에서 확인한 실제 Git 상태, code, build/test 결과를 우선한다.

## 1. 사전 점검과 task branch

파일을 수정하기 전에 다음을 확인한다.

- `pwd`
- `git status --short --branch`
- `git remote -v`
- local/remote branch와 upstream
- 최근 commit과 `dev`, `origin/dev`, `main`, `origin/main` SHA
- 예상하지 않은 tracked·untracked 파일 또는 사용자 변경
- `xcode-select -p`, `xcodebuild -version`, `swift --version`, `uname -m`
- `xcodebuild -list`
- 현재 unsigned arm64 Debug build와 전체 test 실행 가능 여부
- 현재 app/test target source membership과 framework/build settings
- microphone usage description과 sandbox audio-input entitlement
- 현재 SDK에서 사용하는 AVFoundation/AVFAudio/Core Audio API의 macOS 15 availability

working tree가 clean하고 local `dev`가 최신 `origin/dev`와 일치하는 것을 확인한 뒤 정확히 다음 branch를 만든다.

~~~text
task/t05-microphone-capture-monitor
~~~

필요하면 먼저 `git fetch origin`, `git switch dev`, `git pull --ff-only origin dev`를 사용한다. 기존 동명 branch나 예상하지 않은 변경·분기가 있으면 덮어쓰거나 삭제하지 말고 조사한 뒤 안전하게 중단하여 보고한다. force push, destructive reset, checkout/clean을 통한 사용자 변경 폐기는 금지한다.

사전 build/test가 실패하면 T05 구현 전에 기준선 문제인지 환경 문제인지 구분한다. 원인을 모른 채 기존 테스트를 수정하거나 T05 변경에 섞지 않는다.

사전 점검 뒤 아래 12장 acceptance matrix를 `완료 조건 → 구현 위치 → 자동 테스트 → 수동 검증` 형태의 짧은 traceability 표로 먼저 정리하고 **승인을 기다리지 말고 바로 구현을 계속한다**. 실제 명세 충돌만 발견됐을 때 질문한다.

## 2. 고정된 제품 의미

다음 의미는 구현 선택지가 아니라 고정 계약이다.

### 2.1 권한과 시작 부작용

- 권한 상태 조회는 시스템 prompt를 띄우지 않는다.
- 권한 요청은 별도 명시적 API다. capture object 초기화, 앱 시작, view construction, preview, Settings 표시와 test discovery에서 권한 요청을 호출하지 않는다.
- capture `start`는 권한이 이미 authorized인지 확인하고, 그렇지 않으면 typed error를 반환한다. `start` 내부에서 암묵적으로 권한 prompt를 띄우지 않는다.
- 사용자가 T07의 명시적 시작 동작을 수행할 때 permission request와 capture start를 조합할 수 있도록 경계를 둔다.
- denied와 restricted를 동일한 boolean로 잃지 않는다. UI가 서로 구분할 수 있는 stable enum을 둔다.
- 권한 오류가 장치 없음, engine 실패나 무입력으로 잘못 표시되지 않게 한다.

### 2.2 현재 시스템 입력 장치

- T05는 capture 시작 시점의 **현재 시스템 기본 입력 장치 하나**를 사용한다.
- 장치 선택 UI, USB 전용 정책, 장치 우선순위와 재연결 로직은 만들지 않는다.
- 시작할 때 active device의 안정적인 identity와 표시용 이름을 snapshot한다. platform-specific ID 타입은 Infrastructure 안에 둔다.
- active device가 사라지거나 기본 입력이 다른 identity로 바뀌면 기존 세션에서 새 장치로 이어 녹음하지 않는다.
- 연결 해제 또는 강제 route 변경을 즉시 event/error로 알리고 capture를 종료 가능한 실패 상태로 전환한다. 후속 T07/T08이 현재까지의 세션을 보존하도록 판단할 수 있어야 한다.
- unrelated audio device의 연결·해제는 현재 capture를 실패시키지 않는다.
- 단순 `AVAudioEngineConfigurationChange` notification만 보고 곧바로 disconnect로 단정하지 않는다. notification 후 active device identity/alive/default 상태를 다시 확인한다.
- 같은 장치의 format/configuration 변경을 live로 안전하게 재구성하지 않는다면 typed configuration-change 오류로 중지할 수 있다. 단, tap을 중복 설치하거나 다른 장치로 몰래 전환해서는 안 된다.

### 2.3 오디오 저장이 STT보다 우선

- T05의 저장 consumer는 아직 파일을 쓰지 않지만 T06의 recovery writer가 사용할 **loss-intolerant primary stream**을 의미한다.
- STT consumer는 후속 T18/T19가 사용할 **best-effort realtime stream**을 의미한다.
- 각 consumer는 별도 queue/buffer/continuation을 가진다. 한 consumer의 대기, 취소와 종료가 다른 consumer를 자동으로 종료하거나 지연시키지 않는다.
- tap callback은 STT consumer가 읽을 때까지 기다리지 않는다.
- STT backlog는 제한한다. 오래된 realtime chunk를 drop하는 정책을 선택할 수 있지만 drop count 또는 discontinuity를 stable event/state로 노출한다.
- 저장 backlog도 메모리 무제한 증가를 피하도록 명시적인 configurable capacity를 가진다.
- 저장 capacity 초과는 silent drop이나 최신 frame 덮어쓰기로 처리하지 않는다. `recordingBackpressure`와 동등한 typed terminal error를 발행하고 capture owner가 안전 중단할 수 있게 한다.
- capture가 성공 상태를 유지하는 동안 저장 consumer에 전달된 sequence에는 gap과 재정렬이 없어야 한다.
- STT의 drop 또는 failure는 저장 stream을 실패시키지 않는다.

### 2.4 T05에서 다루지 않는 기능

- `.mov`, `.m4a`, AAC writer와 파일 저장: T06
- 세션 생성, metadata/event 기록, 경과 시간과 녹음 시작·종료 UI: T07
- 오디오 마무리와 검증: T08
- 비정상 종료 복구: T09
- pause/resume: T10 이후 관련 Task
- STT engine, model과 실제 추론: T11 이후
- VAD와 발화 구간화: T18
- source PCM을 16kHz mono STT 입력으로 변환: T18/T19
- final session list 및 playback UI: T21 이후

테스트를 위해 session file이나 가짜 STT 구현을 만들지 않는다. T07 UI를 선행 구현하지 않으며 `MainWindowView`에 최종 녹음 버튼이나 level meter를 추가하지 않는다.

## 3. 계층과 공개 계약

T01의 단일 app target 안 논리 경계를 유지한다.

- Domain: 기존 세션 도메인에 프레임워크 비의존이며 장기 보존되는 값만 둔다. transient PCM buffer를 억지로 Domain document로 만들지 않는다.
- Application: permission, capture lifecycle, owned PCM chunk, consumer stream, signal/device state와 typed error 계약
- Infrastructure: AVFoundation/AVFAudio/Core Audio adapter, input tap, PCM copy, 장치 관찰과 실제 permission provider
- App: T07 전에는 live capture를 자동 시작하지 않는다. 필요하다면 side-effect-free factory/composition만 추가한다.
- Features: T07이 사용할 observable state 경계까지만 허용한다. 최종 recording UI는 추가하지 않는다.

이름은 Swift 관례와 기존 코드에 맞게 조정할 수 있지만 다음 책임을 합쳐 테스트 불가능하게 만들지 않는다.

1. `MicrophonePermissionAuthorizing` 또는 동등한 계약
   - 현재 authorization state 조회
   - 명시적 request
2. `MicrophoneCapturing` 또는 동등한 capture owner
   - start/stop과 현재 lifecycle
   - capture generation별 독립된 streams/handle 반환
3. owned PCM application value
   - 순서, source format, frame count, media/sample timing과 소유 PCM bytes
4. fan-out/distributor
   - recording과 STT queue 정책 분리
   - overflow/drop 결과를 typed event로 전달
5. `InputSignalMonitor`
   - PCM level 계산 결과 또는 level sample 수신
   - throttled UI state, 5초 no-input, recovery
6. input device observer
   - start 시 active device snapshot
   - active device disconnect/default route change만 구분

다음 경계를 지킨다.

- Application과 Domain에는 `import AVFoundation`, `import AVFAudio`, `import AudioToolbox` 또는 Core Audio C 타입을 두지 않는다.
- 공개 capture/monitor API에 `AVAudioPCMBuffer`, `AVAudioFormat`, `AVAudioTime`, `AudioDeviceID`, `Notification`, `NSError`를 노출하지 않는다.
- PCM chunk, format description, permission/state/event/error는 `Sendable`이다. live-only stream과 raw PCM을 불필요하게 `Codable`로 만들지 않는다.
- `AVAudioEngine`과 tap의 단일 소유자는 actor, 전용 serial executor 또는 동등하게 검증 가능한 직렬화 경계를 가진다.
- 프레임워크 객체의 동시성 문제를 광범위한 `@unchecked Sendable`, 전역 singleton, `Any`, service locator로 숨기지 않는다.
- 불가피한 좁은 callback bridge에 `@unchecked Sendable`이 필요하면 소유권, lock 범위와 safety invariant를 주석·테스트로 증명하고 AVFoundation 객체 자체를 여러 executor에서 임의 사용하지 않는다.
- UI 발행은 `@MainActor`에서만 수행하되 audio callback에서 main actor를 기다리지 않는다.
- cancellation과 stream termination handler가 engine/tap 전체 lifetime을 우발적으로 중단하지 않게 owner와 subscription lifetime을 분리한다.

## 4. 권한 계약

Application enum은 최소 다음 의미를 유지한다.

- `notDetermined`
- `authorized`
- `denied`
- `restricted`

알 수 없는 future system status는 crash나 authorized로 처리하지 말고 보수적인 unavailable/unknown typed 상태로 매핑할 수 있다.

live adapter는 현재 macOS SDK의 audio capture authorization API를 사용한다. callback 기반 request는 structured concurrency로 감싸되 다음을 지킨다.

- continuation을 정확히 한 번 resume한다.
- request completion queue를 가정하지 않는다.
- request 결과와 후속 status가 모순이면 실제 최종 system status를 다시 읽어 보수적으로 반환한다.
- 테스트 fake는 prompt 없이 모든 status와 request 결과를 결정적으로 재현한다.
- 로그에 OS privacy database 내용이나 사용자 정보를 남기지 않는다.

권한이 authorized가 아닌 capture start는 engine/tap/device observer를 건드리지 않는다.

## 5. PCM chunk와 source format

Application 경계의 PCM chunk에는 최소 다음 의미가 있어야 한다.

- capture generation 또는 session-local sequence number
- monotonically increasing chunk sequence
- source sample rate
- source channel count
- frame count
- sample encoding/layout 설명
- source sample time 또는 동등한 monotonic media position
- callback이 끝난 뒤에도 독립적으로 소유되는 PCM payload

구현 규칙:

- T05의 canonical in-memory sample encoding은 처리하기 쉬운 `Float32`로 통일할 수 있다. interleaved 또는 planar 중 하나를 명시하고 모든 chunk에서 일관되게 유지한다.
- payload의 byte/sample count가 format과 frame count에 맞는지 initializer에서 검증한다.
- `sampleRate > 0`, `channelCount > 0`, 유한 sample과 overflow-safe count 계산을 검증한다.
- input format이 지원되지 않거나 변환/copy할 수 없으면 typed capture error를 발행한다. 잘못된 memory를 넘기지 않는다.
- input tap buffer가 mutable하거나 재사용될 수 있으므로 payload는 callback 안에서 소유 memory로 copy한다.
- unsafe pointer, `AudioBufferList`와 AVFoundation buffer reference를 callback 밖으로 escape하지 않는다.
- device native sample rate/channel을 보존하고 T05에서 48kHz mono 또는 16kHz mono로 강제 변환하지 않는다.
- sequence와 sample timing이 wrap, restart 또는 stale callback 때문에 새 generation에 섞이지 않게 한다.
- capture를 stop한 뒤 늦게 도착한 이전 generation callback은 폐기한다.

level 계산을 위해 전체 payload를 두 번 복사하지 않는다. PCM copy와 함께 필요한 accumulator를 계산하거나 owned chunk에서 효율적으로 계산할 수 있다.

## 6. fan-out과 backpressure

Application consumer가 사용할 API는 recording과 speech-recognition 역할을 명시적으로 구분한다. 정확한 형태는 두 개의 `AsyncThrowingStream`, capture handle 안의 별도 stream 또는 역할별 subscription일 수 있다.

필수 동작:

- 두 경로 모두 동일한 chunk sequence 의미를 사용한다.
- recording path는 성공적으로 capture 중인 모든 chunk를 순서대로 받는다.
- STT path가 전혀 iterate하지 않아도 recording path는 정상적으로 drain된다.
- recording consumer가 취소돼도 STT stream이 자동으로 끝났다고 가장하지 않는다. 대신 owner에게 recording path 부재/overflow를 typed fatal event로 알릴 수 있어야 한다.
- STT consumer 취소는 recording path와 engine을 중지하지 않는다.
- stop은 새 callback 수용을 먼저 닫고 tap/engine/observer를 정리한 다음 각 stream을 정확히 한 번 finish한다.
- start 실패는 부분 생성된 stream을 hanging 상태로 남기지 않고 error로 finish한다.
- recording buffer capacity는 production default와 test override를 제공한다. unbounded memory growth를 허용하지 않는다.
- STT buffer는 bounded 최신성 정책을 사용하고 drop을 관측 가능하게 한다.
- `AsyncStream.Continuation.yield` 결과 또는 동등한 enqueue 결과를 확인하여 dropped/terminated 상태를 무시하지 않는다.
- buffer마다 새 unstructured `Task`를 만드는 방식으로 순서·메모리 문제를 숨기지 않는다.

실시간 callback에서 허용하는 일은 validation된 PCM의 최소 copy, O(n) level accumulator와 non-blocking enqueue 정도다. 다음은 callback에서 금지한다.

- 파일 I/O 또는 SQLite
- STT 추론/await
- JSON encoding
- main actor 동기 호출
- user-visible logging
- network
- 오래 걸리거나 경합 가능한 lock
- stop/start 또는 observer 재구성

## 7. 입력 레벨과 5초 무입력

`InputSignalMonitor`는 VAD와 별개다. 말하고 있는지 판단하지 않고 장치에서 의미 있는 PCM 신호가 도착하는지만 판단한다.

level state는 최소 다음을 제공한다.

- normalized level 또는 UI meter가 사용할 값
- RMS dBFS
- peak dBFS
- signal state: observing/active/noInput/stopped 또는 동등한 구분
- 마지막 갱신의 monotonic timing/sequence

계산과 상태 규칙:

- Float32 full scale 1.0을 기준으로 RMS와 peak를 계산한다.
- absolute sample, square sum과 logarithm 과정에서 NaN/Infinity를 UI로 전파하지 않는다.
- silence의 `log10(0)`은 정한 floor dBFS로 clamp한다.
- UI meter 발행은 기본 약 20Hz 등 15~30Hz 범위의 configurable throttle을 둔다. input tap 빈도 그대로 main actor를 갱신하지 않는다.
- 무입력 판단 threshold는 VAD threshold가 아닌 named tuning value로 둔다. 초기 권장값은 RMS `-60 dBFS`, recovery는 약간의 hysteresis를 둔 `-55 dBFS`다. 실제 구현에서 동등한 근거 있는 값으로 조정하면 docs와 테스트에 명시한다.
- capture가 running이 된 시각부터 또는 마지막 active signal 시각부터 연속 5초가 지나면 no-input warning을 활성화한다.
- 4.999초에는 경고하지 않고 5.000초 이상에서 경고한다.
- PCM frame이 전혀 도착하지 않는 running engine도 5초 후 no-input이다. 따라서 frame callback만으로 시간이 흐르는 것을 판단하지 않는다.
- no-input 상태에서는 매 tick마다 같은 경고 event를 반복 발행하지 않는다.
- recovery threshold 이상의 신호가 오면 warning을 해제하고 active 상태를 발행한다.
- no-input은 engine을 stop하거나 stream을 finish하지 않는다.
- stop/restart는 timer, last-signal timestamp와 warning latch를 새 generation에 맞게 초기화한다.
- 테스트는 injected monotonic clock/scheduler를 사용하고 실제 5초 sleep에 의존하지 않는다.

`Date` wall-clock 변경은 5초 판단에 사용하지 않는다. Swift `Clock`, continuous time 또는 동등한 monotonic abstraction을 사용한다.

## 8. 장치 관찰과 오류 사건

장치 관찰 구현은 AVFoundation connection/disconnection notification, AVAudioEngine configuration change와 필요한 경우 macOS Core Audio property listener를 Infrastructure 안에서 조합할 수 있다. API 선택보다 아래 관측 의미가 중요하다.

- start 직전에 current default input이 존재하고 usable한지 확인한다.
- device identity를 capture generation에 묶는다.
- active identity의 disconnect/alive false 또는 default input identity 변경을 구분한다.
- unrelated device event는 무시한다.
- active device disconnect는 no-input 5초를 기다리지 않고 즉시 typed event/error다.
- disconnect 이후 자동으로 새 default input의 PCM을 같은 generation에 흘리지 않는다.
- observer callback과 engine configuration notification이 동시에 와도 terminal event와 cleanup은 한 번만 실행된다.
- stop 이후 observer token/listener는 제거되고 늦은 notification은 무시된다.
- restart는 새 device snapshot과 observer generation을 사용하며 이전 token을 재사용하지 않는다.

Application error/event code는 최소 다음 상황을 구분한다.

- permission not determined/denied/restricted
- no current input device
- invalid/unsupported input format
- input tap installation or engine start failure
- PCM copy/conversion failure
- recording consumer backpressure/termination
- active input device disconnected or route changed
- engine configuration/runtime failure
- normal stop

문자열 하나나 framework NSError만 내보내지 않는다. user-facing message 작성은 T07 이후 Feature 책임으로 남기되 stable code와 필요한 안전한 context는 제공한다.

## 9. capture lifecycle과 자원 정리

최소 lifecycle 의미:

- idle
- starting
- running
- stopping
- failed 또는 마지막 terminal outcome

구현 선택에 따라 일부를 internal state로 둘 수 있지만 테스트로 전이를 확인할 수 있어야 한다.

필수 규칙:

- start/stop은 단일 직렬화 owner에서 처리한다.
- concurrent start 두 개가 tap을 두 번 설치하지 않는다. 하나만 성공하고 다른 호출은 typed already-running 결과 또는 명시된 idempotent 결과를 받는다.
- idle stop은 안전한 no-op이다.
- running stop은 callback 수용 차단 → tap 제거 → engine stop/reset 필요 여부 처리 → observer 제거 → stream finish 순서를 문서화한다.
- tap 설치 뒤 engine start가 실패하면 tap과 observer를 rollback하고 idle/failed의 일관된 상태로 돌아간다.
- engine start 전에 필요한 준비를 수행하되 프레임워크의 documented order를 지킨다.
- 정상 stop과 terminal error가 race해도 `removeTap`, observer removal과 continuation finish가 각각 한 번만 일어난다.
- stop 완료 뒤 start가 다시 가능하고 새 stream/generation/sequence를 만든다.
- deinit에만 cleanup을 의존하지 않는다.
- capture handle이나 consumer stream이 retain cycle로 engine owner를 영구 보존하지 않는다.
- app/view construction test는 engine start, tap install, permission request가 0회임을 fake로 검증한다.

## 10. 테스트 가능 구조

hardware/TCC와 deterministic logic을 분리한다. 최소 다음 test double 또는 동등한 주입점을 둔다.

- permission provider
- engine/tap driver 또는 synthetic PCM source
- fan-out capacities
- device identity/observer source
- monotonic clock/scheduler
- UI state sink 또는 AsyncSequence collector

실제 `AVAudioEngine` adapter를 통째로 mock하려고 Application 계약에 AVFoundation 타입을 올리지 않는다. synthetic source가 owned PCM과 device event를 발생시키고 Application distributor/monitor를 같은 방식으로 통과하게 한다.

테스트는 timeout에 의존해 우연히 통과하지 않게 expectation, controlled clock과 bounded collection을 사용한다. hang 가능성이 있는 stream test는 명시적인 timeout과 cleanup을 가진다.

## 11. UI와 composition 경계

T05는 T07의 최종 녹음 UI를 만들지 않는다.

- `MainWindowView`에 녹음 시작/종료, 경과 시간, 세션 제목, session state를 추가하지 않는다.
- 입력 레벨을 UI에서 사용할 수 있는 `@MainActor ObservableObject` 또는 순수 state stream 계약을 추가할 수 있다.
- live capture object를 composition root에 넣더라도 init만으로 permission request, tap install, engine start, timer 시작이 발생하지 않아야 한다.
- preview와 integration view construction은 실제 Application Support, 마이크, TCC와 device notification을 건드리지 않는다.
- T07이 permission request → capture start → writer 연결 → UI 표시를 조합할 수 있도록 dependency injection point를 문서화한다.

실제 microphone을 사람이 확인하기 위한 production debug UI를 임시로 추가하지 않는다. 대신 13장의 opt-in 수동 검증 절차를 문서화한다.

## 12. 자동 acceptance matrix

구현 전에 아래 각 항목을 test 이름 또는 검증 방법에 매핑하고, 모두 끝날 때까지 같은 세션에서 계속 작업한다.

### 12.1 권한

1. system authorization status 전체가 stable Application enum으로 정확히 매핑된다.
2. status 조회와 object/view construction은 request를 호출하지 않는다.
3. 명시적 request는 completion을 한 번만 전달하고 최종 status를 반환한다.
4. denied/restricted/notDetermined start는 engine/tap/observer를 전혀 시작하지 않는다.
5. authorized start만 capture setup으로 진행한다.

### 12.2 PCM 소유권과 format

1. 알려진 mono와 multi-channel synthetic samples가 owned chunk로 정확히 copy된다.
2. callback source memory를 이후 변경해도 이미 발행된 chunk bytes가 변하지 않는다.
3. sequence, frame count, sample rate, channel count와 sample timing이 정확하다.
4. invalid format/count/non-finite metadata는 typed error이며 unsafe access를 하지 않는다.
5. stop 뒤 stale generation callback이 새 stream에 들어가지 않는다.

### 12.3 fan-out과 우선순위

1. recording과 STT consumer가 같은 ordered sequence를 독립적으로 받을 수 있다.
2. STT consumer가 전혀 읽지 않거나 의도적으로 느려도 recording consumer는 모든 synthetic frame을 순서대로 받는다.
3. STT bounded buffer drop은 drop/discontinuity로 관측되고 recording에는 gap을 만들지 않는다.
4. STT cancellation/failure는 recording stream과 capture를 중지하지 않는다.
5. recording buffer가 의도적으로 넘치면 silent drop 대신 typed terminal backpressure가 발생한다.
6. 정상 stop은 모든 남은 accepted recording frames의 ordering 의미를 보존하고 streams를 한 번 finish한다.
7. frame마다 unbounded task가 생기지 않는 구조를 code review와 stress test로 확인한다.

### 12.4 level과 no-input

1. silence, full-scale, 알려진 sine/constant samples의 RMS/peak/dBFS가 tolerance 안에서 정확하다.
2. NaN, Infinity와 empty input이 UI state에 전파되지 않는다.
3. high-frequency input에도 UI state 발행률이 설정한 throttle을 넘지 않는다.
4. signal 없는 상태 4.999초에는 경고가 없고 5.000초에 no-input이 된다.
5. frame이 하나도 도착하지 않는 running capture도 5초에 no-input이 된다.
6. no-input warning은 반복 spam되지 않고 capture/recording stream은 계속 running이다.
7. signal recovery가 warning을 해제한다.
8. stop/restart가 timer와 warning latch를 초기화한다.

### 12.5 device와 runtime event

1. start가 current default input identity를 snapshot한다.
2. unrelated device disconnect는 무시한다.
3. active device disconnect는 즉시 정확히 한 terminal event를 낸다.
4. default input이 다른 identity로 바뀌면 자동 전환하지 않고 route/device error를 낸다.
5. engine configuration notification 뒤 device identity를 재확인한다.
6. device event와 engine error race에서도 tap/observer/streams cleanup은 한 번이다.
7. stop 이후 늦은 device notification은 상태를 바꾸지 않는다.

### 12.6 start/stop와 실패 rollback

1. start는 tap과 observer를 각각 한 번 설치하고 engine을 한 번 시작한다.
2. concurrent/repeated start가 duplicate tap을 만들지 않는다.
3. idle stop은 안전한 no-op이다.
4. running stop은 tap, engine, observer와 stream을 한 번 정리한다.
5. tap 설치 후 engine start 실패는 모든 부분 자원을 rollback한다.
6. start → stop → start → stop에서 각 generation의 frame과 event가 섞이지 않는다.
7. consumer cancellation과 terminal failure가 race해도 deadlock, double finish와 crash가 없다.

### 12.7 앱 경계와 회귀

1. app/main view construction은 permission request, tap install, engine start와 device observer registration을 만들지 않는다.
2. Application/Domain의 새 공개 파일에 AVFoundation/Core Audio import나 타입 누출이 없다.
3. T06 writer, T07 recording UI, VAD와 STT가 선행 구현되지 않았다.
4. 기존 unit/integration test가 모두 통과한다.
5. unsigned arm64 Debug build가 통과한다.
6. project에 추가한 production/test source가 올바른 target membership을 가진다.

## 13. 실제 하드웨어 수동 검증

자동 테스트는 synthetic PCM과 fake device event를 사용한다. 실제 마이크 동작은 재현 가능한 별도 절차를 `docs/DEVELOPMENT.md`에 기록한다.

필수 문서 내용:

- App Sandbox와 동일한 microphone entitlement/usage description을 가진 로컬 signed build 또는 opt-in integration harness를 사용하는 방법
- 사용자가 직접 권한을 허용한 상태에서만 실행하는 방법
- 현재 입력 장치와 sample rate/channel을 확인하는 방법
- 말하거나 손뼉을 쳤을 때 level과 PCM chunk가 들어오고 5초 무입력 후 warning이 활성화되는지 확인하는 방법
- start/stop을 여러 번 반복해 duplicate tap crash가 없는지 확인하는 방법
- 외부 입력 장치를 사용할 수 있을 때만 disconnect를 수동 확인하며, 다른 장치로 자동 전환되지 않는지 확인하는 방법
- 권한 거부 상태 변경은 System Settings에서 사용자가 직접 수행하며 `tccutil reset`이나 privacy DB 변경을 자동화하지 않는다는 주의
- 수동 절차 중 생성되는 진단 PCM을 파일로 저장하지 않고 로그에 sample bytes/device ID를 남기지 않는다는 주의

committed opt-in hardware integration test를 추가한다면 기본 CI에서는 명시적으로 skip되고 환경 변수 또는 Xcode test plan 선택이 있을 때만 실행되어야 한다. CI 성공을 실제 microphone 검증으로 과장하지 않는다. opt-in test가 불필요하게 production UI나 session file을 만들지 않게 한다.

실제 hardware 검증을 현재 환경에서 수행할 수 없으면 Task 전체를 blocker로 만들지 않는다. 자동 matrix 통과와 수동 절차를 완료하고, 최종 보고의 `Manual verification still required`에 정확히 남긴다.

## 14. 오류, 개인정보와 안전 규칙

- audio sample payload, device unique ID, 사용자의 음성 내용과 전체 NSError description을 일반 로그에 남기지 않는다.
- T25 이전에 범용 file logger, telemetry, crash uploader를 추가하지 않는다.
- microphone/engine 오류가 나도 session file을 삭제하는 코드는 만들지 않는다.
- 실제 session root, Application Support runtime data 또는 recordings를 test fixture로 사용하지 않는다.
- permission denied를 해결하기 위해 앱이 System Settings를 자동 조작하지 않는다. 후속 UI가 안내할 typed 상태만 제공한다.
- STT를 위해 network를 호출하거나 package/model을 내려받지 않는다.
- 시스템 오디오 capture entitlement/API를 추가하지 않는다.
- user-selected input device UI와 USB 자동 전환을 추가하지 않는다.

## 15. 문서와 project 반영

구현 구조가 확정되면 다음을 갱신한다.

- `docs/ARCHITECTURE.md`
  - permission/capture/distributor/signal-monitor/device-observer 책임
  - owned PCM format과 두 consumer의 buffering/overflow 정책
  - real-time callback과 Swift concurrency 경계
  - T06/T07/T18/T19가 연결할 위치
- `docs/DEVELOPMENT.md`
  - 새 자동 test command가 있다면 정확한 실행법
  - 13장의 실제 마이크 수동 검증 절차
  - CI가 hardware/TCC를 검증하지 않는 한계
- `Application/BOUNDARY.md`, `Infrastructure/BOUNDARY.md`
  - 실제 공개 경계가 materially 변했다면 간결하게 갱신
- `LocalLectureSTT.xcodeproj/project.pbxproj`
  - 새 source/test membership과 필요한 system framework link만 반영
- `PROJECT_STATUS.md`
  - `dev` 통합 시 T05 완료, 실제 최종 test count, 다음 T06, 남은 manual verification을 기록
  - 기존 T04 행의 stale `48 unit tests` 숫자도 실제 T04 baseline 76으로 바로잡기
- `IMPLEMENTATION_PLAN.md`
  - `dev` 통합 시에만 T05 checklist를 `[x]`로 변경

문서가 구현보다 앞서 완료를 주장하지 않게 한다. task branch에서 아직 completion condition이 실패하면 `PROJECT_STATUS`와 checklist를 완료로 바꾸지 않는다.

## 16. 검증 명령

정확한 scheme과 설정은 실제 project에서 다시 확인한다. 최소 다음을 실행한다.

~~~sh
xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T05-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T05-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
~~~

구현 중에는 새 T05 test class를 targeted 실행해도 되지만 완료 판단 전에는 전체 suite를 실행한다. concurrency/fan-out stress test를 여러 번 실행해 순서 의존 flake가 없는지 확인한다. 실제 sleep을 길게 넣어 test 시간을 늘리지 않는다.

검증 결과에서 다음을 구분한다.

- 실제 test failure
- Swift 6 sendability/data-race warning 또는 error
- known AppIntents metadata skipped 진단
- unsigned build라 실제 TCC microphone access를 증명하지 못한 한계
- opt-in hardware test의 명시적 skip

실패를 ignore하거나 test assertion을 약화해 통과시키지 않는다. 현재 환경이 sandbox 때문에 XCTest helper를 막으면 동일 명령을 필요한 승인으로 다시 실행하되, 허가 없이 destructive system 변경을 하지 않는다.

## 17. commit, push, CI와 dev 통합

완료 조건을 모두 충족한 경우에만 다음 순서를 수행한다.

1. `git status`, 전체 task diff와 `git diff --check`를 검토한다.
2. runtime audio, logs, DerivedData, 실제 device 정보와 관련 없는 변경이 없는지 확인한다.
3. T05 관련 경로만 stage한다.
4. Task ID가 포함된 명확한 commit을 만든다. 예: `feat(audio): add microphone capture and signal monitor (T05)`.
5. `task/t05-microphone-capture-monitor`를 push한다.
6. 해당 task branch의 `macOS CI`가 성공할 때까지 확인한다.
7. 최신 `origin/dev`를 fetch하고 task 시작 이후 다른 commit이 추가됐는지 확인한다.
8. 새 `dev` 변경이 있다면 task branch에 안전하게 반영하고 전체 검증/CI를 다시 수행한다. 임의 overwrite하지 않는다.
9. 최신 local `dev`에서 `--squash`로 검증된 task branch를 merge한다.
10. `PROJECT_STATUS.md`, `IMPLEMENTATION_PLAN.md` checklist와 필요한 architecture/development 문서 갱신을 포함한 하나의 T05 integration commit을 만든다.
11. merge된 `dev`에서 unsigned arm64 Debug build와 전체 test를 다시 실행한다.
12. `dev`를 push하고 정확한 `dev` commit의 CI 성공을 확인한다.
13. `origin/dev` SHA와 local `dev` SHA가 일치하는지 확인한다.
14. 그 뒤에만 local/remote task branch를 삭제한다.

정상 Task에는 PR을 만들지 않는다. `main`을 checkout하여 merge하거나 push하지 않는다.

task branch CI 또는 merge 후 `dev` CI가 실패하면 완료로 보고하지 않는다. 같은 T05 세션에서 원인을 고치고 task branch 검증부터 필요한 단계를 반복한다.

## 18. 완료 조건

다음이 모두 참일 때만 T05를 완료라고 보고한다.

- 4~11장의 권한, PCM, fan-out, signal, device와 lifecycle 계약이 실제 구현에 존재한다.
- 12장 자동 acceptance matrix가 빠짐없이 통과한다.
- slow/non-consuming STT test에서 recording sequence가 완전하고 순서가 유지된다.
- recording overflow는 silent loss가 아니라 typed terminal failure다.
- 5초 no-input은 controlled clock으로 검증되고 capture를 중지하지 않는다.
- active device disconnect/default change는 immediate typed failure이며 자동 전환하지 않는다.
- repeated/concurrent start-stop에서 duplicate tap, observer leak와 double finish가 없다.
- Application/Domain에 AVFoundation/Core Audio 타입이 누출되지 않는다.
- T06 이후 기능을 선행 구현하지 않았다.
- 전체 unit/integration tests와 unsigned arm64 Debug build가 통과한다.
- 실제 hardware verification 절차와 unsigned CI 한계가 문서화됐다.
- task branch와 merge된 `dev` CI가 성공했다.
- `PROJECT_STATUS.md`, T05 checklist와 관련 architecture/development 문서가 실제 상태와 일치한다.
- `origin/dev`에 verified squash commit이 있고 `main`은 그대로다.

항목 하나라도 불확실하면 `dev`에 merge하지 않는다. 다만 구현 또는 테스트가 아직 덜 끝난 상태는 안전 차단 사유가 아니므로 같은 branch와 세션에서 계속 완료한다.

## 19. 최종 보고 형식

최종 응답은 다음 순서로 구체적으로 보고한다.

1. `T05 상태`: 완료 또는 차단
2. branch와 commit
   - task commit SHA
   - squash된 `dev` commit SHA
   - local/remote 일치 여부
   - `main` 불변 SHA
3. 변경 파일과 핵심 설계
   - permission boundary
   - owned PCM format
   - recording/STT buffering과 overflow/drop 정책
   - input level/no-input clock 정책
   - active-device disconnect와 cleanup
4. acceptance matrix 결과
   - 각 12.1~12.7 그룹별 test 이름과 결과
5. 실제 실행한 build/test 명령과 test 개수/결과
6. task branch CI와 `dev` CI run URL/결과
7. 수행한 실제 마이크 수동 검증 또는 아직 필요한 절차
8. 명세 이탈 여부
9. 남은 위험과 known diagnostics
10. T06 시작 가능 여부

단순히 “테스트 통과”라고만 쓰지 말고, slow STT 독립성, no-input 5초, disconnect, repeated start-stop와 rollback이 어떤 자동 test로 증명됐는지 연결한다. 실제 수행하지 않은 hardware 검증이나 CI를 성공했다고 주장하지 않는다.
