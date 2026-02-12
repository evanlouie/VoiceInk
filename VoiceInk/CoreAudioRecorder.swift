import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import os

// MARK: - Core Audio Recorder (AUHAL-based, does not change system default device)
final class CoreAudioRecorder {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CoreAudioRecorder")

    private var audioUnit: AudioUnit?
    private var audioFile: ExtAudioFileRef?

    private var isRecording = false
    private var currentDeviceID: AudioDeviceID = 0
    private var recordingURL: URL?

    // Device format (what the hardware provides)
    private var deviceFormat = AudioStreamBasicDescription()
    // Output format (16kHz mono PCM Int16 for transcription)
    private var outputFormat = AudioStreamBasicDescription()

    // Conversion buffer
    private var conversionBuffer: UnsafeMutablePointer<Int16>?
    private var conversionBufferSize: UInt32 = 0

    // AudioConverter for proper sample-rate conversion (anti-aliased)
    private var audioConverter: AudioConverterRef?
    // Pre-allocated buffer for mono-mixed Float32 audio before resampling
    private var monoMixBuffer: UnsafeMutablePointer<Float32>?
    private var monoMixBufferSize: UInt32 = 0

    // Audio metering (thread-safe)
    private let meterLock = NSLock()
    private var _averagePower: Float = -160.0
    private var _peakPower: Float = -160.0

    var averagePower: Float {
        meterLock.lock()
        defer { meterLock.unlock() }
        return _averagePower
    }

    var peakPower: Float {
        meterLock.lock()
        defer { meterLock.unlock() }
        return _peakPower
    }

    // Pre-allocated render buffer (to avoid malloc in real-time callback)
    private var renderBuffer: UnsafeMutablePointer<Float32>?
    private var renderBufferSize: UInt32 = 0

    // Synchronizes access to callback-owned recorder resources.
    private let ioStateLock = NSLock()

    // Serial queue for file writes so the audio callback never performs disk I/O.
    private let fileWriteQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audio-file-writer")
    private var acceptsFileWrites = false

    /// Called on the audio thread with raw PCM data (16-bit, 16kHz, mono) for streaming.
    /// Access is protected by an unfair lock to avoid a data race between the audio thread and callers.
    private let _onAudioChunkLock = OSAllocatedUnfairLock<((Data) -> Void)?>(initialState: nil)

    var onAudioChunk: ((_ data: Data) -> Void)? {
        get { _onAudioChunkLock.withLock { $0 } }
        set { _onAudioChunkLock.withLock { $0 = newValue } }
    }

    // MARK: - Initialization

    init() {}

    deinit {
        stopRecording()
    }

    // MARK: - Public Interface

