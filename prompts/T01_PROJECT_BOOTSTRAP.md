# T01 실행 프롬프트 — macOS 프로젝트와 모듈 경계 생성

## 역할

당신은 `/Users/andyoon/stt` 저장소의 **T01만 담당하는 구현 세션**이다. 확정된 V00 문서 기준선 위에 빌드·테스트·실행 가능한 macOS 앱 셸과 초기 구조를 만들고, 검증에 성공한 경우에만 `dev` 통합과 최초 `main` 기준선 생성까지 완료하라.

T02의 도메인 모델이나 실제 녹음·STT 기능은 구현하지 않는다. 제품 동작이나 명세를 임의로 바꾸지 말고, T01 범위를 완료하는 데 필요한 최소 구조만 만든다.

## 목표

성공 시 다음이 모두 참이어야 한다.

- macOS 15 이상, Apple Silicon 전용 `LocalLectureSTT` SwiftUI 앱 프로젝트가 존재한다.
- 빈 앱 셸이 실행되어 단일 메인 창을 표시하고, macOS 설정 화면을 열 수 있다.
- App Sandbox, 마이크 입력, 사용자 선택 파일 읽기·쓰기 entitlement가 프로젝트에 설정되어 있다.
- 마이크 권한 설명 문자열이 앱 번들 설정에 존재한다.
- App, Domain, Application, Infrastructure, Features의 책임 경계가 실제 소스 트리와 아키텍처 문서에 드러난다.
- 단위 테스트와 통합 테스트를 추가할 수 있는 별도 test target이 있고 현재 smoke test가 통과한다.
- 로컬의 재현 가능한 Debug build와 test 명령이 문서화되고 실제로 통과한다.
- Apple Silicon GitHub Actions에서 같은 build와 test가 통과한다.
- T01 결과가 하나의 squash commit으로 `dev`에 통합되어 있다.
- 최초 `main`이 검증된 `dev`와 정확히 같은 commit에서 생성되어 원격에 push되어 있다.
- `dev`와 `main`의 원격 CI가 통과한다.
- 실제 오디오 캡처, STT, 모델 관리, 세션 저장 기능은 존재하지 않는다.

## 허가된 외부 변경

완료 조건을 모두 충족하는 경우에 한해 다음을 허가한다.

- `task/t01-project-bootstrap` 브랜치 생성과 push
- 검증된 task branch를 로컬에서 squash merge하여 `dev` push
- 최초 `main` 브랜치를 검증된 `dev`와 동일한 commit에서 생성하고 push
- GitHub 저장소의 기본 브랜치를 `main`으로 변경
- task branch, `dev`, `main`의 GitHub Actions 실행과 결과 확인
- `dev`와 `main`이 안전하게 push되고 CI까지 통과한 뒤 T01 task branch 삭제

Pull Request, tag, GitHub Release, 모델·의존성 다운로드, 저장소 공개 범위 변경, branch protection 변경, secret 생성은 허가하지 않는다. `main` 생성은 T01 검증 완료 전에는 금지한다.

## 반드시 먼저 읽을 컨텍스트

다음 순서와 범위로 읽어라.

1. 이 프롬프트 전체
2. `AGENTS.md` 전체
3. `PROJECT_STATUS.md` 전체
4. `IMPLEMENTATION_PLAN.md`
   - 2장 실행 원칙
   - 5.2~5.7절 Git 및 GitHub 정책
   - `T01. macOS 프로젝트와 모듈 경계 생성`
   - 9장 전체 진행 체크리스트
5. `MVP_SPEC.md`
   - 2장 대상 환경과 지원 범위
   - 5장 화면 구조
   - 8장 기술 구조
6. 실제 Git 상태와 현재 파일

관련 문서가 서로 충돌하면 임의로 하나를 선택하지 말고 안전한 상태에서 중단하여 충돌과 권장 해결안을 보고하라.

