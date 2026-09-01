# Infrastructure

AVFoundation, 파일 시스템, SQLite, 모델 엔진처럼 외부 시스템 구현을 둘 논리적 경계입니다.

T05의 `AVFoundationMicrophoneCapture.swift`에는 macOS microphone authorization adapter와 `AVAudioEngine` input-tap driver가 있습니다. Core Audio default-input identity/alive listener와 engine configuration notification은 이 경계 안에서만 사용하며, Application에는 platform-neutral device snapshot과 typed runtime event만 전달합니다.

T06의 `AVFoundationAudioRecorder` actor는 production과 fault test가 함께 사용하는 output-lease, PCM-converter, writer-backend seam 뒤에서 `AVAudioConverter`와 `AVAssetWriter`를 단독 소유합니다. source-native Float32 interleaved PCM의 모든 channel을 명시적으로 mono downmix한 뒤 stateful 48 kHz PCM으로 변환하고 cumulative output frame count로 PTS를 만듭니다. Writer는 audio-only fragmented MOV(AAC-LC, 96 kbps), initial 1 second/subsequent 10 second fragment interval을 writing 전에 설정합니다. Operation gate와 recording ownership token은 await를 가로지르는 stale callback/cleanup을 격리합니다. `StorageRootWriteLease`는 writer start부터 `finishWriting` completion까지 security-scoped root access를 유지하고 terminal path마다 정확히 한 번 닫습니다. Existing/partial recovery artifacts are never deleted or overwritten; production failure/cancellation path는 output을 삭제하는 `cancelWriting()`을 사용하지 않습니다.
