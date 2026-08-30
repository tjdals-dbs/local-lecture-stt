# T03 실행 프롬프트 — 파일 저장소와 루트 폴더 권한

## 역할

당신은 `/Users/andyoon/stt` 저장소의 **T03만 담당하는 새 구현 세션**이다. T02에서 확정한 세션 도메인 DTO 위에 사용자가 선택한 저장 루트의 App Sandbox 권한 관리, 안전한 세션 디렉터리와 파일 저장소, 원자적 JSON 쓰기와 append-only JSONL 쓰기를 구현하고 검증하라.

T04의 SQLite 카탈로그, 실제 녹음·오디오 파일 생성, STT, transcript compact 및 파생 파일 생성은 구현하지 않는다. 파일이 원본이라는 제품 안전 원칙을 실제 저장 경계에서 지키되 다음 작업의 동작을 미리 구현하지 않는다.

## 목표

성공 시 다음이 모두 참이어야 한다.

- 사용자가 `NSOpenPanel`에서 하나의 디렉터리를 선택하고, 앱이 read/write app-scoped security-scoped bookmark를 Application Support에 보존한다.
- 활성 루트를 변경해도 이전 루트의 안정적인 식별자와 bookmark가 남으며, 새 세션은 활성 루트에만 생성된다.
- 앱 재실행을 가정해 저장된 bookmark를 다시 읽고 `.withSecurityScope`로 URL을 resolve한 뒤 접근을 시작하고 종료할 수 있다.
- stale bookmark는 resolve된 URL로 새 bookmark를 만들고 안전하게 교체하며, resolve 또는 접근 실패는 명시적인 재승인 필요 결과가 된다.
- bookmark에서 얻은 security-scoped URL을 실제 파일 작업 동안만 사용하고, 성공한 `startAccessingSecurityScopedResource()` 호출은 반드시 `stopAccessingSecurityScopedResource()`와 짝을 이룬다.
- 세션 폴더 이름은 `YYYYMMDD-HHMMSS_<short-session-id>`이고 생성 후 제목 변경과 무관하게 불변이다.
- 서로 다른 세션 ID는 같은 시각·같은 제목이어도 충돌하지 않으며, 기존 세션 폴더를 재사용하거나 덮어쓰지 않는다.
- 세션 폴더와 `recovery/` 레이아웃을 만들 수 있고, 모든 파일 경로는 앱이 정의한 artifact 이름으로만 생성된다.
- `SessionRepository`가 authoritative/canonical/recovery 파일과 재생성 가능한 derived 파일을 명시적으로 구분한다.
- JSON 교체는 대상과 같은 디렉터리에 임시 파일을 쓰고 flush한 뒤 atomic rename하는 순서를 지키며, rename 전 실패는 기존 정상 파일의 bytes를 바꾸지 않는다.
- JSONL writer는 인코딩이 끝난 한 레코드와 LF 하나만 append하고 flush하며 기존 bytes를 truncate 또는 rewrite하지 않는다.
- 루트 접근 실패, session ID 불일치, 파일 충돌과 쓰기 실패가 typed error 또는 동등한 명시적 결과로 전달되고 원본을 자동 삭제하지 않는다.
- 임시 디렉터리와 주입 가능한 bookmark/file-system 경계를 사용한 결정론적 테스트가 있다.
- 최소한의 최초 루트 선택·변경·재승인 UI 경로가 실제 앱 composition에 연결되어 있다.
- 기존 앱 build와 전체 test suite가 통과한다.
- 검증된 T03 결과가 하나의 squash commit으로 `dev`에 통합되고 `dev` CI가 통과한다.
- `main`은 변경하거나 승격하지 않는다.

## 허가된 외부 변경

완료 조건을 모두 충족하는 경우에 한해 다음을 허가한다.

- `task/t03-file-repository-root-permission` 브랜치 생성과 push
- task branch의 GitHub Actions 실행과 결과 확인
- 검증된 task branch를 로컬에서 squash merge하여 `dev` push
- merge된 `dev`의 GitHub Actions 실행과 결과 확인
- `dev`가 안전하게 push되고 CI까지 통과한 뒤 T03 task branch 삭제
- 수동 검증에서 사용자가 직접 선택한 테스트용 빈 디렉터리 아래에 합성 세션 폴더와 작은 합성 JSON/JSONL 파일 생성

Pull Request, `main` 변경·push·승격, tag, GitHub Release, branch protection 변경, 저장소 공개 범위 변경, 외부 dependency 설치, 네트워크 runtime, 사용자 기존 세션의 이동·삭제·덮어쓰기는 허가하지 않는다.

테스트와 수동 검증에는 실제 강의, 실제 transcript, 모델 파일을 사용하지 않는다. 임시 테스트 산출물, bookmark store, Application Support 내용, session root를 Git에 포함하지 않는다.

## 반드시 먼저 읽을 컨텍스트

다음 순서와 범위로 읽어라.

1. 이 프롬프트 전체
2. `AGENTS.md` 전체
3. `PROJECT_STATUS.md` 전체
4. `IMPLEMENTATION_PLAN.md`
   - 2장 실행 원칙
   - 5.2~5.7절 Git 및 GitHub 정책
   - `T03. 파일 저장소와 루트 폴더 권한`
   - T04의 T03 의존 범위만 확인
   - 8장 작업별 프롬프트 작성 규칙
   - 9장 전체 진행 체크리스트
