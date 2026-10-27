import AppKit
import Combine
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
}

/// Temporary file shelf: drop files on the notch, drag them out somewhere else.
/// Stores references to the files only (nothing is copied) and lives in memory.
@MainActor
final class FileShelf: ObservableObject {
    @Published var items: [ShelfItem] = []

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.insert(ShelfItem(url: url), at: 0)
        }
    }

    func remove(_ item: ShelfItem) { items.removeAll { $0.id == item.id } }
    func clear() { items.removeAll() }

    /// Called from `.onDrop`. Returns true if at least one file was accepted.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in self.add([url]) }
            }
        }
        return accepted
    }
}
