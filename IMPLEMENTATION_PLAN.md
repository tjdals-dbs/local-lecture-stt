# 로컬 강의 STT 앱 MVP 구현 작업 목록

- 문서 상태: 확정 구현 기준선
- 계획 버전: 1.3
- 작성일: 2026-08-29
- 기준 명세: `MVP_SPEC.md` 1.0

## 1. 이 세션의 역할

현재 조정 세션에서는 구현 작업을 하지 않는다.

이 세션의 책임은 다음으로 제한한다.

- 확정 명세 유지 및 변경 관리
- 구현 작업의 순서, 범위, 의존성 관리
- 다른 구현 세션에 전달할 작업별 프롬프트 작성
- 구현 세션의 task branch 결과를 독립 검토하고 보완 또는 통합 프롬프트 작성
- 명세와 실제 구현 사이의 누락 또는 범위 이탈 검토

소스 코드 작성, Xcode 프로젝트 생성, 라이브러리 설치, 빌드, 테스트 실행은 각 구현 세션이 담당한다. 명세서, 구현 계획, 프롬프트 같은 조정 문서는 이 세션에서 작성할 수 있다.

## 2. 실행 원칙

### 2.1 작업 단위

- 아래의 `T01`~`T27`을 기본적으로 하나의 구현 세션에 전달할 수 있는 프롬프트 단위로 사용한다.
- 작업이 예상보다 커지면 구현 전에 하위 작업으로 나누되, 인접한 다음 작업까지 임의로 구현하지 않는다.
- 각 구현 세션은 `AGENTS.md`, `PROJECT_STATUS.md`, 현재 Task 항목, 프롬프트가 지정한 관련 명세 절, 현재 저장소 상태를 먼저 확인한다.
- 매 Task마다 `MVP_SPEC.md`와 이 문서 전체를 반복해서 읽지 않는다. 제품 동작 충돌이나 관련 절이 불명확할 때만 범위를 넓혀 확인한다.
- 이전 작업이 실제로 구현되어 있다는 가정 대신 코드와 테스트로 확인한다.
- 안전한 범위의 세부 구현 판단은 구현 세션이 할 수 있지만 제품 동작을 바꾸는 판단은 이 조정 세션으로 돌려보낸다.

### 2.2 완료 조건

각 작업은 다음을 모두 만족해야 완료로 판정한다.

- 할당된 범위가 구현됨
- 관련 자동 테스트 또는 재현 가능한 수동 검증 절차가 추가됨
- 기존 테스트가 통과함
- 새 경고 또는 명백한 정적 분석 오류가 없음
- 명세와 다른 동작이나 후속 결정이 필요한 부분이 결과 보고에 명시됨
- 변경 파일, 실행한 검증 명령, 남은 위험이 결과 보고에 포함됨
- 조정 세션이 task branch의 acceptance matrix, diff, 테스트와 CI 근거를 독립 검토함
- 독립 검토 승인 후 별도 통합 프롬프트로 `dev` 병합, 병합 후 검증, `dev` CI와 상태 문서 갱신까지 완료됨

구현 세션이 위 기능·검증 조건을 자체 충족한 시점은 `검토 준비 완료`인 구현 후보 상태다. 조정 세션의 독립 검토와 `dev` 통합 전에는 공식 Task `완료`로 판정하지 않는다.

### 2.3 범위 제한

구현 세션은 다음 후속 기능을 선행 구현하지 않는다.

- 시스템 오디오
- USB 마이크 선택 및 자동 전환
- 화자 분리
- 북마크
- 후처리 STT와 요약
- Obsidian 연동
- 파일 가져오기 STT
- 클라우드 기능
- 다중 창 또는 다중 녹음
- 모델 자동 업데이트

확장을 위한 인터페이스 경계는 만들 수 있지만 사용하지 않는 일반화나 플러그인 프레임워크를 미리 만들지는 않는다.

### 2.4 세션과 컨텍스트 운영

- 현재 조정 세션은 프로젝트 전체 기간 동안 유지하며 명세, 작업 순서, 프롬프트, 게이트를 관리한다.
- 각 `T01`~`T27`은 원칙적으로 서로 다른 구현 세션에서 수행한다.
- 하나의 구현 세션은 할당된 Task의 구현, 수정, 테스트, task branch commit/push/CI와 독립 검토 후 승인된 `dev` 통합까지 유지한다.
- 최초 구현 프롬프트는 task branch의 검토 후보 제출까지만 지시한다. 조정 세션은 그 결과를 독립 검토하고, 보완이 필요하면 같은 구현 세션에 보완 프롬프트를 보내며, 승인한 경우에만 별도 통합 프롬프트를 보낸다.
- 동일 Task의 보완, task/dev CI 실패와 범위 안의 수정은 같은 구현 세션에서 계속 처리한다.
- 다음 번호 Task로 넘어갈 때 새 구현 세션을 시작한다.
- G1~G4는 가능하면 해당 기능을 구현하지 않은 별도의 검증 세션에서 점검한다.
- 모든 세션은 같은 저장소를 사용하고, 실제 Git 상태와 코드를 대화 기억보다 우선한다.

컨텍스트는 다음 문서로 전달한다.

- `AGENTS.md`: 모든 세션에 공통인 짧고 안정적인 작업 규칙
- `PROJECT_STATUS.md`: 현재 완료 Task, 다음 Task, 게이트, 알려진 문제와 최근 handoff
- `MVP_SPEC.md`: 제품 및 기술 명세 원본
- `IMPLEMENTATION_PLAN.md`: 전체 작업 범위와 의존성
- `docs/ARCHITECTURE.md`: T01부터 실제 구현 구조를 기록
- `docs/DEVELOPMENT.md`: T01부터 실제 빌드와 테스트 방법을 기록

`PROJECT_STATUS.md`와 구현 계획의 체크리스트는 독립 검토 승인 후 Task가 `dev`에 병합될 때만 함께 갱신한다. 실제 구조나 명령이 바뀌면 `ARCHITECTURE.md`와 `DEVELOPMENT.md`는 검토할 구현 사실의 일부이므로 task branch에서 먼저 갱신한다.

## 3. 우선순위 정의

| 우선순위 | 의미 |
| --- | --- |
| `P0` | 다음 핵심 작업을 막거나 오디오·데이터 안전성에 직접 영향을 주는 기반 작업 |
| `P1` | MVP 출시 전에 반드시 필요한 제품 기능 또는 안정성 작업 |
| `P2` | MVP에 포함되지만 핵심 녹음·STT 흐름이 안정된 뒤 구현할 수 있는 후순위 기능 |

