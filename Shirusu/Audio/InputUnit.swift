import AVFoundation
import CoreAudio
import Foundation

/// Capture straight from an AUHAL, with the device chosen before anything is
/// opened.
///
/// This exists because `AVAudioEngine` cannot be asked for input alone. The
/// first touch of `inputNode` brings up the whole graph, output node included,
/// and that node binds to the default *output* device. With AirPods as the
/// default output, enabling input puts them into the Bluetooth mode that
/// carries a microphone, and `SetBluetoothAudioFormatAndWait` does not fail
/// fast: it times out, twice, and the microphone that was actually asked for
/// opens seconds later. Long enough for an entire press of the Globe key to
/// pass with the hardware still not recording, and for the recording to begin
/// after the key came up.
///
/// The measurement that settled it: the default *input* was the built-in
/// microphone, which is also what the app had resolved to, and the Bluetooth
/// negotiation happened anyway. Nothing on the input side could have dragged
/// the AirPods in.
///
/// Here the output element is switched off and the input device is named
/// outright, so no output device is ever bound and a Bluetooth pair nobody
/// asked about is never touched. A component instance opens no hardware until
/// `AudioUnitInitialize`, so all of that costs nothing: the same sequence run
/// against the built-in microphone, a Continuity iPhone and AirPods Pro
/// settles in around 20 ms each.
nonisolated final class InputUnit: @unchecked Sendable {
    /// What the callback hands out: the device's own rate and channel count,
    /// as deinterleaved Float32. Resampling to 16 kHz happens downstream, once.
    let format: AVAudioFormat

    private let unit: AudioComponentInstance
    private let device: AudioDeviceID

    /// Element 1 is the input side of an AUHAL. Its input scope is the
    /// hardware, its output scope is what we are handed.
    private static let inputElement: AudioUnitElement = 1
    private static let outputElement: AudioUnitElement = 0
    private static let maximumFrames: AVAudioFrameCount = 4096

    private let lock = NSLock()
    /// Where finished chunks go, swapped as one press hands over to the next.
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var isRunning = false
    private var isInitialized = false

    /// Rendered into on the IO thread, then copied out of.
    private let scratch: AVAudioPCMBuffer
    /// Frames gathered so far, handed up in pieces of `chunkFrames`.
    ///
    /// The device calls back at its own buffer size — 512 frames is 11.6 ms at
    /// 44.1 kHz — and everything downstream was written against the 100 ms the
    /// old tap asked for. Passing up eight times as many chunks would put
    /// eight times the resampling and level metering on the main actor for
    /// nothing, so they are gathered here first.
    private var pending: AVAudioPCMBuffer
    private let chunkFrames: AVAudioFrameCount

    init(device: AudioDeviceID) throws {
        self.device = device

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw MicrophoneError.noInputDevice
        }
        var instance: AudioComponentInstance?
        try Self.check(AudioComponentInstanceNew(component, &instance), "creating the input unit")
        guard let unit = instance else { throw MicrophoneError.noInputDevice }
        self.unit = unit

        do {
            // An AUHAL is an output unit until told otherwise, and a
            // capture-only one has to be told both halves.
            var on: UInt32 = 1
            try Self.check(
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                    Self.inputElement, &on, UInt32(MemoryLayout<UInt32>.size)),
                "enabling input")
            var off: UInt32 = 0
            try Self.check(
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                    Self.outputElement, &off, UInt32(MemoryLayout<UInt32>.size)),
                "disabling output")

            // The whole reason this type exists. Nothing is open yet, so
            // naming the device costs nothing, and between this and the
            // disabled output element no default device is ever consulted.
            var wanted = device
            try Self.check(
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                    Self.outputElement, &wanted, UInt32(MemoryLayout<AudioDeviceID>.size)),
                "choosing the input device")

            var frames = Self.maximumFrames
            try Self.check(
                AudioUnitSetProperty(
                    unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global,
                    Self.outputElement, &frames, UInt32(MemoryLayout<AVAudioFrameCount>.size)),
                "setting the slice size")

            // Read what the hardware runs at, then make the client side agree.
            // The second half is the part that is easy to miss: the client
            // format does not follow the device, it is whatever was last set,
            // and a unit asking a 44.1 kHz microphone for 24 kHz fails to
            // start with -10868.
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(
                AudioUnitGetProperty(
                    unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                    Self.inputElement, &hardware, &size),
                "reading the hardware format")
            guard
                hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: hardware.mSampleRate,
                    channels: AVAudioChannelCount(hardware.mChannelsPerFrame),
                    interleaved: false)
            else { throw MicrophoneError.noInputDevice }
            self.format = format

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
                mReserved: 0)
            try Self.check(
                AudioUnitSetProperty(
                    unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                    Self.inputElement, &client,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                "setting the client format")

            chunkFrames = AVAudioFrameCount(hardware.mSampleRate / 10)
            guard
                let scratch = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: Self.maximumFrames),
                let pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
            else { throw MicrophoneError.noInputDevice }
            self.scratch = scratch
            self.pending = pending
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    deinit {
        if isRunning { AudioOutputUnitStop(unit) }
        if isInitialized { AudioUnitUninitialize(unit) }
        AudioComponentInstanceDispose(unit)
    }

    /// Begin delivering chunks to `sink`.
    ///
    /// Idempotent in the sense that matters: a unit already running simply
    /// changes where its audio goes, which is what lets one press hand the
    /// microphone to the next without the HAL ever giving its IO thread back.
    func start(sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        lock.lock()
        self.sink = sink
        pending.frameLength = 0
        let running = isRunning
        lock.unlock()
        guard !running else { return }

        if !isInitialized {
            var callback = AURenderCallbackStruct(
                inputProc: { context, flags, timestamp, _, frames, _ in
                    Unmanaged<InputUnit>.fromOpaque(context)
                        .takeUnretainedValue()
                        .render(flags: flags, timestamp: timestamp, frames: frames)
                },
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try Self.check(
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global,
                    Self.outputElement, &callback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                "installing the input callback")
            try Self.check(AudioUnitInitialize(unit), "opening the input device")
            isInitialized = true
        }

        try Self.check(AudioOutputUnitStart(unit), "starting capture")
        isRunning = true
    }

    /// Stop delivering, without giving the device back.
    ///
    /// The unit stays initialised on purpose: stopping is what the next press
    /// would otherwise have to undo, and reopening a device is the cost this
    /// whole file exists to keep off the press.
    func stop() {
        lock.lock()
        sink = nil
        pending.frameLength = 0
        lock.unlock()
        guard isRunning else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
    }

    /// Whether the device is still there and still running at the rate this
    /// unit was built for.
    ///
    /// Both halves matter. A Bluetooth device keeps its `AudioDeviceID` across
    /// a reconnection and often comes back at a different rate — AirPods move
    /// between 44.1 and 24 kHz — so a unit reused on the strength of the ID
    /// alone would render into a buffer laid out for the old one.
    var isUsable: Bool {
        guard Self.isAlive(device) else { return false }
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard
            AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                Self.inputElement, &hardware, &size) == noErr
        else { return false }
        return hardware.mSampleRate == format.sampleRate
            && AVAudioChannelCount(hardware.mChannelsPerFrame) == format.channelCount
    }

    // MARK: - The IO thread

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        guard frames <= scratch.frameCapacity else { return kAudio_ParamError }
        scratch.frameLength = frames
        let status = AudioUnitRender(
            unit, flags, timestamp, Self.inputElement, frames, scratch.mutableAudioBufferList)
        guard status == noErr else { return status }

        lock.lock()
        defer { lock.unlock() }
        guard sink != nil else { return noErr }

        var offset: AVAudioFrameCount = 0
        while offset < frames {
            let take = min(chunkFrames - pending.frameLength, frames - offset)
            copy(from: scratch, at: offset, count: take)
            pending.frameLength += take
            offset += take
            if pending.frameLength == chunkFrames { flush() }
        }
        return noErr
    }

    /// Callers hold `lock`.
    private func copy(from source: AVAudioPCMBuffer, at offset: AVAudioFrameCount,
                      count: AVAudioFrameCount) {
        guard let src = source.floatChannelData, let dst = pending.floatChannelData else { return }
        for channel in 0..<Int(format.channelCount) {
            dst[channel].advanced(by: Int(pending.frameLength))
                .update(from: src[channel].advanced(by: Int(offset)), count: Int(count))
        }
    }

    /// Callers hold `lock`.
    private func flush() {
        guard pending.frameLength > 0, let sink else { return }
        let full = pending
        // A fresh buffer rather than reusing this one: it is on its way to a
        // consumer that will hold it for as long as it likes.
        guard let next = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return
        }
        pending = next
        sink(full)
    }

    // MARK: - Devices

    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
            id != kAudioObjectUnknown
        else { return nil }
        return id
    }

    private static func isAlive(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr
        else { return false }
        return alive != 0
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        throw MicrophoneError.coreAudio(status, what)
    }
}
