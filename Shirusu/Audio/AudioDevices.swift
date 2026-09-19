import AppKit
import CoreAudio
import Foundation
import Observation
import OSLog

/// One audio input the Mac can hear through.
struct InputDevice: Identifiable, Hashable, Sendable {
    /// The UID, not the numeric id: device ids are reassigned across reboots
    /// and reconnections, so a remembered choice has to be stored by UID or it
    /// silently points at a different microphone next week.
    var id: String
    var deviceID: AudioDeviceID
    var name: String
    var transport: UInt32

    /// What the device looks like, so the list can be read at a glance rather
    /// than parsed. A row of identical microphone glyphs is a list of strings.
    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            // Apple ships a glyph per model and they are instantly recognisable,
            // which is the whole reason to bother matching on the name.
            let lowered = name.lowercased()
            if lowered.contains("airpods max") { return "airpods.max" }
            if lowered.contains("airpods pro") { return "airpods.pro" }
            if lowered.contains("airpods") { return "airpods" }
            if lowered.contains("beats") { return "beats.headphones" }
            return "headphones"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
            kAudioDeviceTransportTypeContinuityCaptureWireless:
            // An iPhone being used as the Mac's microphone. Showing it as a
            // generic mic hides the one thing worth knowing about it.
            return name.lowercased().contains("ipad") ? "ipad" : "iphone"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            return "cable.connector"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform"
        default:
            // Built-in included: it is the Mac's own microphone, and the plain
            // glyph is the honest one on a laptop and a desktop alike.
            return "mic.fill"
        }
    }
}

/// The input devices currently attached, kept current.
///
/// Core Audio is asked again whenever the device list changes rather than only
/// when a screen appears: connecting AirPods while the window is open and not
/// finding them in the list is exactly the moment a picker feels broken.
@MainActor
@Observable
final class AudioInputs {
    private(set) var devices: [InputDevice] = []
    private(set) var defaultDeviceID: AudioDeviceID = 0

    @ObservationIgnored private var listening = false
    @ObservationIgnored private let log = Logger(
        subsystem: "br.com.zesmoi.Shirusu", category: "devices")

    init() {
        refresh()
        listen()
    }

    /// The device to actually open, given what the user picked.
    ///
    /// A remembered choice that is no longer plugged in falls back to the
    /// system default rather than failing: the user asked to dictate, not to
    /// be told about a microphone they already know they unplugged.
    func resolve(_ uid: String?) -> InputDevice? {
        if let uid, let match = devices.first(where: { $0.id == uid }) { return match }
        return devices.first { $0.deviceID == defaultDeviceID } ?? devices.first
    }

    func refresh() {
        devices = Self.inputDevices()
        defaultDeviceID = Self.defaultInput()
    }

    private func listen() {
        guard !listening else { return }
        listening = true
        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
            ) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            if status != noErr {
                log.error("Could not watch device changes (\(status, privacy: .public))")
            }
        }
    }

    // MARK: - Core Audio

    private static func defaultInput() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            // Every output device is in the same list, so the input channel
            // count is what separates a microphone from a pair of speakers.
            guard inputChannels(of: id) > 0 else { return nil }
            guard let uid: String = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            return InputDevice(id: uid, deviceID: id, name: name, transport: transport(of: id))
        }
    }

    private static func inputChannels(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else {
            return 0
        }

        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transport(of device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector)
        -> String?
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Core Audio hands back a +1 CFString here, so it is taken as retained.
        // Reading straight into a `CFString` variable would have the compiler
        // form a raw pointer to a managed reference, which is not the same thing.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
            let text = value?.takeRetainedValue() as String?
        else { return nil }
        return text.isEmpty ? nil : text
    }
}
