import AppKit
import Combine
import CoreAudio

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    /// SF Symbol that matches the kind of device.
    var symbol: String {
        switch transport {
        case UInt32(kAudioDeviceTransportTypeBluetooth), UInt32(kAudioDeviceTransportTypeBluetoothLE):
            return name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones"
        case UInt32(kAudioDeviceTransportTypeHDMI), UInt32(kAudioDeviceTransportTypeDisplayPort):
            return "display"
        case UInt32(kAudioDeviceTransportTypeAirPlay):
            return "airplayaudio"
        case UInt32(kAudioDeviceTransportTypeUSB):
            return "hifispeaker.fill"
        case UInt32(kAudioDeviceTransportTypeBuiltIn):
            if name.localizedCaseInsensitiveContains("headphone") { return "headphones" }
            return name.localizedCaseInsensitiveContains("macbook") ? "laptopcomputer" : "speaker.wave.2.fill"
        case UInt32(kAudioDeviceTransportTypeVirtual), UInt32(kAudioDeviceTransportTypeAggregate):
            return "waveform"
        default:
            return "speaker.wave.2.fill"
        }
    }
}

/// Lists the Mac's sound outputs and switches the default one (what System Settings > Sound > Output does).
/// CoreAudio needs no permission. The list updates by itself when you connect AirPods, plug in a monitor, etc.
@MainActor
final class AudioSwitcher: ObservableObject {
    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var defaultID: AudioDeviceID = 0

    init() {
        refresh()
        listen(kAudioHardwarePropertyDevices)
        listen(kAudioHardwarePropertyDefaultOutputDevice)
    }

    func refresh() {
        let devices = Self.deviceIDs().compactMap { id -> AudioDevice? in
            guard Self.hasOutput(id), Self.uint32(id, kAudioDevicePropertyIsHidden) != 1 else { return nil }
            return AudioDevice(id: id,
                               uid: Self.string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                               name: Self.string(id, kAudioObjectPropertyName) ?? "Unknown",
                               transport: Self.uint32(id, kAudioDevicePropertyTransportType) ?? 0)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let current = Self.uint32(AudioObjectID(kAudioObjectSystemObject),
                                  kAudioHardwarePropertyDefaultOutputDevice) ?? 0
        if devices != outputs { outputs = devices }
        if current != defaultID { defaultID = current }
    }

    func select(_ device: AudioDevice) {
        Self.setDefault(device.id)
        defaultID = device.id            // show it right away; the listener confirms it
        refresh()
    }

    // MARK: - CoreAudio plumbing

    private func listen(_ selector: AudioObjectPropertySelector) {
        var address = Self.address(selector)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// A device is an output if it has at least one output stream.
    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Sets both "output" and "sound effects output", like System Settings does.
    private static func setDefault(_ id: AudioDeviceID) {
        var value = id
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = address(selector)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                       UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        }
    }
}
