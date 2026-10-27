// Streaming window and final-tail logic adapted from VoiceInk 1b04d42c.
// GPL-3.0; provenance and original files are listed in NOTICE.md.
import FluidAudio
import Foundation
import os

enum SpeechError: LocalizedError {
    case missingModel, notReady, busy
    var errorDescription: String? {
        switch self {
        case .missingModel: return "Download Parakeet TDT v3 to prepare dictation."
        case .notReady: return "The speech model is not ready."
        case .busy: return "The speech engine is still finishing the previous operation."
        }
    }
}

actor SpeechEngine {
    private let logger = Logger(subsystem: "xyz.karzaev.ummh", category: "model")
    private var manager: AsrManager?
    private var vad: VadManager?
    private var language: Language? = .russian
    private var decoderLayers = 2
    private let agreement = WordAgreementEngine()
    private var confirmedSegments = 0
    private var lastPassCount = 0
    private var inFlight = false
    private let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)

    static var modelExists: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    func prepare(download: Bool) async throws {
        guard !inFlight else { throw SpeechError.busy }
        inFlight = true
        defer { inFlight = false }
        guard manager == nil else { return }
        var directory = AsrModels.defaultCacheDirectory(for: .v3)
        if !Self.modelExists {
            guard download else { throw SpeechError.missingModel }
            directory = try await AsrModels.download(version: .v3, encoderPrecision: .int8)
        }
        logger.notice("Loading Parakeet models")
        let models = try await AsrModels.load(from: directory, version: .v3, encoderPrecision: .int8)
        logger.notice("Parakeet models loaded")
        let loaded = AsrManager(config: .default, models: models)
        // Load VAD before exposing readiness, never in the first microphone callback.
        let loadedVAD = try await VadManager(config: VadConfig(defaultThreshold: 0.7))
        logger.notice("VAD loaded")
        decoderLayers = await loaded.decoderLayerCount
        manager = loaded
        vad = loadedVAD
        logger.notice("Speech engine ready")
    }

    func begin(language code: String) throws {
        guard manager != nil else { throw SpeechError.notReady }
        guard !inFlight else { throw SpeechError.busy }
        language = code == "auto" ? nil : Language(rawValue: code)
        agreement.reset()
        confirmedSegments = 0
        lastPassCount = 0
    }

    func preview(_ samples: [Float]) async throws -> String? {
        guard let manager, let vad else { throw SpeechError.notReady }
        guard !inFlight else { throw SpeechError.busy }
        guard samples.count >= minimumSamples, samples.count - lastPassCount >= minimumSamples else { return nil }
        inFlight = true
        defer { inFlight = false }
        let offset = tailOffset(samples.count)
        let slice = Array(samples.dropFirst(offset))
        guard slice.count >= minimumSamples else { return nil }
        let segments = try await vad.segmentSpeech(slice)
        try Task.checkCancellation()
        var words: [TimedWord] = []
        var textParts: [String] = []
        var confidence: Float = 1
        var hasUntimedText = false
        for segment in segments {
            try Task.checkCancellation()
            let start = max(0, min(segment.startSample(sampleRate: 16_000), slice.count))
            let end = max(start, min(segment.endSample(sampleRate: 16_000), slice.count))
            guard end > start else { continue }
            var audio = Array(slice[start..<end])
            audio += [Float](repeating: 0, count: 16_000)
            var state = TdtDecoderState.make(decoderLayers: decoderLayers)
            let result = try await manager.transcribe(audio, decoderState: &state, language: language)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { textParts.append(text) }
            confidence = min(confidence, result.confidence)
            if let timings = result.tokenTimings, !timings.isEmpty {
                words += WordAgreementEngine.mergeTokensToWords(timings, timeOffset: Double(offset + start) / 16_000)
            } else if !text.isEmpty { hasUntimedText = true }
        }
        lastPassCount = samples.count
        guard !words.isEmpty, !hasUntimedText else {
            let text = textParts.joined(separator: " ")
            return text.isEmpty ? nil : [agreement.confirmedText, text].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let result = agreement.processTranscriptionResult(words: words, resultConfidence: confidence)
        if !result.newlyConfirmedText.isEmpty { confirmedSegments += 1 }
        return result.fullText
    }

    func finish(_ samples: [Float], batchOnly: Bool = false) async throws -> String {
        guard let manager, let vad else { throw SpeechError.notReady }
        guard !inFlight else { throw SpeechError.busy }
        inFlight = true
        defer { inFlight = false }
        try Task.checkCancellation()
        // VoiceInk uses a clean full pass for short / insufficiently confirmed sessions.
        let useConfirmedPrefix = !batchOnly && confirmedSegments >= 3
        let offset = useConfirmedPrefix ? tailOffset(samples.count) : 0
        let slice = Array(samples.dropFirst(offset))
        let segments = try await vad.segmentSpeech(slice)
        var speech: [Float] = []
        for segment in segments {
            let start = max(0, min(segment.startSample(sampleRate: 16_000), slice.count))
            let end = max(start, min(segment.endSample(sampleRate: 16_000), slice.count))
            speech.append(contentsOf: slice[start..<end])
        }
        try Task.checkCancellation()
        let prefix = useConfirmedPrefix ? agreement.confirmedText : ""
        guard !speech.isEmpty else { return prefix }
        if speech.count < minimumSamples { speech += [Float](repeating: 0, count: minimumSamples - speech.count) }
        speech += [Float](repeating: 0, count: 16_000)
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(speech, decoderState: &state, language: language)
        try Task.checkCancellation()
        return [prefix, result.text.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func tailOffset(_ count: Int) -> Int {
        let time = agreement.hypothesisStartTime > 0 ? agreement.hypothesisStartTime : agreement.confirmedEndTime
        return max(0, min(count, Int(time * 16_000)))
    }
}