우선순위와 실행 순서는 다르다. 같은 우선순위 안에서는 작업 번호와 의존성을 따른다. 모든 `P0`, `P1`, `P2` 작업이 완료되어야 명세상 MVP가 완료된다.

## 4. 마일스톤과 권장 실행 순서

| 마일스톤 | 작업 | 결과 |
| --- | --- | --- |
| V0 저장소 기준선 | V00 | 명세와 계획을 포함한 GitHub 원격 저장소와 안전한 ignore 정책 |
| M0 기반 | T01~T04 | 빌드 가능한 앱, 도메인 모델, 파일 저장소, 재구축 가능한 카탈로그 |
| M1 안전한 녹음기 | T05~T10 | STT 없이도 장시간 녹음, 안전 종료, 복구, 창·잠자기 정책 동작 |
| M2 모델과 엔진 | T11~T17 | 교체 가능한 엔진 경계, 모델 설치, 두 엔진 비교, 제품 엔진 확정 |
| M3 실시간 STT | T18~T20 | VAD, 실시간 transcript, canonical 및 파생 transcript 완성 |
| M4 제품 UI | T21~T25 | 시작·녹음·목록·재생·편집·오류 처리를 포함한 MVP UX 완성 |
| M5 검증 및 배포 | T26~T27 | 장애 복구, 장시간 성능, 오프라인 및 직접 배포 검증 완료 |

권장 기본 순서는 `V00 → T01 → T02 → ... → T27`이다. 의존성이 없는 일부 작업은 병렬화할 수 있지만, 현재 계획은 한 작업씩 별도 세션에 맡기는 흐름을 기준으로 한다.

## 5. Git 및 GitHub 버전 관리 정책

### 5.1 V00 저장소 기준선

T01을 시작하기 전에 별도의 저장소 설정 프롬프트로 다음을 수행한다.

- GitHub 저장소 이름과 공개 범위를 사용자가 결정한다.
- 초기에는 private 저장소를 권장하며, MVP와 라이선스 검토가 끝난 뒤 public 전환 여부를 다시 결정한다.
- 아직 실행 가능한 앱이 없으므로 최초 문서 기준선은 `dev` 브랜치에 만든다.
- GitHub 원격 저장소를 연결한다.
- `MVP_SPEC.md`, `IMPLEMENTATION_PLAN.md`, `AGENTS.md`, `PROJECT_STATUS.md`, 최소 `README.md`, `.gitignore`, `prompts/V00_REPOSITORY_BASELINE.md`를 첫 기준선에 포함한다.
- 첫 커밋 권장 메시지: `docs: define MVP specification and implementation plan`
- 첫 커밋을 `dev`에 push한 뒤 T01을 시작한다.
- T01에서 앱이 실제로 빌드되고 실행되는 것이 확인되면 그 시점의 `dev`를 최초 `main` 기준선으로 승격한다.
- 최초에는 `dev`가 GitHub 기본 브랜치가 될 수 있다. T01에서 `main`을 만든 뒤 GitHub 기본 브랜치를 `main`으로 변경한다.

GitHub 저장소 생성과 원격 연결은 외부 상태 변경이므로, 실행 프롬프트에서 저장소 이름, 공개 범위, 원격 URL을 명시적으로 확정한 뒤 수행한다.

### 5.2 브랜치 전략

- `main`에는 빌드와 실행이 확인된 검증 버전만 둔다.
- `dev`는 다음 검증 버전을 조립하는 통합 브랜치다.
- `dev`도 고의로 깨진 상태를 허용하지 않는다. 각 task는 최소한 해당 작업의 빌드와 테스트를 통과한 뒤에만 `dev`로 병합한다.
- 구현 작업마다 최신 `dev`에서 짧게 유지되는 task branch를 만든다.
- 브랜치 이름 형식: `task/tNN-short-description`
- 예시:
  - `task/t01-project-bootstrap`
  - `task/t06-fragmented-audio-writer`
  - `task/t19-realtime-stt`
- 한 브랜치에는 원칙적으로 하나의 작업 ID만 포함한다.
- 다음 작업을 같은 브랜치에서 이어서 구현하지 않는다.
- `main`, `dev`, 공유된 task branch에는 force push하지 않는다.
- 사용자 또는 다른 작업의 변경을 reset, checkout, clean 등으로 제거하지 않는다.

개인 저장소이므로 일반 작업에 Pull Request를 만들지 않는다. task branch 내부에는 여러 논리적 커밋이 있을 수 있지만, 검증을 통과한 뒤 로컬에서 squash merge하여 `dev`에는 작업 하나가 하나의 명확한 commit으로 남도록 한다.

기본 흐름:

```text
task/tNN-* → 조정 세션 독립 검토 → dev → 검증 게이트 → main
```

- 일반 작업은 Pull Request 없이 `task/* → dev`로 병합한다.
- `task/* → dev`는 로컬에서 squash merge하여 작업 하나를 하나의 통합 commit으로 남긴다.
- `dev → main` 승격은 T01 최초 실행 기준선과 G1~G4 검증 게이트에서만 수행한다.
- `dev → main`은 로컬에서 squash 또는 rebase하지 않고 `--no-ff` merge commit을 사용하여 두 장기 브랜치의 공통 이력을 유지한다.
- 승격 검토 중에는 새로운 task를 `dev`에 병합하지 않아 검증 대상을 고정한다.
- `main`의 긴급 수정은 `hotfix/*`를 `main`에서 만들고, 수정 후 동일 변경을 `dev`에도 즉시 반영한다.

### 5.3 작업 중 커밋 시점

각 구현 세션은 보통 1~3개의 논리적 커밋을 만든다.

커밋하기 좋은 시점:

- 독립적인 하위 기능과 해당 테스트가 함께 완성됐을 때
- 스키마 또는 인터페이스 변경과 migration/contract test가 함께 완성됐을 때
- 외부 dependency revision 고정과 adapter 빌드가 함께 성공했을 때
- 큰 리팩터링 직전 현재의 정상 상태를 task branch에 보존할 때
- 구현 세션을 넘겨야 할 정도로 작업이 길어질 때
- 할당 작업의 모든 완료 조건과 테스트를 통과했을 때

커밋하지 않을 시점:

- 빌드가 깨진 임시 편집 상태
- 테스트 실패 원인을 모르는 상태
- 모델 파일, 녹음 파일, 로그, 사용자 데이터가 staging에 섞인 상태
- 관련 없는 사용자 변경이 포함된 상태
- 다음 작업 범위가 함께 섞인 상태

