# T06 실행 프롬프트 — 복구 가능한 fragmented 오디오 writer

## 역할

당신은 `/Users/andyoon/stt` 저장소의 **T06만 담당하는 새 구현 세션**이다. 최신 `dev`의 T01~T05 기반 위에, T05의 loss-intolerant `recordingPCM`을 받아 세션의 `recovery/audio.recovery.mov`에 audio-only fragmented QuickTime movie를 기록하는 교체 가능한 `AudioRecorder` 경계와 AVFoundation 구현을 완성하라.

이 세션은 분석이나 중간 보고만 하고 멈추는 세션이 아니다. 아래 acceptance matrix를 같은 T06 세션에서 구현·검증하고, 실제 명세 충돌이나 사용자 결정이 필요한 오디오 보존 위험만 없다면 task branch commit·push·CI·`dev` 통합까지 끝낸다. 구현량, 아직 작성하지 않은 테스트, 실제 마이크를 쓸 수 없는 CI 환경은 그 자체로 blocker가 아니다.

T06에서는 녹음 session coordinator와 UI, 정상 종료 후 `audio.m4a` 변환, 시작 시 복구, pause/resume, STT를 구현하지 않는다. 각각 T07 이후 범위다.

## 목표

성공 시 다음이 모두 참이어야 한다.

- Application에 AVFoundation과 파일 URL을 노출하지 않는 `AudioRecorder` 또는 동등한 교체 가능 계약이 생긴다.
- recorder는 기존 `SessionLocation`과 T05 `PCMChunk`만으로 동작하고 세션의 고정된 `recovery/audio.recovery.mov`만 기록한다.
- 실제 writer는 `AVAssetWriter`의 audio-only `.mov`를 사용한다.
- output은 AAC-LC, mono, 48,000Hz, 목표 96kbps다.
- `movieFragmentInterval`은 약 10초, `initialMovieFragmentInterval`은 약 1초로 writing 시작 전에 설정한다.
- 입력이 48kHz mono가 아니어도 T05의 source-native Float32 interleaved PCM을 상태를 유지하는 converter로 mono 48kHz에 변환한다.
- 모든 accepted recording chunk는 순서대로 기록되며 writer가 느릴 때 frame을 조용히 drop하거나 메모리를 무제한 늘리지 않는다.
- STT stream을 만들거나 drain하지 않아도 오디오 저장은 독립적으로 동작한다.
- start부터 stop/failure cleanup까지 security-scoped root 접근이 끊기지 않고 정확히 한 번 해제된다.
- 기존 recovery 파일을 덮어쓰거나 truncate하지 않고, 실패한/부분 파일도 자동 삭제하지 않는다.
- start, append, flush, stop의 의미와 허용 상태가 typed lifecycle로 명확하다.
- writer/storage/conversion 실패는 stable typed error와 후속 T07이 `events.jsonl`에 기록할 수 있는 한 개의 recorder failure event로 전달된다.
- 정상 stop은 converter tail을 drain하고 input을 finish한 뒤 `finishWriting` 완료/status를 확인한다.
- 생성 파일은 AVFoundation으로 열고 오디오를 실제 decode할 수 있다.
- fragment 설정뿐 아니라 작성 중인 미완료 파일에서 이미 확정된 prefix가 읽히는지 합성 오디오 integration test로 확인한다.
- repeated start/stop, sequence·generation·format 위반, writer readiness/failure, storage access lifetime과 cleanup이 결정론적 테스트로 검증된다.
- 기존 T01~T05 테스트, unsigned arm64 Debug build와 전체 test suite가 통과한다.
- 검증된 결과가 하나의 squash commit으로 `dev`에 통합되고 task branch와 `dev` CI가 모두 성공한다.
- `main`은 변경하거나 승격하지 않는다.

## 허가된 외부 변경

완료 조건을 모두 충족하는 경우에 한해 다음을 허가한다.

- `task/t06-fragmented-audio-writer` 브랜치 생성과 push
- task branch의 GitHub Actions 실행과 결과 확인
- 검증된 task branch를 로컬에서 squash merge하여 `dev` push
- merge된 `dev`의 GitHub Actions 실행과 결과 확인
- `origin/dev`가 안전하고 CI까지 통과한 뒤 T06 task branch 삭제

Pull Request, `main` 변경·push·승격, tag, GitHub Release, branch protection 변경, 저장소 공개 범위 변경, 외부 package/dependency 설치, 실제 강의 녹음, 실제 사용자 session root 변경은 허가하지 않는다.

테스트는 임시 directory, synthetic PCM, fake writer/backend와 fake security-scoped bookmark codec을 사용한다. 생성한 `.mov`, DerivedData와 runtime Application Support 자료는 Git에 포함하지 않는다.

## 반드시 먼저 읽을 컨텍스트

다음 순서와 범위로 읽어라.

1. 이 프롬프트 전체
2. `AGENTS.md` 전체
3. `PROJECT_STATUS.md` 전체
4. `IMPLEMENTATION_PLAN.md`
   - 2장 실행 원칙
   - 5.2~5.7절 Git 및 GitHub 정책
   - T06 fragmented 오디오 writer
   - T05, T07, T08, T09의 인접 경계
   - 8장 작업별 프롬프트 작성 규칙
   - 9장 전체 진행 체크리스트
5. `MVP_SPEC.md`
   - 8.1~8.3절 중 AVFoundation, 단일 프로세스와 교체 가능한 경계
   - 10.1절 오디오와 STT의 분리
   - 11.1절 녹음 형식
   - 11.2절 녹음 중 복구 원본
   - 11.3절은 T08 경계를 구분하기 위해서만 확인
   - 12.1~12.5절 파일 원본, 저장 위치와 session layout
   - 13.4절 file/storage session event
   - 14.1절은 T08 checkpoint 경계를 구분하기 위해서만 확인
   - 16.1, 16.2절 파일 쓰기 오류와 오디오 우선순위
   - 17.2, 17.4, 17.6절 중 장시간·필수 저장·복구 검증 방향
   - 18장 개인정보와 완전 오프라인 원칙
6. `docs/ARCHITECTURE.md`와 `docs/DEVELOPMENT.md`
7. 실제 Git 상태와 다음 코드
   - `Application/MicrophoneCapture.swift`
   - `Infrastructure/AVFoundationMicrophoneCapture.swift`
   - `Application/StorageContracts.swift`
   - `Infrastructure/StorageRootManager.swift`
   - `Infrastructure/FileSessionRepository.swift`
   - `Domain/SessionStorage.swift`
   - `Domain/SessionEvents.swift`
   - `Application/BOUNDARY.md`, `Infrastructure/BOUNDARY.md`
   - T03 storage tests와 T05 microphone tests
   - `LocalLectureSTT.xcodeproj/project.pbxproj`
   - `.gitignore`
