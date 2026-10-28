import Foundation

/// Asks GitHub whether a newer release exists. Nothing is downloaded or installed:
/// if there is one, the app offers to open the release page in the browser.
///
/// SETUP: set `repo` to "your-github-name/your-repo", publish releases tagged like v1.2.0,
/// and keep CFBundleShortVersionString (Marketing Version) in the app in step with those tags.
/// (If the app is sandboxed, enable "Outgoing Connections (Client)".)
enum UpdateChecker {
    static let repo = "https://github.com/gargavi-oss/Dynamic-island.git"

    enum Outcome {
        case upToDate
        case available(version: String, page: URL)
        case failed(String)
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }

    private static let lastCheckKey = "lastUpdateCheck"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Automatic checks run at most once a day.
    static var isDue: Bool {
        guard let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(last) > 24 * 3600
    }

    static func markChecked() {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
    }

    static func check() async -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .failed("The update address is invalid.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return .failed("No releases found for \(repo) yet.") }
            guard status == 200 else { return .failed("GitHub answered with status \(status).") }

            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            if latest.compare(currentVersion, options: .numeric) == .orderedDescending,
               let page = URL(string: release.html_url) {
                return .available(version: latest, page: page)
            }
            return .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
