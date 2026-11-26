# T27 검증 준비와 결과

기준: `ac683f2976bc9396d8868e4312ed5246a2706f87` (T26 dev). 2026-11-26 사용자는 **준비·짧은 검증만 진행하고 장시간 시험은 나중에** 하기로 했다. T27 전체 완료, dev 통합, G4 판정, main 승격과 배포 업로드는 이번 범위가 아니다. G1은 미검증이다.

## 현재 확인한 결과

| 검사 | 결과와 한계 |
| --- | --- |
| 실제 기기 | Apple M4 Pro, 25,769,803,776 bytes (24 GiB), arm64, macOS 26.6.2 |
| 로컬 실행용 Release 빌드 | ad-hoc 서명, Sandbox/마이크/사용자 선택 폴더/bookmark entitlement, 최소 OS 15.0, native 제품 엔진 검사 통과. 실제 GUI 실행·권한 허용·녹음은 미검증 |
| 서명 인증서 | `security find-identity -v -p codesigning`: 유효 identity 0개. ad-hoc 검증은 Developer ID 서명·공증·다른 맥 설치의 통과 근거가 아님 |
| 짧은 오프라인 엔진 시험 | OS `deny network*` 아래 설치된 whisper.cpp + 비양자화 large-v3로 합성 영어 음성 3회 모두 final 반환. 별도 socket probe가 `EPERM`으로 거부됨 |
| 측정값 | 워밍업 제외 2회 RTF 0.121 / 0.117, 추론 시작 후 partial 0.873 / 0.846초, process footprint peak 약 3.47 GiB. 전체 앱·실제 발화 지연·장시간 열/메모리 기준을 대체하지 않음 |
| 저장 연결 | 설치된 모델과 합성 capture를 사용하는 `testT19LiveSpeechReachesUIAndJournalWhileAudioIsPreserved` 재실행 통과. 실제 마이크와 전체 오프라인 GUI 시험은 아님 |
| 외부 자원 관측기 | 샘플을 수집해도 대상 프로세스가 계속 실행되는지, 잘못된/없는 PID를 성공으로 취급하지 않는지, 빌드 도구가 기존 출력 폴더를 보존하는지 3개 자동 검사 통과 |

로컬 증거: `/private/tmp/stt-t27-checks`의 `offline/report.json`, `network-denial.log`, `helpers.log`, `RealModel.xcresult`, `real-model.log`. 실행 앱과 서명 검증은 `/private/tmp/stt-t27-local-app`에 있다. 기존 T14 합성 입력 파일은 사라져 있었으므로 `say`로 새 합성 음성을 생성했다. 기존 강의나 세션은 사용하지 않았다. 파일/모델/음성/실행 결과는 Git에 포함하지 않는다. 임시 폴더는 정리될 수 있으므로 이후 세션에서 존재 여부부터 확인한다.

## 사용자가 나중에 준비할 것

1. 전원 연결, 덮개를 연 맥북, 실제 한국어 강의 음원과 마이크에 입력할 스피커를 준비한다. 화면 꺼짐은 허용하지만 장시간 시험 중 덮개를 닫지 않는다. 시간은 2시간 3회, 4시간 1회이며 여러 날로 나눠도 된다.
2. 아래 앱을 열고 처음 요청되는 마이크 권한을 허용한다. 시험용 루트 폴더(예: Documents 아래 `LocalLectureSTT-Validation`)를 선택한다. 실제 공부 기록과 섞지 않는다.
3. 모델이 없다면 앱 **모델 관리 → large-v3 → 파일 폴더 선택**에서 `/private/tmp/stt-t19-model/source`를 선택한다. 현재 `ggml-large-v3.bin` 3,095,033,483 bytes가 확인됐다. 임시 경로가 사라졌다면 기존 모델 폴더를 선택하거나 명시적으로 다운로드한 후 오프라인 시험을 한다.
4. 첫 시험은 짧게 말하고 종료한 뒤 원음 시작/끝 재생, transcript와 타임스탬프, 편집·재열기를 직접 확인한다. 이 확인 전부터 2시간 시험을 시작하지 않는다.

```sh
open /private/tmp/stt-t27-local-app/LocalLectureSTT.app
```

