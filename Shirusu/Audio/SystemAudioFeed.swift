import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Captures whatever the Mac is playing, rather than what its microphone hears.
///
/// This uses a Core Audio process tap, not ScreenCaptureKit. A tap asks only for
/// "System Audio Recording Only" permission; ScreenCaptureKit would demand
/// Screen Recording, put a capture indicator in the menu bar, and on macOS 26
/// re-prompt for approval periodically — all to record audio it does not need
/// the screen for.
///
/// The shape is: a global tap becomes the input of a private aggregate device,
/// and an IO proc on that device hands us the samples.
nonisolated final class SystemAudioFeed: AudioFeed, @unchecked Sendable {
    let duration: TimeInterval? = nil
    let label = String(
        localized: "System audio", comment: "Capture source")

    private let log = Logger(subsystem: "br.com.zesmoi.Shirusu", category: "systemaudio")

    func chunks() -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream<AudioChunk, Error> { continuation in
            let session: TapSession
            do {
                session = try TapSession()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let counter = FrameCounter()
            let rate = session.format.sampleRate

            do {
                try session.start { buffer in
                    let position = counter.advance(by: Int(buffer.frameLength)) / rate
                    continuation.yield(
                        AudioChunk(
                            buffer: buffer,
                            peak: AudioChunk.peakMagnitude(of: buffer),
                            position: position
                        ))
                }
            } catch {
                session.tearDown()
                continuation.finish(throwing: error)
                return
            }

            log.info("System audio tap started at \(rate, privacy: .public) Hz")
            continuation.onTermination = { _ in
                // Same reasoning as the microphone: tearing down audio hardware
                // is slow and the release pass must not wait for it.
                DispatchQueue.global(qos: .utility).async { session.tearDown() }
            }
        }
    }
}

/// Owns the tap, the aggregate device around it, and the IO proc that drains it.
private nonisolated final class TapSession: @unchecked Sendable {
    let format: AVAudioFormat

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "br.com.zesmoi.Shirusu.systemaudio")

    init() throws {
        var tap = AudioObjectID(kAudioObjectUnknown)
        var device = AudioObjectID(kAudioObjectUnknown)
        var isBuilt = false

        // Nothing else would ever give these back. `format` is assigned last,
        // so a throw before it leaves the object partly initialised — and Swift
        // does not run `deinit` on one of those. The tap and the aggregate
        // device would have outlived the app's knowledge of them, sitting in
        // coreaudiod until the process ended.
        defer {
            if !isBuilt {
                if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
                if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
            }
        }

        // A global tap: every process, mixed to mono, and not muted — the user
        // still hears what they are playing.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Shirusu System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isMono = true
        description.isMixdown = true

        try SystemAudioError.check(
            AudioHardwareCreateProcessTap(description, &tap), "creating the tap")
        tapID = tap

        // The tap only becomes readable once it is the input of a device.
        let uid = try Self.string(from: tap, selector: kAudioTapPropertyUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Shirusu System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid]],
        ]
        try SystemAudioError.check(
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device),
            "creating the aggregate device")
        deviceID = device

        var asbd = try Self.streamDescription(from: tap)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioError.unusableFormat
        }
        self.format = format
        isBuilt = true
    }

    /// The backstop for a session that is dropped without anyone saying so.
    /// `tearDown` is idempotent, so the ordinary path calling it first costs
    /// nothing here.
    deinit { tearDown() }

    func start(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let format = self.format
        var proc: AudioDeviceIOProcID?
        try SystemAudioError.check(
            AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, queue) {
                _, inputData, _, _, _ in
                guard let buffer = Self.copy(inputData, into: format) else { return }
                onBuffer(buffer)
            }, "installing the IO proc")
        procID = proc

        // This is where the system asks the user for permission; a refusal
        // surfaces here rather than as silence.
        try SystemAudioError.check(AudioDeviceStart(deviceID, proc), "starting capture")
    }

    func tearDown() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// The callback's buffers are only valid for its duration, so this copies.
    private static func copy(
        _ list: UnsafePointer<AudioBufferList>, into format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return nil }

        let frames = AVAudioFrameCount(
            first.mDataByteSize / UInt32(MemoryLayout<Float>.size)
                / max(first.mNumberChannels, 1))
        guard frames > 0,
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        out.frameLength = frames

        if let destination = out.floatChannelData {
            for channel in 0..<min(buffers.count, Int(format.channelCount)) {
                guard let source = buffers[channel].mData else { continue }
                destination[channel].update(
                    from: source.assumingMemoryBound(to: Float.self), count: Int(frames))
            }
        }
        return out
    }

    private static func address(_ selector: AudioObjectPropertySelector)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(from object: AudioObjectID, selector: AudioObjectPropertySelector)
        throws -> String
    {
        var property = address(selector)
        // Core Audio hands back a +1 CFString here, so it is taken as retained.
        // Writing into a managed `CFString` variable through a raw pointer,
        // which is what this used to do, overwrites a reference ARC is still
        // accounting for and hands ownership of the new one to nobody.
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value)
        try SystemAudioError.check(status, "reading the tap identifier")
        guard let text = value?.takeRetainedValue() as String? else {
            throw SystemAudioError.failed(
                stage: "reading the tap identifier", status: kAudioHardwareUnspecifiedError)
        }
        return text
    }

    private static func streamDescription(from tap: AudioObjectID) throws
        -> AudioStreamBasicDescription
    {
        var property = address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        let status = withUnsafeMutablePointer(to: &asbd) {
            AudioObjectGetPropertyData(tap, &property, 0, nil, &size, $0)
        }
        try SystemAudioError.check(status, "reading the tap format")
        return asbd
    }
}

nonisolated enum SystemAudioError: LocalizedError {
    case failed(stage: String, status: OSStatus)
    case unusableFormat

    static func check(_ status: OSStatus, _ stage: String) throws {
        guard status != noErr else { return }
        throw SystemAudioError.failed(stage: stage, status: status)
    }

    var errorDescription: String? {
        switch self {
        case .unusableFormat:
            return String(
                localized: "The system audio tap reported a format Shirusu cannot read.",
                comment: "Error when the system audio stream format is unusable")
        case .failed(let stage, let status):
            // -4 is the code the HAL returns when the user has not granted
            // system audio recording, which is the failure worth explaining.
            if status == kAudioHardwareIllegalOperationError || status == -4 {
                return String(
                    localized: "Shirusu needs permission to record system audio. Grant it in System Settings, under Privacy & Security.",
                    comment: "Error when system audio recording permission is missing")
            }
            return String(
                localized: "System audio capture failed while \(stage) (error \(Int(status))).",
                comment: "Generic Core Audio tap failure")
        }
    }
}
