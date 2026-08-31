import AVFoundation
import CoreAudio
import Foundation

final class AVFoundationMicrophonePermissionAuthorizer: MicrophonePermissionAuthorizing, @unchecked Sendable {
    func authorizationStatus() async -> MicrophonePermissionStatus {
        Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    func requestAuthorization() async -> MicrophonePermissionStatus {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                // The final system status is authoritative when a completion result races a TCC update.
                continuation.resume(returning: Self.map(AVCaptureDevice.authorizationStatus(for: .audio)))
            }
        }
    }

    static func map(_ status: AVAuthorizationStatus) -> MicrophonePermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unavailable
        }
    }
}

/// The actor is the sole owner of AVAudioEngine, its tap and observer registrations. The tap captures
/// only its small bridge, which copies to application-owned PCM before calling out.
actor AVAudioEngineMicrophoneDriver: MicrophoneCaptureDriving {
    private let engine = AVAudioEngine()
    private var bridge: AVAudioTapBridge?
    private var deviceID: AudioDeviceID = kAudioObjectUnknown
    private var configurationObserver: NSObjectProtocol?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var activeDeviceListener: AudioObjectPropertyListenerBlock?

    func prepare(
        generation: UInt64,
        onChunk: @escaping @Sendable (PCMChunk) -> Void,
        onRuntimeEvent: @escaping @Sendable (CaptureRuntimeEvent) -> Void
    ) async throws -> InputDeviceSnapshot {
        guard bridge == nil else { throw CaptureError(.alreadyRunning) }
        let active = try CoreAudioInputDevice.defaultInput()
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError(.invalidInputFormat)
        }

        let bridge = AVAudioTapBridge(generation: generation, device: active, onChunk: onChunk, onRuntimeEvent: onRuntimeEvent)
        self.bridge = bridge
        self.deviceID = active.id
        do {
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak bridge] buffer, time in
                bridge?.receive(buffer: buffer, time: time)
            }
            try installObservers(for: active.id, bridge: bridge)
        } catch let error as CaptureError {
            cleanup()
            throw error
        } catch {
            cleanup()
            throw CaptureError(.tapInstallationFailed)
        }
        return active.snapshot
    }

    func start() async throws {
        guard bridge != nil else { throw CaptureError(.engineStartFailed) }
        do {
            try engine.start()
        } catch {
            throw CaptureError(.engineStartFailed)
        }
    }

    func stop() async {
        cleanup()
    }

    private func installObservers(for id: AudioDeviceID, bridge: AVAudioTapBridge) throws {
        let configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak bridge] _ in
            // A configuration notification alone does not prove disconnect: check the expected device.
            bridge?.configurationChanged()
        }
        self.configurationObserver = configurationObserver

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultListener: AudioObjectPropertyListenerBlock = { [weak bridge] _, _ in bridge?.defaultInputChanged() }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, nil, defaultListener) == noErr else {
            throw CaptureError(.runtimeFailure)
        }
        self.defaultInputListener = defaultListener

        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let activeListener: AudioObjectPropertyListenerBlock = { [weak bridge] _, _ in bridge?.activeDeviceChanged() }
        guard AudioObjectAddPropertyListenerBlock(id, &aliveAddress, nil, activeListener) == noErr else {
            removeObservers()
            throw CaptureError(.runtimeFailure)
        }
        self.activeDeviceListener = activeListener
    }

    private func cleanup() {
        bridge?.deactivate()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        removeObservers()
        bridge = nil
        deviceID = kAudioObjectUnknown
    }

    private func removeObservers() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, nil, defaultInputListener)
        }
        defaultInputListener = nil
        if deviceID != kAudioObjectUnknown {
            var aliveAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if let activeDeviceListener {
                AudioObjectRemovePropertyListenerBlock(deviceID, &aliveAddress, nil, activeDeviceListener)
            }
        }
        activeDeviceListener = nil
    }
}

