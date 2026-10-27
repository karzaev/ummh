import XCTest
import CoreGraphics
import AppKit
@testable import ummh

final class AgreementTests: XCTestCase {
    private func words(_ texts: [String], confidence: Float = 1) -> [TimedWord] {
        texts.enumerated().map { index, text in
            TimedWord(text: text, startTime: Double(index) * 0.2, endTime: Double(index + 1) * 0.2, confidence: confidence)
        }
    }

    func testGrowingPrefixCannotLendConfirmationsToNewWords() {
        let engine = WordAgreementEngine()
        let prefix = ["Первое", "небольшое", "предложение", "уже", "готово."]
        let tail = ["Вторая", "фраза", "пока", "ошибочна.", "Третья", "фраза", "завершена.", "Четвертая", "фраза", "завершена."]
        _ = engine.processTranscriptionResult(words: words(prefix + ["черновик"]))
        _ = engine.processTranscriptionResult(words: words(prefix + ["вариант"]))
        _ = engine.processTranscriptionResult(words: words(prefix + tail))
        XCTAssertEqual(engine.processTranscriptionResult(words: words(prefix + tail)).newlyConfirmedText, "")
        XCTAssertEqual(engine.processTranscriptionResult(words: words(prefix + tail)).newlyConfirmedText, "")
        let confirmed = engine.processTranscriptionResult(words: words(prefix + tail))
        XCTAssertEqual(confirmed.newlyConfirmedText, (prefix + Array(tail.prefix(4))).joined(separator: " "))
    }

    func testLowConfidenceResetsEachWordsHistory() {
        let engine = WordAgreementEngine()
        let input = words(["Раз", "два", "три", "четыре", "пять.", "Шесть.", "Семь."])
        for _ in 0..<3 { _ = engine.processTranscriptionResult(words: input) }
        _ = engine.processTranscriptionResult(words: input, resultConfidence: 0.01)
        for _ in 0..<2 {
            XCTAssertEqual(engine.processTranscriptionResult(words: input).newlyConfirmedText, "")
        }
        XCTAssertFalse(engine.processTranscriptionResult(words: input).newlyConfirmedText.isEmpty)
    }

    func testUnstablePreviewNeverCommitsWords() {
        let engine = WordAgreementEngine()
        _ = engine.processTranscriptionResult(words: words(["Привет", "мир."]))
        let revised = engine.processTranscriptionResult(words: words(["Привет", "Mac."]))
        XCTAssertEqual(revised.fullText, "Привет Mac.")
        XCTAssertEqual(engine.confirmedText, "")
    }

    func testStablePrefixPreservesUnconfirmedTailPosition() {
        let engine = WordAgreementEngine(config: AgreementConfig(tokenConfirmationsNeeded: 1, minWordsToConfirm: 1))
        let input = words(["Первая", "фраза.", "Вторая", "фраза.", "Третья", "фраза."])
        _ = engine.processTranscriptionResult(words: input)
        let result = engine.processTranscriptionResult(words: input)
        XCTAssertEqual(result.newlyConfirmedText, "Первая фраза.")
        XCTAssertEqual(result.fullText, input.map(\.text).joined(separator: " "))
        XCTAssertEqual(engine.hypothesisStartTime, input[2].startTime)
        XCTAssertEqual(engine.confirmedEndTime, input[1].endTime)
    }

    func testPunctuationChangesCannotFreezeWrongSentenceBoundary() {
        let engine = WordAgreementEngine(config: AgreementConfig(tokenConfirmationsNeeded: 1, minWordsToConfirm: 1))
        _ = engine.processTranscriptionResult(words: words(["Раз.", "Два.", "Три."]))
        let changed = engine.processTranscriptionResult(words: words(["Раз", "Два.", "Три."]))
        XCTAssertEqual(changed.newlyConfirmedText, "")
    }

