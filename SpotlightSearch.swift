import Foundation
import Combine

struct SearchResult: Identifiable {
    let id: String          // file path, or "web:..." for web rows
    let name: String
    let path: String
    var answer: String? = nil   // calculator rows: the value to copy
    var url: URL? = nil     // set for web rows (Google search / open website)

    var isWeb: Bool { url != nil }
    var subtitle: String {
        if answer != nil { return "Copy result" }
        if isWeb { return url?.host ?? "Web" }
        return path.hasSuffix(".app") ? "Application" : folder
    }
    var folder: String {
        if let url { return url.host ?? "" }
        return (URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

/// Fast launcher search:
///  - Apps: matched instantly from an in-memory index built at launch.
///  - Files: Spotlight index (home folder), prefix match, debounced so typing stays smooth.
@MainActor
final class SpotlightSearch: ObservableObject {
    @Published var results: [SearchResult] = []

    private var appIndex: [SearchResult] = []
    private var apps: [SearchResult] = []
    private var files: [SearchResult] = []
    private var text = ""

    private let query = NSMetadataQuery()
    private var debounce: Task<Void, Never>?

    init() {
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.notificationBatchingInterval = 0.1
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collectFiles() }
            }
        }
        buildAppIndex()
    }

    // MARK: - Public

    func search(_ raw: String) {
        debounce?.cancel()
        query.stop()
        files = []
        text = raw.filter { $0 != "*" && $0 != "?" }.trimmingCharacters(in: .whitespaces)

        guard !text.isEmpty else { apps = []; publish(); return }

        // 1) Apps: instant, no Spotlight involved.
        let q = text.lowercased()
        apps = appIndex
            .filter { $0.name.lowercased().contains(q) }
            .sorted { a, b in
                let ap = a.name.lowercased().hasPrefix(q), bp = b.name.lowercased().hasPrefix(q)
                return ap != bp ? ap : a.name.count < b.name.count
            }
        publish()

        // 2) Files: only after the user pauses typing for a moment.
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            // Prefix match on the display name is what Spotlight's index answers quickly.
            query.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemDisplayNameKey, text + "*")
            query.start()
        }
    }

    // MARK: - Internals

    private func collectFiles() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var found: [SearchResult] = []
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if path.contains("/Library/") || path.contains(".app/") || path.contains("/.") { continue }
            let name = item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String
                ?? URL(fileURLWithPath: path).lastPathComponent
            found.append(SearchResult(id: path, name: name, path: path))
            if found.count >= 10 { break }
        }
        files = found
        publish()
    }

    private func publish() {
        var seen = Set<String>()
        var out = Array((apps.prefix(5) + files).filter { seen.insert($0.id).inserted }.prefix(6))
        if !text.isEmpty {
            if let site = websiteURL() {            // "github.com" -> offer to open it, first
                out.insert(SearchResult(id: "web:open", name: "Open \(text)", path: "", url: site), at: 0)
            }
            if let answer = Calculator.evaluate(text) {   // "12*7.5" -> offer the result, first
                out.insert(SearchResult(id: "calc", name: "= \(answer)", path: "", answer: answer), at: 0)
            }
            if let google = googleURL() {
                out.append(SearchResult(id: "web:google", name: "Search Google for “\(text)”", path: "", url: google))
            }
        }
        results = out
    }

    private func googleURL() -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")
        c?.queryItems = [URLQueryItem(name: "q", value: text)]
        return c?.url
    }

    /// Returns a URL when the text looks like a web address (no spaces, ends in a domain).
    private func websiteURL() -> URL? {
        guard !text.contains(" "),
              text.range(of: #"^(https?://)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(/\S*)?$"#,
                         options: .regularExpression) != nil else { return nil }
        return URL(string: text.hasPrefix("http") ? text : "https://" + text)
    }

    private func buildAppIndex() {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", "\(NSHomeDirectory())/Applications"]
        var found: [SearchResult] = []

        func scan(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for n in names where !n.hasPrefix(".") {
                let path = dir + "/" + n
                if n.hasSuffix(".app") {
                    found.append(SearchResult(id: path, name: String(n.dropLast(4)), path: path))
                } else if depth > 0 {
                    scan(path, depth: depth - 1)   // e.g. /Applications/Utilities
                }
            }
        }
        roots.forEach { scan($0, depth: 1) }
        appIndex = found
    }
}
