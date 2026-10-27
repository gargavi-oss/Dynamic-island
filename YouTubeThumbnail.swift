import AppKit

/// Browsers often don't hand the video's picture to the system Now Playing data.
/// For YouTube we find the playing tab (by matching its title), read its URL,
/// and download the thumbnail directly from YouTube's image server.
/// Works with Safari and Chromium browsers (Chrome, Brave, Edge, Arc, Vivaldi, Opera).
enum YouTubeThumbnail {
    private static let chromium = ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
                                   "com.microsoft.edgemac", "company.thebrowser.Browser",
                                   "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]

    static func image(browser bundleID: String, title: String) async -> NSImage? {
        guard let tabs = await tabs(of: bundleID) else { return nil }
        let needle = title.lowercased()
        for (tabTitle, url) in tabs where tabTitle.lowercased().contains(needle) {
            if let id = videoID(from: url), let image = await download(id) { return image }
        }
        return nil
    }

    // MARK: - Browser tabs (AppleScript; macOS asks for permission once per browser)

    private static func tabs(of bundleID: String) async -> [(String, String)]? {
        let isSafari = bundleID.hasPrefix("com.apple.Safari")
        let chromiumID = chromium.first { bundleID == $0 } ?? chromium.first { bundleID.hasPrefix($0 + ".") }
        guard isSafari || chromiumID != nil else { return nil }

        let appID = isSafari ? "com.apple.Safari" : chromiumID!
        let titleProperty = isSafari ? "name" : "title"
        let script = """
        tell application id "\(appID)"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (\(titleProperty) of t) & tab & (URL of t) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """

        // Run as a separate `osascript` process: NSAppleScript is not thread-safe, and the volume
        // slider already uses it on the main thread every second. Two threads inside the
        // AppleScript engine at once is a classic intermittent crash.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { continuation.resume(returning: nil); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }
                let pairs = text.split(separator: "\n").compactMap { line -> (String, String)? in
                    let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
                }
                continuation.resume(returning: pairs)
            }
        }
    }

    // MARK: - YouTube

    private static func videoID(from string: String) -> String? {
        guard let url = URL(string: string), let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("youtu.be") { return url.pathComponents.dropFirst().first }
        guard host.hasSuffix("youtube.com") else { return nil }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value { return v }
        let parts = url.pathComponents                       // ["/", "shorts", "<id>"]
        if parts.count >= 3, parts[1] == "shorts" { return parts[2] }
        return nil
    }

    private static func download(_ id: String) async -> NSImage? {
        for name in ["maxresdefault", "hqdefault"] {         // maxres 404s for some videos
            guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(name).jpg") else { continue }
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }
}
