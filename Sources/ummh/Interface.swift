import AppKit
import SwiftUI

// Wave shape/amplitude formula adapted from VoiceInk AudioVisualizerView.swift.
struct Waveform: View {
    let level: () -> Float
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let amplitude = Double(pow(max(0, min(1, level())), 0.7))
            let time = context.date.timeIntervalSince1970
            HStack(spacing: 2) {
                ForEach(0..<15) { index in
                    let wave = sin(time * 8 + Double(index) * 0.4) * 0.5 + 0.5
                    let distance = abs(Double(index) - 7.5) / 7
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: 3, height: max(4, 4 + amplitude * wave * (1 - distance * 0.4) * 24))
                }
            }
            .frame(height: 28)
        }
        .accessibilityLabel("Microphone level")
    }
}

// Same rotating-arc vocabulary as VoiceInk, scoped to visible processing states.
struct ProcessingSpinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            Circle().trim(from: 0.1, to: 0.9)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 360))
        }
    }
}

struct RecordingView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var settings: Settings

    var body: some View {
        RecordingSurface(phase: controller.phase, partialText: controller.partialText, message: controller.message,
                         showLiveText: settings.showLiveText, level: { controller.capture.level })
    }
}

struct RecordingSurface: View {
    let phase: SessionPhase
    let partialText: String
    let message: String
    let showLiveText: Bool
    let level: () -> Float

    var body: some View {
        VStack(spacing: 0) {
            if showLiveText, !partialText.isEmpty, phase == .recording {
                Text(String(partialText.suffix(480)))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(height: 60)
                Divider().overlay(.white.opacity(0.12))
            }
            Group {
                switch phase {
                case .starting, .recording: Waveform(level: level)
                case .failed:
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(message).font(.system(size: 11)).lineLimit(2)
                    }.padding(.horizontal, 12)
                case .finishing, .cancelling:
                    ProcessingSpinner().accessibilityLabel(message)
                default: EmptyView()
                }
            }
            .frame(height: 44)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12)))
    }
}

@MainActor
final class RecordingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(controller: SessionController) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = NSHostingView(rootView: RecordingView(controller: controller, settings: controller.settings))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = true
    }

    func refresh(_ controller: SessionController) {
        let visible = controller.phase.busy || controller.showsSessionError
        guard visible else { orderOut(nil); return }
        let screen = NSScreen.main
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.screens.first
        guard let screen else { orderOut(nil); return }
        let expanded = controller.settings.showLiveText && !controller.partialText.isEmpty && controller.phase == .recording
        let size = NSSize(width: expanded || controller.showsSessionError ? 360 : 124, height: expanded ? 105 : 44)
        let frame = screen.visibleFrame
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 24, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }
}

struct SettingsView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var settings: Settings
    @ObservedObject var permissions: Permissions
    let onShortcutChange: () -> Void
    @State private var devices: [InputDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("ummh").font(.title2.weight(.semibold))
                Spacer()
                Text("Parakeet TDT v3 · local").font(.caption).foregroundStyle(.secondary)
            }
            Text(permissions.statusMessage(for: controller)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if controller.phase == .needsModel || controller.phase == .modelFailed {
                Button(controller.phase == .needsModel ? "Download model" : "Retry model preparation") { controller.prepare(download: true) }
            }
            if controller.phase == .loading { ProgressView().controlSize(.small) }
            Form {
                HStack {
                    Text("Hold to dictate")
                    Spacer()
                    Button(settings.shortcut.label, action: onShortcutChange)
                }
                Picker("Microphone", selection: $settings.microphoneUID) {
                    Text("System default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                    if !settings.microphoneUID.isEmpty, !devices.contains(where: { $0.id == settings.microphoneUID }) {
                        Text("Unavailable input").tag(settings.microphoneUID)
                    }
                }
                Picker("Language", selection: $settings.language) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                    Text("Auto").tag("auto")
                }
                Toggle("Show live text above the waveform", isOn: $settings.showLiveText)
                Toggle("Paste automatically", isOn: $settings.autoPaste)
            }
            .disabled(controller.phase.busy)
            Divider()
            VStack(spacing: 6) {
                permissionStatus("Microphone", granted: permissions.microphoneGranted)
                permissionStatus("Accessibility · shortcut and paste", granted: permissions.accessibilityGranted)
            }
            Text("Hold the shortcut to record. Release to copy. Escape cancels.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 450)
        .onAppear { devices = AudioDevices.inputs() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            devices = AudioDevices.inputs()
        }
    }

    private func permissionStatus(_ title: String, granted: Bool) -> some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle" : "circle")
            Spacer()
            Text(granted ? "Granted" : "Waiting")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct AboutView: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1" }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("ummh").font(.title.weight(.semibold))
            Text("Version \(version)").foregroundStyle(.secondary)
            HStack(spacing: 0) {
                Text("by ")
                Link("karzaev", destination: URL(string: "https://karzaev.xyz")!)
            }
            .font(.callout)
        }
        .padding(32)
        .frame(width: 300)
    }
}

// Original template microphone vector drawing.
@MainActor
func microphoneImage(active: Bool = false) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.setStroke()
        let capsule = NSBezierPath(roundedRect: NSRect(x: 6.25, y: 6, width: 5.5, height: 10), xRadius: 2.75, yRadius: 2.75)
        capsule.lineWidth = 1.5
        if active {
            NSColor.black.setFill()
            capsule.fill()
        }
        capsule.stroke()
        let cradle = NSBezierPath()
        cradle.move(to: NSPoint(x: 3.5, y: 8))
        cradle.curve(to: NSPoint(x: 9, y: 2.8), controlPoint1: NSPoint(x: 3.5, y: 4.5), controlPoint2: NSPoint(x: 5.8, y: 2.8))
        cradle.curve(to: NSPoint(x: 14.5, y: 8), controlPoint1: NSPoint(x: 12.2, y: 2.8), controlPoint2: NSPoint(x: 14.5, y: 4.5))
        cradle.lineWidth = 1.5
        cradle.lineCapStyle = .round
        cradle.stroke()
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: 9, y: 2.8)); stem.line(to: NSPoint(x: 9, y: 0.8))
        stem.lineWidth = 1.5; stem.stroke()
        return true
    }
    image.isTemplate = true
    image.cacheMode = .never
    return image
}