5. `MVP_SPEC.md`
   - 4.1절 최초 실행
   - 8.1절 기본 기술과 8.3절 `SessionRepository`
   - 12장 저장 구조와 데이터 소유권
   - 13장 파일 스키마
   - 16.1절의 저장 루트·파일 오류와 16.2절 안전 우선순위
6. `docs/ARCHITECTURE.md`와 `docs/DEVELOPMENT.md`
7. 실제 Git 상태, entitlements, Xcode project, T02 Domain DTO, 현재 앱 composition/UI와 tests

관련 문서가 서로 충돌하거나 아래 계약으로는 원본 보존을 보장할 수 없다면 임의로 완화하지 말고 안전한 상태에서 중단하여 충돌, 데이터 위험, 권장 선택지를 보고하라. 전체 명세와 계획을 불필요하게 다시 읽지 않는다.

## 현재 알려진 기준선

다음은 프롬프트 작성 시점의 정보이며 새 세션에서 실제 상태로 다시 확인한다.

- 작업 디렉터리: `/Users/andyoon/stt`
- 현재 장기 branch: `dev`
- T02 완료 기준선: `ee0ee3118d0c659a17feb0ceba8bcd94cfa10a95`
- 이 프롬프트 문서 commit이 위 기준선 뒤의 `dev`에 추가되어 있을 수 있음
- 원격: `https://github.com/tjdals-dbs/local-lecture-stt.git`
- 저장소 공개 범위: private
- GitHub 기본 branch: `main`
- `origin/main`: T01 실행 기준선 `38e126f92ac823d29306ea8c1f7703f7060a5818`
- app target은 macOS 15+, arm64, Swift 6, 단일 프로세스 SwiftUI 앱임
- App Sandbox와 `com.apple.security.files.user-selected.read-write` entitlement가 이미 있음
- app-scoped bookmark 사용에 필요한 `com.apple.security.files.bookmarks.app-scope` entitlement는 아직 없음
- T02 Domain에는 schema v1의 `SessionMetadataDocument`, `TranscriptDocument`, `TranscriptJournalRecord`, `SessionEventRecord`, `FinalizationCheckpointDocument`가 있음
- 현재 `Infrastructure`와 `Application`에는 boundary 문서만 있고 실제 파일 I/O는 없음
- 메인 창과 Settings는 placeholder이며 실제 루트 선택 UI는 없음
- T02 기준 Domain 테스트 17개, app shell unit test 1개, integration smoke test 1개가 있음
- Xcode 26.6의 AppIntents metadata 경고는 알려진 비차단 toolchain 진단임

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
- 현재 unsigned arm64 Debug build와 전체 test 실행 가능 여부
- app target이 실제로 사용하는 entitlements와 `CODE_SIGN_ENTITLEMENTS`

working tree가 clean하고 local `dev`가 최신 `origin/dev`와 일치하는 것을 확인한 뒤 정확히 다음 branch를 만든다.

```text
task/t03-file-repository-root-permission
```

필요하면 먼저 `git fetch origin`, `git switch dev`, `git pull --ff-only origin dev`를 사용한다. 기존 동명 branch나 예상하지 않은 변경·분기가 있으면 덮어쓰거나 삭제하지 말고 조사한 뒤 안전하게 중단하여 보고한다. force push, destructive reset, checkout/clean을 통한 사용자 변경 폐기는 금지한다.

## 2. 계층과 책임 경계

T01의 단일 app target 안 논리 경계를 유지한다.

- `Domain`: 저장 루트 ID, session artifact 의미처럼 프레임워크 비의존 값과 규칙만 둔다. 기존 T02 DTO를 파일 API에 맞추기 위해 변형하거나 Foundation URL/AppKit 타입에 의존시키지 않는다.
- `Application`: `SessionRepository`, 루트 접근 결과와 앱 use case가 사용할 protocol/값 경계를 둔다. AppKit panel, bookmark API와 구체적인 `FileManager`를 노출하지 않는다.
- `Infrastructure`: Application Support bookmark store, Foundation security-scoped bookmark adapter, atomic writer, JSONL writer와 file-backed repository를 둔다.
- `Features`: 최초 선택, 활성 루트 변경, 재승인을 위한 최소 SwiftUI 상태와 사용자 동작만 둔다.
- `App`: live dependency composition만 담당한다.

다음 원칙을 지킨다.

- built-in Swift/Foundation/AppKit만 사용하고 외부 package를 추가하지 않는다.
- `NSOpenPanel`과 UI 갱신은 `@MainActor` 경계 안에서 수행한다.
- persistence와 access orchestration은 actor 또는 동등한 직렬화 경계로 data race와 같은 파일에 대한 동시 write/append interleaving을 막는다.
- actor 밖으로 mutable `FileHandle`, 열린 security scope 또는 비-Sendable 상태를 노출하지 않는다.
- 필요한 경계 값과 오류는 `Sendable`, 비교가 필요한 테스트 값은 `Equatable`로 만든다.
- `@unchecked Sendable`, `Any`, `[String: Any]`, 전역 singleton, service locator로 동시성과 의존성 문제를 숨기지 않는다.
- URL과 실제 file operation은 Infrastructure 안에 제한한다. 표시용 path 문자열을 나중에 URL로 다시 만들어 권한을 우회하지 않는다.
- 테스트할 수 있도록 bookmark 생성/resolve/access, Application Support 위치, 시계·시간대, 파일 작업 또는 fault point를 필요한 최소 범위에서 주입한다.
- 사용하지 않는 범용 virtual file system, migration framework, plugin 구조를 만들지 않는다.

