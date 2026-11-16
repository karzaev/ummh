import AVFoundation
import XCTest
@testable import ummh

final class CaptureConfigurationTests: XCTestCase {
    private func configuration(device: UInt32 = 7, hardwareRate: Double = 48_000,
                               tapRate: Double = 48_000, builtIn: Bool = false) -> CaptureInputConfiguration {
        CaptureInputConfiguration(deviceID: device,
                                  hardwareFormat: AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 1)!,
                                  tapFormat: AVAudioFormat(standardFormatWithSampleRate: tapRate, channels: 1)!, builtIn: builtIn)
    }

    func testDelayedNotificationDoesNotRestartAnUnchangedRunningInput() throws {
        var restarted = false
        try configuration().restore(current: configuration(), lidClosed: false, running: true) { restarted = true }
        XCTAssertFalse(restarted)
    }

    func testOutputRouteChangeRestartsAStoppedEngineWithUnchangedInput() throws {
        var restarts = 0
        try configuration().restore(current: configuration(), lidClosed: false, running: false) { restarts += 1 }
        XCTAssertEqual(restarts, 1)
    }

    func testDisconnectOrDifferentInputCannotRestart() {
        for current in [nil, configuration(device: 8)] {
            XCTAssertThrowsError(try configuration().restore(current: current, lidClosed: false, running: false) {
                XCTFail("Cannot restart a changed microphone")
            }) { XCTAssertEqual(($0 as? CaptureError)?.errorDescription, CaptureError.inputChanged.errorDescription) }
        }
    }

    func testHardwareFormatChangeCannotReuseTheTapEvenIfClientFormatIsUnchanged() {
        XCTAssertThrowsError(try configuration().restore(current: configuration(hardwareRate: 44_100), lidClosed: false, running: false) {
            XCTFail("Cannot reuse a tap after a hardware format change")
        }) { XCTAssertEqual(($0 as? CaptureError)?.errorDescription, CaptureError.formatChanged.errorDescription) }
    }

    func testClientFormatChangeCannotReuseTheConverter() {
        XCTAssertThrowsError(try configuration().restore(current: configuration(tapRate: 44_100), lidClosed: false, running: true) {
            XCTFail("Cannot reuse a converter after a client format change")
        }) { XCTAssertEqual(($0 as? CaptureError)?.errorDescription, CaptureError.formatChanged.errorDescription) }
    }

    func testRestartFailureReportsAudioInterruption() {
        XCTAssertThrowsError(try configuration().restore(current: configuration(), lidClosed: false, running: false) {
            throw CaptureError.unavailable
        }) { XCTAssertEqual(($0 as? CaptureError)?.errorDescription, CaptureError.interrupted.errorDescription) }
    }

    func testClosedLidRejectsBuiltInMicrophoneAtStartupAndRecovery() {
        let input = configuration(builtIn: true)
        XCTAssertThrowsError(try input.validate(lidClosed: true)) {
            XCTAssertEqual(($0 as? CaptureError)?.errorDescription, CaptureError.lidClosed.errorDescription)
        }
        XCTAssertThrowsError(try input.restore(current: input, lidClosed: true, running: true) {
            XCTFail("Cannot restart the hardware-disabled built-in microphone")
        }) { XCTAssertEqual(($0 as? CaptureError)?.errorDescription, CaptureError.lidClosed.errorDescription) }
        XCTAssertNoThrow(try input.validate(lidClosed: false))
    }

    func testClosedLidAllowsAnExternalMicrophone() throws {
        var restarted = false
        try configuration().validate(lidClosed: true)
        try configuration().restore(current: configuration(), lidClosed: true, running: false) { restarted = true }
        XCTAssertTrue(restarted)
    }

    func testEmptyHardwareFormatCannotBecomeTheCaptureBaseline() {
        let unavailable = CaptureInputConfiguration(deviceID: 7, hardwareFormat: AVAudioFormat(),
                                                    tapFormat: configuration().tapFormat, builtIn: false)
        XCTAssertThrowsError(try unavailable.validate(lidClosed: false)) {
            XCTAssertEqual(($0 as? CaptureError)?.errorDescription, CaptureError.unavailable.errorDescription)
        }
    }
}
