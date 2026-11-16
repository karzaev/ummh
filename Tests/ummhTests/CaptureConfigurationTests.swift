import AVFoundation
import CoreAudio
import IOKit.audio
import XCTest
@testable import ummh

final class CaptureConfigurationTests: XCTestCase {
    private let internalMic = InputDevice(id: "internal", name: "Built-in microphone", audioID: 1, isInternal: true)
    private let externalMic = InputDevice(id: "external", name: "USB microphone", audioID: 2, isInternal: false)

    func testDefaultAndExplicitSelectionWithEitherLidPosition() throws {
        for closed in [false, true] {
            let inputs = [internalMic, externalMic]
            XCTAssertEqual(try AudioDevices.resolve(uid: "", inputs: inputs, defaultID: 1, lidClosed: closed).audioID, closed ? 2 : 1)
            XCTAssertEqual(try AudioDevices.resolve(uid: "external", inputs: inputs, defaultID: 1, lidClosed: closed).audioID, 2)
        }
    }

    func testExternalSystemDefaultRemainsPreferredWithLidOpen() throws {
        XCTAssertEqual(try AudioDevices.resolve(uid: "", inputs: [internalMic, externalMic], defaultID: 2, lidClosed: false).audioID, 2)
    }

    func testMissingPreferredInputFallsBackLikeVoiceInk() throws {
        XCTAssertEqual(try AudioDevices.resolve(uid: "missing", inputs: [internalMic, externalMic], defaultID: 1, lidClosed: false).audioID, 1)
        XCTAssertEqual(try AudioDevices.resolve(uid: "missing", inputs: [internalMic, externalMic], defaultID: 1, lidClosed: true).audioID, 2)
    }

    func testClosedLidWithoutExternalInputReportsHardwareRestriction() {
        XCTAssertThrowsError(try AudioDevices.resolve(uid: "", inputs: [internalMic], defaultID: 1, lidClosed: true)) {
            XCTAssertEqual(($0 as? CaptureError)?.errorDescription, CaptureError.lidClosed.errorDescription)
        }
        XCTAssertThrowsError(try AudioDevices.resolve(uid: "", inputs: [], defaultID: nil, lidClosed: false)) {
            XCTAssertEqual(($0 as? CaptureError)?.errorDescription, CaptureError.unavailable.errorDescription)
        }
    }

    func testHeadsetOnBuiltInCodecIsNotDisabledByLid() {
        XCTAssertFalse(AudioDevices.isInternalMicrophone(transport: kAudioDeviceTransportTypeBuiltIn,
                        source: UInt32(kIOAudioSelectorControlSelectionValueExternalMicrophone), uid: "BuiltInMicrophoneDevice"))
        XCTAssertTrue(AudioDevices.isInternalMicrophone(transport: kAudioDeviceTransportTypeBuiltIn,
                        source: UInt32(kIOAudioSelectorControlSelectionValueInternalMicrophone), uid: nil))
        XCTAssertTrue(AudioDevices.isInternalMicrophone(transport: kAudioDeviceTransportTypeBuiltIn,
                        source: nil, uid: "BuiltInMicrophoneDevice"))
        XCTAssertFalse(AudioDevices.isInternalMicrophone(transport: kAudioDeviceTransportTypeBuiltIn,
                        source: nil, uid: "BuiltInHeadphoneInputDevice"))
        XCTAssertFalse(AudioDevices.isInternalMicrophone(transport: kAudioDeviceTransportTypeUSB,
                        source: nil, uid: "BuiltInMicrophoneDevice"))
    }

    func test44100And48000HzCaptureBothProduceOneSecondOf16kHzPCM() throws {
        for rate in [44_100.0, 48_000.0] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: true)!
            let buffer = try CaptureBuffer(format: format, capacity: 4096)
            for _ in 0..<50 {
                XCTAssertEqual(fill(buffer, frames: UInt32(rate / 50), channels: [0.2]), noErr)
            }
            let samples = buffer.finish()
            XCTAssertFalse(buffer.hasFailure)
            XCTAssertEqual(samples.count, 16_000, accuracy: 1)
            XCTAssertEqual(samples.dropFirst(100).reduce(Float(0), +) / Float(samples.count - 100), 0.2, accuracy: 0.01)
        }
    }

    func testStereoDownmixAndStopDrainTheLastQueuedSamples() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let buffer = try CaptureBuffer(format: format, capacity: 4096)
        for _ in 0..<10 { XCTAssertEqual(fill(buffer, frames: 480, channels: [0.2, 0.4]), noErr) }
        let samples = buffer.finish()
        XCTAssertFalse(buffer.hasFailure)
        XCTAssertEqual(samples.count, 1600, accuracy: 1)
        XCTAssertEqual(samples.dropFirst(100).reduce(Float(0), +) / Float(samples.count - 100), 0.3, accuracy: 0.01)
    }

    func testRenderFailureAndOversizedCallbacksCannotDeliverPartialAudioAsSuccess() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let failed = try CaptureBuffer(format: format, capacity: 512)
        XCTAssertEqual(failed.receive(frames: 480) { _ in kAudio_ParamError }, kAudio_ParamError)
        XCTAssertTrue(failed.hasFailure)
        XCTAssertTrue(failed.finish().isEmpty)
        let oversized = try CaptureBuffer(format: format, capacity: 512)
        _ = oversized.receive(frames: 513) { _ in XCTFail("Cannot render beyond allocated storage"); return noErr }
        XCTAssertTrue(oversized.hasFailure)
    }

    private func fill(_ buffer: CaptureBuffer, frames: UInt32, channels: [Float]) -> OSStatus {
        buffer.receive(frames: frames) { list in
            let samples = list.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<Int(frames) {
                for channel in channels.indices { samples[frame * channels.count + channel] = channels[channel] }
            }
            return noErr
        }
    }
}