구현 중 더 안전하고 단순한 이름 또는 파일 분할을 선택할 수 있지만 위 의존 방향과 동작 계약은 유지한다. 추가한 production/test source가 실제 target에 포함됐는지 확인한다.

## 3. 저장 루트 식별자와 bookmark registry

활성 루트와 과거 루트를 경로 문자열만으로 관리하지 말고 UUID 기반의 안정적인 앱 고유 `StorageRootID` 또는 동등한 식별자를 정의한다. 최소 registry 상태는 다음 의미를 표현해야 한다.

- registry 자체의 `schemaVersion: 1`
- `activeRootId`: 아직 선택 전이면 없음
- root entry 목록
  - 안정적인 root ID
  - app-scoped security-scoped bookmark `Data`
  - UI 안내를 위한 마지막 확인 display name과 path
  - 생성/갱신 시각 또는 동등한 관리 정보

Application Support 아래 앱 전용 디렉터리에 registry를 저장한다. 정확한 파일명은 Swift 관례에 맞게 정하되 `docs/ARCHITECTURE.md`에 기록하고, JSON을 사용한다면 T02와 같은 명시적 schema-version 검증 및 atomic writer를 적용한다. bookmark bytes는 Codable `Data`의 안정적인 표현으로 저장할 수 있다. `UserDefaults`나 선택한 사용자 루트 안에 bookmark registry를 두지 않는다.

동작 규칙:

- 첫 선택은 새 root ID와 bookmark를 만들고 active로 지정한다.
- 다른 루트를 선택해 active를 바꾸면 기존 entry와 bookmark를 보존하고 새 세션만 새 active root를 사용한다.
- 이미 등록된 동일 루트를 다시 선택한 경우 무의미한 중복 entry를 만들지 않고 해당 entry의 bookmark와 표시 정보를 갱신한 뒤 active로 지정한다.
- 특정 과거 root의 재승인은 그 root ID를 유지한 채 사용자가 명시적으로 고른 URL로 bookmark를 교체한다.
- active root 변경 또는 재승인은 기존 세션 디렉터리를 이동·복사·삭제하지 않는다.
- 선택 panel 취소는 registry와 active root를 전혀 바꾸지 않는다.
- registry decode 또는 schema 검증 실패 시 손상된 registry를 정상 빈 상태로 간주해 덮어쓰지 않는다. 명시적 오류를 반환하고 원본 파일을 보존한다.
- bookmark의 마지막 path/display name은 UI 안내용일 뿐 file access authority가 아니다.
- bookmark `Data`나 전체 registry 내용을 로그에 출력하지 않는다.

## 4. App Sandbox와 security-scoped access

app target entitlement에 다음을 추가하고 기존 Sandbox 및 user-selected read/write entitlement를 유지한다.

```text
com.apple.security.files.bookmarks.app-scope = true
```

document-scoped bookmark entitlement나 read-only bookmark를 대신 사용하지 않는다. 선택한 루트 전체에 세션 파일을 생성하고 갱신해야 하므로 app-scoped read/write bookmark를 사용한다.

실제 adapter는 다음 수명 규칙을 지킨다.

1. `NSOpenPanel`은 디렉터리 하나만 선택하도록 구성한다.
   - `canChooseDirectories = true`
   - `canChooseFiles = false`
   - `allowsMultipleSelection = false`
2. 선택 URL에서 `.withSecurityScope` app-scoped bookmark를 만들고 registry에 atomic 저장한다.
3. 저장 bookmark는 `.withSecurityScope` 옵션으로, UI 없이 resolve한다.
4. resolve가 실패하거나 `startAccessingSecurityScopedResource()`가 `false`이면 해당 root를 `reauthorizationRequired` 또는 동등한 명시적 상태로 반환한다.
5. `startAccessingSecurityScopedResource()`가 성공한 경우 `defer` 또는 동등한 구조로 모든 성공·실패·취소 경로에서 정확히 한 번 `stopAccessingSecurityScopedResource()`를 호출한다.
6. scope는 실제 repository operation 동안만 유지한다. 앱 전체 수명 동안 무기한 열어두지 않는다.
7. `bookmarkDataIsStale == true`이면 resolve된 security-scoped URL에서 새 bookmark를 만들고 registry의 같은 root entry를 atomic하게 갱신한다. 갱신 실패를 조용히 무시하거나 기존 registry를 손상시키지 않는다.
8. resolve된 URL이 디렉터리이고 접근 가능한지 확인한 뒤에만 파일 작업 closure를 실행한다.
9. 접근을 얻지 못한 경우 세션 폴더 생성, JSON temp file 생성, JSONL open 등 어떠한 사용자 루트 mutation도 먼저 수행하지 않는다.

호출자가 `start`/`stop`을 직접 맞추게 하지 말고 `withAccess(to:)` 같은 lexical closure/operation API 또는 동등하게 누수하기 어려운 설계를 사용한다. security-scoped URL에서 얻은 path 문자열로 새 URL을 만들어 scope를 잃지 않는다.

접근 결과는 최소 다음을 구분한다.

- 아직 루트가 선택되지 않음
- 정상 접근 가능
- 저장 bookmark가 stale하여 갱신됨
- bookmark 누락·손상·resolve 실패
- security scope 시작 실패
- root가 없거나 디렉터리가 아님
- bookmark registry 읽기/갱신 실패
- 사용자의 재승인 필요