작업을 미완료 상태로 다른 세션에 넘겨야만 한다면 task branch에 `wip:` 커밋을 만들고 원격에 push할 수 있다. 이 경우 `dev`와 `main`에는 병합하지 않는다.

### 5.4 push와 병합 시점

| 시점 | commit | push | `dev` 병합 | `main` 병합 |
| --- | --- | --- | --- | --- |
| V00 문서 기준선 완료 | 필수 | `dev`에 push | 해당 없음 | 금지 |
| 작업 중 안정적인 중간 지점 | 선택 | 장시간 작업 또는 세션 전환 전에 task branch 권장 | 금지 | 금지 |
| 구현 후보의 로컬 검증 통과 | 필수 | task branch push | 금지 | 금지 |
| task branch CI 통과 및 검토 준비 | 유지 | task branch 유지 | 독립 검토 전 금지 | 금지 |
| 조정 세션 독립 검토 승인 | 별도 통합 프롬프트 대기 | 변경 없음 | 아직 금지 | 금지 |
| 통합 프롬프트 검증 통과 | squash integration commit | `dev` push | 허용 | 금지 |
| 작업이 막혔거나 테스트 실패 | 필요할 때 `wip:` | task branch에만 허용 | 금지 | 금지 |
| T01 실행 기준선 통과 | 승격 commit | `main` 생성 및 push | 해당 없음 | 허용 |
| G1~G4 결정 게이트 통과 | 승격 commit | `main`과 tag push | 해당 없음 | 검증된 `dev`만 허용 |

최초 구현 프롬프트의 끝에는 다음을 포함한다.

1. commit 전에 `git status`와 task branch 전체 diff를 검토한다.
2. 작업 범위에 해당하는 경로만 명시적으로 stage한다.
3. 관련 테스트가 통과한 경우 task ID가 포함된 commit을 만든다.
4. task branch를 push하고 해당 branch의 CI가 통과하는지 확인한다.
5. `PROJECT_STATUS.md`의 완료 상태와 구현 계획 체크리스트, `dev`, `main`을 변경하지 않는다.
6. task branch를 삭제하지 않고 `검토 준비 완료` 또는 `차단`으로 보고한다.

조정 세션은 acceptance matrix와 실제 diff·테스트·CI를 독립 검토한다. 보고서나 green CI만으로 승인하지 않는다. 누락이 있으면 같은 구현 세션과 branch에 보완 프롬프트를 보내며, 승인한 경우에만 다음 통합 프롬프트를 보낸다.

1. 최신 `dev`를 다시 확인하고 변경이 있으면 task branch에 안전하게 반영한다.
2. 영향받는 로컬 검증과 task CI를 다시 통과시킨다.
3. 최신 `dev`에 로컬 squash merge하고 `PROJECT_STATUS.md`와 구현 계획 체크리스트를 통합 commit에서 갱신한다.
4. merge된 `dev`에서 빌드와 테스트를 다시 실행한다.
5. 검증된 `dev`를 push하고 정확한 commit의 CI 결과를 확인한다.
6. local/origin `dev` 일치를 확인한 뒤에만 task branch를 삭제할 수 있다.

별도 통합 프롬프트가 없거나 하나라도 불확실하거나 실패하면 task branch까지만 유지하고 `dev`에 병합하지 않는다. `main` 승격은 별도의 게이트에서만 안내한다.

### 5.5 커밋 메시지

Conventional Commits에 가까운 짧은 형식을 사용하고 끝에 작업 ID를 적는다.

예시:

```text
chore(project): bootstrap macOS app (T01)
feat(storage): add atomic session repository (T03)
feat(audio): add fragmented recovery writer (T06)
test(recovery): cover interrupted finalization (T26)
docs(engine): record selected engine and model (T16)
fix(transcript): prevent overlap duplication (T18)
```

커밋 메시지는 무엇을 했는지보다 결과적으로 어떤 동작 또는 경계가 생겼는지를 표현한다.

### 5.6 `main` 보호와 CI

- T01에서 macOS build 및 test를 실행하는 GitHub Actions workflow를 추가한다.
- 이후 task branch, `dev`, `main`에서 동일한 핵심 검증을 실행한다.
- GitHub 요금제와 저장소 유형에서 지원한다면 `main`과 `dev`에 다음 보호를 적용한다.
  - force push 금지
  - branch 삭제 금지
- 1인 저장소이므로 다른 사람의 승인까지 필수로 요구하지 않는다.
- `main`에는 기능 개발 commit을 직접 만들지 않는다. 검증된 `dev` 승격 merge와 승인된 hotfix만 push한다.
- branch protection을 사용할 수 없는 경우에도 force push를 하지 않는 동일한 운영 규칙을 따른다.
- Pull Request가 없으므로 branch rules의 필수 status check에만 의존하지 않는다. task branch와 merge된 `dev`에서 GitHub Actions를 각각 실행하고 결과를 확인한다.
- 저장소 또는 계정에서 지원하는 secret scanning과 push protection을 활성화한다.
- push protection 경고는 임의로 우회하지 않고 실제 비밀 여부를 확인한 뒤 staging과 commit history에서 제거한다.

### 5.7 Git에 포함할 것과 제외할 것

반드시 추적:

- Swift source와 test
- Xcode project 및 공유 scheme
- 앱 entitlement와 설정 파일
- `Package.resolved`를 포함한 dependency revision 정보
- 고정 모델 카탈로그와 manifest schema
- checksum 목록과 라이선스 문서
- 명세, ADR, 테스트 결과 요약, 설치 및 배포 문서
- 작은 크기이며 재배포 권한이 명확한 test fixture

절대 추적하지 않음:

- 다운로드한 모델 weight와 변환 모델
- 실제 강의 녹음 및 transcript
- 세션 루트와 recovery 폴더
- `.m4a`, recovery `.mov`, 개인 benchmark 원본
- SQLite runtime DB
- Application Support 사본
- security-scoped bookmark 데이터
- 사용자별 Xcode 상태와 DerivedData
- 로그, crash dump, 임시 다운로드, staging 디렉터리
- 토큰, 서명 인증서, provisioning 관련 비밀, 환경별 credential
- 빌드된 `.app`, `.dmg`, `.zip`

모델과 실제 녹음은 Git LFS에도 올리지 않는다. LFS가 대용량 파일을 지원하더라도 이 프로젝트에서는 개인정보, 모델 라이선스, 저장소 비용과 clone 크기를 이유로 저장소 밖에서 관리한다. 꼭 필요한 대형 test fixture가 생기면 라이선스와 개인정보를 검토한 뒤 별도 결정을 내린다.

