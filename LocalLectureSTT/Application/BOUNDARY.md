# Application

use case와 coordinator, 저장소·엔진 추상화의 orchestration을 둘 논리적 경계입니다.

T05는 이 경계에 framework-independent microphone permission 상태, `PCMChunk`, capture lifecycle/error/event, recording/STT consumer stream, `InputSignalMonitor`를 둡니다. PCM은 frame-major Float32 interleaved owned array이며, Application 공개 계약에는 AVFoundation/AVFAudio/Core Audio 타입이 없습니다. `MicrophoneCaptureController` actor는 start/stop 및 terminal cleanup을 직렬화하고, bounded fan-out은 tap callback이 actor를 await하지 않도록 작은 동기 bridge로 동작합니다.
