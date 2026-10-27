import AppKit
import Combine

struct HoldShortcut: Codable, Equatable {
    var keyCode: UInt16 = 54 // Right Command.
    var modifiers: UInt64 = CGEventFlags.maskCommand.rawValue
    var modifierOnly: Bool = true
    var label: String = "Right Command"

    static let supportedFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
    func matches(_ flags: CGEventFlags) -> Bool {
        flags.intersection(Self.supportedFlags).rawValue == modifiers
    }
}

@MainActor
final class Settings: ObservableObject {
    private let defaults: UserDefaults
    @Published var showLiveText: Bool { didSet { defaults.set(showLiveText, forKey: "showLiveText") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var microphoneUID: String { didSet { defaults.set(microphoneUID, forKey: "microphoneUID") } }
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: "autoPaste") } }
    @Published var shortcut: HoldShortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "holdShortcut") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showLiveText = defaults.bool(forKey: "showLiveText")
        language = defaults.string(forKey: "language") ?? "ru"
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        autoPaste = defaults.bool(forKey: "autoPaste")
        shortcut = defaults.data(forKey: "holdShortcut").flatMap { try? JSONDecoder().decode(HoldShortcut.self, from: $0) } ?? HoldShortcut()
    }
}

enum SessionPhase: Equatable {
    case loading, needsModel, modelFailed, ready, starting, recording, finishing, cancelling, copied, failed
    var busy: Bool { [.starting, .recording, .finishing, .cancelling].contains(self) }
}