8. 선택한 Xcode SDK의 `AVAssetWriter`, `AVAssetWriterInput`, `AVAudioConverter`, `AVAsset`, `AVAssetReader` 공식 header/documentation

관련 문서가 충돌하거나 audio frame 유실, recovery 파일 덮어쓰기, scope 조기 해제를 피하지 않고는 구현할 수 없는 문제가 발견되면 임의로 완화하지 말고 안전한 상태에서 중단하여 충돌, 데이터 위험과 권장 해결안을 보고하라. 단순히 acceptance test가 아직 없거나 구현량이 많다는 이유로 멈추지 않는다.

## 현재 알려진 기준선

다음은 프롬프트 작성 시점의 정보이며 새 세션에서 실제 상태로 다시 확인한다.

- 작업 디렉터리: `/Users/andyoon/stt`
- 장기 branch: `dev`
- T05 최신 통합 commit: `92c5d49a9147e762f69755a8a4272f70319853b8`
- 이 프롬프트 문서 commit이 위 T05 commit 뒤의 `dev`에 추가되어 있을 수 있다.
- `origin/dev`는 새 구현 세션 시작 전에 fetch하여 확인한다.
- `origin/main`은 T01 실행 기준선 `38e126f92ac823d29306ea8c1f7703f7060a5818`이며 T06에서 변경하지 않는다.
- app target은 macOS 15+, arm64, Swift 6, App Sandbox를 사용하는 단일 프로세스 SwiftUI 앱이다.
- 외부 Swift Package dependency는 없다. T06도 Apple system framework만 사용한다.
- T05의 현재 자동 검증은 unit test 95개와 integration test 1개, 전체 96개다. `PROJECT_STATUS.md`의 이전 “96 unit tests” 표기는 문서 오기이며 T06 prompt 문서 commit에서 95 unit + 1 integration으로 바로잡혔을 수 있다.
- T05 `PCMChunk`는 source-native sample rate/channel, generation, sequence, source sample time과 frame-major Float32 interleaved owned samples를 가진다.
- T05 `CaptureHandle.recordingPCM`은 bounded loss-intolerant primary stream이다. `speechPCM`은 별도 best-effort stream이며 T06에서 사용하지 않는다.
- `SessionArtifact.recoveryAudio`는 이미 `recovery/audio.recovery.mov`에 매핑되고 authoritative/recovery로 분류된다.
- 현재 `StorageRootManager.withAccess`는 synchronous lexical closure 동안만 security-scoped access를 유지한다. AVAssetWriter는 start부터 asynchronous finish까지 URL 접근이 필요하므로 T06은 URL을 Application에 노출하지 않으면서 Infrastructure 내부에서 명시적인 장기 access lifetime을 추가해야 한다.
- macOS 15 deployment target에서 `AVAssetWriter.initialMovieFragmentInterval`을 사용할 수 있다. local SDK header에서 availability와 실제 API 의미를 다시 확인한다.
- `AVAssetWriter.flushSegment()`는 delegate 기반 segment-output mode의 API이며 file-backed fragmented movie의 임의 flush API가 아니다. 아래에서 정의한 T06 `flush` 의미와 혼동하지 않는다.
- 현재 app은 storage root와 catalog만 compose하며 microphone capture 또는 writer를 자동 시작하지 않는다.
- Xcode 26.6의 AppIntents metadata skipped 메시지는 알려진 비차단 toolchain 진단이다.

대화나 이 목록보다 새 세션에서 확인한 실제 Git 상태, code, SDK header, build/test 결과를 우선한다.

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
- app/test target source membership과 AVFoundation link/import 방식
- deployment target에서 필요한 AVFoundation API availability
- `.gitignore`가 runtime `.mov`, `.m4a`, session root, DerivedData를 추적하지 않는지

working tree가 clean하고 local `dev`가 최신 `origin/dev`와 일치하는 것을 확인한 뒤 정확히 다음 branch를 만든다.

~~~text
task/t06-fragmented-audio-writer
~~~

필요하면 먼저 `git fetch origin`, `git switch dev`, `git pull --ff-only origin dev`를 사용한다. 기존 동명 branch나 예상하지 않은 변경·분기가 있으면 덮어쓰거나 삭제하지 말고 조사한 뒤 안전하게 중단하여 보고한다. force push, destructive reset, checkout/clean을 통한 사용자 변경 폐기는 금지한다.

사전 build/test가 실패하면 T06 구현 전에 기준선 문제인지 환경 문제인지 구분한다. 원인을 모른 채 기존 테스트를 수정하거나 T06 변경에 섞지 않는다.

사전 점검 뒤 아래 12장 acceptance matrix를 `완료 조건 → 구현 위치 → 자동 테스트 → 수동 검증` 형태의 짧은 traceability 표로 먼저 정리하고 **승인을 기다리지 말고 바로 구현을 계속한다**. 실제 명세 충돌만 발견됐을 때 질문한다.

## 2. 고정된 제품 의미

다음 의미는 구현 선택지가 아니라 고정 계약이다.

### 2.1 recovery 파일의 소유권과 위치

- T06의 유일한 output은 해당 `SessionLocation`의 `SessionArtifact.recoveryAudio`, 즉 `recovery/audio.recovery.mov`다.
- Application API는 `SessionLocation`을 사용하며 root URL, session URL 또는 output URL을 반환·입력받지 않는다.
- 새 녹음용 session folder와 `recovery/`는 T03 repository가 먼저 만들었다고 가정하되, 실제 존재와 directory/symlink 상태를 start에서 검증한다.
- location의 root ID와 immutable folder name을 사용한다. 녹음 도중 active root가 변경되어도 다른 root로 redirect하지 않는다.
- session directory, recovery directory 또는 destination이 예상하지 않은 symlink라면 따라가지 않고 typed layout/access error로 실패한다.
- destination이 이미 존재하면 size나 유효성에 관계없이 overwrite, truncate, rename, delete하지 않고 typed collision error로 실패한다. 기존 파일의 처리는 T09 복구 범위다.
- writer가 output을 만든 뒤 어느 단계에서 실패하더라도 부분 파일을 자동 삭제하지 않는다. 0 byte 또는 unreadable 파일도 진단·복구 판단 전에는 보존한다.
- `AVAssetWriter.cancelWriting()`은 Apple API 계약상 이미 생성한 output file을 삭제하므로 production recovery writer에서 호출하지 않는다. cancellation/early termination도 intake를 닫고 가능한 범위에서 `markAsFinished`/`finishWriting`을 시도하며, 실패 상태의 file은 그대로 둔다.
- SQLite나 derived file은 T06 output이 아니다.

### 2.2 container, codec와 fragment 설정

