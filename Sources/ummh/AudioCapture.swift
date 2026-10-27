import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct InputDevice: Identifiable {
    let id: String
    let name: String
    let audioID: AudioDeviceID
}

enum AudioDevices {
    static func inputs() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                    mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: uid, name: name, audioID: id)
        }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

enum CaptureError: LocalizedError {
    case unavailable, conversion
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The selected microphone is unavailable. Choose an available input in Settings."
        case .conversion: return "The microphone audio format could not be converted."
        }
    }
}

// The tap only converts and appends PCM; ASR never runs on the audio callback.
final class AudioCapture: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var power: Float = 0
    private var accepting = false
    private var conversionFailed = false

    var level: Float { lock.withLock { power } }
    var hasConversionFailure: Bool { lock.withLock { conversionFailed } }
    func snapshot() -> [Float] { lock.withLock { samples } }
    func ownsEngine(_ object: Any?) -> Bool {
        guard let engine, let object = object as? AVAudioEngine else { return false }
        return object === engine
    }

    func waitUntilCapturing() async throws {
        for _ in 0..<100 {
            try Task.checkCancellation()
            if hasConversionFailure { throw CaptureError.conversion }
            if lock.withLock({ !samples.isEmpty }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CaptureError.unavailable
    }

    func start(deviceUID: String) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty {
            guard var device = AudioDevices.inputs().first(where: { $0.id == deviceUID })?.audioID else { throw CaptureError.unavailable }
            let status = input.withAudioUnit { unit -> OSStatus in
                guard let unit else { return kAudio_ParamError }
                return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                            0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            guard status == noErr else { throw CaptureError.unavailable }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw CaptureError.unavailable }
        lock.withLock { samples = []; power = 0; accepting = true; conversionFailed = false }
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / format.sampleRate)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var provided = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if provided { inputStatus.pointee = .noDataNow; return nil }
                provided = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil, let channel = output.floatChannelData?[0] else {
                self.lock.withLock { self.conversionFailed = true }
                return
            }
            let pcm = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            let rms = pcm.isEmpty ? 0 : sqrt(pcm.reduce(Float(0)) { $0 + $1 * $1 } / Float(pcm.count))
            self.lock.withLock {
                guard self.accepting else { return }
                self.samples.append(contentsOf: pcm)
                self.power = min(1, rms * 5)
            }
        }
        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock { accepting = false; samples = []; power = 0 }
            throw error
        }
    }

    @discardableResult
    func stop() -> [Float] {
        lock.withLock { accepting = false; power = 0 }
        let stopping = engine
        engine = nil
        stopping?.inputNode.removeTap(onBus: 0)
        stopping?.stop()
        return lock.withLock { let captured = samples; samples = []; return captured }
    }
}