    func testLowConfidencePassCannotConfirmPrefix() {
        let engine = WordAgreementEngine(config: AgreementConfig(tokenConfirmationsNeeded: 1, minWordsToConfirm: 1))
        let input = words(["Раз.", "Два.", "Три."])
        _ = engine.processTranscriptionResult(words: input)
        let result = engine.processTranscriptionResult(words: input, resultConfidence: 0.01)
        XCTAssertEqual(result.newlyConfirmedText, "")
        XCTAssertEqual(result.fullText, "Раз. Два. Три.")
    }
}

final class ShortcutTests: XCTestCase {
    @MainActor
    func testAutomaticPasteCannotTriggerRecording() async {
        let monitor = HotkeyMonitor()
        monitor.shortcut = HoldShortcut(keyCode: 9, modifiers: CGEventFlags.maskCommand.rawValue,
                                        modifierOnly: false, label: "Command+V")
        var triggered = false
        monitor.onDown = { triggered = true }
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
        event.flags = .maskCommand
        event.setIntegerValueField(.eventSourceUserData, value: AutoPaste.eventMarker)
        monitor.handle(.keyDown, event)
        XCTAssertFalse(triggered)
    }

    @MainActor
    func testRightCommandReleaseFinishesRatherThanCancels() async {
        let monitor = HotkeyMonitor()
        var actions: [String] = []
        monitor.onDown = { actions.append("start") }
        monitor.onUp = { actions.append("finish") }
        monitor.onCancel = { actions.append("cancel") }
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true)!
        event.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        monitor.handle(.flagsChanged, event)
        event.flags = []
        monitor.handle(.flagsChanged, event)
        XCTAssertEqual(actions, ["start", "finish"])
    }

    @MainActor
    func testCommandChordCancelsInsteadOfDictatingShortcut() async {
        let monitor = HotkeyMonitor()
        var actions: [String] = []
        monitor.onDown = { actions.append("start") }
        monitor.onUp = { actions.append("finish") }
        monitor.onCancel = { actions.append("cancel") }
        let command = CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true)!
        command.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        monitor.handle(.flagsChanged, command)
        let c = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true)!
        c.flags = command.flags
        monitor.handle(.keyDown, c)
        command.flags = []
        monitor.handle(.flagsChanged, command)
        XCTAssertEqual(actions, ["start", "cancel"])
    }

    func testRightAndLeftCommandAreDistinguished() {
        let leftOnly = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
        XCTAssertFalse(HotkeyMonitor.modifierIsDown(54, flags: leftOnly))
    }

    @MainActor
    func testRightCommandReleaseFinishesWhileLeftCommandRemainsHeld() async {
        let monitor = HotkeyMonitor()
        var finished = false
        monitor.onUp = { finished = true }
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true)!
        event.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x18)
        monitor.handle(.flagsChanged, event)
        event.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
        monitor.handle(.flagsChanged, event)
        XCTAssertTrue(finished)
    }
}

final class AutoPasteTests: XCTestCase {
    func testPasteRequiresPermissionAndUnchangedExternalTarget() {
        XCTAssertTrue(AutoPaste.mayPost(target: 10, foreground: 10, ownPID: 20, trusted: true, clipboardVersion: 1, currentClipboardVersion: 1))
        XCTAssertFalse(AutoPaste.mayPost(target: 10, foreground: 30, ownPID: 20, trusted: true, clipboardVersion: 1, currentClipboardVersion: 1))
        XCTAssertFalse(AutoPaste.mayPost(target: 20, foreground: 20, ownPID: 20, trusted: true, clipboardVersion: 1, currentClipboardVersion: 1))
        XCTAssertFalse(AutoPaste.mayPost(target: nil, foreground: nil, ownPID: 20, trusted: true, clipboardVersion: 1, currentClipboardVersion: 1))
        XCTAssertFalse(AutoPaste.mayPost(target: 10, foreground: 10, ownPID: 20, trusted: false, clipboardVersion: 1, currentClipboardVersion: 1))
    }

