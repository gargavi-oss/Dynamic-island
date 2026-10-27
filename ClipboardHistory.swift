import AppKit
import Combine

struct ClipItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
}

/// Text clipboard history (in memory only: nothing is written to disk).
/// Skips items that password managers mark as concealed/transient.
@MainActor
final class ClipboardHistory: ObservableObject {
    @Published var items: [ClipItem] = []

    private let maxItems = 40
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard AppSettings.shared.isOn(.tabClipboard) else { return }   // paused while the tab is hidden

        let types = pb.types?.map(\.rawValue) ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return }

        guard let text = pb.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        items.removeAll { $0.text == text }
        items.insert(ClipItem(text: text, date: Date()), at: 0)
        if items.count > maxItems { items.removeLast(items.count - maxItems) }
    }

    /// Put an item back on the clipboard (and move it to the top).
    func copy(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text, forType: .string)
        lastChangeCount = pb.changeCount
        items.removeAll { $0.id == item.id }
        items.insert(ClipItem(text: item.text, date: Date()), at: 0)
    }

    func remove(_ item: ClipItem) { items.removeAll { $0.id == item.id } }
    func clear() { items.removeAll() }
}