### 5.8 태그와 GitHub Release

결정 게이트를 통과한 `main`에 annotated tag를 만든다.

| 게이트 | 권장 태그 | 의미 |
| --- | --- | --- |
| G1 | `v0.1.0-alpha.1` | 안전한 로컬 녹음기 기준선 |
| G2 | `v0.1.0-alpha.2` | 엔진과 기본 모델 확정 |
| G3 | `v0.1.0-beta.1` | MVP 기능 완성, 안정성 검증 전 |
| G4 | `v0.1.0` | 장시간·복구·오프라인 검증 완료 |

- G1~G3는 tag만 push하고 필요하면 GitHub prerelease로 표시한다.
- G4에서는 설치 가능한 앱 패키지와 release notes를 GitHub Release에 첨부한다.
- 빌드된 앱이나 설치 이미지를 Git repository 자체에 commit하지 않는다.
- 서명과 notarization 여부는 T27에서 실제 공유 범위에 맞춰 확정한다.

## 6. 구현 작업 상세

### T01. macOS 프로젝트와 모듈 경계 생성

- 우선순위: `P0`
- 선행 작업: V00
- 관련 명세: 2장, 5장, 8장

범위:

- macOS 15+, Apple Silicon용 SwiftUI 앱 프로젝트 생성
- App Sandbox, 마이크 권한, 사용자 선택 파일 접근 entitlement 설정
- 단일 메인 창과 설정 화면의 최소 셸 생성
- App, Domain, Application, Infrastructure, Features처럼 책임이 드러나는 기본 디렉터리 또는 모듈 경계 설정
- 단위 테스트와 통합 테스트를 추가할 수 있는 테스트 target 구성
- 앱과 테스트가 재현 가능하게 빌드되는 기본 명령 문서화
- 실제 모듈 경계를 설명하는 `docs/ARCHITECTURE.md` 초기 작성
- 로컬 빌드와 테스트 절차를 설명하는 `docs/DEVELOPMENT.md` 초기 작성
- macOS build 및 test를 실행하는 GitHub Actions workflow 추가
- `.gitignore`가 사용자 데이터와 빌드 산출물을 제외하는지 검증
- T01 task branch를 `dev`에 병합한 뒤 빌드와 실행을 다시 검증하고 최초 `main` 기준선으로 승격

완료 기준:

- 빈 상태의 앱이 실행되고 메인 창을 표시한다.
- Debug 빌드와 테스트 target이 성공한다.
- `main`의 최초 코드 기준선이 동일한 commit에서 빌드되고 실행된다.
- 실제 STT, 모델 다운로드, 오디오 녹음은 아직 구현하지 않는다.

### T02. 도메인 모델, 스키마, 상태 머신

- 우선순위: `P0`
- 선행 작업: T01
- 관련 명세: 6장, 8장, 13장, 14장

범위:

- 세션 ID, 상태, capture outcome, 언어 모드, 엔진 및 모델 식별자 정의
- `metadata.json`, transcript segment, event, finalization checkpoint의 Codable/Sendable 도메인 타입 정의
- 모든 파일 스키마의 `schemaVersion` 정책 정의
- 허용된 세션 상태 전이와 금지된 전이 검증
- 밀리초 기반 미디어 시간과 ISO 8601 절대 시각 표현 분리
- 라이브러리 타입을 포함하지 않는 직렬화 가능한 DTO 확정

완료 기준:

- 정상 및 잘못된 상태 전이 단위 테스트가 있다.
- 주요 JSON 타입의 encode/decode round-trip 테스트가 있다.
- `recording/paused` 잔존 세션과 `interrupted` 결과를 구분할 수 있다.

### T03. 파일 저장소와 루트 폴더 권한

- 우선순위: `P0`
- 선행 작업: T02
- 관련 명세: 4.1절, 8.1절, 12장, 13장

범위:

- 최초 루트 폴더 선택과 security-scoped bookmark 저장 및 복원
- 변경된 활성 루트와 과거 루트 bookmark 관리
- 불변 세션 폴더 이름 생성
- 세션 디렉터리 레이아웃 생성
- JSON 임시 쓰기, flush, atomic rename 유틸리티
- append-only JSONL writer
- canonical 파일과 파생 파일을 구분하는 `SessionRepository`
- 임시 디렉터리를 사용하는 파일 저장소 테스트

완료 기준:

- 앱 재실행을 가정한 bookmark 복원 경로가 검증된다.
- 동일 제목 세션도 서로 충돌하지 않는 폴더를 만든다.
- 중간 쓰기 실패가 기존 정상 JSON을 덮어쓰지 않는다.
- 루트 접근 실패 시 원본을 변경하지 않고 재승인 필요 상태를 반환한다.

### T04. SQLite 세션 카탈로그와 파일 시스템 대조

- 우선순위: `P0`
- 선행 작업: T02, T03
- 관련 명세: 5.2절, 12.1절, 12.5절, 14.2절

범위:

- Application Support의 SQLite 카탈로그 구현
- 제목, 날짜, 길이, 상태를 이용한 목록 조회
- 세션 파일에서 insert/update 가능한 projection 정의
- 앱 실행 시 파일 시스템과 카탈로그 대조
- SQLite 삭제 또는 손상 시 전체 재구축
- 과거 루트의 세션 유지
- 파일 누락 세션을 `missing`으로 표시하고 자동 삭제하지 않는 정책

완료 기준:

- 카탈로그를 지운 뒤 세션 폴더만으로 동일한 목록을 복원한다.
- 파일에서 변경된 제목과 상태가 DB에 다시 반영된다.
- DB에만 남은 항목이 자동 삭제되지 않고 누락 상태로 식별된다.

### T05. 마이크 캡처와 입력 신호 모니터

- 우선순위: `P0`
- 선행 작업: T01, T02
- 관련 명세: 3.1절, 3.2절, 10.1절, 10.3절, 16장

범위:

- 마이크 권한 상태 확인 및 요청 경계
- `AVAudioEngine` input tap 기반 PCM 캡처
- 저장 consumer와 STT consumer가 독립적으로 구독할 수 있는 오디오 전달 경계
- 입력 레벨 계산 및 UI에서 사용할 상태 발행
- 5초 무입력 경고의 초기 구현
- 입력 장치 연결 해제 감지와 오류 이벤트
- USB 자동 전환은 구현하지 않음

완료 기준:

