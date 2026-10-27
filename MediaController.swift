import SwiftUI
import AppKit
import Combine

enum Player: String {
    case music = "Music"
    case spotify = "Spotify"
    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
}

/// Repeat modes use the same ids as MediaRemote / `media-control repeat`.
enum RepeatMode: Int {
    case off = 1, track = 2, playlist = 3

    /// off -> playlist -> track -> off
    var next: RepeatMode {
        switch self {
        case .off: return .playlist
        case .playlist: return .track
        case .track: return .off
        }
    }
}

/// Now Playing for ANY app (YouTube in Chrome/Safari/Arc, Spotify, Music, VLC...).
/// Primary source: the `media-control` CLI (`brew install media-control`).
/// Fallback (CLI not installed): Apple Music + Spotify only.
@MainActor
final class MediaController: ObservableObject {
    @Published var title = "Not Playing"
    @Published var artist = ""
    @Published var artwork: NSImage?
    @Published var isPlaying = false
    @Published var hasTrack = false          // true while something is loaded (playing OR paused)
    @Published var duration: Double = 0      // seconds, 0 if unknown (e.g. live streams)
    @Published var shuffleOn = false
    @Published var repeatMode: RepeatMode = .off

    /// Fires when a new track starts playing (used for the "peek").
    let trackChanged = PassthroughSubject<Void, Never>()

    private var elapsedBase: Double = 0
    private var baseDate = Date()
    private var rate: Double = 1

    private let binary: String?
    private var process: Process?
    private var buffer = Data()
    private var lastTrackKey = ""
    private var fallbackPlayer: Player = .music
    private var terminating = false
    private var restartDelay: Double = 1

    init() {
        binary = ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }

        if binary != nil { startStream() } else { startFallback() }
    }

    private func shutdown() {
        terminating = true
        process?.terminate()
    }

    /// Current playback position, extrapolated between updates.
    func elapsed(at date: Date) -> Double {
        guard hasTrack else { return 0 }
        let e = isPlaying ? elapsedBase + date.timeIntervalSince(baseDate) * (rate > 0 ? rate : 1) : elapsedBase
        return duration > 0 ? min(max(e, 0), duration) : max(e, 0)
    }

    // MARK: - Controls

    func togglePlayPause() { control("toggle-play-pause", script: "playpause") }
    func next()            { control("next-track", script: "next track") }
    func previous()        { control("previous-track", script: "previous track") }

    /// Jump to a position (seconds) in the current track. Needs the `media-control` CLI and a known duration.
    func seek(to seconds: Double) {
        guard hasTrack, duration > 0 else { return }
        let target = min(max(seconds, 0), duration)

        // Update the local timeline right away so the bar doesn't snap back
        // while we wait for the stream to report the new position.
        elapsedBase = target
        baseDate = Date()

        _ = runCLI(["seek", String(format: "%.3f", target)])
    }

    func toggleShuffle() {
        shuffleOn.toggle()
        if binary != nil {
            _ = runCLI(["shuffle", shuffleOn ? "3" : "1"])     // 1 = off, 3 = shuffle tracks
        } else if fallbackPlayer.isRunning {
            switch fallbackPlayer {
            case .music:   run("tell application \"Music\" to set shuffle enabled to \(shuffleOn)")
            case .spotify: run("tell application \"Spotify\" to set shuffling to \(shuffleOn)")
            }
        }
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        if binary != nil {
            _ = runCLI(["repeat", String(repeatMode.rawValue)])
        } else if fallbackPlayer.isRunning {
            switch fallbackPlayer {
            case .music:
                let value = repeatMode == .off ? "off" : (repeatMode == .track ? "one" : "all")
                run("tell application \"Music\" to set song repeat to \(value)")
            case .spotify:
                run("tell application \"Spotify\" to set repeating to \(repeatMode != .off)")
            }
        }
    }

    private func control(_ cli: String, script: String) {
        if binary != nil {
            _ = runCLI([cli])
        } else if fallbackPlayer.isRunning {
            run("tell application \"\(fallbackPlayer.rawValue)\" to \(script)")
        }
    }

    @discardableResult
    private func runCLI(_ args: [String]) -> Bool {
        guard let binary else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); return true } catch { return false }
    }

    // MARK: - System-wide stream (media-control)

    private func startStream() {
        guard let binary, !terminating else { return }
        buffer = Data()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["stream", "--no-diff"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF: the process died. Without clearing the handler it fires nonstop (100% CPU).
                handle.readabilityHandler = nil
                Task { @MainActor in self?.streamEnded() }
                return
            }
            Task { @MainActor in self?.consume(data) }
        }

        do {
            try p.run()
            process = p
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            scheduleRestart()
        }
    }

    private func streamEnded() {
        process = nil
        resetToNotPlaying()
        scheduleRestart()
    }

    /// Restart the stream with backoff (1s, 2s, 4s ... max 30s) so a crashing CLI can't spin.
    private func scheduleRestart() {
        guard !terminating else { return }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.startStream()
        }
    }

    private func resetToNotPlaying() {
        hasTrack = false; isPlaying = false; duration = 0
        title = "Not Playing"; artist = ""; artwork = nil; lastTrackKey = ""
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handleLine(line)
        }
    }

    private func handleLine(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return }
        restartDelay = 1     // the stream is healthy

        guard let t = payload["title"] as? String, !t.isEmpty else {
            resetToNotPlaying()
            return
        }
        let a = payload["artist"] as? String ?? ""
        let bundle = payload["bundleIdentifier"] as? String ?? ""

        hasTrack = true
        isPlaying = payload["playing"] as? Bool ?? false
        title = t
        artist = a

        // Timeline for the progress bar
        duration = number(payload["duration"]) ?? 0
        elapsedBase = number(payload["elapsedTime"]) ?? 0
        baseDate = date(payload["timestamp"]) ?? Date()
        rate = number(payload["playbackRate"]) ?? 1

        // Shuffle / repeat state, when the player reports it (ids: 1 = off, 2/3 = on).
        if let m = number(payload["shuffleMode"]) { shuffleOn = m > 1 }
        if let m = number(payload["repeatMode"]) { repeatMode = RepeatMode(rawValue: Int(m)) ?? .off }

        // Artwork
        let key = "\(bundle)|\(t)|\(a)"
        if key != lastTrackKey {
            lastTrackKey = key
            artwork = nil
            if isPlaying { trackChanged.send() }
            fetchArtworkLater(for: key,
                              appID: (payload["parentApplicationBundleIdentifier"] as? String) ?? bundle,
                              title: t)
        }
        if artwork == nil, let b64 = payload["artworkData"] as? String,
           let d = Data(base64Encoded: b64) {
            artwork = NSImage(data: d)
        }
    }

    /// Artwork often arrives after the title. If the stream never delivers it:
    /// 1) ask `media-control get`, 2) for YouTube in a browser, grab the video thumbnail.
    private func fetchArtworkLater(for key: String, appID: String, title: String) {
        Task {
            for delay in [1.0, 2.5, 5.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard lastTrackKey == key, artwork == nil else { return }

                if let binary {
                    let data = await Self.capture(binary, ["get"])
                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let b64 = obj["artworkData"] as? String,
                       let d = Data(base64Encoded: b64), lastTrackKey == key {
                        artwork = NSImage(data: d)
                        return
                    }
                }
                guard lastTrackKey == key, artwork == nil else { return }
                if let image = await YouTubeThumbnail.image(browser: appID, title: title),
                   lastTrackKey == key {
                    artwork = image
                    return
                }
            }
        }
    }

    nonisolated private static func capture(_ path: String, _ args: [String]) async -> Data {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                try? p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: data)
            }
        }
    }

    private func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    private func date(_ v: Any?) -> Date? {
        if let s = v as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
        if let n = v as? NSNumber {
            let x = n.doubleValue
            return Date(timeIntervalSince1970: x > 1e14 ? x / 1e6 : (x > 1e11 ? x / 1e3 : x))
        }
        return nil
    }

    // MARK: - Fallback: Apple Music + Spotify only

    private func startFallback() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"),
                           object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleFallback(note.userInfo, player: .music) }
        }
        center.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
                           object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleFallback(note.userInfo, player: .spotify) }
        }
    }

    private func handleFallback(_ info: [AnyHashable: Any]?, player: Player) {
        guard let info else { return }
        let state = info["Player State"] as? String ?? ""
        fallbackPlayer = player
        isPlaying = (state == "Playing")
        if state == "Stopped" {
            hasTrack = false; title = "Not Playing"; artist = ""; artwork = nil; duration = 0
            return
        }
        hasTrack = true
        let newTitle = info["Name"] as? String ?? title
        let newArtist = info["Artist"] as? String ?? ""
        let changed = (newTitle != title || newArtist != artist)
        title = newTitle
        artist = newArtist
        if changed && isPlaying { trackChanged.send() }
        guard player.isRunning else { return }
        switch player {
        case .spotify:
            if let s = run("tell application \"Spotify\" to get artwork url of current track")?.stringValue,
               let url = URL(string: s) {
                Task { if let (d, _) = try? await URLSession.shared.data(from: url) { artwork = NSImage(data: d) } }
            }
        case .music:
            if let d = run("tell application \"Music\" to get data of artwork 1 of current track")?.data {
                artwork = NSImage(data: d)
            }
        }
    }

    @discardableResult
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}
