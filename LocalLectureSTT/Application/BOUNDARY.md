# Application

use case와 coordinator, 저장소·엔진 추상화의 orchestration을 둘 논리적 경계입니다.

T05는 이 경계에 framework-independent microphone permission 상태, `PCMChunk`, capture lifecycle/error/event, recording/STT consumer stream, `InputSignalMonitor`를 둡니다. PCM은 frame-major Float32 interleaved owned array이며, Application 공개 계약에는 AVFoundation/AVFAudio/Core Audio 타입이 없습니다. `MicrophoneCaptureController` actor는 start/stop 및 terminal cleanup을 직렬화하고, bounded fan-out은 tap callback이 actor를 await하지 않도록 작은 동기 bridge로 동작합니다.

T06은 `AudioRecorder` 계약을 추가합니다. `SessionLocation`, capture generation, `PCMChunk`만 받아 start/append/flush/stop을 표현하며 URL·AVFoundation 타입은 노출하지 않습니다. summary는 recovery artifact, mono 48 kHz/AAC target format, written frames와 media duration만 전달하고 terminal event는 후속 T07이 `.storageAccessError` 또는 `.fileWriteError`로 journal에 기록할 stable code를 제공합니다. Recorder는 cleanup이 완료될 때까지 terminal state를 공개하지 않고, 구독 전에 발생한 terminal event도 한 번 보존합니다.

T07의 `RecordingSessionCoordinator` actor는 root/permission/session/capture/recorder/catalog 계약만 조합하며 URL, AVFoundation, AppKit, SwiftUI 타입을 공개 계약에 넣지 않습니다. 하나의 attempt token과 start/settlement operation이 모든 await 이후 소유권을 재검증합니다. Coordinator가 primary `recordingPCM`의 유일한 저장 consumer, recorder/capture terminal observer, metadata/event ordering과 exact-once settlement를 소유합니다. `RecordingSessionSnapshot`은 UI에 순수 Sendable 상태만 전달하고, Feature의 observation 취소는 coordinator resource lifetime에 영향을 주지 않습니다.

T11의 `STTEngine`은 Sendable orchestration protocol이며 serializable Domain payload만 전달합니다. 단일 consumer `STTEventFeed`와 stream은 control-plane handle입니다. 최신 partial과 terminal을 제한된 버퍼에 보존하며, accepted request의 terminal은 final/failed/cancelled 값 하나로만 전달합니다. 실제 capture/STT 연결은 하지 않습니다.
