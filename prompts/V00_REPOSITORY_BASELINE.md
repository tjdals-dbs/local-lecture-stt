# V00 실행 프롬프트 — GitHub 저장소 기준선

## 역할

당신은 `/Users/andyoon/stt` 저장소의 V00 저장소 기준선만 담당하는 구현 세션이다. 앱 구현을 시작하지 말고, 확정된 명세·계획·작업 규칙을 안전하게 `dev` 브랜치의 최초 원격 기준선으로 만드는 데 집중하라.

## 목표

성공 시 다음이 모두 참이어야 한다.

- `origin`이 사용자가 만든 `https://github.com/tjdals-dbs/local-lecture-stt.git`을 가리킨다.
- 원격 저장소가 예상대로 비어 있었음이 확인된다.
- 최초 개발 브랜치 `dev`가 생성되어 있다.
- 저장소 루트에 최소 `README.md`와 방어적인 `.gitignore`가 있다.
- 승인된 문서와 저장소 제어 파일만 Git에 추적된다.
- V00 기준선과 최신 상태 문서가 commit되어 `origin/dev`에 push되어 있다.
- 로컬 `dev` HEAD와 원격 `dev` HEAD가 일치한다.
- `PROJECT_STATUS.md`는 V00 완료와 다음 작업 T01을 가리킨다.
- `IMPLEMENTATION_PLAN.md`의 V00 체크박스가 완료 상태다.
- `main` 브랜치에는 commit이나 push가 없다.
- Xcode 프로젝트나 앱 코드는 생성되지 않았다.

## 허가된 변경

이 프롬프트는 다음 외부 변경을 명시적으로 허가한다.

- 기존 `origin`의 정확한 상태를 읽는 것
- 빈 원격 저장소에 `dev` 브랜치를 최초 push하는 것
- V00 완료 상태를 기록한 후 `dev`를 다시 push하는 것

GitHub 저장소 생성·삭제, 원격 URL 변경, 저장소 공개 범위 변경, branch protection 설정, `main` 생성, tag 또는 release 생성은 허가하지 않는다.

## 먼저 확인할 컨텍스트

전체 명세를 반복해서 읽지 말고 다음만 확인하라.

1. 저장소 루트의 `AGENTS.md` 전체
2. `PROJECT_STATUS.md` 전체
3. `IMPLEMENTATION_PLAN.md`의 1장, 2장, 5.1~5.7절, 전체 진행 체크리스트
4. `MVP_SPEC.md`의 문서 제목, 상태, 버전만 확인
5. 실제 Git 상태
   - 현재 디렉터리
   - 현재 branch와 commit 유무
   - `git status`
   - `git remote -v`
   - local branch 목록
   - `git ls-remote --heads origin`

현재 알려진 상태는 다음과 같지만 반드시 실제 결과로 다시 검증하라.

- 작업 디렉터리: `/Users/andyoon/stt`
- 현재 local branch: commit이 아직 없는 unborn `main`
- 예상 원격: `origin = https://github.com/tjdals-dbs/local-lecture-stt.git`
- 예상 원격 branch: 없음
- 현재 승인된 미추적 파일:
  - `AGENTS.md`
  - `IMPLEMENTATION_PLAN.md`
  - `MVP_SPEC.md`
  - `PROJECT_STATUS.md`
  - `prompts/V00_REPOSITORY_BASELINE.md`

## 수행 범위

### 1. 안전 점검

- 예상과 다른 tracked 파일, commit, branch, remote head 또는 remote URL이 있으면 덮어쓰거나 정리하지 말고 중단하라.
- 관련 없는 사용자 파일이 있더라도 삭제, 이동, reset, checkout, clean하지 말라.
- `origin`이 비어 있지 않으면 force push하거나 별도 root history를 만들지 말고 발견 내용을 보고하라.

### 2. `README.md`

간결한 초기 README를 작성하라. 최소한 다음을 포함한다.

- 프로젝트 이름: Local Lecture STT
- macOS용 완전 로컬·온디바이스 강의 녹음 및 실시간 STT 앱이라는 한 문단 설명
- 현재 상태: specification/repository setup 단계이며 아직 실행 가능한 앱 없음
- 주요 원칙: 오디오 안전성, 오프라인 실행, 한국어·영어 혼용, 확장 가능한 STT 엔진
- 문서 링크:
  - `MVP_SPEC.md`
  - `IMPLEMENTATION_PLAN.md`
  - `PROJECT_STATUS.md`
- 브랜치 정책 요약:
  - `main`: 빌드·실행이 검증된 버전만
  - `dev`: 완료 Task 통합
  - `task/*`: 개별 Task
- 모델 weight와 사용자 녹음은 저장소에 포함하지 않는다는 안내

아직 존재하지 않는 기능, 스크린샷, 설치법, 성능 수치를 완료된 것처럼 쓰지 말라.

### 3. `.gitignore`

macOS·Xcode·Swift 프로젝트에 필요한 일반 산출물과 이 앱의 민감·대용량 runtime 데이터를 제외하라. 최소 범주는 다음과 같다.

