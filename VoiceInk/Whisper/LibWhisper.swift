import Foundation
#if canImport(whisper)
import whisper
#else
#error("Unable to import whisper module. Please check your project configuration.")
#endif
import os


// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    private var context: OpaquePointer?
    private var languageCString: [CChar]?
    private var prompt: String?
    private var promptCString: [CChar]?
    private var vadModelPath: String?
    private var vadModelPathNSString: NSString?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperContext")

    private init() {}

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        if let context = context {
            whisper_free(context)
        }
    }

    func fullTranscribe(samples: [Float]) -> Bool {
        guard let context = context else { return false }
        
        let maxThreads = max(1, min(8, cpuCount() - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        
        // Read language directly from UserDefaults
        let selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "auto"
        if selectedLanguage != "auto" {
            languageCString = Array(selectedLanguage.utf8CString)
        } else {
            languageCString = nil
            params.language = nil
        }
        
        if let prompt = prompt {
            promptCString = Array(prompt.utf8CString)
        } else {
            promptCString = nil
            params.initial_prompt = nil
        }
        
        params.print_realtime = true
        params.print_progress = false
        params.print_timestamps = true
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        params.temperature = 0.2

        whisper_reset_timings(context)
        
        // Configure VAD if enabled by user and model is available
        let isVADEnabled = UserDefaults.standard.bool(forKey: "IsVADEnabled")
        if isVADEnabled, let vadModelPath = self.vadModelPath {
            params.vad = true
            // Store NSString to keep the utf8String pointer alive for the duration of this call
            let nsPath = vadModelPath as NSString
            self.vadModelPathNSString = nsPath
            params.vad_model_path = nsPath.utf8String
            
            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.50
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 100
            vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
            vadParams.speech_pad_ms = 30
            vadParams.samples_overlap = 0.1
            params.vad_params = vadParams
        } else {
            params.vad = false
        }
        
        // Nest whisper_full inside withUnsafeBufferPointer closures so
        // the C pointers remain valid for the entire duration of the call.
        var success = true
        
        func runWhisper(_ params: inout whisper_full_params) {
            let vadEnabled = params.vad
            samples.withUnsafeBufferPointer { samplesBuffer in
                if whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count)) != 0 {
                    logger.error("Failed to run whisper_full. VAD enabled: \(vadEnabled)")
                    success = false
                }
            }
        }
        
        if let langCString = languageCString, let promptCString = promptCString {
            langCString.withUnsafeBufferPointer { langBuf in
                promptCString.withUnsafeBufferPointer { promptBuf in
                    params.language = langBuf.baseAddress
                    params.initial_prompt = promptBuf.baseAddress
                    runWhisper(&params)
                }
            }
        } else if let langCString = languageCString {
            langCString.withUnsafeBufferPointer { langBuf in
                params.language = langBuf.baseAddress
                runWhisper(&params)
            }
        } else if let promptCString = promptCString {
            promptCString.withUnsafeBufferPointer { promptBuf in
                params.initial_prompt = promptBuf.baseAddress
                runWhisper(&params)
            }
        } else {
            runWhisper(&params)
        }
        
        languageCString = nil
        promptCString = nil
        vadModelPathNSString = nil
        
        return success
    }

    func getTranscription() -> String {
        guard let context = context else { return "" }
        var transcription = ""
        for i in 0..<whisper_full_n_segments(context) {
            guard let segmentText = whisper_full_get_segment_text(context, i) else { continue }
            transcription += String(cString: segmentText)
        }
        return transcription
    }

    static func createContext(path: String) async throws -> WhisperContext {
        let whisperContext = WhisperContext()
        try await whisperContext.initializeModel(path: path)
        
        // Load VAD model from bundle resources
        let vadModelPath = await VADModelManager.shared.getModelPath()
        await whisperContext.setVADModelPath(vadModelPath)
        
        return whisperContext
    }
    
    private func initializeModel(path: String) throws {
        var params = whisper_context_default_params()
        #if targetEnvironment(simulator)
        params.use_gpu = false
        logger.info("Running on the simulator, using CPU")
        #else
        params.flash_attn = true // Enable flash attention for Metal
        logger.info("Flash attention enabled for Metal")
        #endif
        
        let context = whisper_init_from_file_with_params(path, params)
        if let context {
            self.context = context
        } else {
            logger.error("Couldn't load model at \(path)")
            throw WhisperStateError.modelLoadFailed
        }
    }
    
    private func setVADModelPath(_ path: String?) {
        self.vadModelPath = path
        if path != nil {
            logger.info("VAD model loaded from bundle resources")
        }
    }

    func releaseResources() {
        if let context = context {
            whisper_free(context)
            self.context = nil
        }
        languageCString = nil
    }

    func setPrompt(_ prompt: String?) {
        self.prompt = prompt
    }
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}