## 현재 알려진 기준선

다음은 프롬프트 작성 시점의 정보일 뿐이며 반드시 실제 상태로 다시 확인한다.

- 작업 디렉터리: `/Users/andyoon/stt`
- 현재 branch: `dev`
- V00 완료 commit: `5bf8a05483d054dd7713e1ee7665b8d4bb4f8c13`
- 최신 `dev`에는 이 T01 프롬프트를 추가한 조정 문서 commit이 뒤따를 수 있음
- 원격: `https://github.com/tjdals-dbs/local-lecture-stt.git`
- 원격 branch: `dev`만 존재
- `main`: 아직 없음
- working tree: clean
- 전체 Xcode 앱: 발견되지 않음
- 활성 developer directory: `/Library/Developer/CommandLineTools`
- `xcodebuild -version`: 전체 Xcode가 없어 실행 불가
- 설치된 Swift CLI: Swift 6.3.2, arm64 target
- GitHub CLI는 설치되어 있지만 저장된 `tjdals-dbs` 인증은 유효하지 않은 상태였음

대화나 이 목록보다 새 세션에서 확인한 실제 결과를 우선한다.

## 1. 사전 점검과 중단 조건

파일을 수정하거나 task branch를 만들기 전에 다음을 확인한다.

- `pwd`
- `git status --short --branch`
- `git remote -v`
- local 및 remote branch
- 최근 commit
- local `dev`, `origin/dev`, 원격 `dev` HEAD 일치 여부
- 예상하지 않은 tracked·untracked 파일이나 사용자 변경 존재 여부
- `sw_vers`, `uname -m`, `xcode-select -p`, `xcodebuild -version`, `swift --version`
- 전체 Xcode 설치 경로와 license/초기 구성 상태

다음 조건이면 **어떤 프로젝트 파일이나 branch도 만들지 말고** 중단한다.

- 전체 Xcode가 설치되어 있지 않음
- Xcode license 또는 필수 component 설치가 완료되지 않아 `xcodebuild`를 사용할 수 없음
- 현재 branch가 `dev`가 아니거나 working tree가 clean하지 않음
- local `dev`, `origin/dev`, 실제 원격 `dev`가 일치하지 않음
- 예상하지 않은 `main` 또는 T01 branch가 이미 존재함
- 원격 URL이나 V00 기준선이 예상과 다름
- T01과 겹치는 사용자 변경이 있음

전체 Xcode가 설치되어 있지만 `xcode-select`만 Command Line Tools를 가리키는 경우에는 우선 명령별 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 사용을 검토한다. 시스템 전역 developer directory 변경, Xcode 설치, license 동의는 사용자 승인 없이 수행하지 않는다.

중단 시 정확히 무엇이 부족한지, 사용자가 완료해야 할 최소 조치, 조치 후 다시 실행할 확인 명령을 보고한다. 불완전한 프로젝트를 먼저 만들어 두지 않는다.

## 2. 고정 프로젝트 결정

별도 충돌이 발견되지 않는 한 다음 값을 사용한다.

| 항목 | 값 |
| --- | --- |
| 프로젝트 파일 | `LocalLectureSTT.xcodeproj` |
| 앱 target 및 product | `LocalLectureSTT` |
| shared scheme | `LocalLectureSTT` |
| 앱 표시 이름 | `Local Lecture STT` |
| 앱 bundle identifier | `io.github.tjdals-dbs.LocalLectureSTT` |
| 단위 테스트 target | `LocalLectureSTTTests` |
| 통합 테스트 target | `LocalLectureSTTIntegrationTests` |
| 최소 macOS | 15.0 |
| 지원 아키텍처 | arm64만 |
| UI | SwiftUI |
| 언어 모드 | 프로젝트가 지원하는 안정된 Swift 6 모드 |
| 프로세스 | 단일 프로세스 |