- `.DS_Store`
- Xcode `DerivedData`, build 산출물, 사용자별 `xcuserdata`, `*.xcuserstate`
- SwiftPM `.build`와 사용자별 IDE 상태
- 다운로드하거나 변환한 model weight와 model staging 디렉터리
- 사용자 session, recording, recovery, transcript runtime 데이터
- `.m4a`, recovery `.mov`, 실제 benchmark 원본
- runtime SQLite DB와 WAL/SHM
- log, crash dump, temporary download, staging 디렉터리
- `.env` 및 local secret 파일
- 인증서, signing key, provisioning secret
- 빌드된 `.app`, `.dmg`, release `.zip`

다음은 나중에 Git에 포함되어야 하므로 잘못 ignore하지 말라.

- Swift source와 tests
- Xcode project 및 shared scheme
- entitlement와 일반 설정 파일
- `Package.resolved`
- 고정 model catalog, manifest schema, checksum, license 문서
- 현재 Markdown 문서와 `prompts/`

`git check-ignore -v --no-index` 또는 동등한 방법으로 대표적인 민감 경로가 제외되고 승인 문서가 제외되지 않는지 확인하라. 실제 model, recording, credential 파일을 만들 필요는 없다.

### 4. 최초 `dev` 기준선

- unborn `main`에서 최초 `dev` 브랜치를 생성하고 전환하라.
- 다음 파일만 명시적으로 stage하라.
  - `.gitignore`
  - `AGENTS.md`
  - `IMPLEMENTATION_PLAN.md`
  - `MVP_SPEC.md`
  - `PROJECT_STATUS.md`
  - `README.md`
  - `prompts/V00_REPOSITORY_BASELINE.md`
- commit 전에 `git diff --check`, staged diff, `git status`, `git check-ignore` 결과를 검토하라.
- 첫 commit 메시지는 정확히 다음을 사용하라.

```text
docs: define MVP specification and implementation plan
```

- 첫 commit을 `git push -u origin dev`로 push하라.
- 인증 또는 네트워크 오류가 발생하면 안전한 재시도만 수행하고, 지속되면 local commit을 보존한 채 중단하여 보고하라.

### 5. V00 완료 상태 기록

첫 push가 성공한 뒤 다음 두 파일만 갱신하라.

- `PROJECT_STATUS.md`
  - V00 완료
  - 현재 branch와 원격 기준선: `dev`
  - 다음 작업: T01
  - `main`: 아직 생성하지 않음
  - 앱 구현: 아직 시작하지 않음
  - V00 handoff를 완료 기록으로 축약하고 T01 준비 상태를 명시
- `IMPLEMENTATION_PLAN.md`
  - 전체 진행 체크리스트의 V00 항목만 `[x]`로 변경

두 파일의 diff만 검토하고 다음 commit을 만들어 push하라.

```text
docs: record V00 repository baseline
```

### 6. 최종 검증

- 현재 branch가 `dev`인지 확인한다.
- working tree가 clean인지 확인한다.
- 추적 파일이 승인된 7개 기준선 파일과 완료 상태 갱신뿐인지 확인한다.
- `main` local/remote branch가 생성되지 않았는지 확인한다.
- `origin/dev`가 존재하는지 확인한다.
- local `dev` HEAD와 `origin/dev` HEAD가 같은지 확인한다.
- 최근 두 commit의 메시지와 순서를 확인한다.
- Xcode 프로젝트, source code, binary, model, recording, DB, log가 생성·추적되지 않았는지 확인한다.

## 제외 범위

- T01 또는 이후 Task 구현
- Xcode 프로젝트와 Swift source 생성
- GitHub Actions 생성
- `main` 생성 또는 기본 브랜치 변경
- branch protection, secret scanning, repository settings 변경
- tag, release, issue, Pull Request 생성
- dependency 설치 또는 model 다운로드
- 앱 빌드와 테스트

## 중단 조건

다음 중 하나면 추측으로 해결하거나 파괴적 변경을 하지 말고 중단하여 보고하라.

- 원격 URL이 예상과 다름
- 원격에 예상하지 않은 commit 또는 branch가 있음
- 기존 local commit이나 사용자 변경과 충돌함
- 승인 목록 밖의 파일을 첫 commit에 포함해야만 진행할 수 있음
- 인증 실패로 push할 수 없음
- `.gitignore` 요구가 정상 source 또는 canonical 문서를 숨김
- `dev` 생성이 기존 branch를 덮어쓸 위험이 있음

## 최종 보고 형식

다음 순서로 간결하게 보고하라.

1. V00 상태: 완료 또는 차단
2. 현재 branch와 `dev` local/remote HEAD
3. 생성·수정한 파일
4. 생성한 두 commit SHA와 메시지
5. 실행한 Git 및 ignore 검증과 결과
6. push 결과
7. 승인되지 않은 파일이 추적되지 않았다는 확인
8. `main`이 생성되지 않았다는 확인
9. 남은 위험 또는 수동 확인 사항
10. T01 시작 가능 여부

완료 조건을 모두 충족할 때까지 이 V00 범위 안에서 진행하라. 범위를 넓혀 T01을 시작하지 말라.
