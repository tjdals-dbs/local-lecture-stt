# T04 실행 프롬프트 — SQLite 세션 카탈로그와 파일 시스템 대조

## 역할

당신은 /Users/andyoon/stt 저장소의 **T04만 담당하는 새 구현 세션**이다. T02의 세션 도메인 문서와 T03의 active/historical storage root, security-scoped access, file-backed session repository를 기반으로, 세션 파일을 유일한 원본으로 유지하면서 언제든 다시 만들 수 있는 SQLite 목록 카탈로그와 앱 시작 시 파일 시스템 대조를 구현하고 검증하라.

이 작업은 저장 기반 마일스톤 M0의 마지막 Task다. T05 이후의 녹음, 오디오 생성·검사, lifecycle 복구, STT, 모델 관리와 T21의 최종 세션 목록 UI는 구현하지 않는다. SQLite가 원본보다 앞서거나 사용자 세션 파일을 수정·삭제하는 동작을 절대 만들지 않는다.

## 목표

성공 시 다음이 모두 참이어야 한다.

- App Sandbox의 Application Support 아래에 schema-versioned SQLite 카탈로그가 생성된다.
- 앱과 테스트는 macOS SDK가 제공하는 SQLite3와 시스템 libsqlite3만 사용하며 외부 package나 ORM을 추가하지 않는다.
- Application 경계에는 SQLite C 타입, SQL 문자열, URL, bookmark, FileManager가 노출되지 않는다.
- 이 규칙은 T04에서 새로 추가하는 `SessionCataloging`, `SessionCatalogStore`, `SessionFileScanning`, projection/scan/report 계약에 적용한다. 기존 T03 `StorageRootControlling.registerSelectedDirectory(_:)`와 `reauthorize(rootID:with:)`의 `Foundation.URL` 입력은 승인된 기존 예외로 유지하며, T04에서 이를 재설계하지 않는다.
- 목록 항목은 최소한 session ID, root ID, 불변 folder name, 제목, 생성 시각, active duration, metadata 상태, capture outcome, 파일 존재 상태와 metadata 갱신 시각을 보존한다.
- 사용자에게 표시할 상태는 정상 파일이면 metadata 상태, 폴더 또는 metadata가 확인된 누락이면 missing, 읽을 수 없는 metadata면 error로 결정된다. 마지막으로 정상 해석한 metadata 상태를 잃지 않는다.
- 목록은 생성 시각 내림차순과 안정적인 tie-breaker로 결정론적으로 정렬되고 제목, 날짜, 길이, 표시 상태를 제공한다.
- active root뿐 아니라 접근 가능한 모든 historical root를 대조한다.
- 유효한 metadata.json은 SQLite에 insert 또는 update되며, 파일의 값은 DB timestamp나 기존 DB 값과 관계없이 항상 우선한다.
- 접근에 성공해 전체 열거를 완료한 root에서만 DB-only 항목을 missing으로 표시한다. 행을 삭제하지 않는다.
- bookmark, security scope, root 열거에 실패한 root는 missing으로 추정하지 않고 마지막 카탈로그 항목을 그대로 보존한다.
- metadata가 손상·미지원·식별자 불일치인 세션은 원본을 바꾸지 않고 명시적 issue와 error 상태로 다룬다.
- 세션 폴더와 metadata를 읽기 위해 symlink를 따라 root 밖으로 나가지 않는다.
- DB 파일이 없으면 세션 폴더만으로 같은 정상 목록과 정렬을 재구축한다.
- DB가 손상되면 기존 DB와 WAL/SHM을 삭제하지 않고 앱 내부 quarantine에 보존한 뒤 새 DB를 만들어 접근 가능한 세션 폴더에서 재구축한다.
- 미래 버전의 지원하지 않는 DB schema는 손상으로 오인해 재구축하거나 덮어쓰지 않고 명시적으로 중단한다.
- scan과 SQLite 반영은 분리되고, 성공한 filesystem scan 결과는 하나의 SQLite transaction으로 적용된다. 실패 시 반쯤 반영된 상태를 commit하지 않는다.
- 앱의 실제 composition root에서 앱 시작당 한 번 카탈로그 open/recovery/reconciliation이 실행된다. 중복 view construction이나 Settings 표시가 중복 실행을 만들지 않는다.
- deterministic unit/integration test가 deletion rebuild, corruption rebuild, file-authoritative update, missing preservation, historical roots, unavailable root, partial failure, 충돌과 transaction rollback을 검증한다.
- 기존 T01~T03 테스트, unsigned arm64 Debug build와 전체 test suite가 통과한다.
- 검증된 T04 결과가 하나의 squash commit으로 dev에 통합되고 task branch와 dev CI가 모두 통과한다.
- main은 변경하거나 승격하지 않는다.

## 허가된 외부 변경

완료 조건을 모두 충족하는 경우에 한해 다음을 허가한다.

- task/t04-sqlite-catalog-reconciliation 브랜치 생성과 push
- task branch의 GitHub Actions 실행과 결과 확인
- 검증된 task branch를 로컬에서 squash merge하여 dev push
- merge된 dev의 GitHub Actions 실행과 결과 확인
- origin/dev가 안전하고 CI까지 통과한 뒤 T04 task branch 삭제

Pull Request, main 변경·push·승격, tag, GitHub Release, branch protection 변경, 저장소 공개 범위 변경, 외부 dependency 설치, 사용자의 실제 Application Support 또는 실제 세션 루트를 대상으로 한 파괴적 시험은 허가하지 않는다.

테스트는 임시 Application Support와 합성 session root만 사용한다. 실제 강의 녹음, 실제 transcript, 모델 파일, bookmark bytes, runtime SQLite DB와 quarantine 사본을 Git에 포함하지 않는다.

## 반드시 먼저 읽을 컨텍스트

다음 순서와 범위로 읽어라.

1. 이 프롬프트 전체
2. AGENTS.md 전체
3. PROJECT_STATUS.md 전체
4. IMPLEMENTATION_PLAN.md
   - 2장 실행 원칙
   - 5.2~5.7절 Git 및 GitHub 정책
   - T04. SQLite 세션 카탈로그와 파일 시스템 대조
   - T05와 T21의 경계만 확인
   - 8장 작업별 프롬프트 작성 규칙
   - 9장 전체 진행 체크리스트
5. MVP_SPEC.md
   - 5.2절 메인 화면과 세션 상태
   - 5.3절 제목과 불변 folder name
   - 8.3절 SessionCatalog 경계
   - 12.1, 12.2, 12.3, 12.5절
   - 13.1, 13.2절 중 metadata와 시간 표현
   - 14.2절 중 root 복원, filesystem/catalog 대조, 원본 보존, SQLite 재구축
   - 16.1, 16.2절의 파일·권한 오류와 안전 우선순위
   - 17.6절의 SQLite 삭제 복구 시험
6. docs/ARCHITECTURE.md와 docs/DEVELOPMENT.md
7. 실제 Git 상태와 다음 코드
   - Domain/SessionDocuments.swift
   - Domain/SessionLifecycle.swift
   - Domain/SessionStorage.swift
   - Application/StorageContracts.swift
   - Application/StorageRootControlling.swift
   - Infrastructure/StorageRootManager.swift
   - Infrastructure/FileSessionRepository.swift
   - Features/MainWindowView.swift
   - App/LocalLectureSTTApp.swift
   - LocalLectureSTTTests/StorageRepositoryTests.swift
   - LocalLectureSTT.xcodeproj/project.pbxproj
   - .gitignore

