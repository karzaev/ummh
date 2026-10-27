import Foundation
import XCTest
@testable import ummh

final class SessionLifecycleTests: XCTestCase {
    @MainActor
    func testPreparationIsSingleFlightAndModelFailuresCanRetry() async {
        let rig = Rig()
        let preparation = Suspension<Void>()
        rig.speech.preparation = preparation
        rig.controller.prepare()
        rig.controller.prepare(download: true)
        rig.controller.press()
        await eventually { preparation.waiting }
        XCTAssertEqual(rig.speech.downloads, [false])
        XCTAssertEqual(rig.audio.starts, 0)
        preparation.fail(TestFailure.expected)
        await eventually { rig.controller.phase == .modelFailed }
        XCTAssertFalse(rig.controller.showsSessionError)
        rig.speech.preparation = nil
        await rig.ready()
        rig.controller.prepare()
        XCTAssertEqual(rig.speech.downloads, [false, false])
    }

    @MainActor
    func testMissingModelAllowsExplicitDownload() async {
        let rig = Rig()
        rig.speech.prepareError = SpeechError.missingModel
        rig.controller.prepare()
        await eventually { rig.controller.phase == .needsModel }
        rig.speech.prepareError = nil
        rig.controller.prepare(download: true)
        await eventually { rig.controller.phase == .ready }
        XCTAssertEqual(rig.speech.downloads, [false, true])
    }

    @MainActor
    func testRecordingStreamsWithHiddenLiveTextAndDeliversExactlyOnce() async {
        let rig = Rig()
        rig.settings.language = "auto"
        rig.settings.microphoneUID = "test-device"
        await rig.recording()
        XCTAssertFalse(rig.settings.showLiveText)
        XCTAssertEqual(rig.speech.languages, ["auto"])
        XCTAssertEqual(rig.audio.devices, ["test-device"])
        XCTAssertEqual(rig.sound.starts, 1)
        await rig.preview()
        await eventually { rig.controller.partialText == "partial" }
        rig.controller.release()
        rig.controller.release()
        await eventually { rig.controller.phase == .copied }
        XCTAssertEqual(rig.delivery.copies, ["final text"])
        XCTAssertEqual(rig.speech.finishes, 1)
        XCTAssertEqual(rig.speech.finalSamples, rig.audio.samples)
        XCTAssertEqual(rig.speech.batchOnly, [false])
        XCTAssertEqual(rig.audio.stops, 1)
        XCTAssertEqual(rig.sound.finishes, 1)
        XCTAssertEqual(rig.controller.partialText, "")
        await eventually { rig.clock.contains(.milliseconds(700)) }
        rig.clock.advance(.milliseconds(700))
        await eventually { rig.controller.phase == .ready }
    }

    @MainActor
    func testCancellationDuringBeginBlocksRestartAndNeverStartsMicrophone() async {
        let rig = Rig()
        await rig.ready()
        let begin = Suspension<Void>()
        rig.speech.beginning = begin
        rig.controller.press()
        await eventually { begin.waiting }
        rig.controller.cancel()
        rig.controller.press()
        XCTAssertEqual(rig.controller.phase, .cancelling)
        XCTAssertEqual(rig.speech.languages.count, 1)
        begin.resume(())
        await eventually { rig.controller.phase == .ready }
        XCTAssertEqual(rig.audio.starts, 0)
        XCTAssertTrue(rig.delivery.copies.isEmpty)
        XCTAssertEqual(rig.sound.starts, 0)
    }

    @MainActor
    func testReleaseDuringMicrophoneStartupCancelsWithoutStartCue() async {
        let rig = Rig()
        await rig.ready()
        let startup = Suspension<Void>()
        rig.audio.startup = startup
        rig.controller.press()
        await eventually { startup.waiting }
        rig.controller.release()
        XCTAssertFalse(rig.audio.active)
        XCTAssertEqual(rig.controller.phase, .cancelling)
        startup.resume(())
        await eventually { rig.controller.phase == .ready }
        XCTAssertEqual(rig.sound.starts, 0)
        XCTAssertEqual(rig.audio.stops, 1)
        XCTAssertTrue(rig.delivery.copies.isEmpty)
    }