    /// Starts recording from the specified device to the given URL (WAV format)
    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID) throws {
        // Stop any existing recording
        stopRecording()

        if deviceID == 0 {
            logger.error("Cannot start recording - no valid audio device (deviceID is 0)")
            throw CoreAudioRecorderError.failedToSetDevice(status: 0)
        }

        // Validate device still exists before proceeding with setup
        guard isDeviceAvailable(deviceID) else {
            logger.error("Cannot start recording - device \(deviceID) is no longer available")
            throw CoreAudioRecorderError.deviceNotAvailable
        }

        currentDeviceID = deviceID
        recordingURL = url

        logger.notice("🎙️ Starting recording from device \(deviceID)")
        logDeviceDetails(deviceID: deviceID)

        // Step 1: Create and configure the AudioUnit (AUHAL)
        try createAudioUnit()

        // Step 2: Set the input device (does NOT change system default)
        try setInputDevice(deviceID)

        // Step 3: Configure formats
        try configureFormats()

        // Step 4: Set up the input callback
        try setupInputCallback()

        // Step 5: Create the output file
        try createOutputFile(at: url)

        // Step 6: Initialize and start the AudioUnit
        try startAudioUnit()

        ioStateLock.lock()
        isRecording = true
        acceptsFileWrites = true
        ioStateLock.unlock()
    }

    /// Stops the current recording
    func stopRecording() {
        ioStateLock.lock()
        let unitToStop = audioUnit
        let shouldStop = isRecording || unitToStop != nil
        ioStateLock.unlock()

        guard shouldStop else {
            logger.notice("stopRecording: skipped, not recording and no audio unit")
            return
        }
        logger.notice("stopRecording: stopping core audio recorder")

        // Clear streaming callback immediately to prevent additional chunk handling during teardown.
        _onAudioChunkLock.withLock { $0 = nil }

        // Stop, uninitialize, and dispose AudioUnit
        if let unit = unitToStop {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }

        ioStateLock.lock()
        isRecording = false
        acceptsFileWrites = false
        audioUnit = nil
        ioStateLock.unlock()

        // Drain all queued writes before disposing file/buffers.
        fileWriteQueue.sync {}

        ioStateLock.lock()

        // Close audio file
        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }

        // Free conversion buffer
        if let buffer = conversionBuffer {
            buffer.deallocate()
            conversionBuffer = nil
            conversionBufferSize = 0
        }

        // Dispose AudioConverter
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }

        // Free mono mix buffer
        if let buffer = monoMixBuffer {
            buffer.deallocate()
            monoMixBuffer = nil
            monoMixBufferSize = 0
        }

        // Free render buffer
        if let buffer = renderBuffer {
            buffer.deallocate()
            renderBuffer = nil
            renderBufferSize = 0
        }

        currentDeviceID = 0
        recordingURL = nil
        ioStateLock.unlock()

        // Reset meters
        meterLock.lock()
        _averagePower = -160.0
        _peakPower = -160.0
        meterLock.unlock()
    }

    var isCurrentlyRecording: Bool {
        ioStateLock.lock()
        defer { ioStateLock.unlock() }
        return isRecording
    }

    var currentRecordingURL: URL? {
        ioStateLock.lock()
        defer { ioStateLock.unlock() }
        return recordingURL
    }

    var currentDevice: AudioDeviceID {
        ioStateLock.lock()
        defer { ioStateLock.unlock() }
        return currentDeviceID
    }

    /// Switches to a new input device mid-recording without stopping the file write
    func switchDevice(to newDeviceID: AudioDeviceID) throws {
        ioStateLock.lock()
        let currentlyRecording = isRecording
        let unit = audioUnit
        ioStateLock.unlock()

        guard currentlyRecording, let unit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        // Don't switch if it's the same device
        ioStateLock.lock()
        let activeDeviceID = currentDeviceID
        ioStateLock.unlock()
        guard newDeviceID != activeDeviceID else { return }

        let oldDeviceID = activeDeviceID
        logger.notice("🎙️ Switching recording device from \(oldDeviceID) to \(newDeviceID)")

        // Step 1: Stop the AudioUnit (but keep file open)
        var status = AudioOutputUnitStop(unit)
        if status != noErr {
            logger.warning("🎙️ Warning: AudioOutputUnitStop returned \(status)")
        }

        // Step 2: Uninitialize to allow reconfiguration
        status = AudioUnitUninitialize(unit)
        if status != noErr {
            logger.warning("🎙️ Warning: AudioUnitUninitialize returned \(status)")
        }

        // Step 3: Set the new device
        var device = newDeviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            // Try to recover by restarting with old device
            logger.error("Failed to set new device: \(status). Attempting recovery...")
            var recoveryDevice = oldDeviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &recoveryDevice, UInt32(MemoryLayout<AudioDeviceID>.size))
            AudioUnitInitialize(unit)
            AudioOutputUnitStart(unit)
            throw CoreAudioRecorderError.failedToSetDevice(status: status)
        }

        // Step 4: Get new device format
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var newDeviceFormat = AudioStreamBasicDescription()
        status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &newDeviceFormat,
            &formatSize
        )

        if status != noErr {
            throw CoreAudioRecorderError.failedToGetDeviceFormat(status: status)
        }

        // Step 5: Configure callback format for new device
        var callbackFormat = AudioStreamBasicDescription(
            mSampleRate: newDeviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size) * newDeviceFormat.mChannelsPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size) * newDeviceFormat.mChannelsPerFrame,
            mChannelsPerFrame: newDeviceFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &callbackFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )

        if status != noErr {
            throw CoreAudioRecorderError.failedToSetFormat(status: status)
        }

        // Step 6: Reallocate buffers if needed
        let maxFrames: UInt32 = 4096
        ioStateLock.lock()
        let bufferSamples = maxFrames * newDeviceFormat.mChannelsPerFrame
        if bufferSamples > renderBufferSize {
            renderBuffer?.deallocate()
            renderBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(bufferSamples))
            renderBufferSize = bufferSamples
        }

        // Reallocate conversion buffer if new sample rate requires more space
        let maxOutputFrames = UInt32(Double(maxFrames) * (outputFormat.mSampleRate / newDeviceFormat.mSampleRate)) + 2
        if maxOutputFrames > conversionBufferSize {
            conversionBuffer?.deallocate()
            conversionBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: Int(maxOutputFrames))
            conversionBufferSize = maxOutputFrames
        }

        // Reallocate mono mix buffer if needed
        if maxFrames > monoMixBufferSize {
            monoMixBuffer?.deallocate()
            monoMixBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(maxFrames))
            monoMixBufferSize = maxFrames
        }

        // Recreate AudioConverter for new sample rate
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
        if newDeviceFormat.mSampleRate != outputFormat.mSampleRate {
            var converterInputFormat = AudioStreamBasicDescription(
                mSampleRate: newDeviceFormat.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(MemoryLayout<Float32>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float32>.size),
                mChannelsPerFrame: 1,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            var converter: AudioConverterRef?
            let converterStatus = AudioConverterNew(&converterInputFormat, &outputFormat, &converter)
            if converterStatus == noErr, let conv = converter {
                audioConverter = conv
                var quality = kAudioConverterQuality_Max
                AudioConverterSetProperty(
                    conv,
                    kAudioConverterSampleRateConverterQuality,
                    UInt32(MemoryLayout<UInt32>.size),
                    &quality
                )
            }
        }

        // Update stored format
        deviceFormat = newDeviceFormat
        currentDeviceID = newDeviceID
        ioStateLock.unlock()

        // Step 7: Reinitialize and restart
        status = AudioUnitInitialize(unit)
        if status != noErr {
            throw CoreAudioRecorderError.failedToInitialize(status: status)
        }

        status = AudioOutputUnitStart(unit)
        if status != noErr {
            throw CoreAudioRecorderError.failedToStart(status: status)
        }

        logger.notice("🎙️ Successfully switched to device \(newDeviceID)")
    }

    // MARK: - AudioUnit Setup

    private func createAudioUnit() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            logger.error("AudioUnit not found - HAL Output component unavailable")
            throw CoreAudioRecorderError.audioUnitNotFound
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            logger.error("Failed to create AudioUnit instance: \(status)")
            throw CoreAudioRecorderError.failedToCreateAudioUnit(status: status)
        }

        self.audioUnit = audioUnit

        // Enable input on element 1 (input scope)
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1, // Element 1 = input
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )

        if status != noErr {
            logger.error("Failed to enable audio input: \(status)")
            throw CoreAudioRecorderError.failedToEnableInput(status: status)
        }

        // Disable output on element 0 (output scope)
        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0, // Element 0 = output
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )

        if status != noErr {
            logger.error("Failed to disable audio output: \(status)")
            throw CoreAudioRecorderError.failedToDisableOutput(status: status)
        }

        // Enforce maximum frames per slice so our 4096-frame buffer assumption holds
        var maxFrames: UInt32 = 4096
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            UInt32(MemoryLayout<UInt32>.size)
        )
        if status != noErr {
            logger.warning("Failed to set MaximumFramesPerSlice: \(status)")
        }
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            logger.error("Failed to set input device \(deviceID): \(status)")
            throw CoreAudioRecorderError.failedToSetDevice(status: status)
        }
    }

    private func configureFormats() throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        // Get the device's native format (input scope, element 1)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &deviceFormat,
            &formatSize
        )

        if status != noErr {
            logger.error("Failed to get device format: \(status)")
            throw CoreAudioRecorderError.failedToGetDeviceFormat(status: status)
        }

        // Configure output format: 16kHz, mono, PCM Int16
        outputFormat = AudioStreamBasicDescription(
            mSampleRate: 16000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        // Set callback format (Float32 for processing, then convert to Int16 for file)
        var callbackFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size) * deviceFormat.mChannelsPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size) * deviceFormat.mChannelsPerFrame,
            mChannelsPerFrame: deviceFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &callbackFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )

        if status != noErr {
            logger.error("Failed to set audio format: \(status)")
            throw CoreAudioRecorderError.failedToSetFormat(status: status)
        }

        // Log format details
        let devSampleRate = deviceFormat.mSampleRate
        let devChannels = deviceFormat.mChannelsPerFrame
        let devBits = deviceFormat.mBitsPerChannel
        let outSampleRate = outputFormat.mSampleRate
        let outChannels = outputFormat.mChannelsPerFrame
        let outBits = outputFormat.mBitsPerChannel
        logger.notice("🎙️ Device format: sampleRate=\(devSampleRate), channels=\(devChannels), bitsPerChannel=\(devBits)")
        logger.notice("🎙️ Output format: sampleRate=\(outSampleRate), channels=\(outChannels), bitsPerChannel=\(outBits)")
        if devSampleRate != outSampleRate {
            logger.notice("🎙️ Converting: \(Int(devSampleRate))Hz → \(Int(outSampleRate))Hz")
        }

        // Pre-allocate buffers for real-time callback (avoid malloc in callback)
        let maxFrames: UInt32 = 4096
        let bufferSamples = maxFrames * deviceFormat.mChannelsPerFrame
        renderBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(bufferSamples))
        renderBufferSize = bufferSamples

        // Pre-allocate conversion buffer (output is always smaller due to downsampling)
        let maxOutputFrames = UInt32(Double(maxFrames) * (outputFormat.mSampleRate / deviceFormat.mSampleRate)) + 2
        conversionBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: Int(maxOutputFrames))
        conversionBufferSize = maxOutputFrames

        // Pre-allocate mono mix buffer for channel downmixing before resampling
        monoMixBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(maxFrames))
        monoMixBufferSize = maxFrames

        // Create AudioConverter for sample rate conversion with proper anti-aliasing filter
        if deviceFormat.mSampleRate != outputFormat.mSampleRate {
            var converterInputFormat = AudioStreamBasicDescription(
                mSampleRate: deviceFormat.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(MemoryLayout<Float32>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float32>.size),
                mChannelsPerFrame: 1,
                mBitsPerChannel: 32,
                mReserved: 0
            )

            var converter: AudioConverterRef?
            let converterStatus = AudioConverterNew(&converterInputFormat, &outputFormat, &converter)
            if converterStatus != noErr {
                logger.error("Failed to create AudioConverter: \(converterStatus)")
                throw CoreAudioRecorderError.failedToSetFormat(status: converterStatus)
            }
            audioConverter = converter

            // Set maximum quality for best anti-aliasing filter
            var quality = kAudioConverterQuality_Max
            AudioConverterSetProperty(
                converter!,
                kAudioConverterSampleRateConverterQuality,
                UInt32(MemoryLayout<UInt32>.size),
                &quality
            )
        }
    }

    private func setupInputCallback() throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        if status != noErr {
            logger.error("Failed to set input callback: \(status)")
            throw CoreAudioRecorderError.failedToSetCallback(status: status)
        }
    }

    private func createOutputFile(at url: URL) throws {
        // Remove existing file if any
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        // Create ExtAudioFile for writing
        var fileRef: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileWAVEType,
            &outputFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )

        if status != noErr {
            logger.error("Failed to create audio file at \(url.path): \(status)")
            throw CoreAudioRecorderError.failedToCreateFile(status: status)
        }

        audioFile = fileRef

        // Set client format (what we'll write)
        status = ExtAudioFileSetProperty(
            fileRef!,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &outputFormat
        )

        if status != noErr {
            logger.error("Failed to set file format: \(status)")
            throw CoreAudioRecorderError.failedToSetFileFormat(status: status)
        }
    }

    private func startAudioUnit() throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        var status = AudioUnitInitialize(audioUnit)
        if status != noErr {
            logger.error("Failed to initialize AudioUnit: \(status)")
            throw CoreAudioRecorderError.failedToInitialize(status: status)
        }

        status = AudioOutputUnitStart(audioUnit)
        if status != noErr {
            logger.error("Failed to start AudioUnit: \(status)")
            throw CoreAudioRecorderError.failedToStart(status: status)
        }
    }

    // MARK: - Input Callback

    private let inputCallback: AURenderCallback = { (
        inRefCon,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames,
        ioData
    ) -> OSStatus in

        let recorder = Unmanaged<CoreAudioRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
        return recorder.handleInputBuffer(
            ioActionFlags: ioActionFlags,
            inTimeStamp: inTimeStamp,
            inBusNumber: inBusNumber,
            inNumberFrames: inNumberFrames
        )
    }

    private func handleInputBuffer(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        ioStateLock.lock()
        guard isRecording, let audioUnit = audioUnit, let renderBuf = renderBuffer else {
            ioStateLock.unlock()
            return noErr
        }

        // Use pre-allocated buffer for input data
        let channelCount = deviceFormat.mChannelsPerFrame
        let requiredSamples = inNumberFrames * channelCount

        // Safety check - shouldn't happen with 4096 max frames
        guard requiredSamples <= renderBufferSize else {
            ioStateLock.unlock()
            return noErr
        }

        let bytesPerFrame = UInt32(MemoryLayout<Float32>.size) * channelCount
        let bufferSize = inNumberFrames * bytesPerFrame

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channelCount,
                mDataByteSize: bufferSize,
                mData: renderBuf
            )
        )

        // Render audio from the input
        let status = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            inTimeStamp,
            inBusNumber,
            inNumberFrames,
            &bufferList
        )

        if status != noErr {
            ioStateLock.unlock()
            return status
        }

        // Calculate audio meters from input buffer
        calculateMeters(from: &bufferList, frameCount: inNumberFrames)

        // Convert and write to file
        let convertedChunk = convertToPCMChunk(inputBuffer: &bufferList, frameCount: inNumberFrames)
        ioStateLock.unlock()

        if let convertedChunk {
            enqueueFileWrite(data: convertedChunk.data, frameCount: convertedChunk.frameCount)

            // Send the same PCM data to the streaming callback if set.
            // Copy the closure reference out under the lock, then call outside the lock.
            let chunkHandler = _onAudioChunkLock.withLock { $0 }
            chunkHandler?(convertedChunk.data)
        }

        return noErr
    }

    private func calculateMeters(from bufferList: inout AudioBufferList, frameCount: UInt32) {
        guard let data = bufferList.mBuffers.mData else { return }
        guard frameCount > 0 else { return }

        let samples = data.assumingMemoryBound(to: Float32.self)
        let channelCount = Int(deviceFormat.mChannelsPerFrame)
        let totalSamples = Int(frameCount) * channelCount

        guard totalSamples > 0 else { return }

        var sum: Float = 0.0
        var peak: Float = 0.0

        for i in 0..<totalSamples {
            let sample = abs(samples[i])
            sum += sample * sample
            if sample > peak {
                peak = sample
            }
        }

        let rms = sqrt(sum / Float(totalSamples))
        let avgDb = 20.0 * log10(max(rms, 0.000001))
        let peakDb = 20.0 * log10(max(peak, 0.000001))

        meterLock.lock()
        _averagePower = avgDb
        _peakPower = peakDb
        meterLock.unlock()
    }

    private func convertToPCMChunk(inputBuffer: inout AudioBufferList, frameCount: UInt32) -> (data: Data, frameCount: UInt32)? {
        let inputChannels = deviceFormat.mChannelsPerFrame
        let inputSampleRate = deviceFormat.mSampleRate
        let outputSampleRate = outputFormat.mSampleRate

        // Get input samples
          guard let inputData = inputBuffer.mBuffers.mData else { return nil }
        let inputSamples = inputData.assumingMemoryBound(to: Float32.self)

        guard let outputBuffer = conversionBuffer,
              let monoBuffer = monoMixBuffer,
              frameCount <= monoMixBufferSize else { return nil }

        // Step 1: Mix multi-channel Float32 to mono Float32
        for i in 0..<Int(frameCount) {
            var sample: Float32 = 0
            for ch in 0..<Int(inputChannels) {
                sample += inputSamples[i * Int(inputChannels) + ch]
            }
            monoBuffer[i] = sample / Float32(inputChannels)
        }

        let outputFrameCount: UInt32

        if inputSampleRate == outputSampleRate {
            // No resampling needed — convert mono Float32 to Int16
            outputFrameCount = frameCount
            guard outputFrameCount <= conversionBufferSize else { return nil }

            for i in 0..<Int(frameCount) {
                let scaled = monoBuffer[i] * 32767.0
                let clipped = max(-32768.0, min(32767.0, scaled))
                outputBuffer[i] = Int16(clipped)
            }
        } else {
            // Step 2: Use AudioConverter for anti-aliased sample rate conversion (e.g. 48kHz → 16kHz)
            guard let converter = audioConverter else { return }

            let ratio = outputSampleRate / inputSampleRate
            var packetCount = UInt32(Double(frameCount) * ratio) + 2
            packetCount = min(packetCount, conversionBufferSize)

            var context = ConverterCallbackContext(
                inputData: UnsafePointer(monoBuffer),
                inputFrameCount: frameCount,
                dataConsumed: false
            )

            var convertedBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: packetCount * UInt32(outputFormat.mBytesPerFrame),
                    mData: outputBuffer
                )
            )

            let convertStatus = AudioConverterFillComplexBuffer(
                converter,
                converterInputDataProc,
                &context,
                &packetCount,
                &convertedBufferList,
                nil
            )

            if convertStatus != noErr {
                return nil
            }

            outputFrameCount = packetCount
        }

        guard outputFrameCount > 0 else { return nil }

        let byteCount = Int(outputFrameCount) * MemoryLayout<Int16>.size
        let data = Data(bytes: outputBuffer, count: byteCount)
        return (data: data, frameCount: outputFrameCount)
    }

    private func enqueueFileWrite(data: Data, frameCount: UInt32) {
        fileWriteQueue.async { [weak self] in
            guard let self else { return }

            self.ioStateLock.lock()
            let canWrite = self.acceptsFileWrites
            let file = self.audioFile
            let bytesPerFrame = UInt32(MemoryLayout<Int16>.size)
            self.ioStateLock.unlock()

            guard canWrite, let file else { return }

            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }

                var writeBufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: frameCount * bytesPerFrame,
                        mData: UnsafeMutableRawPointer(mutating: baseAddress)
                    )
                )

                let writeStatus = ExtAudioFileWrite(file, frameCount, &writeBufferList)
                if writeStatus != noErr {
                    self.logger.error("🎙️ ExtAudioFileWrite failed with status: \(writeStatus)")
                }
            }
        }
    }

    // MARK: - Device Info Logging

    private func logDeviceDetails(deviceID: AudioDeviceID) {
        // Get device name
        let deviceName = getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"

        // Get device UID
        let deviceUID = getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "Unknown"

        // Get transport type
        let transportType = getTransportType(deviceID: deviceID)

        // Get manufacturer
        let manufacturer = getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceManufacturerCFString) ?? "Unknown"

        logger.notice("🎙️ Device info: name=\(deviceName), uid=\(deviceUID)")
        logger.notice("🎙️ Device details: transport=\(transportType), manufacturer=\(manufacturer)")

        // Get buffer frame size
        if let bufferSize = getBufferFrameSize(deviceID: deviceID) {
            let latencyMs = (Double(bufferSize) / 48000.0) * 1000.0 // Approximate latency assuming 48kHz
            logger.notice("🎙️ Buffer size: \(bufferSize) frames, ~latency: \(String(format: "%.1f", latencyMs))ms")
        }
    }

    private func getDeviceStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize = UInt32(MemoryLayout<CFString>.size)
        var property: CFString?

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &property
        )

        if status == noErr, let cfString = property {
            return cfString as String
        }
        return nil
    }

    private func getTransportType(deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transportType: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &transportType
        )

        if status != noErr {
            return "Unknown"
        }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "Built-in"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        case kAudioDeviceTransportTypeBluetooth:
            return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:
            return "Bluetooth LE"
        case kAudioDeviceTransportTypeAggregate:
            return "Aggregate"
        case kAudioDeviceTransportTypeVirtual:
            return "Virtual"
        case kAudioDeviceTransportTypePCI:
            return "PCI"
        case kAudioDeviceTransportTypeFireWire:
            return "FireWire"
        case kAudioDeviceTransportTypeDisplayPort:
            return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI:
            return "HDMI"
        case kAudioDeviceTransportTypeAVB:
            return "AVB"
        case kAudioDeviceTransportTypeThunderbolt:
            return "Thunderbolt"
        default:
            return "Other (\(transportType))"
        }
    }

    private func getBufferFrameSize(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var bufferSize: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &bufferSize
        )

        return status == noErr ? bufferSize : nil
    }

    /// Checks if a device is currently available using Apple's kAudioDevicePropertyDeviceIsAlive
    private func isDeviceAvailable(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isAlive: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &isAlive
        )

        return status == noErr && isAlive == 1
    }
}