관련 문서가 서로 충돌하거나 아래 계약으로 파일 원본 보존을 보장할 수 없다면 임의로 완화하지 말고 안전한 상태에서 중단하여 충돌, 데이터 위험과 권장 해결안을 보고하라. T04와 무관한 명세 전체를 반복해서 읽지 않는다.

## 현재 알려진 기준선

다음은 프롬프트 작성 시점의 정보이며 새 세션에서 실제 상태로 다시 확인한다.

- 작업 디렉터리: /Users/andyoon/stt
- 장기 branch: dev
- T03 완료 구현 commit: 7bbbeba20e50b8cd28019a9824ff415d173373f2
- 이 프롬프트 문서 commit이 위 T03 commit 뒤의 dev에 추가되어 있을 수 있다.
- origin/dev는 새 구현 세션 시작 전에 다시 fetch하여 확인한다.
- origin/main은 T01 실행 기준선 38e126f92ac823d29306ea8c1f7703f7060a5818이며 T04에서 변경하지 않는다.
- app target은 macOS 15+, arm64, Swift 6, 단일 프로세스 SwiftUI 앱이다.
- Xcode 26.6과 현재 SDK에서 import SQLite3 및 시스템 SQLite 3.51.0 사용 가능 여부가 프롬프트 작성 시 확인됐지만 구현 세션에서 다시 build로 검증한다.
- 외부 Swift Package dependency는 현재 없다.
- Xcode project는 source membership을 수동 PBX reference/build phase로 관리한다. 새 production/test source와 libsqlite3 link가 실제 target에 포함돼야 한다.
- StorageRootManager는 Application Support/LocalLectureSTT/Storage/storage-roots.json의 active/historical root registry를 관리한다.
- StorageRootCatalog는 stable root ID와 active 여부를 URL이나 bookmark 없이 제공한다.
- StorageRootManager.withAccess는 현재 read/write 검사를 함께 수행한다. T04 scan에 필요한 read-only access intent를 안전하게 분리할 필요가 있는지 실제 코드를 보고 판단하되, write repository의 기존 writable 검사를 약화하지 않는다.
- FileSessionRepository는 typed SessionLocation을 통한 개별 metadata read/write는 제공하지만 root의 session directory 열거는 제공하지 않는다.
- SessionFolderName은 생성 initializer만 있고 raw directory name 검증·parsing 계약은 아직 없다.
- SessionMetadataDocument는 schema v1, Codable, Sendable이며 title, status, captureOutcome, createdAt, activeDurationMs, lastUpdatedAt 등을 제공한다.
- main window는 storage root 상태만 표시하고 T21의 세션 목록 UI는 아직 없다.
- T03 완료 기준 LocalLectureSTTTests 38개와 integration construction smoke test가 통과했다.
- Xcode 26.6의 AppIntents metadata skipped 메시지는 알려진 비차단 toolchain 진단이다.
- 현재 .gitignore는 일부 sqlite/db 패턴은 제외하지만 .sqlite3 및 모든 sidecar/quarantine 변형을 완전히 덮는지 재검토해야 한다.

대화나 이 목록보다 새 세션에서 확인한 실제 Git 상태, code, build/test 결과를 우선한다.

## 1. 사전 점검과 task branch

파일을 수정하기 전에 다음을 확인한다.

- pwd
- git status --short --branch
- git remote -v
- local/remote branch와 upstream
- 최근 commit과 dev, origin/dev, main, origin/main SHA
- 예상하지 않은 tracked·untracked 파일 또는 사용자 변경
- xcode-select -p, xcodebuild -version, swift --version, uname -m
- xcodebuild -list
- 현재 unsigned arm64 Debug build와 전체 test 실행 가능 여부
- 현재 app target의 source membership, framework link와 build settings
- 현재 toolchain에서 SQLite3 module import 가능 여부

working tree가 clean하고 local dev가 최신 origin/dev와 일치하는 것을 확인한 뒤 정확히 다음 branch를 만든다.

~~~text
task/t04-sqlite-catalog-reconciliation
~~~

필요하면 먼저 git fetch origin, git switch dev, git pull --ff-only origin dev를 사용한다. 기존 동명 branch나 예상하지 않은 변경·분기가 있으면 덮어쓰거나 삭제하지 말고 조사한 뒤 안전하게 중단하여 보고한다. force push, destructive reset, checkout/clean을 통한 사용자 변경 폐기는 금지한다.

사전 build/test가 실패하면 T04 구현 전에 기준선 문제인지 환경 문제인지 구분한다. 원인을 모른 채 기존 테스트를 수정하거나 T04 변경에 섞지 않는다.

## 2. 고정된 제품 의미

다음 의미는 구현 선택지가 아니라 고정 계약이다.

### 2.1 원본과 파생 데이터

- 세션 root 아래 각 session folder와 metadata.json이 세션 목록의 원본이다.
- SQLite는 목록 조회 속도를 위한 rebuildable projection일 뿐이다.
- SQLite 값이 파일과 다르면 파일이 이긴다. DB의 updated timestamp가 더 새로워 보여도 예외가 아니다.
- reconciliation은 metadata나 folder를 생성, 수정, 이름 변경, 이동, 격리 또는 삭제하지 않는다.
- transcript, audio, events, checkpoint를 읽어서 metadata를 추측하거나 고치지 않는다.
- T04의 정상 session 존재 판정은 session directory와 읽을 수 있는 metadata.json을 기준으로 한다.
- 진행 상태에 따라 audio.m4a, transcript.json 또는 recovery artifact가 아직 없을 수 있으므로 이 파일들의 부재만으로 session을 missing 또는 error로 만들지 않는다.

### 2.2 목록 상태와 마지막 정상 metadata 상태

DB에는 최소 다음 두 의미를 분리해 보존한다.

- metadataStatus: 마지막으로 정상 decode한 metadata.json의 SessionStatus
- presence: 현재 대조 결과의 present, missing 또는 unreadable

표시 상태는 다음처럼 계산한다.

| presence | 표시 상태 | metadataStatus 보존 |
| --- | --- | --- |
| present | metadataStatus | 예 |
| missing | SessionStatus.missing | 예 |
| unreadable | SessionStatus.error | 예 |

missing이나 unreadable 판정 때문에 metadataStatus 자체를 missing/error로 덮어쓰지 않는다. 파일이 다시 정상으로 보이면 같은 metadata projection으로 presence를 present로 되돌리고 파일의 status를 즉시 표시한다.

### 2.3 root 접근 실패와 실제 누락의 구분

- root bookmark resolve 실패, security scope 획득 실패, root 자체 부재, root 열거 실패는 그 root를 성공적으로 조사한 결과가 아니다.
- 이런 root의 기존 catalog row는 삭제하거나 missing으로 바꾸지 않는다.
- root별 reconciliation 결과에 재승인 필요 또는 구체적인 typed error를 남긴다.
- 오직 root의 immediate children 열거가 끝까지 성공한 경우에만 그 root에서 보지 못한 기존 row를 missing으로 표시할 수 있다.
- 한 candidate의 metadata만 손상된 경우 root 열거 자체는 완료될 수 있다. 그 candidate는 seen location으로 기록하고 기존 row가 있으면 unreadable로 표시한다.
- root 열거가 중간에 실패했다면 이미 읽은 유효 projection은 반영할 수 있지만 그 root 전체 missing sweep은 하지 않는다.

