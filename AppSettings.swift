import AppKit
import Combine
import Carbon.HIToolbox

/// Shortcuts offered for the clipboard tab (pick another if one is already used by another app).
enum ClipboardShortcut: String, CaseIterable {
    case cmdShiftV, optCmdV, ctrlOptV, ctrlCmdV

    var title: String {
        switch self {
        case .cmdShiftV: return "⌘⇧V"
        case .optCmdV:   return "⌥⌘V"
        case .ctrlOptV:  return "⌃⌥V"
        case .ctrlCmdV:  return "⌃⌘V"
        }
    }

    var keyCode: Int { kVK_ANSI_V }

    var modifiers: Int {
        switch self {
        case .cmdShiftV: return cmdKey | shiftKey
        case .optCmdV:   return optionKey | cmdKey
        case .ctrlOptV:  return controlKey | optionKey
        case .ctrlCmdV:  return controlKey | cmdKey
        }
    }
}

/// User settings (saved in UserDefaults): which hotkeys are active and which tabs show.
/// Everything defaults to ON.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Key: String, CaseIterable {
        case searchHotkey, clipboardHotkey
        case tabMedia, tabClipboard, tabShelf, tabSearch
    }

    /// The tabs the island opens on when you hover it. At least one must stay on.
    static let pageKeys: [Key] = [.tabMedia, .tabClipboard, .tabShelf]

    /// Fires after any change (the window controller re-registers hotkeys from this).
    let changed = PassthroughSubject<Void, Never>()

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: Key.allCases.map { ($0.rawValue, true) }))
    }

    /// Hotkeys macOS refused to register because another app already owns them.
    var failedHotkeys: Set<Key> = []

    var clipboardShortcut: ClipboardShortcut {
        get { ClipboardShortcut(rawValue: defaults.string(forKey: "clipboardShortcut") ?? "") ?? .cmdShiftV }
        set {
            defaults.set(newValue.rawValue, forKey: "clipboardShortcut")
            objectWillChange.send()
            changed.send()
        }
    }

    func isOn(_ key: Key) -> Bool { defaults.bool(forKey: key.rawValue) }

    func toggle(_ key: Key) { set(key, !isOn(key)) }

    func set(_ key: Key, _ value: Bool) {
        // Never let every hover tab be switched off, or the island couldn't open on hover.
        if !value, Self.pageKeys.contains(key), isOn(key),
           Self.pageKeys.filter({ isOn($0) }).count <= 1 {
            NSSound.beep()
            return
        }
        defaults.set(value, forKey: key.rawValue)
        objectWillChange.send()
        changed.send()
    }

    /// What hovering the island opens: the first tab that is switched on.
    var defaultPage: NotchState {
        if isOn(.tabMedia) { return .media }
        if isOn(.tabClipboard) { return .clipboard }
        return .shelf
    }
}