- container는 audio-only QuickTime movie `.mov`다. 확장자만 `.mov`인 비-fragmented file이나 `.m4a`를 만들지 않는다.
- codec은 AAC-LC, channel은 mono, sample rate는 정확히 48,000Hz, encoder target bitrate는 96,000bps다.
- `AVAssetWriter` output file type은 `.mov`이고 audio input 하나만 추가한다. video, metadata track 또는 system audio를 추가하지 않는다.
- `movieFragmentInterval`은 `CMTime` 약 10초, `initialMovieFragmentInterval`은 약 1초로 **`startWriting()` 전에** 설정한다.
- deployment target이 macOS 15이므로 runtime availability fallback으로 1초 초기 fragment를 생략하지 않는다.
- file-backed fragment 작성에 `preferredOutputSegmentInterval`, delegate segment output 또는 `flushSegment()`를 섞지 않는다.
- `shouldOptimizeForNetworkUse`나 다른 설정은 근거 없이 fragment 안정성 대용으로 사용하지 않는다.
- encoder bitrate는 목표값이다. 실제 compressed track의 평균 data rate가 container overhead와 encoder behavior 때문에 정확히 96,000과 같아야 한다고 잘못 검증하지 않는다. 대신 writer output setting과 합리적 tolerance의 track 확인을 구분한다.
- fragment interval은 미디어 시간 기준이다. wall-clock timer로 1초/10초마다 writer를 stop/restart하거나 여러 파일로 나누지 않는다.

### 2.3 PCM 변환과 미디어 타임라인

- 입력은 T05가 정의한 source-native Float32 interleaved `PCMChunk`다. T06이 T05의 capture tap 또는 source format을 48kHz mono로 바꾸지 않는다.
- 첫 accepted chunk가 recording generation과 source format을 확정한다. start에서 expected generation을 받는 설계라면 첫 chunk와 반드시 일치시킨다.
- 같은 recording에서 generation 또는 source format이 바뀌면 조용히 새 converter를 만들지 않고 typed terminal error를 낸다. T05 configuration change는 새 capture generation으로 재시작해야 한다.
- 첫 sequence는 T05 의미에 맞는 0이어야 하고 이후 sequence는 overflow를 안전하게 검사하며 정확히 1씩 증가해야 한다. gap, duplicate와 reorder는 silent loss가 아니라 typed terminal error다.
- `sourceSampleTime`은 음수가 아님이 T05에서 검증된다. T06 output PTS는 raw device sample time을 48k timescale에 직접 재해석하지 않고, 실제로 변환·append한 output frame 수로 0부터 연속적으로 만든다.
- sequence가 연속인데 device `sourceSampleTime`에 작은 gap이 있다는 이유만으로 임의 silence를 삽입하거나 frame을 버리지 않는다. 역행 또는 명백한 불일치는 진단 가능한 typed error로 다룰 수 있으나, 정상 AVAudioEngine timestamp behavior를 오디오 손실로 오판하지 않도록 테스트와 문서로 정한 규칙을 둔다.
- channel mixing과 resampling은 상태를 유지하는 converter로 수행한다. chunk마다 converter를 새로 만들어 filter state, fractional frame과 converter latency/tail을 잃지 않는다.
- stop에서 converter end-of-stream을 drain해 남은 output을 append한다. 단, 입력에 존재하지 않은 긴 silence를 임의 생성하지 않는다.
- output sample buffers의 presentation timestamp와 duration은 단조 증가하며 overlap, negative time과 gap이 없다.
- pause gap 제거는 T24 범위다. T06은 전달받은 accepted PCM을 연속 미디어 타임라인으로 저장할 뿐 pause UI/state를 구현하지 않는다.

### 2.4 start, append, flush, stop 의미

공개 계약의 정확한 타입 이름은 기존 code style에 맞게 조정할 수 있지만 아래 의미를 고정한다.

- `start`
  - idle에서만 허용한다.
  - scoped write access를 획득하고 session/recovery layout과 collision을 검증한다.
  - writer/input/fragment/output setting을 구성하고 `startWriting`과 media session start가 성공한 뒤에만 성공을 반환한다.
  - 부분 실패 시 만든 자원을 정리하고 scope를 해제하되 생성된 destination은 보존한다.
- `append`
  - running에서만 허용한다.
  - chunk validation, ordering, conversion, writer readiness와 append status를 확인한다.
  - 성공 반환은 해당 chunk의 변환 가능한 PCM이 writer에 순서대로 제출됐다는 뜻이다. 디스크의 다음 fragment가 물리적으로 power-loss durable하다는 뜻은 아니다.
- `flush`
  - 지금까지 recorder가 accepted한 application-level conversion/append work를 순서대로 drain하는 barrier다.
  - writer status와 pending typed failure를 확인하지만 input을 finished로 만들거나 recording을 종료하지 않는다.
  - file-backed AVAssetWriter가 제공하지 않는 arbitrary fragment/fsync 보장을 주장하지 않는다.
  - `AVAssetWriter.flushSegment()`를 호출하지 않는다.
- `stop`
  - 새 append를 차단하고 이미 accepted한 work와 converter tail을 drain한다.
  - writer input을 정확히 한 번 `markAsFinished`하고 `finishWriting` completion을 await한다.
  - writer status가 `.completed`인지 확인하고 요약을 반환한 뒤 scope를 해제한다.
  - 실패 시 typed error/event를 확정하고 scope를 해제하며 recovery file은 그대로 둔다.

추가 lifecycle 규칙:

- 최소 의미는 idle, starting, recording, stopping, completed/failed다. internal state여도 deterministic test가 가능해야 한다.
- concurrent start 두 개가 같은 destination을 두 번 열지 않는다.
- append/flush/stop은 하나의 직렬화 owner에서 order가 보장된다.
- idle append/flush/stop, start 중 stop, stop 중 append, completed 후 start 재사용 여부를 명시한다. 하나의 recorder instance를 재사용할 수 있다면 새 session state가 이전 state와 섞이지 않아야 한다.
- 정상 stop의 반복 호출은 같은 완료 summary를 반환하는 idempotent 동작 또는 stable already-stopped result 중 하나로 명시한다. 두 번째 호출이 파일을 다시 finish하거나 scope를 두 번 해제해서는 안 된다.
- failed 뒤 호출은 최초 terminal error를 잃지 않고 cleanup은 반복하지 않는다.
- audio chunk가 하나도 오지 않은 채 stop돼도 hang하거나 playable file을 만들었다고 거짓 성공하지 않는다. AVAssetWriter가 empty asset을 완료하지 못하면 stable `noAudioSamples` 또는 동등한 typed result로 끝내고 생성된 file은 보존한다.
- Swift task cancellation이 발생해도 writer/scope를 방치하지 않는다. cancellation을 오디오 파일 삭제로 처리하지 않는다.
- cancellation cleanup을 위해 `AVAssetWriter.cancelWriting()`을 사용하지 않는다. caller task가 cancelled여도 별도의 structured cleanup 경계에서 가능한 finish/status 확인과 scope release를 끝낸다.
- deinit에만 finish 또는 scope release를 의존하지 않는다.