외부 project generator, 서드파티 package, CocoaPods, Homebrew dependency를 추가하지 않는다. native `.xcodeproj`, shared scheme, source, tests와 설정을 저장소에 직접 추적한다. 코드 서명에 특정 개인 Development Team이나 인증서를 저장소에 고정하지 않는다.

## 3. 앱 프로젝트와 최소 UI 셸

- macOS App target을 만든다.
- `WindowGroup`으로 새 메인 창을 계속 만들 수 있게 하지 말고, SwiftUI `Window` scene을 사용해 하나의 메인 창만 제공한다.
- 별도의 SwiftUI `Settings` scene을 추가한다.
- 메인 창에는 앱 이름과 현재가 초기 프로젝트 셸임을 알 수 있는 최소 placeholder만 표시한다.
- 설정 화면에도 최소 placeholder만 표시한다.
- UI shell은 접근 가능한 기본 SwiftUI control과 text를 사용하되, 본격적인 디자인 시스템이나 feature navigation을 만들지 않는다.
- 창 닫기 후 백그라운드 작업, 자동 종료, 녹음 확인 대화상자 등은 T10 범위이므로 구현하지 않는다.

## 4. Sandbox와 권한 설정

앱 target에 추적 가능한 entitlement 파일을 두고 최소 다음을 명시한다.

- `com.apple.security.app-sandbox = true`
- `com.apple.security.device.audio-input = true`
- `com.apple.security.files.user-selected.read-write = true`

앱의 Info 설정에는 사용자에게 의미가 분명한 한국어 `NSMicrophoneUsageDescription`을 둔다. entitlement 파일이 실제 app target의 Debug와 Release 설정에 연결되는지 확인한다.

T01에서는 마이크를 열거나 파일 선택 패널을 띄우지 않는다. 권한 요청과 security-scoped bookmark 구현은 각각 후속 Task에서 한다. 네트워크 entitlement, telemetry, cloud, 자동 crash upload는 추가하지 않는다.

## 5. 책임 경계와 소스 구조

최소한 다음 책임이 디렉터리 또는 group 구조로 드러나게 한다.

- `App`: composition root, scene과 앱 생명주기 진입점
- `Domain`: 프레임워크 비의존 핵심 타입과 규칙
- `Application`: use case, coordinator, 저장소·엔진 추상화의 orchestration
- `Infrastructure`: AVFoundation, 파일 시스템, SQLite, 모델 엔진 같은 외부 구현
- `Features`: 화면과 사용자 상호작용 단위

T01에서는 컴파일 가능한 앱 셸에 필요한 파일만 만든다. 빈 경계를 Git에 남겨야 한다면 짧은 경계 설명 문서나 비기능 marker를 사용할 수 있지만, T02 이후의 도메인 타입, protocol, repository, coordinator를 미리 발명하지 않는다.

초기에는 단일 app target 안의 논리적 경계여도 된다. 이 경우 compile-time module 분리가 아직 없음을 `docs/ARCHITECTURE.md`에 솔직하게 기록한다. 의존 방향은 다음을 목표로 문서화한다.

```text
App → Features → Application → Domain
App → Infrastructure → Application/Domain
Domain → 다른 앱 계층에 의존하지 않음
```

라이브러리 고유 타입을 Domain이나 이후 엔진 경계에 노출하지 않고, 단일 프로세스 내부의 비동기 컴포넌트를 추후 XPC 또는 별도 프로세스로 옮길 수 있게 한다는 명세상 방향만 기록한다. 아직 해당 추상화나 XPC를 구현하지 않는다.

## 6. 테스트 target

- `LocalLectureSTTTests`와 `LocalLectureSTTIntegrationTests`를 shared scheme의 Test action에 포함한다.
- 각 target에 최소 하나의 결정론적 smoke test를 둔다.
- 단위 smoke test는 프로젝트의 최소 순수 앱 타입 또는 값이 예상대로 동작하는지만 검증한다.
- 통합 smoke test는 앱 모듈을 link/import하고 root SwiftUI view를 구성할 수 있음을 검증한다.
- 실제 앱 launch가 필요한 수동 검증은 별도로 수행한다. T01을 위해 불안정한 UI automation 체계를 크게 만들지 않는다.
- 테스트용 production API나 T02 도메인 모델을 억지로 추가하지 않는다.

