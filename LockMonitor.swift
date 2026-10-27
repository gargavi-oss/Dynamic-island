import AppKit
import Combine

/// Tells the app when the screen is locked / unlocked.
/// macOS posts these distributed notifications (no permission needed).
@MainActor
final class LockMonitor {
    /// true = just locked, false = just unlocked.
    let events = PassthroughSubject<Bool, Never>()
    private(set) var isLocked = false

    init() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(true) }
        }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(false) }
        }
    }

    private func set(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        print("LockMonitor: screen \(locked ? "locked" : "unlocked")")
        events.send(locked)
    }
}