### 2.5 오디오 저장과 STT의 독립성

- T06은 `CaptureHandle.recordingPCM`의 consumer가 될 수 있는 contract를 제공한다. `speechPCM`을 읽거나 STT consumer의 존재를 요구하지 않는다.
- T06 test는 synthetic recording stream만 recorder에 전달하며 STT stream을 생성·drain하지 않아도 모든 PCM이 저장됨을 증명한다.
- T06 recorder가 느릴 때 자체 unbounded queue로 문제를 숨기지 않는다. 가능하면 append 호출 자체가 readiness를 기다리며 upstream의 기존 bounded recording stream이 backpressure를 드러내게 한다.
- writer가 따라가지 못해 T05 recording stream이 overflow하면 T05의 `recordingBackpressure`가 보존돼야 한다. T06이 frame을 버려 capture를 성공처럼 유지하면 안 된다.
- 반대로 STT drop, delay, cancellation과 failure는 recorder를 중단시키면 안 된다.
- T06이 microphone capture를 직접 start/stop하거나 capture terminal error를 session outcome으로 결정하지 않는다. T07 coordinator가 capture와 recorder lifecycle을 조합한다.

## 3. 계층과 공개 계약

T01의 단일 app target 안 논리 경계를 유지한다.

- Domain: 기존 persisted session/event 값과 artifact ownership. transient writer/framework 타입을 추가하지 않는다.
- Application: framework-independent recorder protocol, lifecycle/result/error/event와 recording PCM orchestration contract
- Infrastructure: AVAssetWriter/AVAudioConverter adapter, security-scoped output lease, sample buffer 제작과 실제 file write
- App: 필요하면 side-effect-free factory만 구성한다. 앱 시작/view construction으로 writer나 file이 열리면 안 된다.
- Features: T07 전에는 recording UI를 추가하지 않는다.

Application 계약은 최소 다음 책임을 표현한다.

1. `AudioRecorder` 또는 동등한 protocol
   - session location과 capture generation을 고정하는 start
   - ordered `PCMChunk` append
   - barrier 의미의 flush
   - finish 결과를 주는 stop
2. `AudioRecorderState` 또는 test 가능한 lifecycle 의미
3. `AudioRecorderSummary`
   - session/location 식별 또는 recovery artifact 식별
   - written output frame count
   - media duration milliseconds
   - fixed output format description
   - raw URL은 포함하지 않음
4. `AudioRecorderErrorCode`와 typed error
5. `AudioRecorderEvent`
   - terminal failure의 stable code
   - `.fileWriteError` 또는 `.storageAccessError`로 persist할 수 있는 session-event 의미
   - 필요한 경우 마지막 안전한 media position

다음 경계를 지킨다.

- Application과 Domain의 새 공개 파일에 `AVFoundation`, `AVFAudio`, `AudioToolbox`, `CoreMedia`를 import하거나 그 타입을 노출하지 않는다.
- Application API에 `URL`, file descriptor, `AVAssetWriter`, `AVAudioConverter`, `CMSampleBuffer`, `CMTime`, `NSError`를 노출하지 않는다.
- 기존 T03의 Feature-to-Infrastructure directory selection `URL` 예외를 T06으로 확대하지 않는다.
- recorder protocol/value/error/event는 `Sendable`이다. 값의 비교가 테스트에 필요하면 `Equatable`을 제공한다. runtime PCM이나 writer state를 불필요하게 `Codable`로 만들지 않는다.
- broad `Any`, service locator, global singleton 또는 unchecked sendability로 framework ownership 문제를 숨기지 않는다.
- framework object가 actor isolation과 충돌해 좁은 `@unchecked Sendable` wrapper가 필요하면 executor/lock/lifetime invariant를 주석과 race test로 증명한다.
- `SessionRepository`의 일반 JSON API에 URL escape hatch를 추가하지 않는다.

## 4. security-scoped 저장 접근 lifetime

현재 T03 `StorageRootManager.withAccess`의 synchronous lexical closure는 장시간 asynchronous writer에 그대로 사용할 수 없다. URL을 lexical closure 밖으로 빼고 즉시 `stopAccessingSecurityScopedResource()`한 뒤 녹음을 계속하는 구현은 금지한다.

Infrastructure 안에 다음과 동등한 명시적 lifetime을 추가한다.

- root ID를 resolve하고 stale bookmark를 기존 규칙대로 refresh
- `startAccessing` 성공과 writable directory를 검증
- session folder/recovery directory/destination을 안전하게 resolve
- writer start 전 lease/acquisition 성공
- writer stop, start failure, append failure, cancellation의 모든 terminal path에서 `stopAccessing` 정확히 한 번
- stop completion 전에는 scope를 해제하지 않음
- active root 변경과 관계없이 location의 root ID 사용

구현은 `StorageRootWriteLease`, Infrastructure-only artifact lease/factory 또는 동등한 형태일 수 있다. 단 다음을 지킨다.

- lease나 resolver의 URL은 Infrastructure 내부에서만 보인다.
- caller가 release를 두 번 호출해도 codec stop은 한 번이다.
- release를 잊은 성공 path가 없고 deinit fallback만을 정상 경로로 삼지 않는다.
- startAccessing 실패, stale refresh 실패, root missing/not writable, layout missing과 destination collision을 stable recorder/storage error로 매핑한다.
- T03의 기존 short lexical operation과 read-only catalog scan 의미를 깨지 않는다.
- fake codec test가 start/stop call count와 scope가 writer finish까지 살아 있음을 확인한다.
- acquire 뒤 writer 생성/setting/start 어느 지점에서 실패해도 scope가 누수되지 않는다.

보안 범위를 넓게 전역에서 잡아 앱 lifetime 전체에 유지하는 방식은 사용하지 않는다. 각 active recorder의 실제 file lifetime으로 제한한다.

## 5. AVFoundation writer와 PCM conversion

### 5.1 writer configuration

live adapter는 최소 다음을 명시적으로 설정·확인한다.

- `AVAssetWriter(outputURL:fileType: .mov)`
- audio input 하나
- output settings:
  - `AVFormatIDKey: kAudioFormatMPEG4AAC`
  - `AVSampleRateKey: 48_000`
  - `AVNumberOfChannelsKey: 1`
  - `AVEncoderBitRateKey: 96_000`
- `expectsMediaDataInRealTime = true`
- `movieFragmentInterval = 10s`
- `initialMovieFragmentInterval = 1s`
- writer가 audio input을 add할 수 있는지 확인
- `startWriting()` 반환값과 즉시 status/error 확인
- media session은 output `.zero`에서 한 번 시작

NSError 전체 description을 Application error나 일반 log로 전달하지 않는다. Infrastructure 내부에서 NS/POSIX/AVFoundation error를 inspect해 disk full, access, writer start/append/finish 등 stable code로 보수적으로 매핑한다.