## 7. 문서

### `docs/ARCHITECTURE.md`

실제로 생성한 구조만 기준으로 다음을 기록한다.

- target과 source tree
- 각 계층의 책임과 허용된 의존 방향
- 현재는 단일 프로세스라는 점
- 논리적 경계인지 compile-time module인지
- AppKit·IOKit·AVFoundation을 Infrastructure 또는 필요한 adapter에 제한할 방향
- T01에서 의도적으로 구현하지 않은 항목

### `docs/DEVELOPMENT.md`

직접 실행하여 검증한 값과 명령만 기록한다.

- 필요한 전체 Xcode 버전과 확인 방법
- 필요한 경우 `DEVELOPER_DIR` 사용법
- 프로젝트와 shared scheme 이름
- Debug build 명령
- 전체 test 명령
- 앱을 Xcode 또는 빌드 산출물에서 실행하는 절차
- arm64 및 deployment target 확인 방법
- CI workflow와 runner 설명
- 코드 서명 또는 로컬 실행 시 알려진 제한

### 기존 문서

- `README.md`의 현재 상태를 “실행 가능한 초기 앱 셸”에 맞게 최소 갱신하고 개발 문서 링크를 추가한다.
- T01이 `dev`에 통합될 준비가 된 시점에만 `PROJECT_STATUS.md`를 T01 완료와 T02 준비 상태로 갱신한다.
- `IMPLEMENTATION_PLAN.md`에서는 T01 체크박스만 완료로 바꾼다.
- 제품 명세 `MVP_SPEC.md`는 변경하지 않는다.

## 8. 로컬 빌드와 검증

정확한 명령은 실제 project와 scheme에 맞춰 문서화하되, 최소 다음 형태를 사용한다.

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

프로젝트 경로, scheme 또는 signing 특성 때문에 안전한 인자가 더 필요하면 실제로 검증한 명령으로 조정하고 이유를 문서화한다. build와 test를 같은 repository state에서 실행한다.

추가로 다음을 확인한다.

- `xcodebuild -list`에서 app과 두 test target, shared scheme 확인
- build setting에서 `MACOSX_DEPLOYMENT_TARGET = 15.0` 확인
- app executable이 arm64임을 `file` 또는 `lipo -archs`로 확인
- source entitlement plist의 문법과 필수 key 확인
- 가능한 로컬 서명 build에서는 최종 app bundle의 적용 entitlement 확인
- `git diff --check`
- 새 compile warning이나 test warning이 없는지 확인
- `.gitignore`가 DerivedData와 build 결과를 제외하고 source, tests, project, shared scheme, entitlement를 숨기지 않는지 확인

## 9. 수동 실행 검증

자동 build와 test만으로 완료 처리하지 않는다. 동일 commit의 Debug 앱을 실제로 실행하여 다음을 확인한다.

- 앱이 crash 없이 실행됨
- 메인 창이 하나 표시됨
- 앱 메뉴에서 설정 화면을 열 수 있음
- 메인 창에 최소 placeholder가 보임
- 추가 메인 창을 생성하는 일반 UI가 없음
- 앱을 정상 종료할 수 있음

검증에 사용한 Xcode 버전, macOS 버전, 실행 방법과 결과를 최종 보고와 `docs/DEVELOPMENT.md`에 기록한다. 스크린샷은 필수가 아니다.

## 10. GitHub Actions

`.github/workflows/macos-ci.yml`을 추가한다.

