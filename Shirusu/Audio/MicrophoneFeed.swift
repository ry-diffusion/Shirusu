import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Live capture from a chosen input device.
///
/// Whatever format that device runs at is handed straight through; the
/// recogniser resamples to 16 kHz internally, and doing it twice would only
/// cost quality.
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
    /// And not one for the whole process either, which is what this was: an
    /// engine carries the device it was bound to, so changing device means a
    /// new one. That alone was not enough to fix -10868, though. See `bind`.
    private nonisolated(unsafe) static var current = AVAudioEngine()
    private nonisolated(unsafe) static var boundDevice: AudioDeviceID?
    /// The format negotiated for `boundDevice`, which the tap has to match.
    private nonisolated(unsafe) static var boundFormat: AVAudioFormat?
    /// Serialises start and teardown, which can arrive from different tasks.
    private static let lock = NSLock()

    /// Which stream currently owns the one engine and the one tap.
    ///
    /// There is only ever one of each, so a second `chunks()` takes the first
    /// one's tap away — and used to take it away in silence. The reader
    /// downstream then waited for a chunk that could no longer arrive: a
    /// release that never finished, and a Globe key dead until the
    /// sixty-second watchdog let go of it. Holding the Globe key while a voice
    /// was being recorded did exactly this.
    ///
    /// Now a stream that is no longer the owner is *finished* instead, so its
    /// reader ends on whatever it managed to hear, and only the owner is
    /// allowed to tear the engine down.
    private nonisolated(unsafe) static var owner = 0
    private nonisolated(unsafe) static var active: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    /// Watches the engine the owner is reading, so a device that disappears
    /// mid-capture ends the stream rather than starving it.
    private nonisolated(unsafe) static var configurationWatch: NSObjectProtocol?

    /// Takes the microphone from whoever holds it. Callers hold `lock`.
    private static func takeOwnership() {
        stopWatching()
        let outgoing = active
        active = nil
        owner &+= 1
        // Finishing runs the outgoing stream's termination handler, which hops
        // to a background queue and waits on this lock rather than re-entering
        // it — by which time `owner` has already moved past it.
        outgoing?.finish()
    }

    /// Gives the microphone up, if it is still ours. Callers hold `lock`.
    private static func resign(_ mine: Int) {
        guard owner == mine else { return }
        stopWatching()
        active = nil
    }

    private static func stopWatching() {
        guard let watch = configurationWatch else { return }
        NotificationCenter.default.removeObserver(watch)
        configurationWatch = nil
    }

    /// An engine pointed at `device`, and the format to tap it with.
    ///
    /// Callers hold `lock`.
    private static func engine(for device: InputDevice?) -> (AVAudioEngine, AVAudioFormat?) {
        let wanted = device?.deviceID

        // A previous session that ended abruptly can leave its tap behind.
        current.inputNode.removeTap(onBus: 0)
        if current.isRunning { current.stop() }

        guard wanted != boundDevice else {
            current.reset()
            guard let wanted else { return (current, nil) }

            // Bluetooth devices keep their AudioDeviceID when they reconnect,
            // but often reopen their microphone at a different rate (AirPods
            // switch between 44.1 and 24 kHz). `boundFormat` describes the
            // previous connection, not necessarily the device we have now.
            // Set both the hardware and the client side again before the tap
            // is installed; otherwise AVAudioEngine starts with a stale client
            // format and fails with -10868.
            if let refreshed = bind(current, to: wanted) {
                boundFormat = refreshed
                return (current, refreshed)
            }

            // A disconnected AUHAL can reject rebinding even after reset. One
            // fresh engine is the safe recovery, still scoped to this device
            // rather than constructing an engine for every normal press.
            current = AVAudioEngine()
            boundFormat = bind(current, to: wanted)
            if boundFormat != nil { return (current, boundFormat) }

            Logger(subsystem: "br.com.zesmoi.Shirusu", category: "mic").error(
                "Could not reopen \(device?.name ?? "that input", privacy: .public); falling back to the system default input")
            current = AVAudioEngine()
            boundDevice = nil
            return (current, nil)
        }

        // The old one goes before the new one asks the HAL for a thread.
        current = AVAudioEngine()
        boundDevice = wanted
        boundFormat = nil

        guard let wanted else { return (current, nil) }

        boundFormat = bind(current, to: wanted)
        if boundFormat == nil {
            // Rather than start with a mismatch: a fresh engine on the system
            // default still records, and the wrong microphone beats -10868.
            Logger(subsystem: "br.com.zesmoi.Shirusu", category: "mic").error(
                """
                Could not open \(device?.name ?? "that input", privacy: .public); \
                falling back to the system default input
                """)
            current = AVAudioEngine()
            boundDevice = nil
        }
        return (current, boundFormat)
    }

    /// Points an engine's input at a specific device, and makes its client
    /// format agree with that device.
    ///
    /// The second half is the part that is easy to miss and is the whole bug.
    /// `kAudioOutputUnitProperty_CurrentDevice` moves the *hardware* side to
    /// the device you asked for. The client format does not follow it — it is
    /// whatever was last set on the unit, which for an `AVAudioEngine` is the
    /// format of whichever device was open when `inputNode` was first touched.
    /// So the unit ends up asking a 44.1 kHz microphone for 24 kHz, and the
    /// engine refuses to start with -10868. Measured on a bare AUHAL, with no
    /// engine involved and nothing started:
    ///
    ///     device                 hardware   client before   client after
    ///     iPhone (Continuity)       48000           44100          48000
    ///     MacBook Air Microphone    44100           48000          44100
    ///     AirPods Pro               24000           44100          24000
    ///
    /// The middle row is the failure as reported, to the hertz. A fresh engine
    /// does not help, because the client format is not something an engine
    /// re-derives. It has to be set, so it is set here.
    ///
    /// Returns the format to tap with, or `nil` if the device could not be
    /// opened, in which case the caller falls back to the system default.
    private static func bind(_ engine: AVAudioEngine, to id: AudioDeviceID) -> AVAudioFormat? {
        engine.inputNode.withAudioUnit { unit -> AVAudioFormat? in
            guard let unit else { return nil }

            var id = id
            guard
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            else { return nil }

            // Element 1 is the input side of an AUHAL. Its input scope is the
            // hardware, its output scope is what we are handed.
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard
                AudioUnitGetProperty(
                    unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                    &hardware, &size) == noErr,
                hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0
            else { return nil }

            var client = AudioStreamBasicDescription(
                mSampleRate: hardware.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                    | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: hardware.mChannelsPerFrame,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            guard
                AudioUnitSetProperty(
                    unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                    &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
            else { return nil }

            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardware.mSampleRate,
                channels: AVAudioChannelCount(hardware.mChannelsPerFrame),
                interleaved: false
            )
        }
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

    /// Whether the microphone has already been granted.
    ///
    /// The one answer that can be given without waiting, which is what lets a
    /// press open the device on the turn it arrived on rather than the next
    /// one. Every press but the very first takes this path.
    static var isAuthorised: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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

            Self.takeOwnership()
            let mine = Self.owner
            Self.active = continuation

            let (engine, negotiated) = Self.engine(for: device)
            let input = engine.inputNode

            // The tap sits on the node's *output* bus, so it wants the output
            // format. Handing it the hardware input format instead is what makes
            // CoreAudio spew -10877 (kAudioUnitErr_InvalidElement) on start.
            let reported = input.outputFormat(forBus: 0)
            let format = negotiated ?? reported
            if let negotiated, negotiated.sampleRate != reported.sampleRate {
                log.notice(
                    """
                    Node reports \(reported.sampleRate, privacy: .public) Hz, \
                    unit negotiated \(negotiated.sampleRate, privacy: .public) Hz; \
                    tapping at the negotiated rate
                    """)
            }

            guard format.sampleRate > 0, format.channelCount > 0 else {
                Self.resign(mine)
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
                        // Only the owner tears down. A stream that was
                        // superseded has already handed the engine over, and
                        // whoever took it has cleaned up after it — stopping it
                        // from here would pull the tap out of the capture that
                        // is running now.
                        guard Self.owner == mine else { return }
                        Self.resign(mine)
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

                // The engine stops itself when its device goes away — AirPods
                // disconnecting, a microphone unplugged mid-sentence — and
                // takes the tap with it. Nothing else would ever tell the
                // reader, which would sit on a source that had quietly ended.
                //
                // Dispatched rather than handled inline because this can be
                // posted on the thread that is already inside `chunks()`, and
                // the lock is not recursive.
                Self.configurationWatch = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { _ in
                    DispatchQueue.global(qos: .utility).async {
                        Self.lock.lock()
                        defer { Self.lock.unlock() }
                        guard Self.owner == mine else { return }
                        Self.active?.finish()
                    }
                }

                log.info(
                    """
                    \(self.label, privacy: .public) open at \(rate, privacy: .public) Hz, \
                    \(format.channelCount, privacy: .public) ch
                    """)
            } catch {
                Self.resign(mine)
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