    @MainActor
    func testCancellationDrainsUncooperativePreviewBeforeNextSession() async {
        let rig = Rig()
        let preview = Suspension<String?>()
        rig.speech.previewing = preview
        await rig.recording()
        await rig.preview()
        await eventually { preview.waiting }
        rig.controller.cancel()
        rig.controller.cancel()
        rig.controller.press()
        XCTAssertEqual(rig.controller.phase, .cancelling)
        XCTAssertFalse(rig.audio.active)
        XCTAssertEqual(rig.sound.finishes, 1)
        XCTAssertEqual(rig.audio.starts, 1)
        preview.resume("must not appear")
        await eventually { rig.controller.phase == .ready }
        XCTAssertEqual(rig.controller.partialText, "")
        XCTAssertEqual(rig.speech.finishes, 0)
        XCTAssertTrue(rig.delivery.copies.isEmpty)
        rig.speech.previewing = nil
        await rig.recording()
        XCTAssertEqual(rig.audio.starts, 2)
        await rig.cancel()
    }

    @MainActor
    func testReleaseDrainsPreviewBeforeFinalRecognition() async {
        let rig = Rig()
        let preview = Suspension<String?>()
        rig.speech.previewing = preview
        await rig.recording()
        await rig.preview()
        await eventually { preview.waiting }
        rig.controller.release()
        XCTAssertEqual(rig.controller.phase, .finishing)
        XCTAssertFalse(rig.audio.active)
        XCTAssertEqual(rig.speech.finishes, 0)
        preview.resume("partial")
        await eventually { rig.controller.phase == .copied }
        XCTAssertFalse(rig.speech.overlapped)
        XCTAssertEqual(rig.delivery.copies.count, 1)
        rig.clock.advance(.milliseconds(700))
    }

    @MainActor
    func testCancelDuringFinalRecognitionSuppressesLateResultAndAllowsRetry() async {
        let rig = Rig()
        let final = Suspension<String>()
        rig.speech.finishing = final
        await rig.recording()
        rig.controller.release()
        await eventually { final.waiting }
        rig.controller.cancel()
        rig.controller.press()
        XCTAssertEqual(rig.controller.phase, .cancelling)
        final.resume("cancelled result")
        await eventually { rig.controller.phase == .ready }
        XCTAssertTrue(rig.delivery.copies.isEmpty)
        rig.speech.finishing = nil
        await rig.recording()
        rig.controller.release()
        await eventually { rig.controller.phase == .copied }
        XCTAssertEqual(rig.delivery.copies, ["final text"])
        XCTAssertFalse(rig.speech.overlapped)
        rig.clock.advance(.milliseconds(700))
    }

    @MainActor
    func testEmptyFinalDoesNotTouchClipboard() async {
        let rig = Rig()
        rig.speech.text = "  \n "
        await rig.recording()
        rig.controller.release()
        await eventually { rig.controller.phase == .ready }
        XCTAssertEqual(rig.controller.message, "No speech detected")
        XCTAssertTrue(rig.delivery.copies.isEmpty)
        XCTAssertEqual(rig.sound.finishes, 1)
    }

    @MainActor
    func testCaptureFailureIsSessionErrorAndRetryDoesNotReloadModel() async {
        let rig = Rig()
        rig.audio.startError = TestFailure.expected
        await rig.ready()
        rig.controller.press()
        await eventually { rig.controller.phase == .failed }
        XCTAssertTrue(rig.controller.showsSessionError)
        rig.controller.prepare()
        XCTAssertEqual(rig.speech.downloads, [false])
        rig.audio.startError = nil
        await rig.recording()
        XCTAssertFalse(rig.controller.showsSessionError)
        await rig.cancel()
    }

    @MainActor
    func testPreviewFailureStopsCaptureAndReleasesSessionWaiter() async {
        let rig = Rig()
        rig.speech.previewError = TestFailure.expected
        await rig.recording()
        await rig.preview()
        await eventually { rig.controller.phase == .failed }
        XCTAssertFalse(rig.audio.active)
        XCTAssertEqual(rig.sound.finishes, 1)
        XCTAssertTrue(rig.delivery.copies.isEmpty)
        rig.speech.previewError = nil
        await rig.recording()
        await rig.cancel()
    }

    @MainActor
    func testConversionFailureOnReleaseDrainsPreviewWithoutFinalDelivery() async {
        let rig = Rig()
        let preview = Suspension<String?>()
        rig.speech.previewing = preview
        await rig.recording()
        await rig.preview()
        await eventually { preview.waiting }
        rig.audio.hasConversionFailure = true
        rig.controller.release()
        rig.controller.press()
        XCTAssertEqual(rig.controller.phase, .finishing)
        XCTAssertEqual(rig.audio.starts, 1)
        preview.resume("obsolete")
        await eventually { rig.controller.phase == .failed }
        XCTAssertEqual(rig.speech.finishes, 0)
        XCTAssertTrue(rig.delivery.copies.isEmpty)
        await eventually { rig.clock.contains(.seconds(4)) }
        rig.clock.advance(.seconds(4))
        await eventually { !rig.controller.showsSessionError }
    }