### 5.2 converter와 sample buffer

- `AVAudioConverter` 또는 검증 가능한 Apple audio conversion API를 사용해 converter가 지원하는 source sample rate/channel count의 interleaved Float32를 mono 48k PCM으로 변환한다. 지원하지 않는 valid-looking format은 typed unsupported-format failure로 처리한다.
- converter의 input/output format, interleaving과 buffer frame capacity 계산은 overflow-safe다.
- mono downmix behavior는 AVAudioConverter channel mapping/default mix의 실제 동작을 test fixture로 검증한다. 한 channel만 기록하거나 sample 배열을 잘못 stride하지 않는다.
- converter input block은 같은 source frames를 중복 공급하지 않으며 `.haveData`, `.noDataNow`, `.endOfStream` 의미를 정확히 사용한다.
- resampling fractional remainder와 converter tail이 chunk boundary 때문에 유실되지 않는다.
- output PCM에서 `CMSampleBuffer`를 만들 때 memory ownership이 append 반환 전까지 유효하고 use-after-free가 없다.
- presentation timestamp는 cumulative written output frames / 48,000이고 duration/packet descriptions가 audio format과 일치한다.
- `AVAssetWriterInput.isReadyForMoreMediaData == false`일 때 append를 강행하거나 sample을 drop하지 않는다.
- readiness 대기는 busy spin과 긴 blocking sleep을 피하고 writer failed/cancelled/stopping 상태를 함께 관찰한다. callback/readiness bridge 또는 동등한 bounded mechanism을 사용한다.
- `append`가 false를 반환하면 writer status/error를 확인하고 정확히 한 terminal failure로 전환한다.
- conversion/append pipeline은 chunk 순서를 보존하고 동시에 여러 converter call을 실행하지 않는다.

### 5.3 bounded memory와 장시간 방향

- input 전체 또는 이미 쓴 PCM을 memory에 누적하지 않는다.
- converter/output buffer와 readiness queue는 작고 명시적인 upper bound를 가진다.
- recorder 내부 queue를 둔다면 capacity, overflow 의미와 high-water test가 있어야 하며 overflow는 silent drop이 아니다.
- 테스트용 synthetic long stream은 작은 chunk를 반복해 처리하여 input duration에 비례한 memory 배열을 만들지 않는다.
- T06에서 1~2시간 실제 녹음을 필수 수동 acceptance로 요구하지 않는다. T27이 장시간 실제 측정을 담당하지만, T06 구조는 인위적인 duration limit와 duration-proportional memory를 두지 않는다.

## 6. failure event와 session event 경계

T06는 writer failure를 두 방법으로 같은 terminal 원인에 연결한다.

1. 호출자는 stable `AudioRecorderError`를 throw/receive한다.
2. recorder event stream 또는 동등한 observer는 같은 failure를 정확히 한 번 전달하고, T07이 다음 `SessionEventKind`로 `events.jsonl`에 append할 수 있게 한다.
   - bookmark/root/scope/layout 접근 문제: `.storageAccessError`
   - disk full, writer create/start/append/flush/finish, converter 또는 file I/O 문제: `.fileWriteError`

T06 recorder가 직접 `events.jsonl`을 append하지 않는다. T07이 session ID, wall-clock time, event ID와 ordering을 조합한다. T06 event는 최소 stable detail code와 가능한 media position을 제공한다. 같은 AVAssetWriter failure가 append, status observation과 stop에서 반복 관측돼도 event는 한 번만 발행한다.

최소 error 의미:

- already started/invalid lifecycle
- session layout missing or unsafe
- recovery artifact already exists
- storage root unavailable/reauthorization required/not writable
- unsupported or changed input format
- capture generation mismatch
- PCM sequence discontinuity
- PCM conversion/sample-buffer creation failure
- writer creation/configuration/start failure
- writer readiness/append failure
- disk full 또는 file write failure
- flush barrier failure
- finish failure/cancelled writer
- operation cancellation

정확한 case 이름은 기존 style에 맞춰 조정할 수 있다. 하나의 `.unknown` 문자열로 위 원인을 모두 잃지 않는다. user-facing 한국어 문구 작성은 T07/T25 범위다.

## 7. T07/T08/T09와의 경계

### T06에 포함

- framework-independent recorder 계약과 typed state/error/event/result
- session recovery artifact를 여는 Infrastructure-only scoped lease
- source PCM → mono 48k conversion
- audio-only fragmented MOV writer
- safe start/append/flush/stop와 failure cleanup
- 합성 PCM 기반 실제 file/read/decode/fragment acceptance test
- 후속 coordinator가 연결할 factory/dependency injection point

### T06에서 제외

- microphone permission 요청과 capture 시작을 UI action으로 조합: T07
- session folder/metadata 생성 및 lifecycle 변경: T07
- `events.jsonl`에 실제 recorder event append: T07
- elapsed-time/level/title/start/stop UI: T07
- recovery MOV를 `audio.finalizing.m4a` 또는 `audio.m4a`로 변환: T08
- `workingAudioSecured`와 finalization checkpoint 기록: T08
- final m4a length/start/end decode 검증과 recovery 삭제: T08
- app launch에서 incomplete session scan/recovery: T09
- process crash subprocess matrix와 checkpoint별 반복 복구: T09/T26
- pause/resume와 pause gap 제거 orchestration: T10/T24
- system sleep prevention, window-close/quit policy: T10
- VAD, 16k STT conversion, STT engine/model: T11 이후
- session list/playback/edit UI: T21 이후

T08을 쉽게 만들기 위해 recovery file을 정상 stop에서 지우거나 이름을 `audio.m4a`로 바꾸지 않는다. T06 stop 성공 뒤에도 `audio.recovery.mov`는 그대로 남아야 한다.

## 8. 테스트 가능한 구조와 fault injection

AVFoundation 실제 integration과 deterministic lifecycle test를 분리한다. 최소 다음 seam 또는 동등한 주입점을 둔다.

- writer backend/factory와 status/error mapping
- PCM converter/sample-buffer adapter 중 pure ordering/timeline logic을 검증할 경계
- security-scoped output lease/factory
- readiness scheduling 또는 controlled writer readiness
- recorder event sink/stream

fake writer는 다음을 원하는 call에서 실패시킬 수 있어야 한다.

- create/configure
- startWriting/startSession
- readiness wait
- append N번째
- flush barrier
- mark finished/finish completion

fault seam이 production에 범용 plugin framework를 만들거나 AVFoundation 타입을 Application에 끌어올리면 안 된다. T26의 전체 fault-injection harness를 선행 구현하지 않고 T06 lifecycle을 결정적으로 테스트하는 최소 seam만 둔다.

비동기 테스트는 임의의 긴 sleep에 의존하지 않는다. controlled continuation, expectation, test clock 또는 bounded polling을 사용하고 hang 시 명확한 timeout과 cleanup을 둔다.