/// This narrow callback bridge owns no framework object after `receive` returns. Its lock protects
/// generation/sequence/terminal state only; no actor await, I/O, UI work or consumer waiting occurs here.
private final class AVAudioTapBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let generation: UInt64
    private let expectedDevice: CoreAudioInputDevice
    private let onChunk: @Sendable (PCMChunk) -> Void
    private let onRuntimeEvent: @Sendable (CaptureRuntimeEvent) -> Void
    private var active = true
    private var nextSequence: UInt64 = 0
    private var nextSampleTime: Int64 = 0

    init(generation: UInt64, device: CoreAudioInputDevice, onChunk: @escaping @Sendable (PCMChunk) -> Void, onRuntimeEvent: @escaping @Sendable (CaptureRuntimeEvent) -> Void) {
        self.generation = generation
        self.expectedDevice = device
        self.onChunk = onChunk
        self.onRuntimeEvent = onRuntimeEvent
    }

    func receive(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        lock.lock()
        guard active else { lock.unlock(); return }
        let sequence = nextSequence
        nextSequence &+= 1
        lock.unlock()

        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
              let channelData = buffer.floatChannelData else {
            emit(.pcmCopyFailed)
            return
        }
        var copied: [Float] = []
        copied.reserveCapacity(frames * channels)
        for frame in 0 ..< frames {
            for channel in 0 ..< channels {
                let sample = channelData[channel][frame]
                guard sample.isFinite else { emit(.pcmCopyFailed); return }
                copied.append(sample)
            }
        }
        let sourceTime: Int64
        if time.sampleTime >= 0 {
            sourceTime = time.sampleTime
            recordNextSampleTime(sourceTime + Int64(frames))
        } else {
            sourceTime = sampleTimeFallback(frameCount: frames)
        }
        do {
            let format = try PCMFormatDescription(sampleRate: buffer.format.sampleRate, channelCount: channels)
            let chunk = try PCMChunk(generation: generation, sequence: sequence, format: format, frameCount: frames, sourceSampleTime: sourceTime, samples: copied)
            lock.lock(); let shouldDeliver = active; lock.unlock()
            if shouldDeliver { onChunk(chunk) }
        } catch {
            emit(.pcmCopyFailed)
        }
    }

    func defaultInputChanged() {
        guard (try? CoreAudioInputDevice.defaultInput().id) == expectedDevice.id else { emit(.inputRouteChanged); return }
    }

    func activeDeviceChanged() {
        guard expectedDevice.isAlive else { emit(.activeDeviceDisconnected); return }
    }

    func configurationChanged() {
        guard (try? CoreAudioInputDevice.defaultInput().id) == expectedDevice.id else { emit(.inputRouteChanged); return }
        guard expectedDevice.isAlive else { emit(.activeDeviceDisconnected); return }
        emit(.engineConfigurationChanged)
    }

    func deactivate() {
        lock.lock(); active = false; lock.unlock()
    }

    private func sampleTimeFallback(frameCount: Int) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let value = nextSampleTime
        nextSampleTime &+= Int64(frameCount)
        return value
    }

    private func recordNextSampleTime(_ value: Int64) {
        lock.lock(); nextSampleTime = max(nextSampleTime, value); lock.unlock()
    }

    private func emit(_ event: CaptureRuntimeEvent) {
        lock.lock()
        guard active else { lock.unlock(); return }
        active = false
        lock.unlock()
        onRuntimeEvent(event)
    }
}

private struct CoreAudioInputDevice: Sendable {
    let id: AudioDeviceID
    let snapshot: InputDeviceSnapshot

    var isAlive: Bool { (try? Self.isAlive(id)) ?? false }

    static func defaultInput() throws -> CoreAudioInputDevice {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else {
            throw CaptureError(.noCurrentInputDevice)
        }
        guard try isAlive(id) else { throw CaptureError(.noCurrentInputDevice) }
        return CoreAudioInputDevice(id: id, snapshot: InputDeviceSnapshot(identity: try stringProperty(kAudioDevicePropertyDeviceUID, id), displayName: try stringProperty(kAudioObjectPropertyName, id)))
    }

    private static func isAlive(_ id: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { throw CaptureError(.noCurrentInputDevice) }
        return value != 0
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, _ id: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { throw CaptureError(.noCurrentInputDevice) }
        return value.takeUnretainedValue() as String
    }
}