- 권한 거부, 정상 입력, 무입력, 장치 해제 상태를 구분한다.
- 느린 STT consumer가 오디오 저장 consumer를 막지 않는 구조다.
- 캡처 시작과 중지가 반복되어도 input tap 또는 engine이 중복 등록되지 않는다.

### T06. 복구 가능한 fragmented 오디오 writer

- 우선순위: `P0`
- 선행 작업: T03, T05
- 관련 명세: 11.1절, 11.2절

범위:

- `AudioRecorder` 인터페이스 구현
- audio-only fragmented `.mov` writer 구현
- AAC-LC, mono, 48kHz, 96kbps 설정
- 최초 약 1초, 이후 약 10초 fragment 정책
- 안전한 start, append, flush, stop 동작
- writer 실패를 typed error와 session event로 전달

완료 기준:

- 생성된 recovery 파일이 재생 또는 AVFoundation으로 읽기 가능하다.
- 22초 이상의 합성 입력에서 여러 active fragment와 finish 전 prefix decode, 정상 완료 파일의 시작·끝 decode를 검증한다.
- 반복·동시 시작/종료, cancellation, writer/converter/storage fault, terminal event와 finish/scope exact-once cleanup 테스트가 있다.
- STT를 연결하지 않아도 오디오가 독립적으로 저장된다.

### T07. 녹음 세션 coordinator와 최소 녹음 UI

- 우선순위: `P0`
- 선행 작업: T04, T05, T06
- 관련 명세: 4.2~4.4절, 5장, 6장

범위:

- 한 번에 하나의 활성 세션만 허용하는 coordinator
- 준비, 녹음, 안전 저장 상태 연결
- 제목 및 자동 제목, 시작 시각, 활성 녹음 시간 기록
- 녹음 시작과 종료의 최소 UI
- 경과 시간과 입력 레벨 표시
- metadata 및 events journal 갱신
- STT와 일시정지는 아직 연결하지 않음

완료 기준:

- 새 세션을 시작하고 종료하여 recovery 오디오와 메타데이터를 생성한다.
- 두 번째 세션 동시 시작을 거부한다.
- UI 상태와 저장된 세션 상태가 일치한다.

### T08. 최종 오디오 마무리 파이프라인

- 우선순위: `P0`
- 선행 작업: T06, T07
- 관련 명세: 6장, 11.3절, 14.1절, 17.4절

범위:

- `securing → finalizing` 단계 구현
- `audio.finalizing.m4a` 생성
- 길이, 읽기 가능성, 시작 및 끝부분 디코딩 검증
- 검증 성공 후 `audio.m4a` atomic rename
- 체크포인트 단계별 기록
- 모든 검증 이후 recovery 오디오 삭제
- 필수 저장과 전체 마무리 API 분리

완료 기준:

- 2시간 상당 샘플 또는 생성 오디오를 대상으로 최종화 경로를 검증한다.
- 최종 파일 검증 실패 시 recovery 원본이 남는다.
- 같은 체크포인트에서 재실행해도 결과가 중복되거나 손상되지 않는다.

### T09. 앱 시작 시 세션 복구

- 우선순위: `P0`
- 선행 작업: T03, T04, T08
- 관련 명세: 6.2절, 14장, 17.6절

범위:

- 불완전 세션 스캔
- 잔존 `recording/paused` 세션을 `interrupted`로 전환
- `securing/finalizing` 체크포인트 자동 재개
- 임시 최종 파일과 recovery 원본의 우선순위 처리
- 손상 및 누락 파일의 보존과 오류 상태
- 복구 결과 카탈로그 반영

완료 기준:

- 각 체크포인트에서 중단한 fixture를 재개하는 통합 테스트가 있다.
- 복구를 반복 실행해도 최종 결과가 동일하다.
- 복구 불가능한 데이터를 자동 삭제하지 않는다.

### T10. 잠자기, 창 닫기, 앱 종료 생명주기

- 우선순위: `P0`
- 선행 작업: T07, T08, T09
- 관련 명세: 7장

범위:

- 활성 작업 중 사용자 유휴 시스템 잠자기 방지
- 디스플레이 잠자기는 허용
- macOS sleep/wake 알림 처리
- 녹음 중 시스템 잠자기를 `interrupted`로 전환
- 마무리 중 wake 후 자동 재개
- 마지막 창 닫기 후 활성 작업 지속
- 유한 작업 완료 후 창이 없을 때 자동 앱 종료
- 창 재개방 시 자동 종료 예약 취소
- `⌘Q`에서 필수 저장 후 종료 흐름

완료 기준:

- 창 닫기와 앱 종료가 서로 다른 경로로 테스트된다.
- 녹음 중 창을 닫아도 녹음이 계속된다.
- 마무리 성공 후 창이 없으면 종료 요청이 발생한다.
- 앱 종료는 전체 최종화를 기다리지 않고 필수 저장까지만 기다린다.

### T11. `STTEngine` 계약과 결정론적 가짜 엔진

- 우선순위: `P0`
- 선행 작업: T02
- 관련 명세: 8.2절, 8.3절, 9장

범위:

- 라이브러리 독립적인 `STTEngine` 프로토콜
- 엔진 capability, lifecycle, request, partial/final result, typed error 정의
- 모든 경계 타입을 Codable/Sendable로 유지
- 향후 XPC로 옮길 수 있는 요청 단위 유지
- 시간에 따라 결정된 결과를 내는 fake engine
- 취소, 지연, 실패, backlog 테스트 지원

완료 기준:

- 앱 코드가 WhisperKit 또는 whisper.cpp 타입을 참조하지 않는다.
- fake engine으로 부분 및 확정 결과, 지연, 오류를 재현한다.
- 세션당 하나의 모델만 고정하는 계약이 테스트된다.

### T12. 모델 저장소, manifest, 가져오기

- 우선순위: `P0`
- 선행 작업: T03, T11
- 관련 명세: 9.2절, 9.3절, 15.1절, 15.3절, 15.4절

범위:

- 앱 번들 고정 모델 카탈로그 스키마
- engine/model/revision namespaced 설치 경로
- 파일 목록, SHA-256, 호환성, 라이선스 manifest
- 설치 모델 검색 및 검증
- 기존 모델 폴더를 앱 저장소로 복사하는 가져오기
- revision 공존
- 참조 세션 경고를 포함한 영구 삭제 정책
- 자동 업데이트 및 원격 카탈로그 확인 금지

완료 기준:

