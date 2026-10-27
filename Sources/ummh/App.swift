import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let permissions = Permissions()
    private lazy var controller = SessionController(settings: settings)
    private let hotkey = HotkeyMonitor()
    private var statusItem: NSStatusItem!
    private lazy var idleStatusIcon = microphoneImage()
    private lazy var activeStatusIcon = microphoneImage(active: true)
    private var panel: RecordingPanel!
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var shortcutEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = idleStatusIcon
        panel = RecordingPanel(controller: controller)
        controller.objectWillChange.merge(with: permissions.objectWillChange).sink { [weak self] _ in
            // ObservableObject announces changes before the new values are stored.
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &subscriptions)
        hotkey.shortcut = settings.shortcut
        hotkey.onDown = { [weak self] in self?.beginDictation() }
        hotkey.onUp = { [weak self] in self?.controller.release() }
        hotkey.onCancel = { [weak self] in self?.controller.cancel() }
        controller.shortcutAvailable = hotkey.start()
        settings.$shortcut.dropFirst().sink { [weak self] value in self?.hotkey.shortcut = value }.store(in: &subscriptions)
        settings.$showLiveText.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &subscriptions)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.cancel() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.controller.capture.ownsEngine(notification.object) else { return }
                self.controller.inputLost()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkPermissions()
            }
        })
        controller.prepare()
        refresh()
        openSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.cancel()
        controller.capture.stop()
        hotkey.stop()
    }

    private func refresh() {
        guard statusItem != nil else { return }
        panel.refresh(controller)
        statusItem.button?.image = controller.phase.busy ? activeStatusIcon : idleStatusIcon
        let message = permissions.statusMessage(for: controller)
        statusItem.button?.toolTip = "ummh · \(message)"
        let menu = NSMenu()
        let state = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        let preferences = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)
        let about = NSMenuItem(title: "About", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ummh", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let root = SettingsView(controller: controller, settings: settings, permissions: permissions,
                                    onShortcutChange: { [weak self] in self?.captureShortcut() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "ummh"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        checkPermissions()
    }

    @objc func openAbout() {
        if aboutWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            window.title = "About"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            aboutWindow = window
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func checkPermissions() {
        guard !controller.phase.busy else { return }
        Task {
            await permissions.ensureAccess()
            guard !controller.phase.busy else { return }
            if permissions.accessibilityGranted {
                if !controller.shortcutAvailable { controller.shortcutAvailable = hotkey.start() }
            } else {
                hotkey.stop()
                controller.shortcutAvailable = false
            }
        }
    }

    private func beginDictation() {
        permissions.refresh()
        guard permissions.microphoneGranted, permissions.accessibilityGranted else { checkPermissions(); return }
        controller.press()
    }

    private func captureShortcut() {
        guard !controller.phase.busy else { return }
        hotkey.suspended = true
        let alert = NSAlert()
        alert.messageText = "Press a shortcut to hold while dictating"
        alert.informativeText = "Use a modifier key on its own, or a modified key combination. Escape cancels."
        alert.addButton(withTitle: "Cancel")
        let modifierNames: [UInt16: String] = [54: "Right Command", 55: "Left Command", 56: "Left Shift", 60: "Right Shift",
                                               58: "Left Option", 61: "Right Option", 59: "Left Control", 62: "Right Control", 63: "Fn"]
        var selected: HoldShortcut?
        var modifierCandidate: HoldShortcut?
        shortcutEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown, event.keyCode == 53 { NSApp.stopModal(); return nil }
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).intersection(HoldShortcut.supportedFlags)
            if event.type == .flagsChanged, let name = modifierNames[event.keyCode],
               HotkeyMonitor.modifierIsDown(event.keyCode, flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))) {
                // Wait for release: the user may still be forming a modified key chord.
                modifierCandidate = HoldShortcut(keyCode: event.keyCode, modifiers: flags.rawValue, modifierOnly: true, label: name)
                return nil
            } else if event.type == .flagsChanged, event.keyCode == modifierCandidate?.keyCode {
                selected = modifierCandidate
            } else if event.type == .keyDown, !flags.isEmpty, !event.isARepeat {
                let symbols = [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
                let label = symbols.filter { flags.contains($0.0) }.map(\.1).joined() + (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
                selected = HoldShortcut(keyCode: event.keyCode, modifiers: flags.rawValue, modifierOnly: false, label: label)
            }
            if selected != nil { NSApp.stopModal(); return nil }
            return event
        }
        alert.runModal()
        alert.window.orderOut(nil)
        if let shortcutEventMonitor { NSEvent.removeMonitor(shortcutEventMonitor) }
        shortcutEventMonitor = nil
        if let selected { settings.shortcut = selected }
        hotkey.suspended = false
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

@main
@MainActor
struct UmmhMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            Task { exit(await Diagnostics.run(arguments)) }
            RunLoop.main.run()
            return
        }
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "xyz.karzaev.ummh")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate()
            return
        }
        UmmhApplication.main()
    }
}

@MainActor
struct UmmhApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        SwiftUI.Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About") { delegate.openAbout() }
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { delegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