### 2.4 T04가 바꾸지 않는 lifecycle

- recording 또는 paused metadata를 interrupted로 바꾸지 않는다. 이는 T09 범위다.
- securing 또는 finalizing을 재개하지 않는다. 이는 T08/T09 범위다.
- completed를 오디오 존재 여부로 재판정하지 않는다.
- captureOutcome이나 metadata status 조합을 임의로 수정하지 않는다.

## 3. 계층과 인터페이스 경계

T01의 단일 app target 안 논리 경계를 유지한다.

- Domain: 기존 식별자, SessionStatus, CaptureOutcome, 시간과 folder name 검증처럼 프레임워크 비의존 값 규칙
- Application: SessionCatalog, 목록 item/query, projection, reconciliation report와 scanner/store protocol
- Infrastructure: SQLite3 C API wrapper와 store, security-scoped root scanner, App Support catalog 경로, quarantine
- App: live dependency composition과 앱 시작당 한 번의 bootstrap
- Features: T21 이전에 필요한 최소 시작 상태 연결만 가능하며 최종 session list UI는 만들지 않음

권장 경계는 다음 책임을 각각 분리하는 것이다. 이름은 Swift 관례에 맞게 조정할 수 있지만 책임을 합쳐 테스트 불가능하게 만들지 않는다.

1. SessionFileScanning
   - StorageRootCatalog의 모든 root를 순회
   - 각 root의 lexical security scope 안에서 direct child만 읽음
   - URL을 외부로 내보내지 않고 Sendable scan value/report 반환
2. SessionCatalogStore
   - schema open/create/validate
   - list query
   - 한 reconciliation batch의 transaction 반영
   - close/checkpoint 또는 테스트에 필요한 명시적 lifetime
3. SessionCatalogReconciler
   - scan 결과를 catalog 정책에 따라 store에 적용
   - root별 success/partial/unavailable과 issue를 보고
4. 앱이 사용할 SessionCatalog facade 또는 동등한 use case
   - reconcile
   - 현재 ordered list 조회

다음 원칙을 지킨다.

- Application과 Domain에는 import SQLite3를 두지 않는다.
- Application API에는 OpaquePointer, sqlite3_stmt, SQLite result code, SQL string, URL을 노출하지 않는다.
- scanner/store/facade 사이를 건너는 독립 값은 Sendable이며 persistence 또는 테스트 비교가 필요한 값은 Codable/Equatable도 제공한다.
- SQLite connection과 statement는 actor 또는 동등한 단일 직렬화 소유자 밖으로 나가지 않는다.
- @unchecked Sendable, Any, [String: Any], 전역 singleton, service locator로 C pointer나 동시성 문제를 숨기지 않는다.
- filesystem scan 중 SQLite write transaction을 열어 둔 채 await하지 않는다.
- SQLite transaction 안에서는 await하지 않는다.
- 파일 scan과 DB 반영을 같은 actor가 직렬화하거나 상위 facade가 동시 reconciliation을 coalesce하여 같은 catalog에 두 대조가 겹치지 않게 한다.
- fake scanner/store로 reconciliation 정책을 단위 테스트할 수 있어야 한다.
- 후속 다중 프로세스/XPC를 위한 plugin framework나 범용 ORM은 만들지 않는다.

## 4. 목록 item과 projection 계약

Application 경계에 최소 다음 의미를 가진 타입을 정의한다. 정확한 타입명은 조정할 수 있다.

### 4.1 SessionCatalogItem

- sessionID: SessionID
- rootID: StorageRootID
- folderName: 검증된 SessionFolderName
- title: String
- createdAt: AbsoluteTime
- activeDuration: MediaMilliseconds
- metadataStatus: SessionStatus
- captureOutcome: CaptureOutcome
- presence: CatalogPresence
- metadataLastUpdatedAt: AbsoluteTime
- catalogUpdatedAt: AbsoluteTime 또는 동등한 내부 갱신 시각
- displayStatus: 위 표로 결정되는 계산 결과

목록 조회는 최소한 title, createdAt, activeDuration, displayStatus를 UI가 즉시 사용할 수 있게 한다. 기본 정렬은 createdAt 내림차순이고 같은 시각은 sessionID canonical string 오름차순처럼 명시적인 안정 tie-breaker를 사용한다. SQLite의 암묵적 row order에 의존하지 않는다.

T04에서는 full-text search, pagination, filter UI를 구현하지 않는다. 다만 향후 query 확장을 막는 SQL/타입 결합은 피한다.

### 4.2 CatalogProjection

정상 SessionMetadataDocument와 검증된 SessionLocation에서 만드는 pure projection을 둔다.

- metadata의 title, createdAt, activeDurationMs, status, captureOutcome, lastUpdatedAt를 그대로 사용한다.
- title normalization, trimming, 자동 제목 변경을 하지 않는다.
- createdAt 또는 lastUpdatedAt이 이전 DB 값보다 과거여도 파일 값을 적용한다.
- MediaMilliseconds와 UUID를 문자열 parsing이나 부동소수 초로 약화하지 않는다.
- mapping 자체를 SQLite 없이 단위 테스트한다.

### 4.3 Reconciliation report와 issue

앱 시작은 일부 historical root가 접근 불가능해도 전체 앱을 crash시키지 않아야 한다. root별 결과와 개별 candidate issue를 stable enum/code로 보고할 수 있어야 한다.

최소 구분:

- root fully reconciled
- root partially scanned; no missing sweep
- root unavailable / reauthorization required
- invalid session folder name
- session directory symlink
- metadata missing
- metadata symlink or not a regular file
- metadata corrupt
- metadata schema unsupported
- folder short ID와 metadata session ID 불일치
- duplicate session ID 또는 location conflict
- SQLite open/schema/integrity/transaction failure
- corrupted catalog quarantined and rebuilt

issue에는 root ID와 안전한 folder name 정도만 담고 bookmark bytes, 전체 사용자 path, metadata 원문, SQL, 실제 강의 내용을 로그나 UI payload에 넣지 않는다. T25 이전에 범용 파일 로그 시스템을 만들지 않는다.

## 5. SessionFolderName 검증과 안전한 filesystem scan

현재 생성 규칙과 정확히 호환되는 validated raw initializer/parser를 추가한다.

~~~text
YYYYMMDD-HHMMSS_<8-char-lowercase-hex-session-prefix>
~~~

필수 규칙:

- 길이, 구분자 위치, ASCII 숫자와 소문자 0-9a-f를 엄격히 검증한다.
- 날짜 부분은 POSIX locale, Gregorian calendar, 고정 GMT와 strict/non-lenient parsing으로 실제 가능한 calendar date/time인지 검증한다. 현재 Mac의 time zone이나 DST 때문에 같은 folder name의 유효성이 달라지면 안 된다.
- path separator, dot component, 대문자 short ID, suffix 추가를 허용하지 않는다.
- metadata를 읽은 뒤 folder의 8자 suffix가 metadata session UUID의 하이픈 제거 lowercase 앞 8자와 같은지 검증한다.
- folder timestamp와 metadata.createdAt은 생성 당시 time zone 정보가 metadata에 별도로 없으므로 역산해 동일성을 강제하지 않는다.
- 기존 생성 initializer가 만드는 모든 이름은 parser를 round-trip한다.
- Codable decode로 rawValue가 들어오는 경우에도 invalid name이 우회되지 않게 한다.

