# Infrastructure

AVFoundation, 파일 시스템, SQLite, 모델 엔진처럼 외부 시스템 구현을 둘 논리적 경계입니다.

T05의 `AVFoundationMicrophoneCapture.swift`에는 macOS microphone authorization adapter와 `AVAudioEngine` input-tap driver가 있습니다. Core Audio default-input identity/alive listener와 engine configuration notification은 이 경계 안에서만 사용하며, Application에는 platform-neutral device snapshot과 typed runtime event만 전달합니다.

T06의 `AVFoundationAudioRecorder` actor는 production과 fault test가 함께 사용하는 output-lease, PCM-converter, writer-backend seam 뒤에서 `AVAudioConverter`와 `AVAssetWriter`를 단독 소유합니다. source-native Float32 interleaved PCM의 모든 channel을 명시적으로 mono downmix한 뒤 stateful 48 kHz PCM으로 변환하고 cumulative output frame count로 PTS를 만듭니다. Writer는 audio-only fragmented MOV(AAC-LC, 96 kbps), initial 1 second/subsequent 10 second fragment interval을 writing 전에 설정합니다. Operation gate와 recording ownership token은 await를 가로지르는 stale callback/cleanup을 격리합니다. `StorageRootWriteLease`는 writer start부터 `finishWriting` completion까지 security-scoped root access를 유지하고 terminal path마다 정확히 한 번 닫습니다. Existing/partial recovery artifacts are never deleted or overwritten; production failure/cancellation path는 output을 삭제하는 `cancelWriting()`을 사용하지 않습니다.

T07 live composition은 하나의 `StorageRootManager`, `FileSessionRepository`, `SessionCatalogReconciler`, `AVFoundationMicrophonePermissionAuthorizer`, `MicrophoneCaptureController`를 공유하고 녹음 attempt마다 새 `AVFoundationAudioRecorder`를 만듭니다. Application coordinator에는 root availability와 catalog refresh conformance만 보이며 실제 bookmark URL, file path, AVAudioEngine/AVAssetWriter 객체는 이 경계를 벗어나지 않습니다. Recorder의 장기 write lease와 repository/catalog의 짧은 lexical scope는 각각 독립적으로 균형을 이루며, coordinator construction 자체는 scope acquisition, folder creation, permission request, capture, writer를 시작하지 않습니다.

T11의 `FakeSTTEngine` actor는 같은 STTEngine 계약을 구현하는 명시적 logical-clock/FIFO 테스트 fake입니다. 모델 파일, 네트워크, 마이크, 실제 추론과 앱 composition에 접근하지 않습니다. generation/request lease와 cleanup settlement로 오래된 callback과 새 작업을 분리하며, bounded pending queue와 event feed를 사용합니다.
