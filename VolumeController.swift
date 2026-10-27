import AppKit
import Combine

/// System output volume (0–100) via AppleScript. No Automation permission prompt is needed
/// because it only uses the standard "volume settings" commands.
@MainActor
final class VolumeController: ObservableObject {
    @Published var level: Double = 50
    var dragging = false
    private var lastSent = -1
    private let readScript = NSAppleScript(source: "output volume of (get volume settings)")   // compiled once

    func refresh() {
        guard !dragging else { return }
        var error: NSDictionary?
        guard let d = readScript?.executeAndReturnError(&error), error == nil,
              d.stringValue != "missing value" else { return }
        let v = Double(d.int32Value)
        if v != level { level = v }
    }

    func set(_ value: Double) {
        level = value
        let v = Int(value.rounded())
        guard v != lastSent else { return }      // avoid spamming AppleScript while dragging
        lastSent = v
        var error: NSDictionary?
        NSAppleScript(source: "set volume output volume \(v)")?.executeAndReturnError(&error)
    }
}
