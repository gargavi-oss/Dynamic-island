import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

/// Borderless panel that is allowed to sit over the menu bar / notch and take keyboard focus.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Stop AppKit from pushing the window below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class NotchWindowController {
    private let vm = NotchViewModel()
    private let panel: NotchPanel
    private var bag = Set<AnyCancellable>()
    private var searchHotKey: GlobalHotKey?
    private var clipboardHotKey: GlobalHotKey?


    /// Prefer the screen that has a physical notch. Can be nil for a moment while displays reconfigure
    /// (wake, lid closed, monitor unplugged); indexing `screens[0]` there would crash.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    init() {
        panel = NotchPanel(contentRect: .zero,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.level = .mainMenu + 3
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Don't let SwiftUI dictate the window's min/max/intrinsic size: we resize the panel ourselves,
        // and the two fighting each other can raise an uncaught AppKit constraint-update exception.
        let host = NSHostingView(rootView: NotchView(vm: vm))
        host.sizingOptions = []
        panel.contentView = host
        vm.panel = panel

        if let s = screen { vm.notch = Self.notchSize(of: s) }

        // First time the Mac locks: move the panel into a space that sits above the lock screen.
        vm.lock.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locked in
                guard let self, locked, AppSettings.shared.isOn(.lockScreen) else { return }
                LockScreenSpace.attach(self.panel)
            }
            .store(in: &bag)

        // Take keyboard focus once, when search opens.
        vm.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard state == .search else { return }
                self?.focusPanel()
            }
            .store(in: &bag)

        // Close search when the panel loses focus (click elsewhere).
        NotificationCenter.default
            .publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                guard let self, self.vm.state == .search else { return }
                self.vm.close()
            }
            .store(in: &bag)

        // Monitor/display changes.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                if let s = self.screen { self.vm.notch = Self.notchSize(of: s) }
                self.apply(self.fixedWindowSize())
            }
            .store(in: &bag)

        AppSettings.shared.changed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateHotkeys() }
            .store(in: &bag)
        updateHotkeys()
    }

    func show() {
        panel.orderFrontRegardless()
        apply(fixedWindowSize())
        if AppSettings.shared.isOn(.lockScreen) { LockScreenSpace.attach(panel) }
    }

    // MARK: - Geometry

    static func notchSize(of screen: NSScreen) -> CGSize {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width,
                          height: screen.safeAreaInsets.top)
        }
        // Mac without a notch: draw a virtual one so the island still works.
        return CGSize(width: 190, height: NSStatusBar.system.thickness)
    }

    /// The panel is created ONCE at the largest size the island can ever need and is never resized
    /// while the app runs. SwiftUI animates the island inside it. Resizing a window that hosts SwiftUI
    /// (while also moving keyboard focus into it) is what raised AppKit's
    /// "more Update Constraints passes than views" exception.
    /// The panel is transparent, so clicks outside the black island fall through to what is underneath.
    private func fixedWindowSize() -> CGSize {
        let n = vm.notch
        let ear = 2 * NotchLayout.ear
        let states: [NotchState] = [.collapsed, .peek, .media, .clipboard, .shelf, .calculator, .locked]
        // Search is the tallest: field + up to 9 result rows (keep in sync with NotchViewModel.size).
        let sizes = states.map { vm.size(for: $0) }
            + [CGSize(width: 480 + ear, height: n.height + 70 + 9 * 40)]
        return CGSize(width: (sizes.map(\.width).max() ?? 0) + 8,
                      height: (sizes.map(\.height).max() ?? 0) + 8)
    }

    private func apply(_ size: CGSize) {
        guard let s = screen?.frame else { return }
        let frame = NSRect(x: s.midX - size.width / 2, y: s.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    private func focusPanel() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Hotkeys (⌘Space = search, ⌘⇧V = clipboard; both can be switched off in the menu bar)
    // Turn off Spotlight's own ⌘Space shortcut in System Settings first.

    private func updateHotkeys() {
        let settings = AppSettings.shared
        searchHotKey?.unregister(); searchHotKey = nil
        clipboardHotKey?.unregister(); clipboardHotKey = nil
        settings.failedHotkeys = []

        if settings.isOn(.searchHotkey) {
            let key = GlobalHotKey(id: 1, keyCode: kVK_Space, modifiers: cmdKey) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.vm.state == .search ? self.vm.close() : self.vm.openSearch()
                }
            }
            searchHotKey = key
            if !key.isRegistered { settings.failedHotkeys.insert(.searchHotkey) }
        }
        // The clipboard hotkey only makes sense while the Clipboard tab is shown.
        if settings.isOn(.clipboardHotkey) && settings.isOn(.tabClipboard) {
            let shortcut = settings.clipboardShortcut
            let key = GlobalHotKey(id: 2, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.vm.state == .clipboard ? self.vm.close() : self.vm.openClipboard()
                }
            }
            clipboardHotKey = key
            if !key.isRegistered { settings.failedHotkeys.insert(.clipboardHotkey) }
        }
    }
}
