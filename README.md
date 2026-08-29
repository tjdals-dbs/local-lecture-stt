# Local Lecture STT

Local Lecture STT는 macOS에서 강의를 안전하게 녹음하고, 완전히 로컬·온디바이스 환경에서 실시간 음성 인식을 수행하기 위한 앱입니다. 한국어와 영어가 섞인 강의를 대상으로 하며, 사용자의 오디오와 transcript가 기기 밖으로 나가지 않도록 설계합니다.

## 현재 상태

실행 가능한 초기 macOS 앱 셸(T01) 단계입니다. 현재는 단일 메인 창과 설정 placeholder만 제공하며, 녹음·STT·모델 관리·세션 저장은 아직 구현하지 않았습니다.

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
