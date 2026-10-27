import ServiceManagement

/// Start the app automatically when you log in (works once it is a real, signed .app).
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            print("Launch at login failed: \(error)")
        }
    }
}
