import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import IOKit

struct InputDevice: Identifiable {
    let id: String
    let name: String
    let audioID: AudioDeviceID
}

enum AudioDevices {
    static var defaultInput: AudioDeviceID? {
        scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
    }

    static var lidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool == true
    }

    static func isBuiltIn(_ device: AudioDeviceID) -> Bool {
        scalar(device, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
    }

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

    private static func scalar(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
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
    case unavailable, conversion, lidClosed, inputChanged, formatChanged, interrupted
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The selected microphone is unavailable. Choose an available input in Settings."
        case .conversion: return "The microphone audio format could not be converted."
        case .lidClosed: return "The built-in microphone is disabled while the MacBook lid is closed. Choose an external microphone in Settings."
        case .inputChanged: return "Recording cancelled because the microphone disconnected or changed."
        case .formatChanged: return "Recording cancelled because the microphone audio format changed."
        case .interrupted: return "Recording cancelled because the audio engine could not restart."
        }
    }
}

struct CaptureInputConfiguration {
    let deviceID: AudioDeviceID
    let hardwareFormat: AVAudioFormat
    let tapFormat: AVAudioFormat
    let builtIn: Bool

    func validate(lidClosed: Bool) throws {
        if builtIn && lidClosed { throw CaptureError.lidClosed }
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else { throw CaptureError.unavailable }
        guard hardwareFormat.sampleRate == tapFormat.sampleRate else { throw CaptureError.formatChanged }
    }

    func restore(current: CaptureInputConfiguration?, lidClosed: Bool, running: Bool,
                 restart: () throws -> Void) throws {
        try validate(lidClosed: lidClosed)
        guard let current, deviceID == current.deviceID else { throw CaptureError.inputChanged }
        guard hardwareFormat == current.hardwareFormat, tapFormat == current.tapFormat else { throw CaptureError.formatChanged }
        guard !running else { return }
        do { try restart() }
        catch { throw CaptureError.interrupted }
    }
}

// The tap only converts and appends PCM; ASR never runs on the audio callback.
final class AudioCapture: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var inputConfiguration: CaptureInputConfiguration?
    private var restartSampleCount: Int?
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

    func recoverAfterConfigurationChange() throws {
        guard let engine, let inputConfiguration else { return }
        let input = engine.inputNode
        let current = Self.deviceID(input).flatMap { device -> CaptureInputConfiguration? in
            guard AudioDevices.inputs().contains(where: { $0.audioID == device }) else { return nil }
            return CaptureInputConfiguration(deviceID: device, hardwareFormat: input.inputFormat(forBus: 0),
                                             tapFormat: input.outputFormat(forBus: 0), builtIn: AudioDevices.isBuiltIn(device))
        }
        try inputConfiguration.restore(current: current, lidClosed: AudioDevices.lidClosed,
                                       running: engine.isRunning) {
            let count = lock.withLock { samples.count }
            // A repeated stop before any new PCM must not create a restart loop.
            guard restartSampleCount != count else { throw CaptureError.interrupted }
            restartSampleCount = count
            try engine.start()
            guard engine.isRunning else { throw CaptureError.interrupted }
        }
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
        let selectedDevice = deviceUID.isEmpty ? AudioDevices.defaultInput
            : AudioDevices.inputs().first(where: { $0.id == deviceUID })?.audioID
        guard var device = selectedDevice, device != kAudioObjectUnknown else { throw CaptureError.unavailable }
        let builtIn = AudioDevices.isBuiltIn(device)
        if builtIn && AudioDevices.lidClosed { throw CaptureError.lidClosed }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        func selectDevice(_ unit: AudioUnit?) -> OSStatus {
            guard let unit else { return kAudio_ParamError }
            return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                        0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let status: OSStatus
        if deviceUID.isEmpty {
            // AVAudioEngine already follows the default input. Reassigning it can
            // leave its client format on the previous device's sample rate.
            status = noErr
        } else if #available(macOS 27.0, *) { status = input.withAudioUnit { selectDevice($0) } }
        else { status = selectDevice(input.audioUnit) }
        guard status == noErr else { throw CaptureError.unavailable }
        // The client output format can still describe the previous device.
        // Installing the tap with the hardware format configures the output bus.
        let format = input.inputFormat(forBus: 0)
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
            let activeDevice = Self.deviceID(input) ?? device
            let configuration = CaptureInputConfiguration(deviceID: activeDevice, hardwareFormat: input.inputFormat(forBus: 0),
                                                          tapFormat: format, builtIn: AudioDevices.isBuiltIn(activeDevice))
            try configuration.validate(lidClosed: AudioDevices.lidClosed)
            inputConfiguration = configuration
            restartSampleCount = nil
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            lock.withLock { accepting = false; samples = []; power = 0 }
            throw error
        }
    }

    @discardableResult
    func stop() -> [Float] {
        lock.withLock { accepting = false; power = 0 }
        let stopping = engine
        engine = nil
        inputConfiguration = nil
        restartSampleCount = nil
        stopping?.inputNode.removeTap(onBus: 0)
        stopping?.stop()
        return lock.withLock { let captured = samples; samples = []; return captured }
    }

    private static func deviceID(_ input: AVAudioInputNode) -> AudioDeviceID? {
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        func readDevice(_ unit: AudioUnit?) -> OSStatus {
            guard let unit else { return kAudio_ParamError }
            return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
        }
        let status: OSStatus
        if #available(macOS 27.0, *) { status = input.withAudioUnit { readDevice($0) } }
        else { status = readDevice(input.audioUnit) }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}
