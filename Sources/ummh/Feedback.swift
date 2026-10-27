import AppKit
import AVFoundation

// Uses VoiceInk's default start/stop samples at the same reduced volume.
final class SoundFeedback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "xyz.karzaev.ummh.sounds", qos: .userInitiated)
    private var startPlayer: AVAudioPlayer?
    private var finishPlayer: AVAudioPlayer?
    private var started = false

    init() {
        queue.async { [self] in
            startPlayer = player("start")
            finishPlayer = player("finish")
        }
    }

    func start() {
        queue.async { [self] in
            started = true
            finishPlayer?.stop()
            startPlayer?.currentTime = 0
            startPlayer?.play()
        }
    }

    func finish() {
        queue.async { [self] in
            guard started else { return }
            started = false
            startPlayer?.stop()
            finishPlayer?.currentTime = 0
            finishPlayer?.play()
        }
    }

    private func player(_ name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "sounds"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.volume = 0.3
        player.prepareToPlay()
        return player
    }
}

enum AutoPasteResult: Equatable { case sent, manual, cancelled }

enum AutoPaste {
    static let eventMarker: Int64 = 0x756d6d68
    nonisolated static func mayPost(target: pid_t?, foreground: pid_t?, ownPID: pid_t, trusted: Bool,
                                    clipboardVersion: Int, currentClipboardVersion: Int) -> Bool {
        trusted && target != nil && target == foreground && target != ownPID
            && clipboardVersion == currentClipboardVersion
    }

    @MainActor
    static func send(to target: pid_t?, clipboardVersion: Int, isCurrent: () -> Bool) async -> AutoPasteResult {
        // Wait for the physical hold shortcut to be released, including extra modifiers.
        for _ in 0..<20 {
            guard !Task.isCancelled, isCurrent() else { return .cancelled }
            if CGEventSource.flagsState(.combinedSessionState).intersection(HoldShortcut.supportedFlags).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled, isCurrent() else { return .cancelled }
        guard mayPost(target: target, foreground: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                      ownPID: ProcessInfo.processInfo.processIdentifier, trusted: Permissions.accessibilityTrusted,
                      clipboardVersion: clipboardVersion, currentClipboardVersion: NSPasteboard.general.changeCount),
              CGEventSource.flagsState(.combinedSessionState).intersection(HoldShortcut.supportedFlags).isEmpty,
              let source = CGEventSource(stateID: .hidSystemState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else { return .manual }
        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.flags = []
        // No suspension between key-down and key-up; cancellation cannot leave Command held.
        for event in [commandDown, vDown, vUp, commandUp] {
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            event.post(tap: .cghidEventTap)
        }
        return .sent
    }
}
