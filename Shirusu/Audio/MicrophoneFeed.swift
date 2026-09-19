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

    /// One engine for the whole process.
    ///
    /// Each press of Dictate used to build its own `AVAudioEngine`. Stopping an
    /// engine does not hand the HAL input thread back synchronously, so the next
    /// one started while the previous still held it — which is CoreAudio logging
    /// "HALB_IOThread::_Start: there already is a thread". One engine, taps
    /// installed and removed around it, has nothing to race.
    private static let engine = AVAudioEngine()
    /// Serialises start and teardown, which can arrive from different tasks.
    private static let lock = NSLock()

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

            let engine = Self.engine
            let input = engine.inputNode

            // A previous session that ended abruptly can leave its tap behind.
            input.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            engine.reset()

            // Before the format is read, because pointing the node at another
            // device is what decides the format. The engine has to be stopped
            // for this, which it is: the reset above just saw to that.
            if let device {
                var id = device.deviceID
                let status = input.withAudioUnit { unit -> OSStatus in
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
                if status != noErr {
                    // Not fatal: the engine still has the system default open,
                    // and captioning from the wrong microphone beats refusing
                    // to caption at all.
                    log.error(
                        """
                        Could not switch to \(device.name, privacy: .public) \
                        (\(status, privacy: .public)); staying on the default input
                        """)
                }
            }

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
                        input.removeTap(onBus: 0)
                        if engine.isRunning { engine.stop() }
                    }
                }

                engine.prepare()
                try engine.start()
                log.info("Microphone engine started at \(rate, privacy: .public) Hz")
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
