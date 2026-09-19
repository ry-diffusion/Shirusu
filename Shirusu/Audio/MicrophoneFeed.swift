import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Live capture from the default input device.
///
/// The engine's own format is handed straight through; the recogniser resamples
/// to 16 kHz internally, and doing it twice would only cost quality.
nonisolated final class MicrophoneFeed: AudioFeed, @unchecked Sendable {
    let duration: TimeInterval? = nil
    let label: String

    /// One engine per input device, reused across presses.
    ///
    /// Not one per press: stopping an engine does not hand the HAL input thread
    /// back synchronously, so the next one started while the previous still
    /// held it, and CoreAudio logged "HALB_IOThread::_Start: there already is a
    /// thread". Taps installed and removed around a standing engine have
    /// nothing to race.
    ///
    /// And not one for the whole process either, which is what this was.
    /// `AVAudioEngine` keeps the input node's client format from the device it
    /// first opened, and pointing the node at a different one does not update
    /// it. Switching from AirPods at 24 kHz to the built-in microphone at
    /// 44.1 kHz left the engine still asking for 24 kHz, and it refused to
    /// start: "Format mismatch: input hw 44100 Hz, client format 24000 Hz",
    /// -10868. So the engine is rebuilt when the device changes, which is rare,
    /// and kept when it does not, which is every press.
    private static var current = AVAudioEngine()
    private static var boundDevice: AudioDeviceID?
    /// Serialises start and teardown, which can arrive from different tasks.
    private static let lock = NSLock()

    /// An engine already pointed at `device`, ready to be tapped.
    ///
    /// Callers hold `lock`.
    private static func engine(for device: InputDevice?) -> AVAudioEngine {
        let wanted = device?.deviceID

        // A previous session that ended abruptly can leave its tap behind.
        current.inputNode.removeTap(onBus: 0)
        if current.isRunning { current.stop() }

        guard wanted != boundDevice else {
            current.reset()
            return current
        }

        // The old one goes before the new one asks the HAL for a thread.
        current = AVAudioEngine()
        boundDevice = wanted
        if let wanted { bind(current, to: wanted, device: device) }
        return current
    }

    /// Points a fresh engine's input at a specific device.
    ///
    /// Before anything reads the format, because which device is open is what
    /// decides the format.
    private static func bind(_ engine: AVAudioEngine, to id: AudioDeviceID, device: InputDevice?) {
        var id = id
        let status = engine.inputNode.withAudioUnit { unit -> OSStatus in
            guard let unit else { return kAudioUnitErr_Uninitialized }
            return AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        guard status != noErr else { return }
        // Not fatal: the engine still has the system default open, and
        // dictating from the wrong microphone beats refusing to dictate.
        Logger(subsystem: "br.com.zesmoi.Shirusu", category: "mic").error(
            """
            Could not switch to \(device?.name ?? "that input", privacy: .public) \
            (\(status, privacy: .public)); staying on the default input
            """)
    }

    /// Which input to open. `nil` means whatever the system calls default.
    private let device: InputDevice?

    private let log = Logger(subsystem: "br.com.zesmoi.Shirusu", category: "mic")

    init(device: InputDevice? = nil) {
        self.device = device
        label = device?.name
            ?? AVCaptureDevice.default(for: .audio)?.localizedName
            ?? String(localized: "Microphone", comment: "Capture source")
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func chunks() -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            Self.lock.lock()
            defer { Self.lock.unlock() }

            let engine = Self.engine(for: device)
            let input = engine.inputNode

            // The tap sits on the node's *output* bus, so it wants the output
            // format. Handing it the hardware input format instead is what makes
            // CoreAudio spew -10877 (kAudioUnitErr_InvalidElement) on start.
            let format = input.outputFormat(forBus: 0)

            guard format.sampleRate > 0, format.channelCount > 0 else {
                continuation.finish(throwing: MicrophoneError.noInputDevice)
                return
            }

            let rate = format.sampleRate
            let counter = FrameCounter()

            do {
                // 100 ms, the shortest buffer the tap API accepts.
                try input.installAudioTap(
                    onBus: 0,
                    bufferSize: AVAudioFrameCount(rate / 10),
                    format: format
                ) { readOnly, _ in
                    let buffer = AVAudioPCMBuffer(copying: readOnly)
                    let position = counter.advance(by: Int(buffer.frameLength)) / rate
                    continuation.yield(
                        AudioChunk(
                            buffer: buffer,
                            peak: AudioChunk.peakMagnitude(of: buffer),
                            position: position
                        )
                    )
                }

                continuation.onTermination = { _ in
                    // Tearing down an audio engine is not quick, and this fires
                    // the instant the consumer stops reading — which is exactly
                    // when the release pass wants to start decoding. Detach it
                    // so the user is not waiting on CoreAudio housekeeping.
                    DispatchQueue.global(qos: .utility).async {
                        Self.lock.lock()
                        defer { Self.lock.unlock() }
                        // `engine` is captured, not read back off the class: by
                        // the time this runs the device may have changed and
                        // the current engine may be a different object, which
                        // this has no business stopping.
                        input.removeTap(onBus: 0)
                        if engine.isRunning { engine.stop() }
                    }
                }

                engine.prepare()
                try engine.start()
                log.info(
                    """
                    \(self.label, privacy: .public) open at \(rate, privacy: .public) Hz, \
                    \(format.channelCount, privacy: .public) ch
                    """)
            } catch {
                input.removeTap(onBus: 0)
                continuation.finish(throwing: error)
            }
        }
    }
}

enum MicrophoneError: LocalizedError {
    case noInputDevice
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return String(
                localized: "No audio input device is available.",
                comment: "Error when the Mac has no usable microphone"
            )
        case .accessDenied:
            return String(
                localized: "Shirusu needs microphone access. Grant it in System Settings, under Privacy & Security.",
                comment: "Error when microphone permission was denied"
            )
        }
    }
}
