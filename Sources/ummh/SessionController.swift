import Combine
import Foundation
import os

@MainActor
final class SessionController: ObservableObject {
    private let logger = Logger(subsystem: "xyz.karzaev.ummh", category: "session")
    let settings: Settings
    let capture: any AudioCapturing
    private let speech: any SpeechRecognizing
    private let delivery: any TranscriptDelivering
    private let sound: any RecordingFeedback
    private let sleep: @MainActor (Duration) async throws -> Void
    @Published private(set) var phase: SessionPhase = .loading {
        didSet { logger.notice("State: \(String(describing: self.phase), privacy: .public)") }
    }
    @Published private(set) var partialText = ""
    @Published private(set) var message = "Preparing Parakeet TDT v3…"
    @Published private(set) var showsSessionError = false
    @Published var shortcutAvailable = false
    private var modelReady = false
    private var operation: Task<Void, Never>?
    private var releaseSignal: AsyncThrowingStream<[Float], Error>.Continuation?
    private var sessionID = 0
    private var soundActive = false
    private var cancellationMessage: String?

    convenience init(settings: Settings) {
        self.init(settings: settings, capture: AudioCapture(), speech: SpeechEngine(),
                  delivery: SystemTranscriptDelivery(), sound: SoundFeedback())
    }

    init(settings: Settings, capture: any AudioCapturing, speech: any SpeechRecognizing,
         delivery: any TranscriptDelivering, sound: any RecordingFeedback,
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.settings = settings
        self.capture = capture
        self.speech = speech
        self.delivery = delivery
        self.sound = sound
        self.sleep = sleep
    }

    func prepare(download: Bool = false) {
        guard operation == nil, !modelReady else { return }
        message = download ? "Downloading and preparing the local speech models…" : "Loading Parakeet TDT v3…"
        phase = .loading
        operation = Task {
            defer { operation = nil }
            do {
                try await speech.prepare(download: download)
                modelReady = true
                message = "Ready to dictate"
                phase = .ready
            } catch SpeechError.missingModel {
                message = "Download Parakeet TDT v3 to enable dictation."
                phase = .needsModel
            } catch {
                message = "Could not prepare the speech model. \(error.localizedDescription)"
                phase = .modelFailed
            }
        }
    }

    func press() {
        guard modelReady, phase == .ready || phase == .copied || phase == .failed else { return }
        operation?.cancel()
        sessionID += 1
        let id = sessionID
        let language = settings.language
        let microphone = settings.microphoneUID
        let autoPaste = settings.autoPaste
        let target = delivery.targetPID()
        cancellationMessage = nil
        showsSessionError = false
        partialText = ""
        message = "Starting microphone…"
        phase = .starting
        operation = Task { await runSession(id, language: language, microphone: microphone, autoPaste: autoPaste, target: target) }
    }

    func release() {
        if phase == .starting { cancel(); return }
        guard phase == .recording else { return }
        message = "Finishing transcription…"
        phase = .finishing
        let samples = capture.stop()
        let signal = releaseSignal
        releaseSignal = nil
        if capture.hasConversionFailure { signal?.finish(throwing: CaptureError.conversion) }
        else { signal?.yield(samples); signal?.finish() }
    }

    func cancel(reason: String? = nil) {
        guard phase.busy, phase != .cancelling else { return }
        cancellationMessage = reason
        message = reason ?? "Cancelling…"
        phase = .cancelling
        partialText = ""
        capture.stop()
        finishSound()
        operation?.cancel()
        releaseSignal?.finish()
        releaseSignal = nil
    }

    func inputLost() {
        guard phase == .recording || phase == .starting else { return }
        cancel(reason: "Recording cancelled because the microphone changed.")
    }

    private func runSession(_ id: Int, language: String, microphone: String, autoPaste: Bool, target: pid_t?) async {
        defer {
            if id == sessionID {
                capture.stop()
                finishSound()
                releaseSignal?.finish()
                releaseSignal = nil
                operation = nil
            }
        }
        do {
            try await speech.begin(language: language)
            try Task.checkCancellation()
            try capture.start(deviceUID: microphone)
            try await capture.waitUntilCapturing()
            try Task.checkCancellation()
            let (releases, signal) = AsyncThrowingStream<[Float], Error>.makeStream()
            releaseSignal = signal
            sound.start()
            soundActive = true
            message = "Listening · release the shortcut to copy"
            phase = .recording
            let samples = try await record(until: releases)
            try Task.checkCancellation()
            let text = try await speech.finish(samples, batchOnly: false).trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard id == sessionID else { return }
            guard !text.isEmpty else {
                message = "No speech detected"
                phase = .ready
                return
            }
            let clipboardVersion = try delivery.copy(text)
            finishSound()
            partialText = ""
            message = "Copied"
            phase = .copied
            if autoPaste {
                let result = await delivery.paste(to: target, clipboardVersion: clipboardVersion) {
                    id == self.sessionID && !Task.isCancelled
                }
                guard id == sessionID, !Task.isCancelled else { return }
                message = result == .sent ? "Copied · paste shortcut sent" : "Copied · paste manually (permission, clipboard or focus changed)"
            }
            try await sleep(.milliseconds(700))
            try Task.checkCancellation()
            guard id == sessionID else { return }
            message = "Ready to dictate"
            phase = .ready
        } catch {
            guard id == sessionID else { return }
            if Task.isCancelled || error is CancellationError {
                message = cancellationMessage ?? "Ready to dictate"
                phase = .ready
                return
            }
            capture.stop()
            finishSound()
            partialText = ""
            message = String(error.localizedDescription.prefix(200))
            phase = .failed
            showsSessionError = true
            do {
                try await sleep(.seconds(4))
                guard id == sessionID, !Task.isCancelled else { return }
                showsSessionError = false
            } catch { }
        }
    }

    private func record(until releases: AsyncThrowingStream<[Float], Error>) async throws -> [Float] {
        defer { releaseSignal = nil }
        return try await withThrowingTaskGroup(of: [Float]?.self) { group in
            group.addTask {
                do { try await self.streamPreview() }
                catch { if !Task.isCancelled { throw error } }
                return nil
            }
            group.addTask {
                for try await samples in releases { return samples }
                return nil
            }
            var captured: [Float] = []
            while let result = try await group.next() {
                if let result { captured = result; group.cancelAll() }
            }
            try Task.checkCancellation()
            return captured
        }
    }

    private func streamPreview() async throws {
        while !Task.isCancelled {
            try await sleep(.seconds(1))
            try Task.checkCancellation()
            if capture.hasConversionFailure { throw CaptureError.conversion }
            let text = try await speech.preview(capture.snapshot())
            try Task.checkCancellation()
            if let text { partialText = text }
        }
    }

    private func finishSound() {
        guard soundActive else { return }
        soundActive = false
        sound.finish()
    }
}
