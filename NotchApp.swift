import SwiftUI
import AppKit

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var controller: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var loginItem: NSMenuItem?
    private var settingItems: [NSMenuItem] = []
    private var searchHotkeyItem: NSMenuItem?
    private var clipboardHotkeyItem: NSMenuItem?
    private var shortcutItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon
        controller = NotchWindowController()
        controller?.show()
        setupStatusItem()
        ImageConverter.cleanTemp()              // converted files from the last run
        if AppSettings.shared.isOn(.autoCheckUpdates), UpdateChecker.isDue {
            Task { await runUpdateCheck(manual: false) }
        }
    }

    // MARK: - Menu bar item (settings, Launch at Login, Quit)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.tophalf.filled",
                                     accessibilityDescription: "Notch Island")

        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(.sectionHeader(title: "Hotkeys"))
        let search = settingItem("Search", .searchHotkey)
        let clipboard = settingItem("Clipboard", .clipboardHotkey)
        searchHotkeyItem = search
        clipboardHotkeyItem = clipboard
        menu.addItem(search)
        menu.addItem(clipboard)

        // Pick another shortcut if the default is already used by another app.
        let shortcutMenu = NSMenu()
        for option in ClipboardShortcut.allCases {
            let it = NSMenuItem(title: option.title, action: #selector(chooseShortcut(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = option.rawValue
            shortcutMenu.addItem(it)
            shortcutItems.append(it)
        }
        let shortcutParent = NSMenuItem(title: "Clipboard shortcut", action: nil, keyEquivalent: "")
        shortcutParent.submenu = shortcutMenu
        shortcutParent.indentationLevel = 1
        menu.addItem(shortcutParent)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Tabs"))
        menu.addItem(settingItem("Music", .tabMedia))
        menu.addItem(settingItem("Clipboard", .tabClipboard))
        menu.addItem(settingItem("File Shelf", .tabShelf))
        menu.addItem(settingItem("Audio", .tabAudio))
        menu.addItem(settingItem("Calculator", .tabCalculator))
        menu.addItem(settingItem("Search", .tabSearch))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Lock Screen"))
        menu.addItem(settingItem("Show island when locked", .lockScreen))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Updates"))
        let version = NSMenuItem(title: "Version \(UpdateChecker.currentVersion)", action: nil, keyEquivalent: "")
        version.indentationLevel = 1
        menu.addItem(version)
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.indentationLevel = 1
        menu.addItem(check)
        menu.addItem(settingItem("Check automatically (daily)", .autoCheckUpdates))

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login

        let quit = NSMenuItem(title: "Quit Notch Island", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func settingItem(_ title: String, _ key: AppSettings.Key) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = key.rawValue
        item.indentationLevel = 1
        settingItems.append(item)
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        let settings = AppSettings.shared
        loginItem?.state = LaunchAtLogin.isEnabled ? .on : .off

        for item in settingItems {
            if let raw = item.representedObject as? String, let key = AppSettings.Key(rawValue: raw) {
                item.state = settings.isOn(key) ? .on : .off
            }
        }

        // Show the shortcut, and say so when another app already owns it.
        let taken = "  (taken by another app)"
        searchHotkeyItem?.title = "Search  (⌘Space)" + (settings.failedHotkeys.contains(.searchHotkey) ? taken : "")
        clipboardHotkeyItem?.title = "Clipboard  (\(settings.clipboardShortcut.title))"
            + (settings.failedHotkeys.contains(.clipboardHotkey) ? taken : "")

        for item in shortcutItems {
            item.state = (item.representedObject as? String) == settings.clipboardShortcut.rawValue ? .on : .off
        }
    }

    /// The clipboard hotkey is greyed out while the Clipboard tab is hidden (it has nothing to open).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let raw = menuItem.representedObject as? String,
           raw == AppSettings.Key.clipboardHotkey.rawValue {
            return AppSettings.shared.isOn(.tabClipboard)
        }
        return true
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let key = AppSettings.Key(rawValue: raw) else { return }
        AppSettings.shared.toggle(key)
    }

    @objc private func chooseShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let shortcut = ClipboardShortcut(rawValue: raw) else { return }
        AppSettings.shared.clipboardShortcut = shortcut
    }

    @objc private func checkForUpdates() { Task { await runUpdateCheck(manual: true) } }

    /// Automatic checks stay silent unless there is something new; manual ones always answer.
    private func runUpdateCheck(manual: Bool) async {
        switch await UpdateChecker.check() {
        case .available(let version, let page):
            UpdateChecker.markChecked()
            showAlert("Version \(version) is available",
                      "You have \(UpdateChecker.currentVersion).", download: page)
        case .upToDate:
            UpdateChecker.markChecked()
            if manual { showAlert("You're up to date", "Notch Island \(UpdateChecker.currentVersion) is the latest version.") }
        case .failed(let reason):
            if manual { showAlert("Couldn't check for updates", reason) }
        }
    }

    private func showAlert(_ title: String, _ text: String, download: URL? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: download == nil ? "OK" : "Download")
        if download != nil { alert.addButton(withTitle: "Later") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let download { NSWorkspace.shared.open(download) }
    }

    @objc private func toggleLogin() { LaunchAtLogin.set(!LaunchAtLogin.isEnabled) }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