- `push`의 `task/**`, `dev`, `main`에서 실행
- 필요하면 수동 `workflow_dispatch` 허용
- 현재 공식 Apple Silicon 표준 label인 `macos-15` 사용
- checkout 후 Xcode·Swift·architecture를 로그에 출력
- 로컬에서 검증한 것과 동등한 unsigned arm64 Debug build와 test 실행
- signing secret이나 개인 Development Team을 요구하지 않음
- 외부 formatter, project generator, package cache action을 T01에서 추가하지 않음
- build product, DerivedData, app binary를 저장소에 commit하지 않음

`macos-latest` 대신 명세의 최소 OS와 아키텍처가 분명한 `macos-15`를 사용한다. GitHub 공식 runner 문서상 이 label은 현재 arm64 macOS 표준 runner를 가리킨다. CI 로그에서도 `uname -m`이 `arm64`인지 확인한다.

참고: <https://docs.github.com/en/actions/reference/runners/github-hosted-runners>

## 11. 명시적 제외 범위

- T02 도메인 모델, JSON schema와 상태 머신
- 루트 저장 폴더 선택과 security-scoped bookmark 저장
- SQLite 또는 session repository
- 마이크 캡처, 입력 레벨, 녹음과 오디오 파일 생성
- 실제 권한 요청 흐름
- STT engine, 모델 catalog, 모델 다운로드 또는 dependency
- 세션 목록, 녹음 화면 등 본격적인 MVP UI
- 창 닫기·앱 종료·잠자기 정책 구현
- 시스템 오디오, USB 마이크 선택, Obsidian, cloud 등 후속 기능
- 다중 process 또는 XPC 구현
- telemetry, 자동 update, 자동 crash upload
- icon과 시각 디자인 polish
- tag, release, PR, signing·notarization·배포 패키지

확장을 명분으로 사용하지 않는 protocol, generic plugin framework, service locator를 만들지 않는다.

## 12. commit, CI, `dev` 통합

1. 모든 사전 점검을 통과한 뒤 최신 `dev`에서 정확히 `task/t01-project-bootstrap`을 만든다.
2. 구현과 문서화를 마치고 전체 local diff와 `git diff --check`를 검토한다.
3. build, test, 수동 실행 검증이 모두 통과한 경우에만 T01 관련 경로를 명시적으로 stage한다.
4. task branch commit 메시지는 다음을 사용한다. 논리적인 중간 commit이 필요하면 1~3개 범위에서 모두 T01을 표시한다.

```text
chore(project): bootstrap macOS app (T01)
```

5. task branch를 push하고 해당 branch의 GitHub Actions가 통과했는지 run URL 또는 run ID와 함께 확인한다.
6. CI가 실패하면 같은 구현 세션에서 T01 범위 안의 원인을 수정하고 다시 검증한다. CI를 확인할 수 없거나 실패 상태면 `dev`에 병합하지 않는다.
7. merge 직전 원격 `dev`가 branch 생성 기준선 이후 예상 밖으로 변경되지 않았는지 확인한다. 변경됐다면 덮어쓰지 말고 안전하게 최신 `dev`에 맞춘 뒤 전체 검증을 다시 한다.
8. 모든 완료 조건이 충족되면 local `dev`에서 `git merge --squash task/t01-project-bootstrap`을 수행하고 다음 제목으로 하나의 commit을 만든다.

```text
chore(project): bootstrap macOS app (T01)
```

9. merge된 `dev`에서 build, test, 수동 실행 검증을 다시 수행한다.
10. 검증된 `dev`를 push하고 `dev` CI 통과를 확인한다.

commit 전에 녹음, 모델, DB, log, credential, build product, 개인 Xcode 상태가 stage되지 않았는지 반드시 확인한다. 하나라도 완료 조건이 불확실하면 task branch까지만 보존하고 `dev`로 병합하지 않는다.

## 13. 최초 `main` 생성

이 절은 **T01이 `dev`에 통합되고 local 검증과 `origin/dev` CI가 모두 통과한 경우에만** 수행한다.

