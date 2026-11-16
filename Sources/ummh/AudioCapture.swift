import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import IOKit
import IOKit.audio
import Synchronization
import os

struct InputDevice: Identifiable {
    let id: String
    let name: String
    let audioID: AudioDeviceID
    let isInternal: Bool
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

    static func isInternalMicrophone(_ device: AudioDeviceID) -> Bool {
        isInternalMicrophone(transport: scalar(device, kAudioDevicePropertyTransportType),
                             source: scalar(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeInput),
                             uid: string(device, kAudioDevicePropertyDeviceUID))
    }

    static func isInternalMicrophone(transport: UInt32?, source: UInt32?, uid: String?) -> Bool {
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        if source == UInt32(kIOAudioSelectorControlSelectionValueExternalMicrophone) { return false }
        if source == UInt32(kIOAudioSelectorControlSelectionValueInternalMicrophone) { return true }
        return uid == "BuiltInMicrophoneDevice"
    }

    static func resolve(uid: String, inputs: [InputDevice], defaultID: AudioDeviceID?, lidClosed: Bool) throws -> InputDevice {
        let preferred = uid.isEmpty ? inputs.first { $0.audioID == defaultID } : inputs.first { $0.id == uid }
        let fallback = inputs.filter { $0.isInternal } + inputs.filter { !$0.isInternal }
        if let device = ([preferred].compactMap { $0 } + fallback).first(where: { !(lidClosed && $0.isInternal) }) {
            return device
        }
        if lidClosed && inputs.contains(where: { $0.isInternal }) { throw CaptureError.lidClosed }
        throw CaptureError.unavailable
    }

    static func isAlive(_ device: AudioDeviceID) -> Bool {
        scalar(device, kAudioDevicePropertyDeviceIsAlive) == 1
    }

    static func bufferCapacity(_ device: AudioDeviceID) -> UInt32 {
        max(4096, scalar(device, kAudioDevicePropertyBufferFrameSize) ?? 4096)
    }

    static func sampleRate(_ device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
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
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0, isAlive(id) else { return nil }
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: uid, name: name, audioID: id, isInternal: isInternalMicrophone(id))
        }
    }

    private static func scalar(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
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
    case unavailable, conversion, lidClosed, inputChanged, formatChanged
    case hardware(OSStatus)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The selected microphone is unavailable. Choose an available input in Settings."
        case .conversion: return "The microphone audio format could not be converted."
        case .lidClosed: return "The built-in microphone is disabled while the MacBook lid is closed. Choose an external microphone in Settings."
        case .inputChanged: return "Recording cancelled because the microphone disconnected or changed."
        case .formatChanged: return "Recording cancelled because the microphone audio format changed."
        case .hardware(let status): return "The microphone could not start (Core Audio error \(status))."
        }
    }
}

// Input-only AUHAL setup and teardown adapted from VoiceInk CoreAudioRecorder.
// Recording-device resolution follows AudioDeviceManager+RecordingRouting.swift.
final class AudioCapture: @unchecked Sendable {
    private let logger = Logger(subsystem: "xyz.karzaev.ummh", category: "capture")
    private var unit: AudioUnit?
    private var buffer: CaptureBuffer?
    private var device: InputDevice?
    private var hardwareFormat = AudioStreamBasicDescription()
    private var initialized = false
    private var lastFailure = false
    private let active = Atomic<Bool>(false)
    private let callbacks = Atomic<UInt32>(0)

    var level: Float { buffer?.level ?? 0 }
    var hasConversionFailure: Bool { buffer?.hasFailure ?? lastFailure }
    func snapshot() -> [Float] { buffer?.snapshot() ?? [] }

    func validateInput() throws {
        guard let unit, let device, AudioDevices.isAlive(device.audioID) else { throw CaptureError.inputChanged }
        if device.isInternal && AudioDevices.lidClosed { throw CaptureError.lidClosed }
        var current = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &current, &size))
        guard current.mSampleRate == hardwareFormat.mSampleRate,
              current.mChannelsPerFrame == hardwareFormat.mChannelsPerFrame,
              AudioDevices.sampleRate(device.audioID) == hardwareFormat.mSampleRate else { throw CaptureError.formatChanged }
    }

    func waitUntilCapturing() async throws {
        for _ in 0..<100 {
            try Task.checkCancellation()
            try validateInput()
            if hasConversionFailure { throw CaptureError.conversion }
            if !snapshot().isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CaptureError.unavailable
    }

    func start(deviceUID: String) throws {
        stop()
        lastFailure = false
        let device = try AudioDevices.resolve(uid: deviceUID, inputs: AudioDevices.inputs(),
                                              defaultID: AudioDevices.defaultInput, lidClosed: AudioDevices.lidClosed)
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw CaptureError.unavailable }
        var created: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &created))
        guard let unit = created else { throw CaptureError.unavailable }
        self.unit = unit
        self.device = device
        do {
            var enabled: UInt32 = 1
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                               &enabled, UInt32(MemoryLayout<UInt32>.size)))
            var disabled: UInt32 = 0
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                               &disabled, UInt32(MemoryLayout<UInt32>.size)))
            var deviceID = device.audioID
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                               &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)))
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardwareFormat, &size))
            guard hardwareFormat.mSampleRate > 0, hardwareFormat.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardwareFormat.mSampleRate,
                                             channels: hardwareFormat.mChannelsPerFrame, interleaved: true) else { throw CaptureError.unavailable }
            var clientFormat = format.streamDescription.pointee
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientFormat, size))
            let capacity = AudioDevices.bufferCapacity(device.audioID)
            buffer = try CaptureBuffer(format: format, capacity: capacity)
            var callback = AURenderCallbackStruct(inputProc: { context, flags, time, _, frames, _ in
                let capture = Unmanaged<AudioCapture>.fromOpaque(context).takeUnretainedValue()
                capture.callbacks.wrappingAdd(1, ordering: .acquiringAndReleasing)
                defer { capture.callbacks.wrappingSubtract(1, ordering: .acquiringAndReleasing) }
                guard capture.active.load(ordering: .acquiring), let unit = capture.unit, let buffer = capture.buffer else { return noErr }
                return buffer.receive(frames: frames) { AudioUnitRender(unit, flags, time, 1, frames, $0) }
            }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                               &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try Self.check(AudioUnitInitialize(unit))
            initialized = true
            try validateInput()
            active.store(true, ordering: .releasing)
            try Self.check(AudioOutputUnitStart(unit))
            logger.notice("AUHAL input \(device.audioID, privacy: .public), \(self.hardwareFormat.mSampleRate, privacy: .public) Hz, lid closed \(AudioDevices.lidClosed, privacy: .public)")
        } catch {
            stop()
            throw error
        }
    }

    @discardableResult
    func stop() -> [Float] {
        let wasStarted = unit != nil
        active.store(false, ordering: .releasing)
        if let unit {
            AudioOutputUnitStop(unit)
            while callbacks.load(ordering: .acquiring) > 0 { Thread.sleep(forTimeInterval: 0.001) }
            if initialized { AudioUnitUninitialize(unit) }
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        initialized = false
        let samples = buffer?.finish() ?? []
        lastFailure = buffer?.hasFailure ?? lastFailure
        buffer = nil
        device = nil
        if wasStarted { logger.notice("AUHAL stopped, \(samples.count, privacy: .public) PCM samples, failed \(self.lastFailure, privacy: .public)") }
        return samples
    }

    deinit { stop() }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw CaptureError.hardware(status) }
    }
}
