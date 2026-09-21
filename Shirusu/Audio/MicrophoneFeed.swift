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

    /// One unit per input device, reused across presses.
    ///
    /// Not one per press: opening a device does not hand its IO thread back
    /// synchronously, so the next one started while the previous still held it
    /// and CoreAudio logged "HALB_IOThread::_Start: there already is a thread".
    /// A standing unit that is started and stopped has nothing to race.
    ///
    /// This is also where the first press stops being slow. Building the unit
    /// is what negotiates with the hardware, and doing it once per device
    /// rather than once per press means only the first press of a given
    /// microphone pays for it — and now that `InputUnit` binds no output
    /// device, that first press no longer pays for a Bluetooth pair it never
    /// asked about.
    private nonisolated(unsafe) static var current: InputUnit?
    private nonisolated(unsafe) static var boundDevice: AudioDeviceID?
    /// Serialises start and teardown, which can arrive from different tasks.
    private static let lock = NSLock()
    private static let log = Logger(subsystem: "br.com.zesmoi.Shirusu", category: "mic")

    /// Which stream currently owns the one unit.
    ///
    /// There is only ever one, so a second `chunks()` takes the first one's
    /// audio away — and used to take it away in silence. The reader downstream
    /// then waited for a chunk that could no longer arrive: a release that
    /// never finished, and a Globe key dead until the sixty-second watchdog
    /// let go of it. Holding the Globe key while a voice was being recorded
    /// did exactly this.
    ///
    /// Now a stream that is no longer the owner is *finished* instead, so its
    /// reader ends on whatever it managed to hear, and only the owner is
    /// allowed to tear anything down.
    private nonisolated(unsafe) static var owner = 0
    private nonisolated(unsafe) static var active: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    /// Watches the device list, so one that disappears mid-capture ends the
    /// stream rather than starving it.
    private nonisolated(unsafe) static var deviceWatch: AudioObjectPropertyListenerBlock?

    private nonisolated(unsafe) static var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

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

    /// Callers hold `lock`.
    private static func startWatching(_ mine: Int) {
        stopWatching()
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.global(qos: .utility).async {
                lock.lock()
                defer { lock.unlock() }
                guard owner == mine else { return }
                // The list changed; that is only our business if what we are
                // reading went with it.
                guard current?.isUsable != true else { return }
                active?.finish()
            }
        }
        // The system object rather than the device: a Bluetooth microphone
        // that disconnects takes its `AudioObjectID` with it, and a listener
        // registered on that object goes at the same moment it would have
        // fired.
        guard
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &devicesAddress, nil, block) == noErr
        else { return }
        deviceWatch = block
    }

    /// Callers hold `lock`.
    private static func stopWatching() {
        guard let watch = deviceWatch else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, nil, watch)
        deviceWatch = nil
    }

    /// A unit pointed at `device`. Callers hold `lock`.
    private static func unit(for device: InputDevice?) throws -> InputUnit {
        guard let wanted = device?.deviceID ?? InputUnit.defaultInputDevice() else {
            throw MicrophoneError.noInputDevice
        }

        if let current, boundDevice == wanted, current.isUsable { return current }

        current?.stop()
        current = nil
        boundDevice = nil

        do {
            let fresh = try InputUnit(device: wanted)
            current = fresh
            boundDevice = wanted
            return fresh
        } catch {
            // Rather than give up: a fresh unit on the system default still
            // records, and the wrong microphone beats no microphone.
            guard let fallback = InputUnit.defaultInputDevice(), fallback != wanted else {
                throw error
            }
            log.error(
                """
                Could not open \(device?.name ?? "that input", privacy: .public); \
                falling back to the system default input
                """)
            let fresh = try InputUnit(device: fallback)
            current = fresh
            boundDevice = fallback
            return fresh
        }
    }

    /// Which input to open. `nil` means whatever the system calls default.
    private let device: InputDevice?

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

            let unit: InputUnit
            do {
                unit = try Self.unit(for: device)
            } catch {
                Self.resign(mine)
                continuation.finish(throwing: error)
                return
            }

            let rate = unit.format.sampleRate
            let counter = FrameCounter()

            do {
                // The buffer arrives owned by nobody else — `InputUnit` hands
                // over a fresh one and keeps none of it — so unlike a tap
                // there is nothing to copy here.
                try unit.start { buffer in
                    let position = counter.advance(by: Int(buffer.frameLength)) / rate
                    continuation.yield(
                        AudioChunk(
                            buffer: buffer,
                            peak: AudioChunk.peakMagnitude(of: buffer),
                            position: position
                        )
                    )
                }
            } catch {
                Self.resign(mine)
                continuation.finish(throwing: error)
                return
            }

            continuation.onTermination = { _ in
                // Stopping is not instant, and this fires the moment the
                // consumer stops reading — which is exactly when the release
                // pass wants to start decoding. Detach it so the user is not
                // waiting on CoreAudio housekeeping.
                DispatchQueue.global(qos: .utility).async {
                    Self.lock.lock()
                    defer { Self.lock.unlock() }
                    // Only the owner tears down. A stream that was superseded
                    // has already handed the microphone over, and whoever took
                    // it has cleaned up after it — stopping it from here would
                    // silence the capture that is running now.
                    guard Self.owner == mine else { return }
                    Self.resign(mine)
                    // Stopped, not disposed: the unit stays initialised so the
                    // next press does not reopen the device.
                    unit.stop()
                }
            }

            Self.startWatching(mine)

            Self.log.info(
                """
                \(self.label, privacy: .public) open at \(rate, privacy: .public) Hz, \
                \(unit.format.channelCount, privacy: .public) ch
                """)
        }
    }
}

enum MicrophoneError: LocalizedError {
    case noInputDevice
    case accessDenied
    case coreAudio(OSStatus, String)

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
        case .coreAudio(let status, let what):
            return String(
                localized: "The microphone failed while \(what) (error \(Int(status))).",
                comment: "Error when Core Audio refuses a step of opening the input"
            )
        }
    }
}
