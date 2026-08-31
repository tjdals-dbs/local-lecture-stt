# Application

use case와 coordinator, 저장소·엔진 추상화의 orchestration을 둘 논리적 경계입니다.

T05는 이 경계에 framework-independent microphone permission 상태, `PCMChunk`, capture lifecycle/error/event, recording/STT consumer stream, `InputSignalMonitor`를 둡니다. PCM은 frame-major Float32 interleaved owned array이며, Application 공개 계약에는 AVFoundation/AVFAudio/Core Audio 타입이 없습니다. `MicrophoneCaptureController` actor는 start/stop 및 terminal cleanup을 직렬화하고, bounded fan-out은 tap callback이 actor를 await하지 않도록 작은 동기 bridge로 동작합니다.

T06은 `AudioRecorder` 계약을 추가합니다. `SessionLocation`, capture generation, `PCMChunk`만 받아 start/append/flush/stop을 표현하며 URL·AVFoundation 타입은 노출하지 않습니다. summary는 recovery artifact, mono 48 kHz/AAC target format, written frames와 media duration만 전달하고 terminal event는 후속 T07이 `.storageAccessError` 또는 `.fileWriteError`로 journal에 기록할 stable code를 제공합니다.