Foundation/AppKit의 원래 error를 내부 원인으로 보존할 수 있지만 Application/UI 경계에는 안정적인 typed code와 사용자에게 설명 가능한 상태를 제공한다. 재승인 가능한 경우 치명적 일반 오류로 뭉개지 않는다.

현재 SDK 동작을 확인할 때는 다음 Apple 공식 문서를 우선한다.

- [Enabling Security-Scoped Bookmark and URL Access](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access)
- [NSURL — Bookmarks and Security Scope](https://developer.apple.com/documentation/foundation/nsurl)
- [NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel)

## 5. 최초 선택, 변경, 재승인 UI

T03에서는 최종 세션 UI를 만들지 않지만 저장 루트 기능이 실제 앱에서 도달 가능해야 한다.

- 앱 시작 시 registry를 읽고 active root 복원을 시도한다.
- active root가 없으면 메인 창의 기존 placeholder 안에서 저장 폴더가 필요하다는 상태와 사용자가 누를 수 있는 선택 동작을 제공한다.
- 앱이 실행되자마자 panel을 자동으로 띄우지는 않는다. 사용자의 명시적 버튼 동작으로 연다.
- active root가 정상이면 최소한 선택된 폴더의 display name 또는 path와 접근 가능 상태를 표시한다.
- Settings에서 active root 변경 동작을 제공한다.
- 접근 실패 시 `재승인 필요` 상태와 해당 root를 다시 선택할 수 있는 동작을 제공한다.
- panel 취소, resolve 중, 저장 중, 실패 상태를 구분하고 앱이 멈추거나 panel을 중복 표시하지 않게 한다.
- 과거 root의 전체 목록/세션 목록을 완성된 제품 UI로 만들 필요는 없지만 Application 상태에서는 보존되고 T04가 사용할 수 있어야 한다.
- UI 문자열은 최소한으로 유지하고 T21의 최종 화면을 선행 구현하지 않는다.
- 기존 view 구성 integration test는 live Application Support나 panel을 건드리지 않는 fake/in-memory dependency로 갱신한다.

실제 AppKit panel adapter와 상태 모델을 분리하여 unit test에서 panel을 열지 않고 승인·취소·오류 흐름을 검증한다.

## 6. 세션 폴더 이름과 레이아웃

세션 폴더 이름 생성은 순수하고 결정론적인 값 규칙으로 둔다.

```text
YYYYMMDD-HHMMSS_<short-session-id>
```

- 날짜/시각은 session의 생성 절대 시각을 생성 당시 사용자의 로컬 calendar/time zone으로 포맷한다.
- short ID는 `SessionID` UUID의 하이픈을 제거한 canonical 문자열 앞 8자를 소문자로 사용한다.
- 사용자 제목, 강의명, 원문 문자열을 폴더 이름에 넣지 않는다.
- 한 번 계산해 생성한 폴더 이름은 metadata 제목 변경 또는 root 변경으로 바꾸지 않는다.
- formatter 의존성은 locale/calendar/time zone에 따라 숫자 형태가 흔들리지 않게 고정하고 테스트에서는 time zone을 주입한다.

세션 생성 시 active root 바로 아래에 세션 디렉터리와 그 아래 `recovery/`를 만든다. T03에서는 최종 파일이나 recovery 파일의 빈 placeholder를 만들지 않는다. 이후 작업이 필요할 때 다음 고정 artifact만 앱 정의 경로로 접근할 수 있게 한다.

```text
metadata.json
audio.m4a
transcript.json
transcript.txt
transcript.md
events.jsonl
recovery/audio.recovery.mov
recovery/transcript.journal.jsonl
recovery/finalization.checkpoint.json
```

경로 규칙:

- session folder와 artifact path는 raw 사용자 상대경로를 받지 않고 typed artifact enum/값에서 계산한다.
- 표준화한 결과가 선택 root/session folder 밖으로 벗어날 수 없어야 한다.
- 같은 session folder가 이미 있으면 기존 내용을 정상 새 세션으로 간주하거나 덮어쓰지 말고 collision 오류를 반환한다. 생성 후의 기존 JSON 문서는 아래 atomic replacement 계약에 따라서만 갱신한다.
- 세션 폴더 생성 중 일부 단계가 실패하면 이미 존재할 수 있는 폴더나 파일을 자동 삭제하지 않고 실패를 보고한다.
- 동일 제목·동일 초에 서로 다른 session ID로 만든 두 폴더가 충돌하지 않아야 한다.
- 같은 session ID와 생성 시각을 다시 신규 생성하려는 호출은 기존 폴더를 재사용하지 않고 명시적으로 거부한다.

## 7. SessionRepository 계약과 데이터 소유권

Application에서 사용할 `SessionRepository` protocol과 Infrastructure의 file-backed 구현을 만든다. 메서드 이름과 분할은 구현에 맞게 조정할 수 있지만 최소 다음 책임을 명시적으로 제공한다.

- active root와 명시된 historical root에서 scoped operation 수행
- session directory 생성 및 이미 존재하는 session 충돌 거부
- typed artifact URL 내부 해석
- T02 JSON document의 atomic write/read
  - `SessionMetadataDocument`
  - `TranscriptDocument`
  - `FinalizationCheckpointDocument`
- T02 JSONL record append
  - `SessionEventRecord` → `events.jsonl`
  - `TranscriptJournalRecord` → `recovery/transcript.journal.jsonl`
- 파일 존재/누락과 decode/write 오류를 typed 결과로 전달
- artifact가 authoritative/canonical/recovery인지 derived인지 질의 가능한 분류

분류 의미는 다음과 같다.

- authoritative/canonical 또는 recovery source:
  - `metadata.json`
  - `audio.m4a`
  - `transcript.json`
  - `events.jsonl`
  - `recovery/audio.recovery.mov`
  - `recovery/transcript.journal.jsonl`
  - `recovery/finalization.checkpoint.json`
- derived, 다시 생성 가능:
  - `transcript.txt`
  - `transcript.md`

`audio.m4a`와 recovery audio는 T03에서 만들거나 검사하지 않지만 파일 의미 분류에는 포함한다. derived 파일도 T03에서 render하거나 write하지 않는다.

안전 규칙:

- 쓰려는 document/record의 `sessionId`가 대상 session과 다르면 파일을 열기 전에 거부한다.
- `transcript.json`과 derived 파일을 서로 역수입하거나 자동 동기화하지 않는다.
- 읽기 실패를 빈 문서로 해석해 원본을 덮어쓰지 않는다.
- schema decode 실패, 파일 손상, missing을 서로 가능한 범위에서 구분한다.
- repository는 SQLite를 갱신하거나 catalog를 소유하지 않는다.
- repository는 사용자의 path 문자열을 public API에 받아 임의 파일을 열지 않는다.
- repository operation은 루트 security scope 획득에 성공한 뒤에만 실제 파일 시스템에 접근한다.
- 오류가 난 원본·부분 파일을 자동 삭제하거나 정상 데이터로 대체하지 않는다.

## 8. 원자적 JSON 쓰기

모든 교체형 JSON 문서와 bookmark registry에 재사용할 수 있는 작은 atomic writer를 구현한다.

필수 순서:

1. 최종 JSON `Data`를 메모리에서 완전히 encode한다.
2. 대상 파일과 **같은 디렉터리**에 충돌하지 않는 앱 소유 임시 파일을 exclusive하게 생성한다.
3. 모든 bytes를 쓴다. short write 가능성을 처리한다.
4. file contents를 `FileHandle.synchronize()`/`fsync` 또는 현재 SDK의 동등한 API로 flush한다.
5. handle을 닫는다.
6. 같은 volume 안에서 atomic rename으로 destination을 생성 또는 교체한다.
7. 필요하고 지원되는 범위에서 parent directory metadata도 동기화하되, 명세보다 약한 동작을 조용히 선택하지 않는다.

`Data.write(options: .atomic)` 한 줄에 의존하려면 위 flush와 기존 파일 보존 의미가 현재 SDK에서 충족됨을 근거와 테스트로 입증해야 한다. 그렇지 않으면 명시적인 temp/write/sync/rename 경계를 구현한다.

실패 규칙:

- encode 실패 시 destination과 filesystem을 변경하지 않는다.
- temp 생성·write·flush·close 실패 시 기존 destination bytes를 바꾸지 않는다.
- rename 직전 fault를 주입해도 기존 정상 JSON이 그대로여야 한다.
- rename 성공 전에는 destination을 먼저 삭제하거나 truncate하지 않는다.
- writer가 만든 고유 temp 파일만 안전한 경우 best-effort 정리할 수 있다. destination, 알 수 없는 temp, 기존 session 파일은 삭제하지 않는다.
- 교체 실패와 temp cleanup 실패를 숨기지 않되 기존 원본 보존을 최우선으로 한다.

테스트에서 각 단계 전체를 mock할 필요는 없지만 최소한 rename 전 결정론적 fault point 또는 동등한 주입 경계를 제공하여 기존 파일 불변을 검증한다. 성공 경로에서는 새 JSON을 decode해 입력 DTO와 동일함을 확인한다.

## 9. append-only JSONL writer

JSONL append는 atomic replacement와 다른 계약으로 구현한다.

- record를 파일을 열기 전에 한 줄 JSON `Data`로 완전히 encode한다.
- encoded record 내부에는 실제 LF/CR 구분자가 없어야 하며 마지막에 LF 하나만 붙인다.
- 파일이 없으면 생성하고, 있으면 끝으로 이동해 bytes를 append한다.
- 기존 bytes를 truncate, rewrite 또는 compact하지 않는다.
- append 후 file contents를 flush한다.
- 같은 파일에 대한 동시 append를 actor 또는 동등한 직렬화로 보호하여 record bytes가 서로 섞이지 않게 한다.
- append 실패가 발생해도 기존 파일을 삭제하거나 앞부분을 되돌려 쓰지 않는다. 부분 trailing record가 생길 가능성을 숨기지 말고 명시적 오류를 반환하며, 이후 복구/검증은 T20/T26 범위로 남긴다.
- pretty-printed multi-line JSON을 JSONL에 쓰지 않는다.

`SessionEventRecord`와 `TranscriptJournalRecord`를 실제로 여러 개 append한 합성 테스트에서 각 line을 독립 decode하고 순서와 기존 bytes 보존을 검증한다. encode 실패는 파일을 열기 전에 발생하여 기존 bytes가 완전히 같아야 한다. 가능한 경우 동시 append 후 모든 line이 온전한 JSON record인지도 검증한다.

## 10. 오류 모델과 원본 보존

최소 다음 오류 의미를 호출자가 구분할 수 있어야 한다.

- no active root
- reauthorization required
- bookmark registry corrupt/unsupported
- bookmark create/resolve/refresh 실패
- security scope access 실패
- root missing/not directory/not writable
- session directory collision 또는 layout creation 실패
- artifact missing
- session ID mismatch
- JSON encode/decode 실패
- temp create/write/flush/rename 실패
- JSONL append/flush 실패

오류 문자열 비교에 동작을 의존하지 않는다. underlying `Error`를 보존하더라도 stable category/code를 함께 둔다. UI에는 루트 재승인과 일반 파일 오류를 구분해 전달한다.

어떤 오류에서도 다음을 하지 않는다.

- 접근 권한을 얻기 전에 사용자 root를 probe하기 위한 파일 생성
- 기존 정상 JSON을 먼저 삭제하거나 빈 파일로 truncate
- 손상되거나 decode할 수 없는 파일을 자동 빈 문서로 교체
- 접근할 수 없는 historical root나 session을 자동 삭제
- 일부 생성된 session/recovery data를 자동 정리
- derived 생성 실패를 이유로 canonical/recovery 원본 삭제

## 11. 자동 테스트와 수동 검증

결정론적 테스트는 `LocalLectureSTTTests`에 추가하고 실제 panel이나 사용자의 실제 폴더에 의존하지 않는다. 임시 디렉터리, 합성 T02 DTO, fake bookmark codec/access client와 fault injection을 사용한다.

최소 자동 테스트:

### Root registry와 bookmark

- 최초 선택이 schema v1 registry와 active root를 저장함
- 두 번째 다른 root 선택이 첫 root entry를 보존하고 active만 변경함
- 동일 root 재선택이 중복 entry를 만들지 않음
- 특정 historical root 재승인이 root ID를 유지함
- panel 취소가 registry를 변경하지 않음
- 새 manager/store instance가 같은 Application Support fixture에서 active 및 historical root를 복원함
- stale bookmark resolve가 같은 root ID의 bookmark를 갱신함
- unsupported/corrupt registry가 자동으로 빈 registry로 덮어써지지 않음
- resolve 또는 start-access 실패가 reauthorization-required 결과를 내고 repository file operation을 실행하지 않음
- 성공한 access가 operation 성공/throw 양쪽에서 정확히 한 번 stop됨

### Session layout와 repository

- 고정 time zone/date/session ID가 정확한 `YYYYMMDD-HHMMSS_a1b2c3d4` 형태를 만듦
- 동일 제목·시각과 서로 다른 ID가 서로 다른 폴더를 만듦
- 제목이 폴더명에 들어가지 않고 이후 제목 변경과 무관함
- session 및 `recovery/`만 만들고 빈 최종 artifact를 만들지 않음
- 기존 동일 session folder 충돌이 원본을 변경하지 않음
- 모든 typed artifact가 명세의 정확한 상대 경로와 source/derived 분류를 가짐
- 대상 session과 document/record session ID 불일치가 파일 생성 전에 거부됨
- metadata/transcript/checkpoint write 후 동일 DTO read round-trip
- missing과 corrupt/unsupported document 오류 구분

### Atomic JSON과 JSONL

- 새 JSON write 및 기존 JSON 교체 성공
- rename 전 주입 실패에서 기존 destination bytes가 동일함
- temp/write/flush 실패가 기존 destination을 truncate하지 않음
- temp 파일이 destination과 같은 디렉터리에 생성됨
- event 여러 개 append 후 각 line이 독립 `SessionEventRecord`로 decode됨
- transcript journal 여러 개 append 후 각 line이 독립 `TranscriptJournalRecord`로 decode됨
- 두 번째 append가 첫 record bytes를 보존함
- encode 실패가 기존 JSONL bytes를 변경하지 않음
- 동시 append를 지원한다면 모든 line이 섞이지 않고 decode됨

### UI/Application 경계

- no-root, available, reauthorization-required 상태 표현
- choose/change/reauthorize와 cancel/error 흐름이 fake panel로 검증됨
- view construction test가 Application Support 또는 AppKit panel side effect 없이 통과함

실제 macOS adapter는 자동 테스트와 별도로 재현 가능한 수동 절차를 `docs/DEVELOPMENT.md`에 기록하고 가능한 범위에서 실행한다.

1. 테스트용 빈 폴더 A를 만든다.
2. 앱을 실행하고 선택 버튼으로 A를 고른다.
3. 합성 세션 생성 또는 쓰기 진단 경로가 있다면 A 아래에 명세 형태의 session/recovery layout이 생기는지 확인한다. 제품 UI에 테스트 전용 위험한 동작을 추가하지 않는다.
4. 앱을 정상 종료한 뒤 같은 build를 다시 실행해 panel을 다시 띄우지 않고 A를 active root로 복원하는지 확인한다.
5. 테스트용 빈 폴더 B로 active root를 변경하고 A의 기존 내용이 이동·삭제되지 않으며 B가 active가 되는지 확인한다.
6. 취소 동작이 현재 active root를 바꾸지 않는지 확인한다.
7. 재승인 필요 상태는 fake adapter 자동 테스트로 강제하고, 실제 권한 철회 시험이 안전하고 재현 가능할 때만 추가로 수행한다.

app-scoped bookmark는 code-signing identity와 연관되므로 unsigned CI build만으로 Sandbox 지속 권한 전체를 입증했다고 주장하지 않는다. 같은 로컬 build 재실행 검증과 deterministic adapter tests를 구분해 보고하고, 실제 Sandbox enforcement를 검증하지 못했다면 정확한 이유와 후속 수동 절차를 남긴다. 이를 숨기기 위해 entitlement를 제거하거나 path fallback을 추가하지 않는다.

## 12. 문서와 기존 앱

- `docs/ARCHITECTURE.md`를 실제 T03 구조에 맞게 갱신한다.
  - root ID와 active/historical bookmark registry
  - Application Support 내부 registry 파일 위치와 schema
  - security scope access lifetime
  - Application protocol과 Infrastructure 구현 의존 방향
  - session folder/artifact path와 source/derived 분류
  - atomic JSON 및 JSONL append 보장과 한계
  - Swift concurrency/serialization 경계
- `docs/DEVELOPMENT.md`를 갱신한다.
  - 최초 루트 선택, 재실행 복원, 변경, 취소 수동 검증 절차
  - security-scoped bookmark와 signing identity 관련 검증 범위
  - test/runtime 파일이 저장되는 위치와 안전한 테스트 디렉터리 사용법
- `MVP_SPEC.md`의 제품 요구사항은 변경하지 않는다.
- T03를 `dev`에 통합하는 시점에만 `PROJECT_STATUS.md`를 T03 완료 및 T04 준비 상태로 갱신한다.
- 같은 통합 commit에서 `IMPLEMENTATION_PLAN.md` 9장의 T03 체크박스만 완료로 바꾼다.
- 상태 문서에는 `dev`가 T03로 전진하고 `main`은 마지막 승인된 T01 기준선을 유지한다는 실제 상태, test 수와 미실시 수동 검증을 정확히 기록한다.

## 13. 명시적 제외 범위

- T04 SQLite catalog, filesystem reconciliation, missing session 판정과 catalog rebuild
- T05 마이크 권한·캡처·입력 레벨·장치 상태
- T06 recovery audio writer와 실제 `.mov` 생성
- T07 recording coordinator, 실제 recording session 시작과 metadata lifecycle orchestration
- T08 final `.m4a` 생성·검증과 finalization 실행
- T09 앱 시작 시 interrupted session 검색·복구
- T10 잠자기·창 닫기·앱 종료 정책
- STT engine, 모델 저장·다운로드·선택, VAD, transcript reconciliation
- transcript journal compact, `.txt`/`.md` renderer와 사용자 편집
- 세션 목록, 오디오 재생, 파일 열기, 휴지통 삭제
- root 사이 기존 session 자동 이동·복사·삭제
- 저장 공간 사전 예측
- arbitrary path 기반 범용 file manager 또는 file importer STT
- XPC, 별도 process, plugin framework
- telemetry, cloud sync, 자동 update, crash upload
- 외부 package/dependency와 runtime network
- `main` 승격, tag, release, PR

T03 UI는 루트 선택·변경·재승인에 필요한 최소 상태만 구현한다. 완성된 세션 목록이나 녹음 화면을 선행 구현하지 않는다.

## 14. 로컬 검증

구현 후 별도 임시 DerivedData 경로를 사용하여 최소 다음을 실행한다.

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
- app target의 built entitlements 또는 build settings에 Sandbox, user-selected read/write, app-scope bookmark가 모두 반영됨
- 모든 새 production/test source의 target membership
- Swift 6 concurrency warning과 actor isolation 오류가 없음
- `git diff --check`
- 전체 task branch diff와 staged diff
- 기존 알려진 AppIntents metadata 경고와 새 source/build/test warning을 구분
- test가 실제 사용자 홈의 임의 폴더나 실제 Application Support를 변경하지 않음
- bookmark data, runtime registry, 합성 session root, `.m4a`, `.mov`, JSON/JSONL runtime 파일, logs, DerivedData, built app가 Git에 포함되지 않음
- T03 외의 dependency 또는 후속 기능이 들어오지 않음

테스트 실패나 warning을 숨기기 위해 안전 검사를 완화하거나 entitlement를 제거하지 않는다. 알려진 비차단 toolchain 진단 외에 T03가 만든 새 경고가 있으면 T03 범위에서 해결하거나 완료를 차단한 이유를 보고한다.

## 15. commit, CI, `dev` 통합

1. T03 구현, unit/integration tests와 관련 문서 갱신을 task branch에서 완료한다.
2. 전체 local diff, `git diff --check`, build와 전체 test가 통과한 경우에만 T03 관련 경로를 명시적으로 stage한다.
3. task branch의 최종 commit 메시지는 정확히 다음 형식을 사용한다. 논리적 중간 commit이 필요하면 1~3개 범위에서 모두 끝에 `(T03)`을 붙이고 Conventional Commits 형식을 지킨다.

```text
feat(storage): add atomic session repository (T03)
```

4. task branch를 push하고 해당 branch의 `macOS CI`가 통과했는지 run URL 또는 run ID와 함께 확인한다.
5. CI가 실패하면 같은 구현 세션에서 T03 범위 원인을 수정하고 다시 local 검증과 CI를 수행한다. task CI가 실패·미확인 상태면 `dev`에 병합하지 않는다.
6. merge 직전 원격 `dev`가 branch 생성 기준선 이후 예상 밖으로 변경되지 않았는지 확인한다. 변경됐다면 덮어쓰지 말고 최신 `dev`에 안전하게 맞춘 뒤 전체 검증을 다시 한다.
7. 모든 완료 조건이 충족되면 local `dev`에서 task branch를 squash merge한다.
8. squash commit을 만들기 전에 `PROJECT_STATUS.md`와 `IMPLEMENTATION_PLAN.md` T03 체크박스를 위 문서 규칙대로 갱신한다.
9. `dev` squash commit 제목도 정확히 다음을 사용한다.

```text
feat(storage): add atomic session repository (T03)
```

10. merge된 `dev`에서 build와 전체 test를 다시 실행한다.
11. 검증된 `dev`를 push하고 `dev`의 `macOS CI` 통과를 확인한다.
12. `origin/dev`가 안전하고 CI가 성공한 뒤에만 local/remote T03 task branch를 삭제한다.
13. 최종 checkout은 `dev`, working tree는 clean, local `dev`와 `origin/dev`는 동일해야 한다.

commit 전에 모델, 실제 녹음/transcript, session root, bookmark registry, Application Support 내용, DB, log, credential, build product와 개인 Xcode 상태가 stage되지 않았는지 반드시 확인한다. `main`에는 어떤 commit도 push하거나 merge하지 않는다.

## 16. 완료 조건

다음 항목을 모두 근거와 함께 확인해야 완료다.

- [ ] 최신 clean `dev`에서 정확한 T03 task branch 생성
- [ ] app-scoped bookmark entitlement 추가 및 기존 Sandbox/read-write entitlement 유지
- [ ] stable root ID와 schema-versioned active/historical bookmark registry 구현
- [ ] 최초 선택, 변경, 동일 root 재선택, 특정 root 재승인 규칙 구현
- [ ] bookmark resolve, stale refresh, scope start/stop 수명 구현
- [ ] no-root와 reauthorization-required 상태 구현
- [ ] 최소 root 선택·변경·재승인 UI가 live app composition에 연결됨
- [ ] session folder naming과 collision 방지 구현
- [ ] session 및 recovery directory layout 구현
- [ ] typed artifact 경로와 source/derived 분류 구현
- [ ] `SessionRepository` protocol과 file-backed 구현
- [ ] metadata/transcript/checkpoint atomic write/read 구현
- [ ] event/transcript journal append 구현
- [ ] session ID mismatch와 root access 실패의 pre-write 거부 구현
- [ ] temp-write/flush/atomic-rename writer 구현
- [ ] append-only, flushed, serialized JSONL writer 구현
- [ ] rename 전 실패가 기존 JSON을 보존하는 테스트 통과
- [ ] bookmark 재실행 복원·stale·재승인·scope balance 테스트 통과
- [ ] session collision과 동일 제목 비충돌 테스트 통과
- [ ] canonical/recovery/derived 분류와 정확한 artifact path 테스트 통과
- [ ] JSON/JSONL round-trip·append·기존 bytes 보존 테스트 통과
- [ ] UI/Application 상태 테스트와 기존 smoke/integration test 통과
- [ ] local clean Debug build와 전체 test 통과
- [ ] `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT.md`가 실제 T03 구조·검증과 일치
- [ ] actual security-scope 수동 검증 결과 또는 정확한 미실시 이유와 절차 기록
- [ ] T04 이후 기능, 외부 dependency, runtime data 미포함
- [ ] task branch commit/push와 task CI 통과
- [ ] T03 체크리스트와 상태 문서 갱신
- [ ] 정확한 Conventional Commit으로 `dev` squash 통합
- [ ] merge된 `dev` build/test 재검증 통과
- [ ] `origin/dev` CI 통과
- [ ] `main` 미변경
- [ ] task branch 정리 후 working tree clean

## 17. 최종 보고 형식

다음 순서로 간결하지만 검증 가능하게 보고한다.

1. T03 상태: 완료 또는 차단
2. 사전 기준선과 환경
   - 시작 `dev` SHA
   - macOS, architecture, Xcode와 Swift 버전
3. branch와 commit
   - task branch와 commit
   - squash된 `dev` commit
   - local/remote `dev` SHA
   - `main` 미변경 확인과 SHA
4. 생성·수정한 파일
5. 핵심 설계
   - active/historical root registry와 stable root ID
   - bookmark create/resolve/stale/reauthorization와 scope 수명
   - session folder/artifact 경로와 source/derived 분류
   - atomic JSON writer와 JSONL append 보장·한계
   - `SessionRepository`와 concurrency 경계
   - 최소 root 설정 UI wiring
6. 실행한 local build/test 명령과 결과
   - 총 test 수와 주요 범주
   - fault-injection 및 scope-balance 결과
   - 새 warning 유무
7. 수동 검증
   - 선택, 종료/재실행 복원, 변경, 취소
   - 실제 Sandbox enforcement 여부와 signing 조건
8. task branch와 `dev` CI run URL/ID 및 결과
9. 명세 또는 프롬프트에서 벗어난 사항
10. 남은 위험과 후속 수동 확인
11. 승인되지 않은 runtime/user data와 후속 기능이 포함되지 않았다는 확인
12. T04 시작 가능 여부

완료 조건을 모두 충족할 때까지 같은 구현 세션에서 T03 범위 안의 문제를 해결한다. 명세 충돌, 원본 보존 불확실성, local build/test 실패, task CI 실패·미확인, `dev` CI 실패가 남아 있으면 완료라고 보고하거나 `dev`에 병합하지 않는다.