앱이 macOS 권한/Gatekeeper에서 거부되면 표시된 메시지를 기록한다. 보안 설정을 일괄 해제하거나 quarantine을 재귀 삭제하지 않는다. 자동 서명/공증·인증서 구입은 수행하지 않았다.

## 제가 이어서 맡을 것

- 실행 커밋/모델/언어/입력/전원 조건과 시험 ID를 고정하고 메모리·열 상태 샘플 수집을 시작한다.
- 발화 시작/끝 및 UI 표시 시점, STT 추론 시간과 처리한 오디오, backlog, Stop/필수 저장/마무리 완료 시점을 함께 수집한다. **현재 외부 관측기만으로 이 지연·대기열 수치를 측정할 수 없다.** 첫 장시간 시험 전에 타이밍 관측 경로를 준비하고 짧게 검증해야 한다.
- 종료 후 원음/최종 오디오 길이와 시작·끝 디코딩, journal/canonical/derived, 메타데이터·카탈로그, 반복 복구를 검사하고 결과표를 작성한다.
- 사용자는 시험 시작 준비와 실제 소리·UI 반응 확인을 맡는다. 10시간 동안 계속 화면을 보고 있을 필요는 없지만 입력 공급과 맥북 실행 상태는 유지해야 한다.

## 장시간·오프라인 결과표 (아직 실행하지 않음)

| 명세 | 합격 기준 | 상태 |
| --- | --- | --- |
| 17.1 partial / final | 발화 시작→partial 일반 3초/느린 경우 5초, 발화 끝→final 일반 3초 | Pending: 실제 발화 기준 계측 필요 |
| 17.1 처리량·backlog | RTF ≤ 0.83 목표, 2시간 동안 대기열 지속 증가 없음 | Pending: 짧은 CLI RTF로 통과 처리하지 않음 |
| 17.2 L01 / L02 / L03 | 2시간 연속 녹음 각각 무손실·무충돌·순서/중복/UI 정상 | 모두 Pending |
| 17.2 L04 | 4시간 연속 녹음, 같은 조건 | Pending |
| 17.3 메모리 | 워밍업 후 2시간 증가 ≤ 1GB, 전체 앱 목표 ≤ 12GB, 심각한 메모리 압력 없음 | Pending: 시작/워밍업/종료 지점과 압력 관측 필요 |
| 17.3 열 | 열로 인한 지속적 실시간 미달 없음, 배터리는 기록만 | Pending |
| 17.4 종료 | 필수 저장 ≤ 2초, 2시간 전체 마무리 ≤ 1분 목표; 초과 시 작업 진행 안내 | Pending |
| 17.4 완료 검증 | 재생·길이·시작/끝 decode, canonical/TXT/MD, metadata/catalog | Pending: 실제 장시간 세션 기준 |
| 17.5 엔진·모델 결정 | 사용자 비교·선택 | 기존 G2 결정 유지; 이번에 정확도 재판정하지 않음 |
| 17.6 복구 | T26 자동 근거와 수동 M01–M08 | 자동 근거는 [T26](T26_ACCEPTANCE.md); G1/실기기는 미검증 |
| 17.7 전체 오프라인 | 실행/목록/녹음/STT/pause-resume/마무리/이전 세션/재생-seek/편집/파생 재생성/강제 종료 복구 | 모두 GUI 기준 Pending; 엔진 3회 성공과 구분 |
| 2·18 네트워크·개인정보 | startup의 불필요한 연결 없음, 모델 자동 갱신/원격 전송 없음 | 전체 GUI startup 연결 시도 관측 Pending; network denial 성공만으로 무시도 판정하지 않음 |
| OS·직접 배포 | macOS 15 target/현재 OS, 재현 가능한 설치, 지원 범위/제한 | target·로컬 빌드 확인. macOS 15 실기기·타 Mac 설치·공증 Pending |

T27은 미달/미측정 항목의 원인·영향·조치 또는 사용자가 승인한 기준 변경 없이 완료 처리하지 않는다. 4시간 검증을 하기 전에는 “검증된 연속 녹음 4시간”이라고 표시하지 않는다.

## 재현 명령

