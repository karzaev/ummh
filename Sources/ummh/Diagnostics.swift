import AppKit
import AVFoundation
import FluidAudio
import Foundation
import SwiftUI

// Development-only, opt-in evaluation. No audio is recorded and no clipboard is touched.
@MainActor
enum Diagnostics {
    static func run(_ arguments: [String]) async -> Int32 {
        if arguments == ["--help"] {
            print("ummh\n  --replay FILE [--batch] [--language ru|en|auto]\n  --render-preview DIRECTORY")
            return 0
        }
        do {
            if arguments.first == "--render-preview", arguments.count == 2 {
                try renderPreviews(to: URL(fileURLWithPath: arguments[1], isDirectory: true))
                return 0
            }
            guard arguments.first == "--replay", arguments.count >= 2 else {
                fputs("Use ummh --help for development commands.\n", stderr)
                return 2
            }
            let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: arguments[1]))
            let languageIndex = arguments.firstIndex(of: "--language")
            let language = languageIndex.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "ru"
            let batch = arguments.contains("--batch")
            let engine = SpeechEngine()
            let start = Date()
            try await engine.prepare(download: false)
            let loaded = Date()
            try await engine.begin(language: language)
            var firstPartial: Double?
            let transcriptionStart = Date()
            if !batch {
                for end in stride(from: 16_000, through: audio.count, by: 16_000) {
                    let text = try await engine.preview(Array(audio.prefix(end)))
                    if firstPartial == nil, let text, !text.isEmpty { firstPartial = Date().timeIntervalSince(transcriptionStart) }
                }
            }
            let stopped = Date()
            let text = try await engine.finish(audio, batchOnly: batch)
            let result: [String: Any] = [
                "mode": batch ? "batch" : "agreement-replay", "language": language,
                "audioSeconds": Double(audio.count) / 16_000,
                "loadSeconds": loaded.timeIntervalSince(start),
                "decodeSeconds": Date().timeIntervalSince(transcriptionStart),
                "finishSeconds": Date().timeIntervalSince(stopped),
                "firstPartialDecodeSeconds": firstPartial as Any? ?? NSNull(), "text": text
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return 0
        } catch {
            fputs("ummh evaluation failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func renderPreviews(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for expanded in [false, true] {
            let view = RecordingSurface(phase: .recording,
                                        partialText: expanded ? "Сегодня проверяем локальное распознавание. Текст остаётся на этом Mac." : "",
                                        message: "Listening", showLiveText: expanded, level: { 0.7 })
            .frame(width: expanded ? 360 : 124, height: expanded ? 105 : 44)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let data = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: directory.appendingPathComponent(expanded ? "panel-live.png" : "panel-compact.png"))
        }
        let starting = RecordingSurface(phase: .starting, partialText: "", message: "Starting microphone…",
                                        showLiveText: false, level: { 0 }).frame(width: 124, height: 44)
        let startingRenderer = ImageRenderer(content: starting)
        startingRenderer.scale = 2
        if let data = startingRenderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: directory.appendingPathComponent("panel-starting.png"))
        }
        let processing = RecordingSurface(phase: .finishing, partialText: "", message: "Finishing transcription…",
                                          showLiveText: false, level: { 0 }).frame(width: 124, height: 44)
        let processingRenderer = ImageRenderer(content: processing)
        processingRenderer.scale = 2
        if let data = processingRenderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: directory.appendingPathComponent("panel-processing.png"))
        }
        for active in [false, true] {
            let icon = microphoneImage(active: active)
            icon.isTemplate = false
            guard let data = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try png.write(to: directory.appendingPathComponent(active ? "menubar-active.png" : "menubar-microphone.png"))
            let iconPreview = Image(nsImage: icon).resizable().frame(width: 72, height: 72).padding(24).background(.white)
            let renderer = ImageRenderer(content: iconPreview)
            renderer.scale = 2
            if let data = renderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent(active ? "menubar-active-preview.png" : "menubar-preview.png"))
            }
        }
    }
}