    @MainActor
    func testNewRecordingInvalidatesOldPasteAndOldCleanupCannotStopNewMicrophone() async {
        let rig = Rig(autoPaste: true)
        let paste = Suspension<Void>()
        rig.delivery.pasting = paste
        await rig.recording()
        rig.controller.release()
        await eventually { paste.waiting }
        XCTAssertEqual(rig.controller.phase, .copied)
        await rig.recording()
        paste.resume(())
        await eventually { rig.delivery.attempts == 1 }
        XCTAssertEqual(rig.delivery.posts, 0)
        XCTAssertTrue(rig.audio.active)
        XCTAssertEqual(rig.controller.phase, .recording)
        XCTAssertEqual(rig.sound.starts, 2)
        XCTAssertEqual(rig.sound.finishes, 1)
        await rig.cancel()
        XCTAssertEqual(rig.sound.finishes, 2)
    }

    @MainActor
    func testClipboardChangedWhilePasteWaitsPreventsPosting() async {
        let rig = Rig(autoPaste: true)
        let paste = Suspension<Void>()
        rig.delivery.pasting = paste
        await rig.recording()
        rig.controller.release()
        await eventually { paste.waiting }
        rig.delivery.clipboard = "new user copy"
        rig.delivery.version += 1
        paste.resume(())
        await eventually { rig.delivery.attempts == 1 }
        XCTAssertEqual(rig.delivery.posts, 0)
        XCTAssertEqual(rig.delivery.clipboard, "new user copy")
        XCTAssertTrue(rig.controller.message.contains("paste manually"))
        rig.clock.advance(.milliseconds(700))
    }

    @MainActor
    func testCancelledRecognitionFailureDoesNotBecomeSessionError() async {
        let rig = Rig()
        let final = Suspension<String>()
        rig.speech.finishing = final
        await rig.recording()
        rig.controller.release()
        await eventually { final.waiting }
        rig.controller.cancel()
        final.fail(TestFailure.expected)
        await eventually { rig.controller.phase == .ready }
        XCTAssertFalse(rig.controller.showsSessionError)
        XCTAssertTrue(rig.delivery.copies.isEmpty)
    }

    @MainActor
    func testClipboardFailureDoesNotOfferModelRetryOrAttemptPaste() async {
        let rig = Rig(autoPaste: true)
        rig.delivery.copyError = DeliveryError.clipboardUnavailable
        await rig.recording()
        rig.controller.release()
        await eventually { rig.controller.phase == .failed }
        XCTAssertTrue(rig.controller.message.contains("clipboard"))
        XCTAssertEqual(rig.delivery.attempts, 0)
        XCTAssertEqual(rig.sound.finishes, 1)
        rig.controller.prepare()
        XCTAssertEqual(rig.speech.downloads, [false])
        await eventually { rig.clock.contains(.seconds(4)) }
        rig.clock.advance(.seconds(4))
        await eventually { !rig.controller.showsSessionError }
    }

    @MainActor
    func testSuccessfulAutomaticPasteUsesCommittedClipboardVersion() async {
        let rig = Rig(autoPaste: true)
        await rig.recording()
        rig.controller.release()
        await eventually { rig.delivery.posts == 1 }
        XCTAssertEqual(rig.delivery.copies, ["final text"])
        XCTAssertTrue(rig.controller.message.contains("paste shortcut sent"))
        rig.clock.advance(.milliseconds(700))
        await eventually { rig.controller.phase == .ready }
    }

    @MainActor
    func testInputLossCancelsAndPreservesReason() async {
        let rig = Rig()
        await rig.recording()
        rig.controller.inputLost()
        await eventually { rig.controller.phase == .ready }
        XCTAssertTrue(rig.controller.message.contains("microphone changed"))
        XCTAssertFalse(rig.audio.active)
        XCTAssertTrue(rig.delivery.copies.isEmpty)
        XCTAssertEqual(rig.sound.finishes, 1)
    }
}

private enum TestFailure: Error { case expected }

// These gates deliberately ignore cancellation, like an already-running CoreML call.
@MainActor
private final class Suspension<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    var waiting: Bool { continuation != nil }
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func resume(_ value: Value) { let saved = continuation; continuation = nil; saved?.resume(returning: value) }
    func fail(_ error: Error) { let saved = continuation; continuation = nil; saved?.resume(throwing: error) }
}

@MainActor
private final class TestClock {
    private var pending: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { pending[id] = (duration, continuation) }
            }
        } onCancel: {
            Task { @MainActor in self.pending.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        }
    }
    func contains(_ duration: Duration) -> Bool { pending.values.contains { $0.0 == duration } }
    func advance(_ duration: Duration) {
        for (id, entry) in pending where entry.0 == duration {
            pending.removeValue(forKey: id)?.1.resume()
        }
    }
}

