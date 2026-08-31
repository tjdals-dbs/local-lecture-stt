# Infrastructure

AVFoundation, 파일 시스템, SQLite, 모델 엔진처럼 외부 시스템 구현을 둘 논리적 경계입니다.

T05의 `AVFoundationMicrophoneCapture.swift`에는 macOS microphone authorization adapter와 `AVAudioEngine` input-tap driver가 있습니다. Core Audio default-input identity/alive listener와 engine configuration notification은 이 경계 안에서만 사용하며, Application에는 platform-neutral device snapshot과 typed runtime event만 전달합니다.