// MARK: - AudioConverter Support

/// Context for the AudioConverter input data callback
private struct ConverterCallbackContext {
    var inputData: UnsafePointer<Float32>
    var inputFrameCount: UInt32
    var dataConsumed: Bool
}

/// Input data proc for AudioConverterFillComplexBuffer — provides mono Float32 audio to the converter
private let converterInputDataProc: AudioConverterComplexInputDataProc = { (
    _,
    ioNumberDataPackets,
    ioData,
    outDataPacketDescription,
    inUserData
) -> OSStatus in
    guard let contextPtr = inUserData?.assumingMemoryBound(to: ConverterCallbackContext.self) else {
        ioNumberDataPackets.pointee = 0
        return -50 // paramErr
    }

    // Return no data if we've already provided our chunk
    if contextPtr.pointee.dataConsumed {
        ioNumberDataPackets.pointee = 0
        return noErr
    }

    // Provide the mono Float32 buffer to the converter
    ioNumberDataPackets.pointee = contextPtr.pointee.inputFrameCount
    ioData.pointee.mBuffers.mNumberChannels = 1
    ioData.pointee.mBuffers.mDataByteSize = contextPtr.pointee.inputFrameCount * UInt32(MemoryLayout<Float32>.size)
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: contextPtr.pointee.inputData)
    contextPtr.pointee.dataConsumed = true

    return noErr
}

