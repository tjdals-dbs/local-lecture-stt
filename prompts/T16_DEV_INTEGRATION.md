# T16 Phase 2 — 강의 비교 및 사용자 모델 선택을 dev에 통합

기존 T16 구현 세션에서 실행한다. 저장소는 `/Users/andyoon/stt`이며 권장 설정은 기존의 **Astra / high**다. 이 파일은 독립 검토 후 사용자가 내린 T16 통합 승인이다. 아래 두 문서 보완부터 로컬 squash, 커밋한 dev 검증, push, 해당 커밋 CI 확인, task 브랜치 정리까지 진행한다.

## 1. 승인된 기준과 범위

| 항목 | 독립 검토 및 프롬프트 작성 시점의 값 |
| --- | --- |
| Task 브랜치 | `task/t16-engine-model-comparison` |
| 승인된 소스 | `672ec984574951e407a683f0a84d35983dbba426` |
| 승인 소스의 부모 및 dev | `177152fbc4df848a3dc12d58f41602c6d8e57022` |
| 보호할 main | `38e126f92ac823d29306ea8c1f7703f7060a5818` |
| Task CI | [macOS CI 43706895281](https://github.com/tjdals-dbs/local-lecture-stt/actions/runs/43706895281), 승인된 SHA에서 성공 |

사용자는 공개 한국어 기술 강의를 사용하도록 승인했고 비교 자료를 받은 후 **whisper.cpp + 비양자화 large-v3**를 선택했다. 결정은 `docs/T16_ENGINE_MODEL_DECISION.md`와 `MVP_SPEC.md` 부록 A에 있다. 독립 검토에서 세 강의 각 10분의 PCM을 재현하고 네 후보의 360개 구간을 대조했다. 선택 조합은 90/90개에서 비어 있지 않은 final을 반환했다. 전체 12회 중 8회가 완주했고 다른 후보의 실패 4건은 기록돼 있다. 품질 3개 항목은 미채점이다. 소스 검토 결과는 Xcode 423 unit + 10 integration, Python 4개 통과, SwiftPM CLI 빌드 성공이다. 이 결과와 통합 후 결과를 구분해 보고한다.

이번 승인은 T16에 한정한다. **G1은 Unverified, G2는 별도 판정 대기**로 둔다. T17의 제품 엔진 연결·의존성 정리, main 승격, tag/release, PR은 이번 작업 범위 밖이다.

## 2. 시작점 확인

1. 이 프롬프트와 `AGENTS.md`, `PROJECT_STATUS.md`, `IMPLEMENTATION_PLAN.md`의 T16·G2·통합 절차를 읽는다. 선택 근거는 결정 문서와 명세 9.1·부록 A, 문서 수정 위치는 `docs/DEVELOPMENT.md`의 T16 두 절에서 확인한다.
2. Git 상태·작업 트리·worktree·원격·최근 커밋을 확인하고 fetch한다. 로컬 및 실제 원격의 task/dev/main SHA와 승인 소스의 CI를 확인한다. 기존 사용자 변경 및 미추적 `prompts/T09_FRESH_SESSION_DIAGNOSIS.md`, `prompts/T10_REVIEW_REPAIR.md`를 보존하고 staging에서 제외한다.
3. dev가 위 기준이면 승인된 task tip을 바로 squash한다. 아래 문서 보완은 dev 통합 커밋에 같이 넣어도 된다. dev가 앞섰으면 최신 dev를 기존 task 브랜치에 안전하게 반영하고, 영향받은 검증·전체 테스트·CLI 빌드를 실행하고 그 준비 커밋을 push한 뒤 해당 task SHA의 CI를 확인한다. 검토되지 않은 별도 task 커밋이 있거나 충돌 해소에 모델·추론 동작 변경이 필요하면 해당 차이를 보존하고 독립 검토를 요청한다.

## 3. 통합 커밋에 포함할 문서 보완 두 가지

1. **FFmpeg 재현 환경.** `docs/DEVELOPMENT.md`의 `T16 developer lecture comparison`에서 `compare.py prepare` 예제 가까이에 이 Mac의 조건을 기록한다. 기본 Homebrew FFmpeg/ffprobe가 `libx265.216.dylib`를 못 찾는 경우, 이 Mac에 설치된 x265 4.2를 사용해 성공한 명령을 보여준다. 예: `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/Cellar/x265/4.2/lib python3 tools/t16/compare.py prepare "$SAMPLE_A" 120000 600000 "$R/sample-01"`. 동일한 접두어는 B/C에도 적용된다. 정상 작동하는 환경은 기존 예제를 그대로 사용한다. 해당 설정으로 세 샘플의 원본·PCM 해시와 각 30개 구간표가 기존 결과와 일치했음을 기록한다. 앱 설정, 셸 프로필, Homebrew 설치, CI 변경은 필요 없다.
2. **검토 페이지 링크 집계.** 같은 문서의 `T16 Phase 1 verification` 끝에 있는 `480 local links`를 바로잡는다. 기존 `benchmark-results/t16/lecture.qWMHE5/REVIEW.html`에는 **로컬 파일 참조 456개, 페이지 내부 앵커 15개, 외부 출처 참조 9개로 총 480개**가 있다. HTML의 `href`와 `src` 출현 횟수이며 중복 참조도 포함한다. 로컬 파일 존재와 내부 앵커 대상을 확인하고 외부 출처는 참조 개수로 기록한다. 기존 HTML·채점표·측정 자료는 그대로 보존한다.

## 4. 최신 dev에 로컬 squash하고 완료 기록 갱신

- 최신 dev에서 검증한 task tip을 로컬 squash한다. `PROJECT_STATUS.md`의 현재 위치, 완료 표, 저장소 상태, 인계 항목을 T16 기준으로 갱신한다. 선택한 엔진·모델과 결정 문서를 연결하고, T17에서 제품 적용 예정임을 명시한다. 현재 진행 중 Task 없음, 다음 단계 G2 별도 판정 및 T17 착수 지시 대기, G1 미검증으로 기록한다. 이전 Task의 역사적 인계 기록을 보존한다.
- `IMPLEMENTATION_PLAN.md`에서는 `T16 비교 및 사용자 결정` 체크박스만 완료 처리한다. 이번 통합 기록에는 검토한 원본 및 해당 시 준비 SHA를 쓸 수 있다. 최종 dev SHA·검증 결과·CI URL은 실제 검증 후 전달할 완료 메시지에 기록한다.
- 두 T16 프롬프트 `prompts/T16_ENGINE_MODEL_COMPARISON.md`와 `prompts/T16_DEV_INTEGRATION.md`는 관련 인계 자료로 이 커밋에 포함한다. 원본 강의·PCM·전사·검토 HTML·모델·로컬 실행 결과는 Git에 추가하지 않는다.
- 명시적으로 경로를 stage하고 staged diff와 `git diff --cached --check`를 확인한다. dev 기준이 그대로라면 **승인된 task tip 대비** 추가 차이는 상태 문서·계획 체크박스·개발 문서 두 보완·T16 프롬프트 두 개뿐이다. 승인된 소스 및 최신 dev의 변경이 모두 보존되었는지 확인한 뒤 **dev에 통합 커밋 하나**를 만든다. 예시 메시지는 `feat(stt): record lecture comparison and default model selection (T16)`이다.

## 5. 커밋한 dev 검증

아래 명령은 저장소 루트에서 실행한다. 통합 커밋의 SHA를 먼저 기록하고 실제 빌드·테스트 결과를 수집한다. 새 결과 디렉터리를 사용하며 의존성 캐시는 재사용 가능하다. 예시 캐시가 없으면 기존 핀으로 준비한 캐시를 사용한다.

```sh
t16_out="$(mktemp -d /private/tmp/stt-t16-integration.XXXXXX)"
t16_cache=/private/tmp/stt-t15-validation.Uth8xp
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$t16_cache/DerivedData" -resultBundlePath "$t16_out/CommittedHead.xcresult" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  CODE_SIGNING_ALLOWED=NO build test
xcrun xcresulttool get test-results summary --path "$t16_out/CommittedHead.xcresult"
xcrun xcresulttool get test-results tests --path "$t16_out/CommittedHead.xcresult" > "$t16_out/tests.json"
swift build --scratch-path "$t16_cache/CLI" --disable-automatic-resolution
python3 -B -m unittest discover -s tools/t16 -p 'test_*.py' -v
```

확인할 기준은 Xcode **433개(단위 423 + 통합 10)**, 실패·건너뜀 0개, Python 비교 도구 테스트 **4개**, SwiftPM `stt-benchmark` 빌드 성공이다. 최신 dev가 테스트를 추가했다면 실제 개수와 이유를 쓰고 승인된 테스트가 모두 실행됐는지 확인한다.

엔진·모델 manifest·의존성 핀·오디오 변환·벤치마크·집계 도구가 승인된 소스와 동일하다는 것을 Git diff로 확인하면 검토된 강의 측정값을 재사용한다. 이번 문서 보완을 위해 모델을 다시 받거나 12회 추론을 반복할 필요는 없다. 실행 입력이 달라졌다면 기존 모델과 새 로컬 결과 경로로 영향받은 검증을 다시 하고, 사용자 선택의 근거가 바뀌는 경우 별도 검토를 받는다.

## 6. push, CI, 브랜치 정리, 보고

1. push 직전 검증한 HEAD와 원격 dev를 재확인한다. 새 원격 작업이 있으면 보존해 동기화하고 새 통합 SHA를 다시 검증한다. 정상 push로 dev를 올린다.
2. GitHub Actions의 `headBranch=dev`, `headSha=<방금 push한 SHA>`인 macOS CI가 끝날 때까지 확인한다. 앱 빌드·테스트, CLI 빌드, Python 단계의 성공과 run URL을 기록한다. 실패하면 task 브랜치를 보존하고 원인을 확인한다. 수정 커밋이 필요한 경우 실제 최종 SHA에서 검증을 반복한다.
3. 커밋한 dev 검증과 해당 dev CI가 모두 성공한 뒤 로컬 dev·origin/dev·실제 원격 dev 일치를 확인한다. 로컬/원격 task tip이 실제 통합한 tip과 같고 다른 worktree에서 사용하지 않는지 다시 확인한 뒤 **`task/t16-engine-model-comparison` 하나만** 원격·로컬에서 삭제한다. squash로 `git branch -d`가 거부하면 위 조건을 만족하는 이 로컬 브랜치에 한해 `git branch -D task/t16-engine-model-comparison`을 사용할 수 있다. 새 커밋이 발견되면 보존한다. 삭제 후 실제 원격 및 로컬 ref를 다시 조회하고 main과 기존 미추적 파일도 확인한다.
4. 실제 squash, 커밋한 dev 검증, push, 해당 SHA의 CI 성공 후 `T16 — integrated`로 보고한다. 시작 dev·승인 소스·준비 SHA(해당 시)·최종 dev SHA, 문서 두 수정 결과, 실행 명령과 결과 경로·테스트 수, 강의 결과 재사용 근거, dev CI URL, 로컬/원격 브랜치 정리 결과, G1/G2 상태를 포함한다. 통합 성공 후 정리만 막히면 어느 ref가 왜 남았는지 명시한다. 다음 Task는 별도 지시를 기다린다.