각 root scan은 다음 순서를 따른다.

1. StorageRootCatalog에서 active와 historical root를 stable ID 기준으로 얻는다.
2. root마다 StorageRootManager의 lexical scoped access를 사용한다.
3. root의 immediate children만 열거한다. recursive enumerator로 임의 하위 tree를 훑지 않는다.
4. hidden item과 session 형태가 아닌 unrelated file/directory는 조용히 무시한다. session naming 형태를 의도한 것으로 보이지만 strict parser를 통과하지 못한 candidate만 invalid-folder issue로 남긴다.
5. child가 실제 directory인지 확인하고 symbolic link이면 따라가지 않고 issue를 남긴다.
6. candidate/session metadata.json도 regular file이고 symbolic link가 아닌지 확인한다.
7. metadata bytes를 읽고 SessionMetadataDocument로 decode한다.
8. unsupported schema와 corrupt JSON을 구분한다.
9. folder suffix와 metadata session ID를 검증한다.
10. 정상 값만 CatalogProjection으로 반환한다.

root URL 또는 child URL을 Application 값에 보존하지 않는다. security scope가 닫힌 뒤 URL을 사용하지 않는다.

현재 StorageRootManager.withAccess가 write 가능성까지 요구해 읽기 가능한 historical root를 scan하지 못한다면 access intent 또는 별도 read access API를 최소 변경으로 도입한다.

- read scan은 directory/read 가능성만 요구한다.
- FileSessionRepository의 create/write/append는 기존처럼 write 가능성을 계속 요구한다.
- write 검사를 전역에서 제거하지 않는다.
- read와 write 모두 bookmark resolve/start/stop의 정확한 수명을 지킨다.
- 접근 실패 전에는 사용자 root를 mutate하지 않는다.
- 이 변경은 read-only historical root scan과 기존 write 거부를 각각 테스트한다.

T04 scanner는 사용자 root에 temp, marker, lock, DB, cache 파일을 만들지 않는다. scan 전후 directory tree와 file bytes가 같은지 테스트한다.

## 6. SQLite 저장 위치와 연결

기본 live 경로는 다음으로 고정하고 docs/ARCHITECTURE.md에 기록한다.

~~~text
Application Support/LocalLectureSTT/Catalog/session-catalog.sqlite3
~~~

- 사용자 선택 root, Documents, UserDefaults, 앱 bundle에 DB를 두지 않는다.
- 테스트는 주입한 임시 Application Support 경로를 사용한다.
- 디렉터리 생성 실패는 typed catalog error다.
- model DB나 향후 log DB와 파일을 공유하지 않는다.

macOS SDK의 SQLite3 module과 system libsqlite3를 직접 사용한다.

- LocalLectureSTT app target에 libsqlite3.tbd 또는 동등한 명시적 -lsqlite3 link를 Debug/Release 모두 적용한다.
- 외부 Swift package, SQLite.swift, GRDB, Core Data, SwiftData를 추가하지 않는다.
- test target이 app module을 통해 구현을 검증하도록 target dependency/link를 확인한다.
- 새 source와 test source를 project.pbxproj의 올바른 group, file reference와 build phase에 빠짐없이 넣는다.

연결 소유자는 최소 다음을 보장한다.

- sqlite3_open_v2 반환 code와 optional connection handle을 모두 검사한다.
- 필요한 read/write/create/full-mutex 또는 actor 직렬화와 호환되는 flag를 명시한다.
- busy timeout을 유한 값으로 설정하고 SQLITE_BUSY를 무한 retry하지 않는다.
- PRAGMA foreign_keys = ON
- PRAGMA trusted_schema = OFF
- PRAGMA journal_mode = WAL 결과가 실제 wal인지 확인
- PRAGMA synchronous = FULL
- 모든 statement는 sqlite3_prepare_v2, typed bind, step result 검사, defer/finalize를 따른다.
- 문자열과 UUID는 parameter binding하며 SQL interpolation을 하지 않는다.
- text binding lifetime은 SQLITE_TRANSIENT와 동등하게 안전하다.
- nullable 값은 sqlite3_bind_null을 사용한다.
- column type/null과 enum raw value를 검증하고 invalid DB row를 조용히 기본값으로 바꾸지 않는다.
- transaction은 BEGIN IMMEDIATE, COMMIT, 오류 시 ROLLBACK 또는 동등한 원자성을 갖는다.
- connection close 시 남은 statement가 없도록 하고 close 실패를 테스트/진단에서 숨기지 않는다.

SQLite가 rebuildable이라고 synchronous OFF, 무검사 replace, 무제한 busy loop를 선택하지 않는다. WAL+FULL은 작은 개인 카탈로그에서 단순성과 power-loss durability를 우선하기 위한 T04 결정이다.

기존 DB를 여는 순서는 미래 schema 보존을 위해 중요하다.

1. main DB가 이미 존재하면 먼저 read-only connection으로 header/user_version과 quick_check를 검사한다.
2. user_version이 미래 버전이면 이 read-only 검사 뒤 즉시 unsupported로 반환한다. journal mode 변경, schema DDL, WAL checkpoint와 write connection open을 하지 않는다.
3. 지원되는 v1이고 integrity/schema가 정상일 때만 read/write connection으로 다시 열고 connection PRAGMA와 WAL 설정을 적용한다.
4. 새 DB일 때만 create flag로 열어 schema v1을 만든다.
5. main DB 없이 고아 WAL/SHM/journal만 존재하면 이를 무시한 채 새 DB를 만들지 말고 손상 묶음으로 안전하게 quarantine한 뒤 생성한다.

단순히 read/write open 직후 PRAGMA journal_mode = WAL을 먼저 실행하면 지원하지 않는 미래 DB의 bytes 또는 sidecar를 바꿀 수 있으므로 금지한다.

참고할 공식 문서:

- https://www.sqlite.org/pragma.html
- https://www.sqlite.org/wal.html
- https://www.sqlite.org/c3ref/open.html
- https://www.sqlite.org/c3ref/prepare.html
- https://www.sqlite.org/c3ref/bind_blob.html
- https://www.sqlite.org/c3ref/step.html
- https://www.sqlite.org/c3ref/finalize.html

## 7. SQLite schema v1

PRAGMA user_version을 application schema version으로 사용하고 현재 버전은 1로 둔다. 최소 sessions table은 다음 의미를 가진다.

| column 의미 | 권장 SQLite 표현 | 규칙 |
| --- | --- | --- |
| session ID | TEXT PRIMARY KEY | canonical lowercase UUID |
| root ID | TEXT NOT NULL | canonical lowercase UUID |
| folder name | TEXT NOT NULL | validated SessionFolderName |
| title | TEXT NOT NULL | metadata 원문 |
| created at | INTEGER NOT NULL | Unix epoch milliseconds |
| active duration | INTEGER NOT NULL | 0 이상 milliseconds |
| metadata status | TEXT NOT NULL | SessionStatus raw value |
| capture outcome | TEXT NOT NULL | CaptureOutcome raw value |
| presence | TEXT NOT NULL | present/missing/unreadable |
| metadata last updated | INTEGER NOT NULL | Unix epoch milliseconds |
| catalog updated | INTEGER NOT NULL | Unix epoch milliseconds |

