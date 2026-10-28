import AppKit
import Combine
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var canConvert: Bool { ImageConverter.canConvert(url) }
    var format: ImageFormat? { ImageFormat(url: url) }
}

/// Temporary file shelf: drop files on the notch, drag them out somewhere else.
/// Stores references to the files only (nothing is copied) and lives in memory.
/// Photos and PDFs can be converted offline; the result lands on the shelf as a new item.
@MainActor
final class FileShelf: ObservableObject {
    @Published var items: [ShelfItem] = []
    @Published var selectedID: UUID?
    @Published private(set) var converting = false
    @Published private(set) var message: String?          // short status / error under the tiles

    private var messageTask: Task<Void, Never>?

    /// The item the convert buttons act on: the selected one, else the first convertible one.
    var selectedItem: ShelfItem? {
        items.first { $0.id == selectedID && $0.canConvert } ?? items.first { $0.canConvert }
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.insert(ShelfItem(url: url), at: 0)
        }
    }

    func remove(_ item: ShelfItem) { items.removeAll { $0.id == item.id } }
    func clear() { items.removeAll() }

    func convert(_ item: ShelfItem, to format: ImageFormat) {
        guard !converting else { return }
        let source = item.url
        converting = true
        flash("Converting \(item.name)…", for: nil)
        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try ImageConverter.convert(source, to: format)
                }.value
                add([output])
                flash("Saved as \(output.lastPathComponent). Drag it out.", for: 4)
            } catch {
                flash(error.localizedDescription, for: 4)
            }
            converting = false
        }
    }

    private func flash(_ text: String, for seconds: Double?) {
        messageTask?.cancel()
        message = text
        guard let seconds else { return }
        messageTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { message = nil }
        }
    }

    /// Called from `.onDrop`. Returns true if at least one file was accepted.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.add([url]) }
                }
            } else if let type = provider.registeredTypeIdentifiers
                .compactMap({ UTType($0) }).first(where: { $0.conforms(to: .image) || $0.conforms(to: .pdf) }) {
                // A picture dragged out of Photos / a browser / Preview arrives as data, not as a file:
                // save it to a temp file so it can sit on the shelf and be converted.
                accepted = true
                let name = provider.suggestedName ?? "Image"
                let ext = type.preferredFilenameExtension ?? "png"
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data else { return }
                    let folder = ImageConverter.outputRoot
                        .appendingPathComponent("Dropped", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let file = folder.appendingPathComponent(name).appendingPathExtension(ext)
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try data.write(to: file)
                    } catch { return }
                    Task { @MainActor in self.add([file]) }
                }
            }
        }
        return accepted
    }
}
