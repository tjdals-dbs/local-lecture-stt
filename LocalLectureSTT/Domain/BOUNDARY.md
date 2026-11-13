# Domain

프레임워크에 의존하지 않는 핵심 타입과 규칙을 둘 논리적 경계입니다. T01에서는 도메인 타입을 아직 정의하지 않습니다.

T11의 `STTContracts.swift`는 Foundation-only Codable/Sendable 값으로 engine/model provenance, session configuration, owned inference audio, request/hypothesis response와 typed error를 정의합니다. 기존 persisted transcript schema와 capture PCM 타입은 변경하지 않습니다.