추가 제약:

- UNIQUE(root_id, folder_name)로 같은 location이 다른 session에 중복 매핑되지 않게 한다.
- CHECK(active_duration_ms >= 0)
- presence 허용값 CHECK
- created_at_ms DESC와 deterministic tie-breaker를 지원하는 index
- 향후 title/status filter를 막지 않는 작고 명확한 index는 허용하지만 사용하지 않는 FTS schema는 만들지 않는다.

AbsoluteTime은 이미 millisecond precision으로 정규화돼 있다. DB에서는 ISO 8601 text를 재파싱하지 않고 epoch millisecond Int64로 정확히 round-trip할 수 있다. Double seconds를 public catalog 값으로 노출하지 않는다. Int64 overflow 또는 invalid timestamp는 typed error다.

open/schema 규칙:

1. DB가 없으면 parent directory를 만들고 schema v1을 하나의 transaction으로 생성한 뒤 user_version = 1을 설정한다.
2. user_version = 1이면 expected table/index/columns를 검증한다.
3. user_version이 현재보다 크면 catalogSchemaUnsupported로 중단하고 파일과 sidecar를 그대로 보존한다.
4. user_version = 0인데 예상 밖 user table이 있거나 부분 schema라면 빈 새 DB로 간주해 덮어쓰지 않는다. 손상/불완전 catalog recovery 정책으로 보존 후 재구축한다.
5. T04에서 미래 migration을 구현하지 않지만 version switch와 migration transaction을 추가할 수 있는 구조는 유지한다.

## 8. upsert, missing과 unreadable 반영 규칙

정상 projection은 session ID를 identity로 upsert한다.

- insert 시 location과 metadata projection 전체를 저장하고 presence = present로 둔다.
- 기존 같은 session ID가 있으면 파일 projection 전체와 location을 갱신하고 presence를 present로 되돌린다.
- DB의 metadataLastUpdatedAt이 더 새롭다는 이유로 file update를 건너뛰지 않는다.
- 같은 session ID의 유효한 파일이 한 번의 scan에서 둘 이상 발견되면 임의 root, 최신 시각, active root를 선택하지 않는다. conflict issue를 반환하고 원본을 보존한다.
- 동일 root/folder location이 기존 DB의 다른 session ID와 충돌하면 둘 중 하나를 조용히 덮어쓰지 않는다.
- 충돌로 신뢰할 수 없는 기존 row가 있으면 last-known projection을 보존한 채 unreadable/error로 표시할 수 있어야 한다.

성공적으로 전체 열거한 root마다 scan에서 확인한 location/session 집합을 DB와 비교한다.

- session directory가 사라졌으면 row를 유지하고 presence = missing
- directory는 있으나 metadata.json이 없으면 기존 row를 유지하고 presence = missing
- metadata가 symlink, non-regular, corrupt, unsupported 또는 ID mismatch이면 기존 row를 유지하고 presence = unreadable
- 기존 row가 없는 invalid/corrupt candidate는 완전한 session ID와 목록 필드를 신뢰할 수 없으므로 가짜 ID나 제목을 만들어 row를 insert하지 않고 issue만 남긴다.
- 이전 missing/unreadable row의 metadata가 다시 정상이면 파일 projection으로 present 복구
- root가 unavailable 또는 partial scan이면 unseen row의 presence를 변경하지 않음
- 어떠한 경우에도 DELETE FROM sessions를 reconciliation 정책으로 실행하지 않음

여러 root 결과를 적용하는 transaction에서 다음을 지킨다.

- complete root의 projection/unreadable/missing 계산과 partial root의 안전한 projection만 한 transaction에 반영한다.
- root별 seen set을 SQL string으로 보간하지 않는다. 임시 table, parameterized statement 또는 크기 제한에 안전한 동등한 방식으로 처리한다.
- SQLite 오류가 하나라도 나면 전체 batch를 rollback한다.
- filesystem scan에는 이미 성공했지만 DB transaction이 실패하면 파일은 그대로이고 report는 catalog failure를 나타낸다.
- catalogUpdatedAt은 주입 가능한 clock으로 결정론적으로 테스트한다.

## 9. DB 삭제, 손상과 지원하지 않는 schema

### 9.1 DB 삭제

닫힌 catalog의 main DB와 관련 sidecar가 없는 상태에서 새 instance를 열고 reconcile하면 schema v1을 새로 만들고 접근 가능한 모든 root의 정상 session을 복원한다.

“동일한 목록”은 정상 파일 기반 항목에 대해 최소 다음이 같다는 뜻이다.

- session ID와 location
- title
- createdAt
- activeDuration
- metadataStatus와 displayStatus
- captureOutcome
- metadataLastUpdatedAt
- 정렬 순서

catalogUpdatedAt은 재구축 시각이므로 달라도 된다. DB에만 있던 missing row는 파일 원본이 없으므로 DB 완전 삭제 후 복원할 수 없다는 사실을 테스트/문서에서 숨기지 않는다.

### 9.2 DB 손상

DB open, schema query, quick_check 또는 실제 read에서 corruption/not-a-database가 확인되면 다음 순서를 따른다.

1. 열린 statement와 connection을 닫는다.
2. Application Support의 Catalog/Corrupt/<timestamp>-<uuid>/ 같은 앱 내부 고유 quarantine directory를 만든다.
3. 존재하는 -wal, -shm, -journal sidecar를 먼저 이동하고 main DB를 마지막에 같은 묶음으로 이동한다.
4. 기존 bytes를 삭제하거나 truncate하지 않는다.
5. quarantine이 안전하게 끝난 뒤에만 원래 경로에 새 schema v1 DB를 만든다.
6. 접근 가능한 session root를 scan하여 rebuild한다.
7. report에 recoveredFromCorruption와 quarantine 성공을 남긴다.

main DB를 마지막에 이동하는 이유는 sidecar 이동 중 실패해도 원래 위치의 main DB가 남아 새 DB 생성이 시작되지 않게 하기 위함이다. quarantine 도중 일부 move가 실패하면 원본과 이미 이동된 파일을 삭제하지 않는다. 새 DB를 무리하게 만들지 말고 typed quarantine failure로 중단한다. test fixture 밖의 실제 quarantine을 자동 삭제하는 retention 정책은 T04에서 만들지 않는다.

기존 DB에는 startup/open 시 PRAGMA quick_check를 실행해 단일 ok 결과를 확인한다. quick_check가 오류 문자열 또는 SQLite error를 반환하면 corruption으로 취급한다. schema version이 미래 버전인 것은 corruption이 아니다.

### 9.3 미래 schema

- user_version > 1이면 unsupported를 반환한다.
- DB/WAL/SHM을 quarantine, 삭제, rename, rebuild하지 않는다.
- 파일 scan으로 새 DB를 덮어쓰지 않는다.
- downgrade가 미래 catalog를 파괴하지 않게 한다.

## 10. 앱 시작 reconciliation 연결

T04는 backend type만 만들고 끝내지 않는다. 실제 LocalLectureSTTApp composition에서 live StorageRootManager, scanner, SQLite store/reconciler를 조립하고 앱 시작당 한 번 다음 flow를 실행한다.