## 9. 실제 MOV 검증 원칙

실제 AVFoundation integration test는 temporary session root와 runtime-generated synthetic PCM만 사용한다. 최소 다음을 확인한다.

- output path가 정확히 `recovery/audio.recovery.mov`
- AVURLAsset이 열리고 audio track 정확히 하나, video track 0개
- track format description이 AAC, 48,000Hz, mono
- duration이 입력 PCM duration과 encoder priming을 고려한 작은 tolerance 안에 있음
- AVAssetReader 또는 동등한 방식으로 시작과 끝의 audio sample을 실제 decode 가능
- writer 설정 seam에서 initial 1s/subsequent 10s와 96kbps가 정확히 전달됨
- 충분히 긴 synthetic media를 기록했을 때 file box 구조 또는 동등한 evidence로 fragmented `moof`가 존재하며 여러 fragment가 만들어짐
- writer를 아직 정상 finish하지 않은 active 상태에서도 이미 fragment로 확정된 prefix를 별도 AVURLAsset/reader가 읽을 수 있음
- 그 test 뒤에는 writer를 정상 cleanup하되 “정상 finish된 파일만 읽힌 것”을 interrupted-prefix evidence로 잘못 보고하지 않음

MOV box parser를 test helper로 만든다면 top-level box size, 64-bit extended size, bounds와 malformed input을 안전하게 처리하고 production parser로 승격하지 않는다. exact byte offset나 encoder 내부 box ordering에 과도하게 결합하지 않는다.

T06에서 실제 앱 process를 kill하거나 전원 상실을 흉내 내는 helper executable까지 만들 필요는 없다. process interruption과 최대 10초 목표의 전체 matrix는 T09/T26에서 검증한다. 단, fragment property만 설정하고 실제 output의 fragment/readable prefix evidence를 전혀 확인하지 않는 것은 T06 완료로 충분하지 않다.

## 10. lifecycle과 자원 정리 규칙

- actor 또는 동등한 단일 직렬화 owner가 state, converter, writer, input, lease, sequence와 cumulative frame count를 함께 소유한다.
- AVAssetWriter completion callback을 async로 감쌀 때 continuation을 정확히 한 번 resume한다.
- stop과 writer failure가 race해도 mark finished, finish request, terminal event, scope release는 각각 한 번이다.
- start 중 cancellation/failure는 partially acquired lease/writer를 정리한다.
- append task cancellation이 recorder state를 모호한 running 성공으로 두지 않는다. 현재까지의 file은 보존하고 typed failure/cleanup 정책을 적용한다.
- writer callback이 actor를 강하게 순환 참조해 recorder를 영구 보존하지 않는다.
- stale callback 또는 이전 recording generation의 readiness/finish completion이 새 recording state를 바꾸지 않는다.
- completed summary의 frame count와 duration은 overflow-safe이며 integer millisecond 변환 규칙이 명확하다.
- normal stop에서는 writer completion이 끝나기 전에 lease를 해제하지 않는다.
- failure stop에서도 가능한 writer cleanup을 시도하되 최초 오류를 cleanup 오류로 덮어쓰지 않는다.
- cleanup 실패 때문에 기존 output을 지우지 않는다.

## 11. 개인정보, 파일 안전과 범위 제한

- PCM sample bytes, 실제 녹음 내용, 실제 root path와 full NSError description을 일반 log에 남기지 않는다.
- T25 이전에 범용 file logger, telemetry, crash uploader를 추가하지 않는다.
- network, model download, STT package를 추가하지 않는다.
- system audio capture, USB microphone selector, automatic input fallback을 추가하지 않는다.
- 실제 사용자 root, Application Support runtime data 또는 lecture recording을 test fixture로 사용하지 않는다.
- test가 만든 temp output은 test lifetime에만 cleanup한다. production failure output을 자동 cleanup하는 code path와 혼동하지 않는다.
- `.gitignore`를 약화하거나 broad pattern으로 source/test fixtures까지 숨기지 않는다.
- final `.m4a`와 recovery 삭제/교체를 T06에서 수행하지 않는다.

## 12. 자동 acceptance matrix

구현 전에 아래 각 항목을 test 이름 또는 검증 방법에 매핑하고, 모두 끝날 때까지 같은 세션에서 계속 작업한다.

### 12.1 Application 계약과 계층

1. recorder contract가 `SessionLocation`, expected capture generation, `PCMChunk`로 start/append/flush/stop을 표현한다.
2. summary/error/event/state가 framework-independent `Sendable` value다.
3. Application/Domain에 AVFoundation/CoreMedia/AudioToolbox/URL 타입 누출이 없다.
4. app/main view construction은 writer, file, scope access를 시작하지 않는다.
5. T07 UI/coordinator, T08 finalization, T09 recovery를 선행 구현하지 않았다.

### 12.2 path와 security scope

1. location의 root ID와 fixed artifact path를 사용하고 active root 변경에 redirect되지 않는다.
2. scoped access는 writer start 전 한 번 열리고 asynchronous finish가 완료된 뒤 한 번 닫힌다.
3. start failure, append failure, finish failure와 cancellation 각각에서 scope가 정확히 한 번 닫힌다.
4. release 반복과 stop/failure race에서 codec stop이 중복되지 않는다.
5. stale bookmark refresh와 T03 existing lexical access tests가 계속 통과한다.
6. no root/reauthorization/root missing/not writable가 typed storage failure와 한 event로 매핑된다.
7. session/recovery missing 또는 symlink layout은 실패하고 바깥 path에 file을 만들지 않는다.
8. 기존 recovery file은 overwrite/truncate/delete되지 않고 원래 bytes가 그대로다.
9. writer가 file을 만든 뒤 start/append/finish 실패해도 partial artifact가 남는다.

### 12.3 ordering, conversion과 timeline

1. 48k mono synthetic Float32가 sample order를 유지해 기록된다.
2. 44.1k mono, 48k stereo와 하나 이상의 다른 valid source format이 mono 48k로 변환된다.
3. stereo downmix가 left/right stride를 정확히 사용하고 한 channel을 우발적으로 버리지 않는다.
4. 작은 irregular chunk boundary에서도 converter state/tail이 유지되고 output duration/frame count가 tolerance 안에 있다.
5. generation mismatch는 first invalid append에서 typed terminal failure다.
6. sequence gap, duplicate와 reorder가 silent drop 없이 각각 실패한다.
7. source format change는 새 converter로 몰래 이어 쓰지 않고 실패한다.
8. output PTS가 0부터 monotonic/contiguous하고 negative, overlap, unexpected gap이 없다.
9. chunk가 많아져도 written PCM/history를 누적하지 않고 bounded buffer high-water를 유지한다.
10. stop이 converter tail을 한 번 drain하고 repeated stop이 tail을 중복 append하지 않는다.

