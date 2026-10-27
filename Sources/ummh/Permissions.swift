import AppKit
import AVFoundation
import ApplicationServices
import Combine

enum RequiredPermission: Hashable {
    case microphone, accessibility
}

// One attempt per access per launch avoids a prompt loop on app activation.
struct PermissionRequests {
    private var attempted: Set<RequiredPermission> = []
    mutating func next(microphone: Bool, accessibility: Bool) -> RequiredPermission? {
        let missing: RequiredPermission?
        if !microphone { missing = .microphone }
        else if !accessibility { missing = .accessibility }
        else { missing = nil }
        guard let missing, attempted.insert(missing).inserted else { return nil }
        return missing
    }
}

@MainActor
final class Permissions: ObservableObject {
    @Published private(set) var microphoneGranted = false
    @Published private(set) var accessibilityGranted = false
    private var requests = PermissionRequests()
    private var checking = false
    nonisolated static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    func statusMessage(for controller: SessionController) -> String {
        Self.statusMessage(phase: controller.phase, message: controller.message,
                           microphone: microphoneGranted, accessibility: accessibilityGranted,
                           shortcutAvailable: controller.shortcutAvailable)
    }

    nonisolated static func statusMessage(phase: SessionPhase, message: String, microphone: Bool,
                                         accessibility: Bool, shortcutAvailable: Bool) -> String {
        guard phase == .ready else { return message }
        if !microphone { return "Microphone access unavailable" }
        if !accessibility { return "Accessibility access unavailable" }
        if !shortcutAvailable { return "Global shortcut unavailable" }
        return message
    }

    func refresh() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = Self.accessibilityTrusted
    }

    func ensureAccess() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        refresh()
        while let permission = requests.next(microphone: microphoneGranted, accessibility: accessibilityGranted) {
            switch permission {
            case .microphone:
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .notDetermined: _ = await AVCaptureDevice.requestAccess(for: .audio)
                case .denied: openPrivacyPane("Microphone")
                default: break
                }
            case .accessibility:
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                if !Self.accessibilityTrusted { openPrivacyPane("Accessibility") }
            }
            refresh()
        }
    }

    private func openPrivacyPane(_ name: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(name)") {
            NSWorkspace.shared.open(url)
        }
    }
}
