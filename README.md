# Local Lecture STT

Local Lecture STT는 macOS에서 강의를 안전하게 녹음하고, 완전히 로컬·온디바이스 환경에서 실시간 음성 인식을 수행하기 위한 앱입니다. 한국어와 영어가 섞인 강의를 대상으로 하며, 사용자의 오디오와 transcript가 기기 밖으로 나가지 않도록 설계합니다.

## 현재 상태

개발 중인 앱은 마이크 녹음, 로컬 실시간 STT, 복구 및 transcript 저장, 세션 목록과 모델 관리 화면을 제공합니다. `main`은 검증된 T01 초기 실행 버전을 유지하며, 개발 통합은 `dev`에서 진행합니다. 현재 Task와 수동 검증 여부는 [PROJECT_STATUS.md](PROJECT_STATUS.md)를 확인하세요.

앱에서 저장 폴더를 지정한 뒤 **모델 관리**에서 모델을 명시적으로 다운로드하거나 가져오세요. 설치·검증이 끝나면 새 녹음 화면에서 제목, 언어와 모델을 선택할 수 있습니다. 기본 모델은 `whisper.cpp · large-v3`이며 모델 설치 이후 런타임은 오프라인으로 동작합니다. 이전 세션 재생·편집 화면은 후속 작업입니다.

## 주요 원칙

- 오디오 원본의 안전한 보존
- 설치된 모델만으로 가능한 오프라인 실행
- 한국어·영어 혼용 강의 지원
- 확장 가능한 STT 엔진 경계

## 문서

- [MVP 명세](MVP_SPEC.md)
- [구현 계획](IMPLEMENTATION_PLAN.md)
- [프로젝트 상태](PROJECT_STATUS.md)
- [아키텍처](docs/ARCHITECTURE.md)
- [개발·빌드·테스트](docs/DEVELOPMENT.md)

## 브랜치 정책

- `main`: 빌드와 실행이 검증된 버전만 보관합니다.
- `dev`: 완료된 Task를 통합합니다.
- `task/*`: 개별 Task 작업용 브랜치입니다.

다운로드한 모델 weight와 사용자의 녹음·transcript는 저장소에 포함하지 않습니다.