    @MainActor
    func testChangedClipboardPreventsDelayedPaste() {
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("dictation", forType: .string)
        let copiedVersion = clipboard.changeCount
        XCTAssertTrue(AutoPaste.mayPost(target: 10, foreground: 10, ownPID: 20, trusted: true,
                                        clipboardVersion: copiedVersion, currentClipboardVersion: clipboard.changeCount))
        clipboard.clearContents()
        clipboard.setString("new user copy", forType: .string)
        XCTAssertFalse(AutoPaste.mayPost(target: 10, foreground: 10, ownPID: 20, trusted: true,
                                         clipboardVersion: copiedVersion, currentClipboardVersion: clipboard.changeCount))
        XCTAssertEqual(clipboard.string(forType: .string), "new user copy")
    }

    @MainActor
    func testAutomaticPasteDefaultsOffAndPersistsOptIn() async {
        let name = "xyz.karzaev.ummh.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        XCTAssertFalse(settings.autoPaste)
        settings.autoPaste = true
        XCTAssertTrue(Settings(defaults: defaults).autoPaste)
    }
}

final class PermissionTests: XCTestCase {
    func testModelReadyCannotHideMissingMicrophoneOrShortcutAccess() {
        XCTAssertEqual(Permissions.statusMessage(phase: .ready, message: "Ready to dictate", microphone: false,
                                                accessibility: true, shortcutAvailable: true), "Microphone access unavailable")
        XCTAssertEqual(Permissions.statusMessage(phase: .ready, message: "Ready to dictate", microphone: true,
                                                accessibility: false, shortcutAvailable: false), "Accessibility access unavailable")
    }

    func testGrantedPermissionStillRequiresRunningShortcutMonitor() {
        XCTAssertEqual(Permissions.statusMessage(phase: .ready, message: "Ready to dictate", microphone: true,
                                                accessibility: true, shortcutAvailable: false), "Global shortcut unavailable")
        XCTAssertEqual(Permissions.statusMessage(phase: .ready, message: "Ready to dictate", microphone: true,
                                                accessibility: true, shortcutAvailable: true), "Ready to dictate")
    }

    func testPermissionStatusDoesNotReplaceLoadingOrRecordingState() {
        XCTAssertEqual(Permissions.statusMessage(phase: .loading, message: "Loading model…", microphone: false,
                                                accessibility: false, shortcutAvailable: false), "Loading model…")
        XCTAssertEqual(Permissions.statusMessage(phase: .recording, message: "Listening", microphone: true,
                                                accessibility: true, shortcutAvailable: true), "Listening")
    }

    func testPermissionsAreRequestedInOrderAsAccessIsGranted() {
        var requests = PermissionRequests()
        XCTAssertEqual(requests.next(microphone: false, accessibility: false), .microphone)
        XCTAssertEqual(requests.next(microphone: true, accessibility: false), .accessibility)
        XCTAssertNil(requests.next(microphone: true, accessibility: true))
    }

    func testDeniedPermissionStopsOtherPromptsAndDoesNotLoopOnActivation() {
        var requests = PermissionRequests()
        _ = requests.next(microphone: false, accessibility: false)
        for _ in 0..<5 {
            XCTAssertNil(requests.next(microphone: false, accessibility: false))
        }
        XCTAssertEqual(requests.next(microphone: true, accessibility: false), .accessibility)
        XCTAssertNil(requests.next(microphone: true, accessibility: false))
    }

    func testAccessibilityIsRequiredForTheHotkeyEvenWithManualPaste() {
        var requests = PermissionRequests()
        XCTAssertEqual(requests.next(microphone: true, accessibility: false), .accessibility)
        XCTAssertNil(requests.next(microphone: true, accessibility: false))
        XCTAssertNil(requests.next(microphone: true, accessibility: true))
    }
}
