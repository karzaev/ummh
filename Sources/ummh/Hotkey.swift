import AppKit
import CoreGraphics

// A small subset of VoiceInk's event-tap shortcut handling; see NOTICE.md.
@MainActor
final class HotkeyMonitor {
    var shortcut = HoldShortcut()
    var suspended = false { didSet { if suspended { interrupt() } } }
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onCancel: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pressed = false

    func start() -> Bool {
        stop()
        // Check the running code's permission, not the toggle for an older build.
        guard Permissions.accessibilityTrusted else { return false }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handle(type, event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        pressed = false
    }

    private func interrupt() {
        pressed = false
        onCancel?()
    }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        guard event.getIntegerValueField(.eventSourceUserData) != AutoPaste.eventMarker else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            interrupt()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard !suspended else { return }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown, code == 53 { interrupt(); return }
        if shortcut.modifierOnly {
            if type == .keyDown, pressed { interrupt(); return } // Command+C must not become dictation.
            guard type == .flagsChanged else { return }
            guard code == shortcut.keyCode else {
                if pressed, !shortcut.matches(event.flags) { interrupt() }
                return
            }
            let down = Self.modifierIsDown(code, flags: event.flags)
            if down, !pressed, shortcut.matches(event.flags) { pressed = true; onDown?() }
            else if !down, pressed { pressed = false; onUp?() }
        } else {
            if type == .flagsChanged, pressed, !shortcut.matches(event.flags) { interrupt(); return }
            guard code == shortcut.keyCode else { return }
            if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               !pressed, shortcut.matches(event.flags) { pressed = true; onDown?() }
            else if type == .keyUp, pressed { pressed = false; onUp?() }
        }
    }

    nonisolated static func modifierIsDown(_ code: UInt16, flags: CGEventFlags) -> Bool {
        // Device-specific NX modifier bits distinguish left/right keys even when both are held.
        let bits: [UInt16: UInt64] = [54: 0x10, 55: 0x8, 56: 0x2, 60: 0x4, 58: 0x20, 61: 0x40, 59: 0x1, 62: 0x2000]
        if let bit = bits[code] { return flags.rawValue & bit != 0 }
        return code == 63 && flags.contains(.maskSecondaryFn)
    }
}