- 유효 모델, 손상 모델, 호환되지 않는 모델 상태를 구분한다.
- 가져오기 후 원본 폴더 없이 앱 저장소 사본만으로 동작한다.
- 새 revision이 기존 revision을 덮어쓰지 않는다.

### T13. 모델 다운로드, 검증, 원자적 설치

- 우선순위: `P0`
- 선행 작업: T12
- 관련 명세: 15.1절, 15.2절, 17.7절

범위:

- 사용자 명시 동작으로만 시작되는 다운로드
- 설치 전 저장 공간 확인
- 임시 다운로드와 staging 디렉터리
- 가능한 경우 background URLSession 재개
- SHA-256 검증
- 엔진 형식 검증
- atomic directory install
- 실패 또는 취소 후 정리 및 재시도
- 앱 시작 시 네트워크 요청이 없는지 검증

완료 기준:

- 정상, 중단 후 재개, 체크섬 불일치, 저장 공간 부족을 재현한다.
- 설치 완료 전에는 모델이 선택 가능 상태가 되지 않는다.
- 네트워크가 없어도 이미 설치된 모델 목록과 검증이 동작한다.

### T14. WhisperKit 실험 어댑터

- 우선순위: `P0`
- 선행 작업: T11, T12, T13
- 관련 명세: 9.1절, 9.2절, 17.1절, 17.5절

범위:

- 정확한 WhisperKit dependency revision 고정
- `STTEngine` 뒤에 WhisperKit 어댑터 구현
- 모델 로드, 언어 지정, context, 구간 추론, 취소 지원
- 엔진 및 모델 재현 정보 반환
- benchmark에서 latency, RTF, memory, transcript 결과 수집
- WhisperKit 고유 타입이 앱 경계 밖으로 나오지 않도록 유지

완료 기준:

- 설치된 후보 모델로 동일 입력을 반복 처리할 수 있다.
- 결과와 성능 지표를 파일로 비교 가능하게 내보낼 수 있다.
- adapter contract test를 통과한다.

### T15. whisper.cpp 실험 어댑터

- 우선순위: `P0`
- 선행 작업: T11, T12, T13
- 관련 명세: 9.1절, 9.2절, 17.1절, 17.5절

범위:

- 정확한 whisper.cpp dependency revision 고정
- `STTEngine` 뒤에 whisper.cpp 어댑터 구현
- T14와 동일한 입력, 출력, 취소, 언어 및 context 계약 지원
- 후보 모델 형식 및 설치 manifest 지원
- latency, RTF, memory, transcript 결과를 동일 형식으로 수집

완료 기준:

- T14와 동일한 benchmark 입력과 결과 형식을 사용한다.
- 라이브러리 타입이 앱 도메인에 노출되지 않는다.
- adapter contract test를 통과한다.

### T16. 엔진 및 모델 비교와 결정 기록

- 우선순위: `P0` 결정 게이트
- 선행 작업: T14, T15
- 관련 명세: 9.1절, 9.2절, 17.5절

범위:

- 사용자가 제공하는 실제 강의 10~15분 샘플 3개 이상으로 동일 조건 비교
- 한국어, 영어 전공 용어, 환각·반복·누락, latency, RTF, memory 기록
- 명세의 40/25/20/10/5 평가 비중으로 결과 정리
- `large-v3`, `large-v3-turbo` 우선 비교
- 필요할 때만 medium, 이후 양자화 검토
- 비교 결과를 ADR 또는 구현 결정 문서로 작성

완료 기준:

- 측정 자료와 대표 transcript를 사용자가 직접 검토할 수 있다.
- 사용자가 기본 엔진과 모델을 명시적으로 선택한다.
- 사용자 선택 전에는 T17을 시작하지 않는다.

### T17. 제품 엔진 고정 및 비선택 실험 코드 정리

- 우선순위: `P0`
- 선행 작업: T16 및 사용자 결정
- 관련 명세: 9장

범위:

- 선택된 어댑터를 MVP production engine으로 고정
- 선택 엔진과 모델 revision, checksum, 설정을 세션 메타데이터에 연결
- 비선택 엔진을 production target과 배포 의존성에서 제거
- 비교 결과와 재현 방법은 문서로 보존
- 시작 화면 기본 모델 정책 연결
- 자동 모델 업데이트 또는 자동 기본 변경이 없는지 확인

완료 기준:

- 제품 빌드에는 선택 엔진만 포함된다.
- `STTEngine` 인터페이스와 fake engine 테스트는 유지된다.
- 세션 파일만으로 사용한 엔진과 모델을 식별할 수 있다.

### T18. VAD, 발화 구간화, transcript reconciler

- 우선순위: `P0`
- 선행 작업: T05, T11
- 관련 명세: 10.2~10.5절

범위:

- 교체 가능한 `VoiceActivityDetector`
- 적응형 에너지 VAD 초기 구현
- 300ms prefix, 800ms 무음 확정, 20초 최대 구간, 1초 overlap
- 긴 발화 분할
- overlap 결과의 중복 제거를 담당하는 `TranscriptReconciler`
- 안정적인 segment UUID, sequence, start/end milliseconds 생성

완료 기준:

- 짧은 문장, 연속 발화, 긴 발화, 잡음, 긴 무음 fixture 테스트가 있다.
- overlap으로 같은 문구가 반복 저장되지 않는다.
- VAD 판단이 저장 오디오를 끊지 않는다.

### T19. 실시간 STT coordinator와 backpressure

- 우선순위: `P0`
- 선행 작업: T07, T17, T18
- 관련 명세: 4.3절, 9.4절, 10장, 17.1절

범위:

- 캡처 오디오의 16kHz mono STT 변환 경로
- 약 2초 간격 임시 추론과 발화 종료 확정 추론
- 한 개의 변경 가능한 partial과 불변 final segment 관리
- 직전 확정 segment만 bounded context로 전달
- 한국어, 영어, 자동 감지 후 세션 고정
- backlog 계측
- 밀릴 때 partial 빈도를 줄이고 final과 audio를 우선하는 저하 모드
- STT 실패가 녹음을 중단하지 않는 오류 격리
- 확정 segment의 transcript journal append

완료 기준:

- fake engine으로 partial/final, 오류, 취소, backlog 동작을 결정론적으로 테스트한다.
- 실제 선택 엔진으로 첫 결과와 확정 결과가 UI 상태에 전달된다.
- 세션 도중 모델과 언어 결정이 바뀌지 않는다.

### T20. canonical transcript와 Markdown 파생 파일

- 우선순위: `P0`
- 선행 작업: T03, T09, T19
- 관련 명세: 4.4절, 12.1절, 13.3절, 13.5절