### 12.4 실제 fragmented MOV

1. 실제 adapter가 `.mov`, audio input 하나, AAC-LC/mono/48k/96kbps를 구성한다.
2. initial fragment 1s와 subsequent fragment 10s가 startWriting 전에 설정된다.
3. 충분히 긴 synthetic audio의 output에 여러 fragmented movie box가 존재한다.
4. 정상 stop 후 AVURLAsset이 audio-only asset으로 열리고 실제 decode가 가능하다.
5. 시작과 끝부분 sample을 reader로 읽어 truncated/corrupt output이 아님을 확인한다.
6. duration과 format description이 expected tolerance 안에 있다.
7. 정상 finish 전에도 충분히 확정된 fragment prefix를 별도 reader가 읽을 수 있다.
8. recovery file은 stop 성공 후에도 제 위치에 보존되고 final m4a가 생성되지 않는다.

### 12.5 start/append/flush/stop

1. start 성공은 writer configured/start/session-start가 성공한 뒤에만 반환한다.
2. concurrent/repeated start가 writer/file/scope를 중복 생성하지 않는다.
3. append는 running에서만 성공하고 serial order를 보존한다.
4. writer not-ready에서 frame을 drop하거나 append를 강행하지 않고 readiness 후 진행한다.
5. flush는 accepted work barrier이며 recorder를 종료하거나 `flushSegment()`를 호출하지 않는다.
6. stop은 intake close → pending/converter drain → mark finished → finish await → status 확인 → scope release 순서를 지킨다.
7. repeated stop과 stop/failure race가 double finish/double release/event duplication을 만들지 않는다.
8. start → stop → 새 start를 지원한다면 generation, summary, callback과 state가 섞이지 않는다. 지원하지 않는다면 factory가 recorder-per-session을 명확히 보장한다.
9. stale readiness/finish callback이 이후 state를 바꾸지 않는다.
10. zero-sample stop이 hang/false playable success 없이 typed outcome과 single scope release로 끝난다.

### 12.6 fault injection과 event

1. writer create/configure/start failure가 stable error이며 scope cleanup 후 artifact 보존 정책을 따른다.
2. N번째 append failure가 최초 원인, 마지막 media position과 한 개의 `.fileWriteError` event를 낸다.
3. disk-full mapping이 일반 lifecycle error와 구분된다.
4. flush/finish failure가 성공 summary를 반환하지 않는다.
5. root/scope failure는 `.storageAccessError`, writer/converter/file failure는 `.fileWriteError` 의미로 구분된다.
6. 같은 terminal failure를 append, event와 stop에서 다시 관측해도 terminal event는 한 번이다.
7. cleanup에서 추가 오류가 나도 최초 failure를 덮어쓰거나 artifact를 삭제하지 않는다.
8. cancellation이 hang, leaked scope와 false completed state를 만들지 않는다.
9. production failure/cancellation path가 output을 삭제하는 `cancelWriting()`을 호출하지 않음을 fake backend와 실제 partial-file preservation으로 확인한다.

### 12.7 STT 독립성, 회귀와 project

1. synthetic recording PCM만 연결하고 speech/STT consumer를 전혀 만들지 않아도 모든 audio가 저장된다.
2. 별도 STT stream이 느리거나 drop/fail하는 T05 fake scenario가 recorder ordering에 영향을 주지 않는다.
3. recorder 내부 buffer는 bounded이며 slow writer가 silent audio loss로 성공하지 않는다.
4. 기존 T03 storage root/repository와 T05 capture/fan-out tests가 모두 통과한다.
5. unsigned arm64 Debug build와 전체 unit/integration suite가 통과한다.
6. production/test source가 올바른 target membership을 가지며 runtime `.mov`가 Git에 없다.
7. 새 external dependency, network, logging/telemetry와 T07 이후 UI가 없다.

## 13. 수동 검증 문서

실제 microphone과 sandbox root를 CI에서 검증했다고 주장하지 않는다. `docs/DEVELOPMENT.md`에 T06용 재현 가능한 opt-in procedure를 추가한다.

절차는 disposable empty root와 합성 PCM integration test 또는 T07 이후 실제 recording flow를 사용하며 최소 다음을 설명한다.

- 실제 사용자 lecture root가 아닌 test root 선택
- locally signed sandbox build에서 security-scoped access가 writer lifetime 동안 유지되는지 확인
- T07 전에는 production UI로 실제 녹음을 시작할 수 없으므로 T06 자동 synthetic integration test가 현재 acceptance evidence임을 명시
- T07 이후 20초 이상 녹음하고 `recovery/audio.recovery.mov`를 AVFoundation/QuickTime Player로 확인할 방법
- recovery MOV만 생기고 `audio.m4a`는 아직 생기지 않는 것이 T06의 정상 범위임을 명시
- forced quit/crash loss window와 finalization은 T09/T26에서 검증한다는 한계
- 생성된 test recording을 commit하지 않는 주의

현재 T07 UI가 없어서 실제 microphone procedure를 수행할 수 없는 것은 blocker가 아니다. 자동 AVFoundation file test를 실제로 실행하고 manual verification still required로 정확히 보고한다.

## 14. 문서와 project 반영

구현 구조가 확정되면 다음을 갱신한다.

- `docs/ARCHITECTURE.md`
  - Application recorder contract와 Infrastructure AVFoundation adapter
  - source PCM → mono 48k conversion과 cumulative output timeline
  - initial/subsequent fragment policy
  - scoped root lease lifetime과 partial-file preservation
  - typed failure/event와 T07/T08/T09 연결 지점
- `docs/DEVELOPMENT.md`
  - T06 실제/synthetic test command와 수동 확인 절차
  - unsigned CI가 sandbox persistence/physical microphone/process crash를 증명하지 않는 한계
- `Application/BOUNDARY.md`, `Infrastructure/BOUNDARY.md`
  - 실제 공개 경계와 writer/lease 책임
- `LocalLectureSTT.xcodeproj/project.pbxproj`
  - 새 production/test source membership과 필요한 system framework만 반영
- `.gitignore`
  - 현재 정책이 runtime audio를 충분히 차단하지 않을 때만 좁게 보완
- `PROJECT_STATUS.md`
  - `dev` 통합 시 T06 완료, 실제 최종 unit/integration count, 다음 T07, 남은 manual verification 기록
- `IMPLEMENTATION_PLAN.md`
  - `dev` 통합 시에만 T06 checklist를 `[x]`로 변경

문서가 구현보다 앞서 완료를 주장하지 않게 한다. task branch에서 completion condition이 실패하면 `PROJECT_STATUS.md`와 checklist를 완료로 바꾸지 않는다.

## 15. 검증 명령

정확한 scheme과 설정은 실제 project에서 다시 확인한다. 최소 다음을 실행한다.

~~~sh
xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T06-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T06-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
~~~