1. 검증된 local `dev`, `origin/dev`와 원격 `dev` SHA가 같은지 확인한다.
2. 기존 local/remote `main`이 여전히 없는지 확인한다.
3. 최초 `main`을 정확히 그 `dev` commit에서 생성한다. 최초 기준선에는 별도 merge commit을 만들지 않는다.
4. `main`을 `origin`에 push한다.
5. local `dev`, local `main`, `origin/dev`, `origin/main`이 모두 같은 SHA인지 확인한다.
6. `main` CI 통과를 확인한다.
7. 인증된 GitHub UI 또는 CLI/API가 있으면 저장소 기본 브랜치를 `main`으로 변경하고 결과를 다시 확인한다.
8. 기본 브랜치 변경 권한이나 인증만 없다면 이미 push된 branch를 되돌리지 말고, 사용자가 수행할 정확한 수동 절차를 보고한다. 이 경우 코드 기준선 완료와 저장소 설정 미완료를 구분하여 판정한다.
9. 최종 작업 branch는 `dev`로 돌아오고 working tree가 clean이어야 한다.

최초 `main` 생성 이후의 `dev → main` 승격부터는 구현 계획의 `--no-ff` gate merge 정책을 따른다. T01에서 tag나 release를 만들지 않는다.

## 14. 완료 조건

다음 항목을 전부 근거와 함께 확인해야 완료다.

- [ ] 전체 Xcode preflight 통과
- [ ] native macOS SwiftUI app project와 shared scheme 존재
- [ ] macOS 15.0, arm64-only 설정 확인
- [ ] 단일 main `Window`와 `Settings` scene 실제 실행 확인
- [ ] Sandbox, microphone, user-selected read/write entitlement 연결 확인
- [ ] 마이크 사용 설명 문자열 확인
- [ ] 책임별 source 경계와 실제 구조 문서화
- [ ] unit 및 integration test target과 smoke test 통과
- [ ] local Debug build 통과
- [ ] local 전체 test 통과
- [ ] local 수동 app launch 통과
- [ ] GitHub Actions task branch 통과
- [ ] T01 체크리스트와 상태 문서 갱신
- [ ] squash commit 하나로 `dev` 통합
- [ ] merge된 `dev` build, test, 수동 실행 재검증 통과
- [ ] `origin/dev` CI 통과
- [ ] 최초 `main`이 검증된 `dev`와 동일 SHA로 생성·push됨
- [ ] `origin/main` CI 통과
- [ ] working tree clean
- [ ] T02 이후 기능이나 사용자 runtime 데이터가 포함되지 않음

## 15. 최종 보고 형식

다음 순서로 간결하지만 검증 가능하게 보고한다.

1. T01 상태: 완료 또는 차단
2. 사전 환경
   - macOS, architecture, Xcode와 Swift 버전
3. branch와 commit
   - task commit
   - squash된 `dev` commit
   - `dev`/`main` local 및 remote SHA
4. 생성·수정한 파일
5. 실제 target, scheme, source 경계와 핵심 설계 결정
6. entitlement와 deployment/architecture 확인 결과
7. 실행한 local build·test 명령과 결과
8. 수동 앱 실행 검증 결과
9. task branch, `dev`, `main` CI run과 결과
10. GitHub 기본 브랜치 변경 결과
11. 명세 또는 프롬프트에서 벗어난 사항
12. 남은 위험과 수동 확인 사항
13. 승인되지 않은 파일이나 후속 기능이 포함되지 않았다는 확인
14. T02 시작 가능 여부

완료 조건을 모두 충족할 때까지 같은 구현 세션에서 T01 범위 안의 문제를 해결한다. Xcode 부재, CI 미확인, build/test 실패, 수동 실행 실패가 남아 있으면 완료라고 보고하거나 `dev`/`main`으로 진행하지 않는다.