범위:

- journal에서 `transcript.json`으로 compact
- `originalText`와 편집 가능한 `text` 분리
- segment 순서와 시간 검증
- `transcript.txt` renderer
- YAML front matter와 타임스탬프를 포함한 `transcript.md` renderer
- 파생 파일 atomic regeneration
- 외부에서 변경된 파생 파일을 canonical JSON으로 역수입하지 않는 정책

완료 기준:

- 동일 canonical JSON은 결정론적으로 동일한 파생 파일을 만든다.
- text 수정 후 originalText와 timestamp가 유지된다.
- 손상된 journal entry가 있으면 원본을 보존하고 명확한 오류를 낸다.

### T21. 세션 목록, 새 녹음, 모델 관리 UI

- 우선순위: `P1`
- 선행 작업: T04, T12, T13, T17
- 관련 명세: 4.1절, 4.2절, 5장, 15장

범위:

- 단일 창 내 세션 목록과 시작 화면
- 제목, 날짜, 길이, 상태 표시
- 시작 전 제목, 언어, 모델 선택
- 모델 준비 완료 전 녹음 시작 차단
- 모델 다운로드, 진행 상태, 검증, 가져오기, 삭제 UI
- 루트 저장 폴더 선택 및 변경 UI
- 제목 미입력 시 자동 제목

완료 기준:

- 최초 실행부터 모델 준비와 새 녹음 시작까지 막힌 이유가 명확히 표시된다.
- 녹음 중 모델 변경 UI가 노출되지 않는다.
- 앱 시작만으로 네트워크 요청이 발생하지 않는다.

### T22. 활성 녹음 및 실시간 transcript UI

- 우선순위: `P1`
- 선행 작업: T07, T19, T21
- 관련 명세: 3.1절, 4.3절, 5.2절

범위:

- 경과 시간, 입력 레벨, 세션 상태 표시
- 녹음 종료 제어
- final과 partial transcript의 명확한 시각적 구분
- 녹음 중 transcript 읽기 전용
- 자동 스크롤과 사용자의 수동 스크롤 충돌 방지
- 무입력, STT 지연, STT 오류의 비차단 안내
- background 작업 및 마무리 상태 표시

완료 기준:

- partial이 갱신되어도 final segment가 흔들리지 않는다.
- 장시간 transcript에서도 UI가 전체 데이터를 매번 재렌더링하지 않는다.
- STT 오류 중에도 녹음 상태와 종료 제어가 동작한다.

### T23. 세션 상세, 재생, 편집, 파일 관리

- 우선순위: `P1`
- 선행 작업: T04, T08, T20, T21
- 관련 명세: 3.1절, 4.4절, 5.2절, 12장, 16.2절

범위:

- `audio.m4a` 재생, 탐색, 현재 시간 표시
- transcript 타임스탬프 클릭 seek
- 마무리 완료 후 `text`만 수정
- 수정 후 파생 txt/md 재생성
- 제목 변경
- 오디오, canonical transcript, Markdown을 Finder에서 열기
- 세션 삭제 시 휴지통으로 이동
- 누락되거나 손상된 파일의 안전한 표시

완료 기준:

- 타임스탬프 클릭 시 해당 segment 시작으로 이동한다.
- text 편집이 timestamp와 originalText를 바꾸지 않는다.
- 삭제된 세션은 휴지통에서 복구 가능하다.
- missing/error 세션을 열어도 앱이 충돌하거나 자동 삭제하지 않는다.

### T24. 일시정지와 재개

- 우선순위: `P2`
- 선행 작업: T07, T19, T22
- 관련 명세: 3.1절, 4.3절, 6장, 11.1절

범위:

- `recording ↔ paused` 상태 전이
- 일시정지 시 열린 transcript 구간 확정
- 일시정지 중 오디오와 STT 입력 제외
- 재개 후 연속된 미디어 타임라인 유지
- 벽시계 일시정지 및 재개 event 기록
- 재실행 시 잔존 paused 세션을 interrupted 처리

완료 기준:

- 최종 오디오와 timestamp에 pause 공백이 포함되지 않는다.
- pause/resume 반복 후 segment 순서와 시간이 단조 증가한다.
- pause 중 창 닫기와 앱 종료 정책이 기존 생명주기 규칙을 따른다.

### T25. 통합 오류 표시와 로컬 진단 로그

- 우선순위: `P1`
- 선행 작업: T05, T09, T10, T13, T22, T23
- 관련 명세: 16장, 18장

범위:

- 마이크 권한, 무입력, 연결 해제, 저장 위치, 디스크, 모델, 엔진, 최종화 오류의 사용자 메시지 통합
- 오류별 복구 가능 여부와 다음 행동 표시
- session `events.jsonl` 기록 통합
- transcript 본문을 제외한 로컬 진단 로그
- 최근 30일 또는 100MB 보존 한도
- 로그 열기, 내보내기, 삭제 UI
- 자동 telemetry 및 자동 crash upload 부재 확인

완료 기준:

- 오류 메시지가 원인과 사용자가 할 수 있는 조치를 구분해 보여준다.
- 로그 회전이 활성 세션 파일을 삭제하지 않는다.
- 로그 삭제와 내보내기가 transcript 또는 audio를 변경하지 않는다.

### T26. 장애 주입과 복구 통합 시험

- 우선순위: `P1`
- 선행 작업: T09, T10, T19, T20, T25
- 관련 명세: 14장, 17.6절

범위:

- writer, atomic write, checksum, finalization 단계에 장애를 주입할 수 있는 test seam
- 녹음 중 강제 종료 fixture
- 체크포인트별 종료와 반복 복구
- 저장 권한 상실, 디스크 쓰기 실패, 누락 파일
- SQLite 삭제와 재구축
- 파생 Markdown 삭제와 재생성
- 창 닫기 후 완료 및 자동 종료 경로
- 테스트 결과표 작성

완료 기준:

- 명세 17.6절의 모든 시나리오가 자동 테스트 또는 명시적 수동 테스트로 연결된다.
- 정상 녹음 손실 없음과 충돌 시 최대 10초 목표를 검증한다.
- 복구 반복 실행의 idempotency가 입증된다.

### T27. 장시간, 성능, 오프라인, 직접 배포 검증

- 우선순위: `P1` 최종 게이트
- 선행 작업: T01~T26
- 관련 명세: 2장, 17장, 18장

범위:

- M4 Pro 24GB에서 2시간 녹음 3회, 4시간 녹음 1회
- partial/final latency, RTF, backlog, 메모리, 열 저하 측정
- 종료 후 필수 저장 2초 및 2시간 세션 마무리 1분 목표 측정
- 네트워크 차단 상태에서 전체 MVP 흐름 검증
- 앱 시작 시 불필요한 네트워크 연결이 없는지 확인
- macOS 15 deployment target과 현재 개발 OS 동작 검토
- GitHub 직접 배포용 빌드 및 설치 절차 문서화
- 알려진 제한과 검증된 하드웨어 범위 문서화

완료 기준:

- 명세 17장의 수치와 시나리오별 통과 여부가 결과 문서에 기록된다.
- 미달 항목은 원인, 영향, 수정 작업 또는 명시적 기준 변경 없이 완료 처리하지 않는다.
- 완전 오프라인 상태에서 녹음, STT, 마무리, 재생, 편집, 복구가 동작한다.

## 7. 결정 게이트

### G1. 안전한 녹음기 게이트

- 시점: T10 완료 후
- 확인할 것:
  - STT 없이 1~2시간 녹음 가능
  - 정상 종료와 비정상 종료 복구 가능
  - 최종 m4a 검증 가능
  - 창 닫기, 덮개 닫기, 앱 종료 정책 동작
- 실패하면 모델 또는 STT 작업을 진행하기 전에 오디오 안전성부터 수정한다.

### G2. 엔진 및 모델 선택 게이트

- 시점: T16 완료 후
- 확인할 것:
  - WhisperKit과 whisper.cpp 비교 자료
  - large-v3와 large-v3-turbo 비교 자료
  - 정확도, 영어 용어, 환각, RTF, 메모리
- 사용자가 명시적으로 엔진과 기본 모델을 선택한 뒤 T17을 시작한다.

### G3. 기능 완성 게이트

- 시점: T25 완료 후
- 확인할 것:
  - 명세의 모든 MVP 사용자 기능 존재
  - 후속 기능이 범위에 섞이지 않음
  - 오류와 복구 경로가 UI에서 접근 가능

### G4. MVP 완료 게이트

- 시점: T27 완료 후
- 확인할 것:
  - 장시간, 지연, 메모리, 복구 기준 통과
  - 완전 오프라인 검증 통과
  - 설치 및 실행 절차 재현 가능
  - 알려진 제한 문서화

## 8. 작업별 프롬프트 작성 규칙

이후 이 조정 세션에서 각 작업의 프롬프트를 작성할 때 다음 구조를 사용한다.

1. 역할과 목표
2. 반드시 읽을 문서와 관련 명세 절
3. 현재 저장소에서 먼저 확인할 사항
4. 이번 작업에 포함되는 구현 범위
5. 명시적으로 제외되는 범위
6. 구현상 지켜야 할 인터페이스와 데이터 안전 규칙
7. 테스트 및 수동 검증 요구사항
8. 완료 조건
9. 최종 결과 보고 형식

각 프롬프트에는 다음 공통 지시를 포함한다.

- 먼저 `AGENTS.md`, `PROJECT_STATUS.md`, 현재 Task 항목, 지정된 `MVP_SPEC.md` 절을 읽고 Git 상태와 실제 코드를 확인한다.
- 할당된 작업의 독립 검토 제출 조건을 만족할 때까지 구현하고 검증한다.
- 관련 없는 파일이나 사용자 변경을 되돌리지 않는다.
- 명세를 바꾸어야 할 문제가 발견되면 임의로 결정하지 말고 구현을 안전한 지점에서 멈춘 뒤 선택지를 보고한다.
- 다음 번호 작업을 선행 구현하지 않는다.
- 최종 보고에는 변경 파일, 핵심 설계, 실행한 테스트, 테스트 결과, 남은 위험을 포함한다. 최초 구현 후보는 다음 작업 가능 여부를 확정하지 않고 조정 세션의 검토가 필요하다고 명시한다.
- 지정된 task branch만 사용하고 관련 파일만 stage한다.
- 테스트 통과 후 작업 ID가 포함된 commit을 만들고 task branch를 push한다.
- task branch의 CI를 확인하고 `검토 준비 완료` 또는 `차단`으로 보고한다. 공식 Task `완료`라고 선언하지 않는다.
- 조정 세션의 독립 검토 전에는 `PROJECT_STATUS.md` 완료 상태와 구현 계획 체크리스트를 바꾸지 않고, `dev`를 merge/push하지 않으며 task branch도 삭제하지 않는다.
- 실제 구조 또는 개발 명령이 달라졌다면 `docs/ARCHITECTURE.md` 또는 `docs/DEVELOPMENT.md`도 갱신한다.
- task commit SHA, task branch CI URL과 결과, local/origin branch 상태를 보고한다.
- `main`에는 직접 push하거나 임의로 승격하지 않는다.

독립 검토 승인 뒤 같은 구현 세션에 보내는 별도 통합 프롬프트에는 최신 `dev` 동기화, 필요 시 재검증과 task CI, 상태 문서 갱신, 로컬 squash merge, merge 후 build/test, `dev` push/CI, local/origin 일치 확인과 안전한 task branch 삭제를 명시한다.

## 9. 전체 진행 체크리스트

- [x] V00 GitHub 저장소와 문서 기준선
- [x] T01 프로젝트와 모듈 경계
- [x] T02 도메인 모델과 상태 머신
- [x] T03 파일 저장소와 루트 권한
- [x] T04 SQLite 카탈로그와 대조
- [x] T05 마이크 캡처와 입력 모니터
- [x] T06 fragmented 오디오 writer
- [x] T07 녹음 coordinator와 최소 UI
- [x] T08 오디오 마무리
- [ ] T09 시작 시 복구
- [ ] T10 앱 생명주기
- [ ] T11 STTEngine 계약과 fake
- [ ] T12 모델 저장소와 가져오기
- [ ] T13 모델 다운로드와 설치
- [ ] T14 WhisperKit 어댑터
- [ ] T15 whisper.cpp 어댑터
- [ ] T16 비교 및 사용자 결정
- [ ] T17 제품 엔진 고정
- [ ] T18 VAD와 reconciler
- [ ] T19 실시간 STT coordinator
- [ ] T20 canonical 및 파생 transcript
- [ ] T21 세션·시작·모델 UI
- [ ] T22 활성 녹음 UI
- [ ] T23 재생·편집·파일 관리
- [ ] T24 일시정지·재개
- [ ] T25 오류와 진단 로그
- [ ] T26 장애 주입과 복구 시험
- [ ] T27 장시간·오프라인·배포 검증
