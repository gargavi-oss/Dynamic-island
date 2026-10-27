import SwiftUI
import AppKit
import Combine

enum NotchState { case collapsed, peek, media, clipboard, shelf, search, calculator, locked }

/// While the Mac is locked: `.locked` shows the padlock, `.unlocking` shows the open padlock for a moment.
enum LockPhase { case unlocked, locked, unlocking }

@MainActor
final class NotchViewModel: ObservableObject {
    /// `state` and `contentSize` always change together, inside ONE animation transaction,
    /// so the shape, the content and the size all move on the same spring.
    @Published private(set) var state: NotchState = .collapsed
    @Published private(set) var contentSize = CGSize(width: 190, height: 32)

    /// Selection is tracked by result id (not row index), so it can't jump when results re-sort.
    @Published var selectedID: String?
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }   // Return can re-write the same text; don't reset
            search.search(query)
            selectedID = nil
        }
    }

    let media = MediaController()
    let volume = VolumeController()
    let clipboard = ClipboardHistory()
    let search = SpotlightSearch()
    let shelf = FileShelf()
    let calc = CalculatorModel()
    let lock = LockMonitor()
    @Published private(set) var lockPhase: LockPhase = .unlocked
    private var lockTask: Task<Void, Never>?
    weak var panel: NSPanel?                       // set by the window controller

    var notch = CGSize(width: 190, height: 32) {
        didSet { contentSize = size(for: state) }  // screen change: no animation
    }

    // Opening has a little life in it; closing settles without bounce.
    private static let expandSpring = Animation.spring(response: 0.42, dampingFraction: 0.78)
    private static let collapseSpring = Animation.spring(response: 0.34, dampingFraction: 0.9)
    private static let resizeSpring = Animation.spring(response: 0.30, dampingFraction: 0.88)

    private var hoverTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    init() {
        // Screen locked / unlocked.
        lock.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locked in self?.lockChanged(locked) }
            .store(in: &bag)

        // New song starts -> briefly show it.
        media.trackChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.peek() }
            .store(in: &bag)

        // Island width/height depends on these too (artwork pill, number of search rows).
        Publishers.Merge(media.$hasTrack.map { _ in () },
                         search.$results.map { _ in () })
            .receive(on: DispatchQueue.main)       // @Published fires before the value changes
            .sink { [weak self] in self?.refreshSize() }
            .store(in: &bag)
    }

    // MARK: - Size

    func size(for s: NotchState) -> CGSize {
        let n = notch
        let ear = 2 * NotchLayout.ear
        switch s {
        case .collapsed:
            return CGSize(width: n.width + (media.hasTrack ? 100 : 0), height: n.height)
        case .peek:
            return CGSize(width: 330 + ear, height: n.height + 64)
        case .media, .clipboard, .shelf:
            return CGSize(width: 400 + ear, height: n.height + 185)
        case .calculator:
            return CGSize(width: 400 + ear, height: n.height + 200)
        case .locked:
            // With a track: compact player. Without: just the notch pill with a padlock.
            return media.hasTrack
                ? CGSize(width: 340 + ear, height: n.height + 130)
                : CGSize(width: n.width + 100, height: n.height)
        case .search:
            let rows = min(search.results.count, 9)
            return CGSize(width: 480 + ear, height: n.height + 70 + CGFloat(rows) * 40)
        }
    }

    private func refreshSize() {
        let target = size(for: state)
        guard target != contentSize else { return }
        withAnimation(Self.resizeSpring) { contentSize = target }
    }

    /// The only place `state` changes.
    func setState(_ new: NotchState) {
        guard new != state else { return }
        withAnimation(new == .collapsed ? Self.collapseSpring : Self.expandSpring) {
            state = new
            contentSize = size(for: new)
        }
    }

    // MARK: - Hover / peek / drag

    /// Hover expands the island (after a tiny intent delay); leaving collapses it (except while searching).
    func hoverChanged(_ inside: Bool) {
        hoverTask?.cancel()
        if inside {
            guard state == .collapsed || state == .peek else { return }
            peekTask?.cancel()
            let delay = state == .peek ? 0 : 70       // ms: ignores the pointer just sweeping past
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(delay))
                if !Task.isCancelled { setState(AppSettings.shared.defaultPage) }
            }
        } else if state == .media || state == .clipboard || state == .shelf || state == .calculator {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { setState(.collapsed) }
            }
        }
    }

    /// Show the new track for a couple of seconds, then collapse again.
    func peek() {
        guard state == .collapsed else { return }
        setState(.peek)
        peekTask?.cancel()
        peekTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled, state == .peek { setState(.collapsed) }
        }
    }

    /// A file drag entered / left the island.
    func dropTargetChanged(_ targeted: Bool) {
        hoverTask?.cancel()
        if targeted {
            peekTask?.cancel()
            if state != .search, state != .locked, AppSettings.shared.isOn(.tabShelf) { setState(.shelf) }
        } else if state == .shelf {
            // Drag left without a drop (or a drop just finished): collapse only if the pointer is gone.
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, state == .shelf, !pointerInsideIsland else { return }
                setState(.collapsed)
            }
        }
    }

    private var pointerInsideIsland: Bool {
        guard let f = panel?.frame else { return false }
        let island = CGRect(x: f.midX - contentSize.width / 2, y: f.maxY - contentSize.height,
                            width: contentSize.width, height: contentSize.height)
        return island.contains(NSEvent.mouseLocation)
    }

    // MARK: - Clipboard (⌘⇧V)

    /// Open the clipboard tab from the keyboard. Since the pointer isn't on the island,
    /// it closes by itself after a few idle seconds (unless you move onto it).
    func openClipboard() {
        guard state != .locked else { return }
        hoverTask?.cancel()
        peekTask?.cancel()
        setState(.clipboard)
        hoverTask = Task {
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled, state == .clipboard {
                if !pointerInsideIsland { setState(.collapsed); return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Lock screen

    /// True when locked and nothing is playing: drawn like the collapsed notch, plus a padlock.
    var isCompactLock: Bool { state == .locked && !media.hasTrack }

    private func lockChanged(_ locked: Bool) {
        lockTask?.cancel()
        hoverTask?.cancel()
        peekTask?.cancel()

        if locked {
            guard AppSettings.shared.isOn(.lockScreen) else { print("Lock screen island is switched off in the menu"); return }
            query = ""
            lockPhase = .locked
            setState(.locked)
        } else {
            guard state == .locked else { lockPhase = .unlocked; return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { lockPhase = .unlocking }
            lockTask = Task {
                try? await Task.sleep(for: .milliseconds(1100))     // let the open padlock be seen
                guard !Task.isCancelled else { return }
                lockPhase = .unlocked
                setState(.collapsed)
            }
        }
    }

    // MARK: - Search

    func openSearch() {
        guard state != .locked else { return }
        hoverTask?.cancel()
        peekTask?.cancel()
        query = ""
        setState(.search)
    }

    func close() {
        setState(.collapsed)
        query = ""
    }

    /// The highlighted result (defaults to the first one until the user moves).
    var currentSelection: SearchResult? {
        search.results.first { $0.id == selectedID } ?? search.results.first
    }

    func moveSelection(_ delta: Int) {
        let r = search.results
        guard !r.isEmpty else { return }
        let index = r.firstIndex { $0.id == currentSelection?.id } ?? 0
        selectedID = r[max(0, min(r.count - 1, index + delta))].id
    }

    func openSelected() {
        guard let r = currentSelection else { return }
        if let answer = r.answer {                      // calculator: copy the result
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer, forType: .string)
        } else if let url = r.url {
            NSWorkspace.shared.open(url)                // Google search / website
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: r.path))
        }
        close()
    }
}