구현 중에는 새 T06 test class를 targeted 실행해도 되지만 완료 판단 전에는 전체 suite를 실행한다. lifecycle/race test는 여러 번 실행해 순서 의존 flake가 없는지 확인한다. 실제 MOV integration test는 CI에서도 synthetic PCM만으로 실행 가능해야 하고 microphone permission을 요청하지 않는다.

검증 결과에서 다음을 구분한다.

- 실제 test failure
- Swift 6 sendability/data-race warning 또는 error
- AVFoundation encoder unavailable/asset-reader 오류
- known AppIntents metadata skipped 진단
- unsigned build라 실제 security-scoped sandbox persistence와 microphone을 증명하지 못한 한계

실패를 ignore하거나 assertion/tolerance를 의미 없게 넓혀 통과시키지 않는다. active fragmented prefix test가 환경에 따라 실패하면 fragment가 실제로 emit됐는지, writer append가 끝났는지와 asset cache를 조사하고 deterministic bounded synchronization을 추가한다. 필요하면 writer를 finish하기 전에 active file의 byte-for-byte snapshot을 별도 temp path에 만든 뒤 그 interrupted snapshot을 읽어도 된다. 정상 finish 뒤의 파일만 검사하도록 test 의미를 약화하지 않는다.

## 16. commit, push, CI와 dev 통합

완료 조건을 모두 충족한 경우에만 다음 순서를 수행한다.

1. `git status`, 전체 task diff와 `git diff --check`를 검토한다.
2. runtime `.mov`/`.m4a`, logs, DerivedData, 실제 session data와 관련 없는 변경이 없는지 확인한다.
3. T06 관련 경로만 stage한다.
4. Task ID가 포함된 명확한 commit을 만든다. 예: `feat(audio): add fragmented recovery writer (T06)`.
5. `task/t06-fragmented-audio-writer`를 push한다.
6. 해당 task branch의 `macOS CI`가 성공할 때까지 확인한다.
7. 최신 `origin/dev`를 fetch하고 task 시작 이후 다른 commit이 추가됐는지 확인한다.
8. 새 `dev` 변경이 있다면 task branch에 안전하게 반영하고 전체 검증/CI를 다시 수행한다. 임의 overwrite하지 않는다.
9. 최신 local `dev`에서 `--squash`로 검증된 task branch를 merge한다.
10. `PROJECT_STATUS.md`, `IMPLEMENTATION_PLAN.md` checklist와 필요한 architecture/development 문서 갱신을 포함한 하나의 T06 integration commit을 만든다.
11. merge된 `dev`에서 unsigned arm64 Debug build와 전체 test를 다시 실행한다.
12. `dev`를 push하고 정확한 `dev` commit의 CI 성공을 확인한다.
13. `origin/dev` SHA와 local `dev` SHA가 일치하는지 확인한다.
14. 그 뒤에만 local/remote task branch를 삭제한다.

정상 Task에는 PR을 만들지 않는다. `main`을 checkout하여 merge하거나 push하지 않는다.

task branch CI 또는 merge 후 `dev` CI가 실패하면 완료로 보고하지 않는다. 같은 T06 세션에서 원인을 고치고 task branch 검증부터 필요한 단계를 반복한다.

## 17. 완료 조건

다음이 모두 참일 때만 T06을 완료라고 보고한다.

- 2~10장의 file ownership, format, fragment, conversion, lifecycle, scoped access와 failure 계약이 실제 구현에 존재한다.
- 12장 자동 acceptance matrix가 빠짐없이 통과한다.
- output이 실제 audio-only fragmented MOV이고 AAC-LC/mono/48k/96kbps 설정을 사용한다.
- initial 1초/subsequent 10초 설정과 여러 actual fragment/readable active prefix evidence가 있다.
- 44.1k/48k, mono/stereo와 irregular chunks가 stateful conversion을 통과하고 output timeline이 연속적이다.
- sequence/generation/format 위반과 writer failure가 silent loss나 false success가 아니다.
- start부터 asynchronous finish까지 security scope가 유지되고 모든 terminal path에서 정확히 한 번 닫힌다.
- 기존 artifact와 실패한 partial artifact가 삭제·덮어쓰기되지 않는다.
- flush가 허위 durability/fragment 보장을 하지 않고 `flushSegment()`를 오용하지 않는다.
- repeated/concurrent start-stop과 failure/cancellation race에서 double finish, event duplication, scope leak와 hang이 없다.
- STT consumer 없이 recording PCM만으로 audio가 완전하게 저장된다.
- Application/Domain에 AVFoundation/CoreMedia/URL 타입이 누출되지 않는다.
- T07 이후 기능을 선행 구현하지 않았다.
- 전체 unit/integration tests와 unsigned arm64 Debug build가 통과한다.
- synthetic/수동 검증 절차와 CI 한계가 문서화됐다.
- task branch와 merge된 `dev` CI가 성공했다.
- `PROJECT_STATUS.md`, T06 checklist와 관련 architecture/development 문서가 실제 상태와 일치한다.
- `origin/dev`에 verified squash commit이 있고 `main`은 그대로다.

항목 하나라도 불확실하면 `dev`에 merge하지 않는다. 다만 구현 또는 테스트가 아직 덜 끝난 상태는 안전 차단 사유가 아니므로 같은 branch와 세션에서 계속 완료한다.

## 18. 최종 보고 형식

최종 응답은 다음 순서로 구체적으로 보고한다.

1. `T06 상태`: 완료 또는 차단
2. branch와 commit
   - task commit SHA
   - squash된 `dev` commit SHA
   - local/remote 일치 여부
   - `main` 불변 SHA
3. 변경 파일과 핵심 설계
   - Application recorder contract
   - security-scoped output lease lifetime
   - AVAssetWriter/AVAudioConverter 설정
   - ordering/timeline/readiness와 bounded memory
   - partial artifact preservation과 typed event
4. acceptance matrix 결과
   - 각 12.1~12.7 그룹별 test 이름과 결과
5. 실제 MOV evidence
   - codec/sample rate/channel/duration/decode
   - fragment count/structure
   - finish 전 readable prefix 검증 방법과 결과
6. 실제 실행한 build/test 명령과 unit/integration test 개수/결과
7. task branch CI와 `dev` CI run URL/결과
8. 수행한 수동 검증 또는 아직 필요한 절차
9. 명세 이탈 여부
10. 남은 위험과 known diagnostics
11. T07 시작 가능 여부

단순히 “테스트 통과”라고만 쓰지 말고, scoped access lifetime, converter tail, sequence failure, writer fault, fragment/readable prefix와 STT-independent recording을 어떤 자동 test로 증명했는지 연결한다. 정상 finish된 파일만 읽고 crash recovery를 증명했다고 주장하거나, 실제 수행하지 않은 sandbox/microphone/process-crash 검증을 성공했다고 주장하지 않는다.
