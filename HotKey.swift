import Carbon.HIToolbox

// Carbon hot keys need NO permissions (unlike NSEvent global monitors) and they
// swallow the keypress, so the shortcut works from any app.
// Several hot keys share one event handler; each has its own numeric id.

nonisolated(unsafe) private var hotKeyActions: [UInt32: () -> Void] = [:]
nonisolated(unsafe) private var handlerInstalled = false

private nonisolated func hotKeyCallback(_ next: EventHandlerCallRef?,
                                        _ event: EventRef?,
                                        _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    DispatchQueue.main.async { hotKeyActions[id]?() }
    return noErr
}

private func installHandlerOnce() {
    guard !handlerInstalled else { return }
    handlerInstalled = true
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                             eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, nil)
}

final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    /// false when another app already owns this shortcut (error -9878).
    private(set) var isRegistered = false

    /// - Parameters:
    ///   - id: any number that is unique per hot key
    ///   - keyCode: e.g. `kVK_Space`, `kVK_ANSI_V`
    ///   - modifiers: Carbon flags, e.g. `cmdKey | shiftKey`
    init(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.id = id
        installHandlerOnce()
        hotKeyActions[id] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E544348), id: id)   // 'NTCH'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        isRegistered = (status == noErr)
        if !isRegistered { print("Hotkey \(id) registration failed: \(status)  (-9878 = already used by another app)") }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        hotKeyActions[id] = nil
    }
}