// MARK: - Error Types

enum CoreAudioRecorderError: LocalizedError {
    case audioUnitNotFound
    case audioUnitNotInitialized
    case deviceNotAvailable
    case failedToCreateAudioUnit(status: OSStatus)
    case failedToEnableInput(status: OSStatus)
    case failedToDisableOutput(status: OSStatus)
    case failedToSetDevice(status: OSStatus)
    case failedToGetDeviceFormat(status: OSStatus)
    case failedToSetFormat(status: OSStatus)
    case failedToSetCallback(status: OSStatus)
    case failedToCreateFile(status: OSStatus)
    case failedToSetFileFormat(status: OSStatus)
    case failedToInitialize(status: OSStatus)
    case failedToStart(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .audioUnitNotFound:
            return "HAL Output AudioUnit not found"
        case .audioUnitNotInitialized:
            return "AudioUnit not initialized"
        case .deviceNotAvailable:
            return "Audio device is no longer available"
        case .failedToCreateAudioUnit(let status):
            return "Failed to create AudioUnit: \(status)"
        case .failedToEnableInput(let status):
            return "Failed to enable input: \(status)"
        case .failedToDisableOutput(let status):
            return "Failed to disable output: \(status)"
        case .failedToSetDevice(let status):
            return "Failed to set input device: \(status)"
        case .failedToGetDeviceFormat(let status):
            return "Failed to get device format: \(status)"
        case .failedToSetFormat(let status):
            return "Failed to set audio format: \(status)"
        case .failedToSetCallback(let status):
            return "Failed to set input callback: \(status)"
        case .failedToCreateFile(let status):
            return "Failed to create audio file: \(status)"
        case .failedToSetFileFormat(let status):
            return "Failed to set file format: \(status)"
        case .failedToInitialize(let status):
            return "Failed to initialize AudioUnit: \(status)"
        case .failedToStart(let status):
            return "Failed to start AudioUnit: \(status)"
        }
    }
}