1. catalog directory/open/schema/integrity 확인
2. 필요 시 손상 DB quarantine과 새 catalog 생성
3. StorageRootCatalog 로드
4. 접근 가능한 active/historical root scan
5. reconciliation transaction 적용
6. ordered session list를 읽을 수 있는 ready 상태

구현 방식은 AppStartupCoordinator, CatalogBootstrapViewModel 또는 동등한 구조를 사용할 수 있다.

- @MainActor UI state와 actor-backed I/O를 분리한다.
- main window와 Settings가 각각 .task를 실행해 두 번 bootstrap하지 않게 한다.
- 같은 coordinator의 start가 반복 호출되면 이미 완료된 결과를 재사용하거나 in-flight 작업을 coalesce한다.
- no root selected는 정상적인 empty reconciliation 결과이며 app crash/error가 아니다.
- 일부 historical root 실패는 전체 app launch를 실패시키지 않고 partial report로 남긴다.
- SQLite 자체 open/schema/transaction 실패는 catalog failure로 분명히 남긴다.
- 앱 시작 후 사용자가 새 root를 선택하거나 특정 root를 재승인하면 그 성공 이벤트 뒤에 명시적인 새 reconciliation을 요청한다. 최초 실행에서 기존 session root를 선택했는데 다음 앱 실행까지 catalog가 비어 있으면 안 된다.
- root 선택/재승인에 따른 refresh와 startup 중복 방지는 같은 facade/coordinator의 직렬화 규칙을 사용한다.
- root 선택/재승인 refresh가 startup reconciliation 진행 중 도착하면 이를 단순 중복 호출로 버리지 않는다. 현재 pass 뒤 최신 StorageRootCatalog로 정확히 한 번 더 실행하도록 pending refresh를 합치거나 동등한 보장을 둔다.
- T21의 실제 세션 row UI, 검색, 선택과 navigation을 구현하지 않는다.
- T04를 증명하기 위한 숨은 side effect나 preview가 실제 사용자 Application Support를 건드리지 않게 한다.

최소한 fake facade/coordinator test로 앱 시작 호출이 한 번 일어나고 반복 start가 중복 reconciliation을 만들지 않음을 검증한다. live composition source가 실제 target에 들어가며 app이 compile/run 가능한지 integration construction test로 확인한다.

## 11. 오류 정책과 사용자 데이터 안전

stable catalog error code를 최소 다음 범주로 구분한다.

- applicationSupportUnavailable / catalogDirectoryCreateFailed
- openFailed
- configureFailed
- schemaCreateFailed
- schemaCorrupt 또는 schemaInvalid
- schemaUnsupported
- integrityCheckFailed
- prepareFailed
- bindFailed
- stepFailed
- invalidStoredValue
- transactionBegin/commit/rollback failure
- quarantineFailed
- filesystemScanFailed
- reconciliationConflict

SQLite numeric extended code와 underlying error를 Infrastructure 내부 진단에 보존할 수 있지만 Application 동작을 localized message/string 비교에 의존시키지 않는다.

어떤 오류에서도 다음을 하지 않는다.

- 사용자 session folder, metadata, audio, transcript, recovery file 수정·삭제·이동
- 접근 불가 root의 catalog row 삭제 또는 missing 전환
- corrupt/unsupported metadata를 빈 metadata로 교체
- corrupt DB를 quarantine 전에 truncate 또는 unlink
- future schema DB를 자동 downgrade/rebuild
- catalog 오류를 이유로 storage root registry를 초기화
- DB row에서 metadata.json을 역생성
- 실제 사용자 path, bookmark, 강의 title/content, SQL bind 값을 console에 무차별 출력

SQLite catalog는 rebuildable이지만 사용자 파일을 보호하는 오류 경계와 명시적 report는 필수다.

## 12. 자동 테스트

LocalLectureSTTTests에 임시 Application Support와 합성 root를 사용하는 deterministic test를 추가한다. 실제 사용자 홈의 Application Support나 기존 root를 읽거나 쓰지 않는다. 필요하면 test fixture helper를 분리하되 production에 위험한 test-only bypass를 노출하지 않는다.

최소 자동 테스트는 다음 전부를 포함한다.

### 12.1 value, parser와 projection

- valid folder name 생성 → parser round-trip
- invalid 길이, separator, impossible date, uppercase/non-hex suffix, path separator 거부
- folder short ID와 metadata session ID 일치/불일치
- SessionMetadataDocument → CatalogProjection이 Unicode/영어 혼용 title, createdAt, duration, status, outcome, lastUpdatedAt를 정확히 보존
- present/missing/unreadable에 따른 displayStatus와 metadataStatus 보존
- catalog item과 report의 Codable/Sendable/Equatable 요구사항

### 12.2 SQLite schema와 query

- 빈 임시 Application Support에서 v1 DB와 expected schema 생성
- 정확한 live 상대 경로
- Unicode, quote, percent, SQL-like title을 parameter binding으로 round-trip
- Int64 millisecond time/duration과 UUID/enum round-trip
- createdAt 내림차순 + deterministic tie-breaker
- insert 후 update가 row 중복 없이 file projection을 반영
- missing/unreadable 전환이 row와 last-known metadataStatus를 보존
- present 복구가 metadata status를 다시 표시
- invalid DB enum/time/folder row를 조용히 기본값으로 읽지 않고 typed error
- unsupported user_version이 bytes를 바꾸거나 quarantine/rebuild하지 않음
- injected failure 중 reconciliation transaction 전체 rollback
- statement finalize/connection close 이후 DB 파일을 안전하게 시험 조작 가능

### 12.3 filesystem scan

- root direct child의 유효한 session metadata만 projection
- hidden/unrelated item은 조용히 무시하고 session 형태의 invalid folder는 issue
- nested session-looking folder를 recursive하게 수집하지 않음
- session directory symlink와 metadata symlink를 따라가지 않음
- metadata missing, corrupt, unsupported, ID mismatch를 서로 구분
- scan 전후 사용자 root tree와 기존 bytes가 동일
- read-only root는 scan 가능하고 기존 FileSessionRepository write는 계속 거부
- bookmark/security-scope 실패 시 scan closure가 실행되지 않고 scope start/stop 수명이 균형

### 12.4 reconciliation acceptance

- active root와 historical root의 session이 한 목록에 보존
- file title/status/duration 변경 후 reconcile하면 DB에 정확히 반영
- DB 값을 직접 다르게 만든 뒤 reconcile해도 file 값이 이김
- complete-scanned root의 DB-only row는 삭제되지 않고 missing
- session folder는 있으나 metadata가 없어진 기존 row도 missing
- corrupt/unsupported metadata의 기존 row는 unreadable/error이고 last-known fields 보존
- missing/unreadable 파일이 정상 복구되면 present와 metadata status 복원
- unavailable root의 기존 present/missing 상태가 바뀌지 않음
- partial enumeration root에서 unseen row를 missing으로 만들지 않음
- 한 root 실패가 다른 성공 root의 projection 반영을 막지 않음
- duplicate session ID와 location conflict에서 임의 덮어쓰기·삭제가 없고 issue 반환
- no root selected가 빈 성공 결과

### 12.5 rebuild와 corruption

