# Architecture

## T01 baseline

`LocalLectureSTT`는 macOS 15 이상, arm64 전용 SwiftUI 앱 target 하나와 두 test target으로 시작한다.

```text
LocalLectureSTT (app)
├── App             composition root와 scene 진입점
├── Features        화면과 사용자 상호작용 단위
├── Application     use case와 orchestration의 예정 경계
├── Domain          프레임워크 비의존 타입과 규칙의 예정 경계
└── Infrastructure  외부 시스템 구현의 예정 경계

LocalLectureSTTTests             unit smoke test
LocalLectureSTTIntegrationTests  app module을 연결하는 integration smoke test
```

`Application`, `Domain`, `Infrastructure`는 T01에서 기능을 선행 구현하지 않기 위해 짧은 boundary marker만 둔다. 현재 경계는 하나의 app target 안에 있는 **논리적 경계**이며 compile-time module 분리는 아직 없다.

목표 의존 방향은 다음과 같다.

```text
App → Features → Application → Domain
App → Infrastructure → Application/Domain
Domain → 다른 앱 계층에 의존하지 않음
```

MVP는 단일 프로세스다. 이후 비동기 구성 요소는 XPC나 별도 프로세스로 이동할 수 있도록 경계를 유지하되, T01에서는 그 추상화나 XPC를 만들지 않는다. AppKit, IOKit, AVFoundation은 필요한 adapter 또는 Infrastructure에만 제한할 예정이다.

의도적으로 아직 구현하지 않은 항목은 도메인 모델, persistence, 권한 요청, AVFoundation 마이크 캡처, STT 엔진과 모델 관리, 세션 UI 및 앱 생명주기 정책이다.
