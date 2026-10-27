import AppKit

// Narrow boundaries for lifecycle tests; production keeps the existing audio/ASR implementations.
protocol AudioCapturing: AnyObject {
    @MainActor var level: Float { get }
    @MainActor var hasConversionFailure: Bool { get }
    @MainActor func ownsEngine(_ object: Any?) -> Bool
    @MainActor func start(deviceUID: String) throws
    @MainActor func waitUntilCapturing() async throws
    @MainActor func snapshot() -> [Float]
    @MainActor @discardableResult func stop() -> [Float]
}

extension AudioCapture: AudioCapturing {}

protocol SpeechRecognizing: Sendable {
    func prepare(download: Bool) async throws
    func begin(language: String) async throws
    func preview(_ samples: [Float]) async throws -> String?
    func finish(_ samples: [Float], batchOnly: Bool) async throws -> String
}

extension SpeechEngine: SpeechRecognizing {}

protocol RecordingFeedback: AnyObject {
    func start()
    func finish()
}

extension SoundFeedback: RecordingFeedback {}

@MainActor
protocol TranscriptDelivering {
    func targetPID() -> pid_t?
    func copy(_ text: String) throws -> Int
    func paste(to target: pid_t?, clipboardVersion: Int, isCurrent: () -> Bool) async -> AutoPasteResult
}

enum DeliveryError: LocalizedError {
    case clipboardUnavailable
    var errorDescription: String? { "Could not copy the result. The clipboard is unavailable." }
}

@MainActor
struct SystemTranscriptDelivery: TranscriptDelivering {
    func targetPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func copy(_ text: String) throws -> Int {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        guard clipboard.setString(text, forType: .string) else { throw DeliveryError.clipboardUnavailable }
        return clipboard.changeCount
    }

    func paste(to target: pid_t?, clipboardVersion: Int, isCurrent: () -> Bool) async -> AutoPasteResult {
        await AutoPaste.send(to: target, clipboardVersion: clipboardVersion, isCurrent: isCurrent)
    }
}