- catalog connection을 닫고 main DB 및 sidecar를 제거한 뒤 새 instance + reconcile로 정상 파일 기반 목록과 order 복원
- garbage/not-a-database fixture가 corruption으로 감지됨
- corrupt main DB와 존재하는 sidecar가 quarantine에 bytes 그대로 보존됨
- quarantine 후 새 v1 DB가 만들어지고 session files에서 목록 복원
- quarantine fault injection에서 기존 DB components를 삭제하지 않고 새 DB 생성을 중단
- future user_version DB는 quarantine되지 않고 원래 bytes 보존
- rebuild 중 일부 root 접근 실패가 기존 사용자 파일을 바꾸지 않음

### 12.6 startup wiring과 regression

- fake catalog bootstrap start가 반복 호출돼도 reconciliation 한 번
- 성공한 root 선택/재승인이 새 reconciliation을 요청하고 panel 취소/실패는 요청하지 않음
- startup 진행 중 root 변경 refresh가 유실되지 않고 current pass 뒤 한 번 더 실행됨
- no-root, success, partial root failure, catalog failure 상태가 crash 없이 전달
- live MainWindowView/Settings 또는 app dependency construction이 실제 Application Support side effect 없이 test construction 가능
- 기존 DomainModelTests, StorageRepositoryTests와 integration smoke test 모두 통과

테스트를 줄여 위 항목을 이름만 문서화하지 않는다. 서로 같은 원인을 검증하는 경우 table-driven test로 합칠 수 있지만 각 acceptance 의미를 assertion으로 확인한다.

## 13. 수동 검증

실제 사용자 세션 대신 새 임시 test root와 합성 metadata만 사용하는 재현 가능한 절차를 docs/DEVELOPMENT.md에 기록한다.

권장 절차:

1. 빈 test root A와 B를 준비한다.
2. 동일 signed local build에서 A를 active root로 선택한다.
3. 개발용 test/helper가 아닌 안전한 합성 fixture 절차로 A와 historical B에 유효 metadata session을 둔다. 제품 UI에 임의 파일 생성 버튼을 추가하지 않는다.
4. 앱을 시작해 bootstrap이 crash 없이 끝나는지 확인한다.
5. 앱을 종료하고 Application Support의 catalog DB 묶음을 별도 임시 위치로 이동한 뒤 재실행하여 목록 projection이 다시 생기는지 확인한다.
6. metadata title/status를 안전한 합성 값으로 atomic 교체하고 재실행하여 DB projection이 바뀌는지 확인한다.
7. test root에서 한 합성 session folder를 별도 보관 위치로 이동하고 재실행하여 row가 삭제되지 않고 missing인지 확인한다.
8. 원래 위치로 복원하고 present로 돌아오는지 확인한다.

현재 T21 list UI가 없으므로 SQLite CLI를 필수 사용자 도구로 만들거나 실제 DB를 수동 수정하도록 요구하지 않는다. 자동 테스트가 핵심 acceptance를 증명하고, 수동 절차는 앱 시작·Sandbox scope와 실제 live path를 보조 검증한다. sqlite3 CLI를 사용했다면 read-only query와 합성 DB에 한정하고 정확한 명령을 기록한다.

## 14. 문서, Xcode project와 ignore 정책

- docs/ARCHITECTURE.md를 실제 T04 구조에 맞게 갱신한다.
  - Application SessionCatalog/scanner/store/reconciler 경계
  - App Support DB와 quarantine 위치
  - schema v1 columns, presence와 displayStatus 의미
  - file-authoritative projection과 root별 reconciliation algorithm
  - actor/transaction/security-scope 수명
  - corrupt DB recovery와 unsupported schema 차이
  - startup wiring
- docs/DEVELOPMENT.md를 갱신한다.
  - libsqlite3 사용과 추가 설치 불필요
  - build/test 명령
  - 임시 root를 이용한 safe manual verification
  - runtime DB 위치와 DB 삭제/rebuild 시험 시 app을 먼저 닫아야 한다는 점
  - quarantine 보존과 자동 정리 없음
- .gitignore에 최소 다음 runtime 변형을 빠짐없이 제외한다.
  - *.sqlite3
  - *.sqlite3-wal
  - *.sqlite3-shm
  - *.sqlite3-journal
  - 기존 *.sqlite, *.db 계열 유지
- ignore 확인은 임시 runtime DB를 git status에서 제외하는 방식으로 검증하되 runtime 파일을 repository 안에 실제 fixture로 남기지 않는다.
- LocalLectureSTT.xcodeproj에 새 source/test membership과 libsqlite3 link가 Debug/Release 모두 반영됐는지 확인한다.
- Package.resolved 또는 외부 dependency를 새로 만들지 않는다.
- MVP_SPEC.md의 제품 요구사항은 변경하지 않는다.
- T04를 dev에 통합하는 시점에만 PROJECT_STATUS.md를 T04 완료 및 T05 준비 상태로 갱신한다.
- 같은 통합 commit에서 IMPLEMENTATION_PLAN.md 9장의 T04 체크박스만 완료로 바꾼다.
- status에는 실제 test 수, task/dev CI, 미실시 수동 검증과 main이 T01에 남아 있음을 정확히 기록한다.

## 15. 명시적 제외 범위

- T05 마이크 권한, AVAudioEngine 캡처, input level과 무입력 감지
- T06 recovery audio writer와 .mov 생성
- T07 녹음 coordinator와 신규 session metadata lifecycle
- T08 final m4a 생성·검증과 checkpoint 실행
- T09 recording/paused → interrupted 변환, securing/finalizing 자동 재개
- T10 sleep/window/termination 정책
- STT engine, VAD, 모델 catalog/download/import
- transcript journal compact와 txt/md rendering
- T21의 완성된 session list/start/model UI
- 세션 상세, 재생, 편집, 파일 열기, 휴지통 삭제
- arbitrary audio import
- root 사이 session 파일 자동 이동·복사·중복 제거
- audio/transcript 내용 기반 metadata repair
- FTS, advanced search, pagination, sort preference UI
- SQLite cloud sync, telemetry, crash upload, auto update
- Core Data, SwiftData, 외부 SQLite package/ORM
- XPC, 별도 process, plugin framework
- main 승격, tag, release, PR

T04에서 목록 data source와 startup 상태를 만들 수 있지만 T21 화면을 미리 구현하지 않는다. 향후 API를 위해 사용되지 않는 범용 query language나 migration framework를 만들지 않는다.

## 16. 로컬 검증

구현 후 repository 밖의 별도 임시 DerivedData 경로를 사용하여 최소 다음을 실행한다.

~~~sh
xcodebuild -list -project LocalLectureSTT.xcodeproj

xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T04-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project LocalLectureSTT.xcodeproj \
  -scheme LocalLectureSTT \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/LocalLectureSTT-T04-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
~~~

추가 확인:

- app binary가 arm64
- app target이 libsqlite3를 실제 link하며 otool -L 또는 동등한 결과로 확인
- 모든 새 production/test source의 target membership
- Swift 6 concurrency warning과 actor isolation 오류 없음
- git diff --check
- 전체 task branch diff와 staged diff
- runtime .sqlite3, WAL/SHM/journal, quarantine, synthetic session root, bookmark registry, logs와 DerivedData가 Git에 없음
- 테스트가 실제 사용자 Application Support 또는 실제 session root를 변경하지 않음
- 사용자 root scan 전후 bytes/tree 불변 test
- 기존 AppIntents metadata skipped 진단과 T04가 만든 새 warning 구분
- T05 이후 기능과 외부 dependency가 들어오지 않음