새 출력 폴더를 사용한다. 빌드 helper는 기존 폴더 또는 저장소 내부를 거부하며 앱을 자동 실행하거나 업로드하지 않는다. 생성 앱은 로컬 시험 전용이다.

```sh
bash tools/t27/prepare_local_app.sh /private/tmp/stt-t27-local-app /private/tmp/stt-t15-validation.Uth8xp/DerivedData
swiftc -O tools/t27/ProcessMonitor.swift -o /private/tmp/stt-t27-checks/process-monitor
python3 -B tools/t27/test_validation_tools.py --monitor /private/tmp/stt-t27-checks/process-monitor
swift build --scratch-path /private/tmp/stt-t15-validation.Uth8xp/CLI --disable-automatic-resolution
```

자원 관측기는 `proc_pid_rusage`의 physical footprint/resident bytes/CPU raw counter 및 시스템 thermal state를 JSONL로 기록한다. PID 시작 시각이 바뀌거나 읽기 실패하면 비정상 종료하며 다른 프로세스를 관측하지 않는다. 앱에 신호를 보내거나 내용을 읽지 않는다. 샘플 종료는 T27 통과를 뜻하지 않는다. CPU raw 값은 시간 단위를 변환하지 않았으므로 CPU 사용률로 보고하면 안 된다. 메모리 압력·backlog·UI 지연·오디오 누락은 별도 관측 대상이다.

```sh
# PID를 실제 실행 중인 LocalLectureSTT 프로세스 번호로 바꾼다.
# 2시간 동안 5초 간격. 새 파일만 생성하여 기존 결과를 보존한다.
( set -C; /private/tmp/stt-t27-checks/process-monitor PID 7200 5 > /private/tmp/stt-t27-checks/L01-resources.jsonl )
```

실제로 실행한 짧은 엔진 검사:

```sh
say -v Samantha -r 155 -o /private/tmp/stt-t27-checks/speech.aiff 'This local lecture explains how neural networks learn from examples and why careful validation matters in practical applications.'
afconvert -f WAVE -d LEF32@16000 -c 1 /private/tmp/stt-t27-checks/speech.aiff /private/tmp/stt-t27-checks/speech.wav
/private/tmp/stt-t15-validation.Uth8xp/CLI/debug/stt-benchmark prepare /private/tmp/stt-t27-checks/speech.wav /private/tmp/stt-t27-checks/input.json t27-synthetic-local 'T27 local synthetic speech smoke; no lecture recording'
sandbox-exec -f tools/t14/offline.sb /usr/bin/python3 -c 'import socket; s=socket.socket(); s.connect(("127.0.0.1",9))'
# 위 probe는 EPERM 실패가 기대 결과이며 다음 명령의 성공과 구분한다.
sandbox-exec -f tools/t14/offline.sb /private/tmp/stt-t15-validation.Uth8xp/CLI/debug/stt-benchmark run tools/t15/candidate.json /private/tmp/stt-t19-model/store /private/tmp/stt-t27-checks/input.json /private/tmp/stt-t27-checks/offline english
TEST_RUNNER_LLSTT_T19_MODEL_STORE=/private/tmp/stt-t19-model/store TEST_RUNNER_LLSTT_T19_SPEECH_F32=/private/tmp/stt-t19-work/speech.f32 xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/stt-t15-validation.Uth8xp/DerivedData -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -resultBundlePath /private/tmp/stt-t27-checks/RealModel.xcresult -only-testing:LocalLectureSTTIntegrationTests/RecordingSessionFileIntegrationTests/testT19LiveSpeechReachesUIAndJournalWhileAudioIsPreserved -test-timeouts-enabled YES -default-test-execution-time-allowance 180 CODE_SIGNING_ALLOWED=NO build test
```

`RealModel.xcresult`와 report 출력 디렉토리는 재실행 시 새 이름을 쓴다. XCTest와 CLI의 입력은 합성 음성이며 물리 마이크를 사용하지 않는다. 로컬 앱 ad-hoc 빌드는 권한 요청을 없애거나 배포용 서명을 대체하지 않는다. Developer ID/공증 여부는 실제 공유 범위가 정해질 때 결정한다.