@MainActor
private final class FakeAudio: AudioCapturing {
    var level: Float = 0
    var hasConversionFailure = false
    var active = false
    var starts = 0
    var stops = 0
    var devices: [String] = []
    let samples: [Float] = [0.1, -0.1, 0.2]
    var startup: Suspension<Void>?
    var startError: Error?
    func ownsEngine(_ object: Any?) -> Bool { false }
    func start(deviceUID: String) throws {
        if let startError { throw startError }
        starts += 1
        devices.append(deviceUID)
        active = true
    }
    func waitUntilCapturing() async throws { if let startup { try await startup.wait() } }
    func snapshot() -> [Float] { samples }
    @discardableResult func stop() -> [Float] {
        if active { stops += 1; active = false }
        return samples
    }
}

@MainActor
private final class FakeSpeech: SpeechRecognizing {
    var downloads: [Bool] = []
    var languages: [String] = []
    var finishes = 0
    var finalSamples: [Float] = []
    var batchOnly: [Bool] = []
    var text = " final text \n"
    var prepareError: Error?
    var previewError: Error?
    var preparation: Suspension<Void>?
    var beginning: Suspension<Void>?
    var previewing: Suspension<String?>?
    var finishing: Suspension<String>?
    private var inFlight = false
    var overlapped = false
    func prepare(download: Bool) async throws {
        downloads.append(download)
        if let prepareError { throw prepareError }
        if let preparation { try await preparation.wait() }
    }
    func begin(language: String) async throws {
        overlapped = overlapped || inFlight
        languages.append(language)
        if let beginning { try await beginning.wait() }
    }
    func preview(_ samples: [Float]) async throws -> String? {
        overlapped = overlapped || inFlight
        inFlight = true
        defer { inFlight = false }
        if let previewError { throw previewError }
        if let previewing { return try await previewing.wait() }
        return "partial"
    }
    func finish(_ samples: [Float], batchOnly: Bool) async throws -> String {
        overlapped = overlapped || inFlight
        inFlight = true
        defer { inFlight = false }
        finishes += 1
        finalSamples = samples
        self.batchOnly.append(batchOnly)
        if let finishing { return try await finishing.wait() }
        return text
    }
}

private final class FakeSound: RecordingFeedback {
    var starts = 0
    var finishes = 0
    func start() { starts += 1 }
    func finish() { finishes += 1 }
}

@MainActor
private final class FakeDelivery: TranscriptDelivering {
    var copies: [String] = []
    var clipboard = "untouched"
    var version = 0
    var posts = 0
    var attempts = 0
    var pasting: Suspension<Void>?
    var copyError: Error?
    func targetPID() -> pid_t? { 100 }
    func copy(_ text: String) throws -> Int {
        if let copyError { throw copyError }
        copies.append(text)
        clipboard = text
        version += 1
        return version
    }
    func paste(to target: pid_t?, clipboardVersion: Int, isCurrent: () -> Bool) async -> AutoPasteResult {
        if let pasting { try? await pasting.wait() }
        attempts += 1
        guard isCurrent(), AutoPaste.mayPost(target: target, foreground: 100, ownPID: 200, trusted: true,
                                            clipboardVersion: clipboardVersion, currentClipboardVersion: version) else { return .manual }
        posts += 1
        return .sent
    }
}

@MainActor
private final class Rig {
    private let suite = "ummh-lifecycle-\(UUID())"
    private let defaults: UserDefaults
    let settings: Settings
    let audio = FakeAudio()
    let speech = FakeSpeech()
    let delivery = FakeDelivery()
    let sound = FakeSound()
    let clock = TestClock()
    let controller: SessionController
    init(autoPaste: Bool = false) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(autoPaste, forKey: "autoPaste")
        settings = Settings(defaults: defaults)
        controller = SessionController(settings: settings, capture: audio, speech: speech,
                                       delivery: delivery, sound: sound, sleep: clock.sleep)
    }
    deinit { defaults.removePersistentDomain(forName: suite) }
    func ready() async {
        controller.prepare()
        await eventually { self.controller.phase == .ready }
    }
    func recording() async {
        if controller.phase == .loading { await ready() }
        controller.press()
        await eventually { self.controller.phase == .recording }
    }
    func preview() async {
        await eventually { self.clock.contains(.seconds(1)) }
        clock.advance(.seconds(1))
    }
    func cancel() async {
        controller.cancel()
        await eventually { self.controller.phase == .ready }
    }
}

@MainActor
private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    XCTAssertTrue(condition(), "Timed out waiting for lifecycle transition", file: file, line: line)
}