test log에서 총 실행 수와 T04 test 범주를 기록한다. 테스트 실패나 warning을 숨기기 위해 schema 검증, quick_check, transaction, root 접근 또는 원본 보존 규칙을 약화하지 않는다.

## 17. commit, CI와 dev 통합

1. T04 구현, unit/integration tests와 관련 문서 갱신을 task branch에서 완료한다.
2. 전체 local diff, git diff --check, build와 전체 test가 통과한 경우에만 T04 관련 경로를 명시적으로 stage한다.
3. task branch의 최종 commit 메시지는 정확히 다음 형식을 사용한다. 논리적 중간 commit이 필요하면 1~3개 범위에서 모두 끝에 (T04)를 붙이고 Conventional Commits 형식을 지킨다.

~~~text
feat(catalog): add rebuildable session catalog (T04)
~~~

4. task branch를 push하고 해당 branch의 macOS CI가 통과했는지 run URL 또는 run ID와 함께 확인한다.
5. CI 실패 시 같은 구현 세션에서 T04 범위 원인을 수정하고 local 검증과 CI를 다시 수행한다. task CI가 실패 또는 미확인 상태면 dev에 병합하지 않는다.
6. merge 직전 git fetch origin 후 원격 dev가 branch 생성 기준선 이후 예상 밖으로 변경되지 않았는지 확인한다. 변경됐다면 덮어쓰지 말고 최신 dev에 안전하게 맞춘 뒤 전체 검증을 다시 한다.
7. 모든 완료 조건이 충족되면 local dev에서 task branch를 squash merge한다.
8. squash commit을 만들기 전에 PROJECT_STATUS.md와 IMPLEMENTATION_PLAN.md T04 체크박스를 문서 규칙대로 갱신한다.
9. dev squash commit 제목도 정확히 다음을 사용한다.

~~~text
feat(catalog): add rebuildable session catalog (T04)
~~~

10. merge된 dev에서 위 clean build와 전체 test를 다시 실행한다.
11. 검증된 dev를 push하고 dev의 macOS CI 통과를 확인한다.
12. origin/dev가 안전하고 CI가 성공한 뒤에만 local/remote T04 task branch를 삭제한다.
13. 최종 checkout은 dev, working tree는 clean, local dev와 origin/dev는 동일해야 한다.

commit 전에 모델, 실제 녹음/transcript, session root, bookmark registry, Application Support 내용, SQLite DB/sidecar/quarantine, log, credential, build product와 개인 Xcode 상태가 stage되지 않았는지 반드시 확인한다. main에는 어떤 commit도 push하거나 merge하지 않는다.

## 18. 완료 조건

다음 항목을 모두 근거와 함께 확인해야 완료다.

- [ ] 최신 clean dev에서 정확한 T04 task branch 생성
- [ ] macOS system SQLite3만 사용하고 외부 dependency 없음
- [ ] app target libsqlite3 link와 source/test target membership 확인
- [ ] Application/Domain 경계에 SQLite/URL/C pointer가 노출되지 않음
- [ ] validated SessionFolderName parser와 metadata short-ID 검증
- [ ] symlink를 따라 root 밖으로 나가지 않는 direct-child scanner
- [ ] read-only scan과 기존 write-required repository 의미 보존
- [ ] active/historical root 전체 scan
- [ ] catalog item/projection/presence/displayStatus/report 계약
- [ ] App Support 고정 DB 위치와 SQLite schema v1
- [ ] user_version, expected schema, future schema 보존
- [ ] parameter binding, statement finalize, busy timeout과 connection lifetime
- [ ] WAL, synchronous FULL, foreign_keys ON, trusted_schema OFF와 결과 검사
- [ ] transaction 기반 batch upsert/missing/unreadable 반영
- [ ] file value가 DB 값과 timestamp보다 항상 우선
- [ ] complete root에서만 DB-only row missing, DELETE 없음
- [ ] unavailable/partial root row 상태 보존
- [ ] corrupt/unsupported/mismatch metadata의 원본 보존과 error/issue
- [ ] missing/unreadable → present 복구
- [ ] duplicate identity/location conflict에서 임의 덮어쓰기 없음
- [ ] DB deletion 후 정상 파일 기반 동일 목록과 order rebuild
- [ ] corrupt DB와 sidecar quarantine 후 rebuild
- [ ] quarantine failure와 future schema에서 기존 bytes 보존
- [ ] 앱 시작당 한 번 live reconciliation 연결과 중복 start 방지
- [ ] 성공한 root 선택/재승인 후 refresh와 취소/실패 시 무변경
- [ ] no-root/partial-root/catalog-failure startup 상태 처리
- [ ] 사용자 root scan 비변경 테스트
- [ ] parser/projection/schema/query/reconciliation/rebuild/corruption/startup 자동 테스트
- [ ] 기존 T01~T03 tests와 integration smoke test 통과
- [ ] local clean Debug build와 전체 test 통과
- [ ] 새 warning 또는 Swift concurrency issue 없음
- [ ] docs/ARCHITECTURE.md와 docs/DEVELOPMENT.md 실제 구현과 일치
- [ ] .sqlite3와 모든 sidecar/quarantine runtime 파일 ignore
- [ ] T05 이후 기능, T21 UI, 외부 dependency, runtime user data 미포함
- [ ] task branch commit/push와 task CI 통과
- [ ] T04 checklist와 PROJECT_STATUS 갱신
- [ ] 정확한 Conventional Commit으로 dev squash 통합
- [ ] merge된 dev build/test 재검증 통과
- [ ] origin/dev CI 통과
- [ ] main 미변경
- [ ] task branch 정리 후 working tree clean

## 19. 최종 보고 형식

다음 순서로 간결하지만 검증 가능하게 보고한다.

1. T04 상태: 완료 또는 차단
2. 사전 기준선과 환경
   - 시작 dev SHA
   - macOS, architecture, Xcode, Swift와 SQLite version
3. branch와 commit
   - task branch와 task commit
   - squash된 dev commit
   - local/remote dev SHA
   - main 미변경 확인과 SHA
4. 생성·수정한 파일
5. 핵심 설계
   - catalog item/projection/presence/displayStatus
   - App Support DB path와 schema v1
   - SQLite connection/transaction/concurrency 경계
   - root scanner와 security scope/read intent
   - complete/partial/unavailable reconciliation 규칙
   - corrupt DB quarantine/rebuild와 future schema 보존
   - app startup wiring
6. 실행한 local build/test 명령과 결과
   - 총 test 수와 새 T04 test 수
   - deletion/corruption/transaction/symlink/unavailable-root 결과
   - 새 warning 유무
7. 수동 검증
   - 실행한 절차와 결과
   - 미실시 항목과 정확한 이유
8. task branch와 dev CI run URL/ID 및 결과
9. 명세 또는 프롬프트에서 벗어난 사항
10. 남은 위험과 후속 수동 확인
11. runtime DB, quarantine, session, bookmark와 후속 기능이 commit되지 않았다는 확인
12. T05 시작 가능 여부

완료 조건을 모두 충족할 때까지 같은 구현 세션에서 T04 범위 안의 문제를 해결한다. 명세 충돌, 사용자 파일 보존 불확실성, local build/test 실패, task CI 실패·미확인, dev CI 실패가 남아 있으면 완료라고 보고하거나 dev에 병합하지 않는다.
