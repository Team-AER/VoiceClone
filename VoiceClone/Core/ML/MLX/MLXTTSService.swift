//
//  MLXTTSService.swift
//  VoiceClone
//
//  TTS service using MLX backend instead of CoreML
//

import Foundation
@preconcurrency import MLX
import AVFoundation
import Combine

/// TTS Service using MLX backend
@available(iOS 16.0, *)
@MainActor
final class MLXTTSService: ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var state: TTSServiceState = .idle
    @Published private(set) var loadedCapabilities: Set<TTSCapability> = []

    // MARK: - Private Properties

    private var talkerModel: MLXQwen3TTSModel?
    private var decoderModel: MLXSpeechDecoder?
    private let tokenizer: Qwen3Tokenizer
    private let audioEngine: AudioEngine

    // MARK: - Initialization

    init(tokenizer: Qwen3Tokenizer, audioEngine: AudioEngine) {
        self.tokenizer = tokenizer
        self.audioEngine = audioEngine
    }

    // MARK: - Public Methods

    func loadCapability(_ capability: TTSCapability) async throws {
        state = .loading

        do {
            // Get model path from bundle
            guard let talkerPath = getModelPath(for: capability) else {
                throw TTSError.modelNotFound(capability)
            }

            // Load talker model on background thread
            let talker = try await Task.detached(priority: .userInitiated) {
                try await MLXQwen3TTSModel(modelPath: talkerPath)
            }.value

            // Load decoder model if available
            let decoder: MLXSpeechDecoder?
            if let decoderPath = getDecoderPath() {
                decoder = try await Task.detached(priority: .userInitiated) {
                    try await MLXSpeechDecoder(modelPath: decoderPath)
                }.value
                print("✓ Speech decoder loaded")
            } else {
                decoder = nil
                print("⚠️ Speech decoder not found, using placeholder audio")
            }

            await MainActor.run {
                self.talkerModel = talker
                self.decoderModel = decoder
                self.loadedCapabilities.insert(capability)
                self.state = .ready
            }

            print("✓ MLX models loaded for \(capability)")
        } catch {
            state = .idle
            throw TTSError.modelLoadFailed(error.localizedDescription)
        }
    }

    func synthesize(
        text: String,
        language: Language,
        instruction: String
    ) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        guard loadedCapabilities.contains(.voiceDesign) else {
            throw TTSError.capabilityNotLoaded(.voiceDesign)
        }

        state = .synthesizing(progress: 0)

        guard let talker = talkerModel else {
            throw TTSError.modelNotLoaded
        }

        return AsyncThrowingStream<AudioChunk, Error> { (continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation) in
            Task { @MainActor in
                await self.performSynthesis(
                    tokens: self.tokenizer.encode(text: text, language: language, instruction: instruction),
                    talker: talker,
                    continuation: continuation
                )
            }
        }
    }
    
    private func performSynthesis(
        tokens: [Int],
        talker: MLXQwen3TTSModel,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        do {
            guard !tokens.isEmpty else {
                throw TTSError.tokenizationFailed
            }

            print("MLX: Synthesizing \(tokens.count) tokens...")

            // Generate audio codes - talker is an actor, so call directly
            let inputIds = MLXArray(tokens.map { Int32($0) }).reshaped(1, tokens.count)
            let audioCodes = try await talker.generate(inputIds: inputIds)

            // Decode audio codes to waveform
            let samples: [Float]
            let sampleRate = 24000
            
            if let decoder = self.decoderModel {
                let waveform = try await decoder.decode(audioCodes)
                samples = Array(waveform.asArray(Float.self))
                print("✓ Decoded \(samples.count) audio samples")
            } else {
                // Fallback to placeholder audio
                let duration = Float(tokens.count) * 0.05
                let numSamples = Int(Float(sampleRate) * duration)
                samples = Self.generatePlaceholderSamples(count: numSamples, sampleRate: sampleRate)
                print("⚠️ Using placeholder audio (decoder not loaded)")
            }

            let chunk = AudioChunk(
                samples: samples,
                sampleRate: sampleRate,
                timestamp: Date().timeIntervalSince1970
            )

            continuation.yield(chunk)
            continuation.finish()
            self.state = .ready
        } catch {
            continuation.finish(throwing: error)
            self.state = .error(error.localizedDescription)
        }
    }
    
    private static func generatePlaceholderSamples(count: Int, sampleRate: Int) -> [Float] {
        let sr = Float(sampleRate)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Float(i)
            let freq1: Float = sin(t * 2.0 * .pi * 440.0 / sr)
            let freq2: Float = sin(t * 2.0 * .pi * 554.0 / sr) * 0.5
            samples[i] = (freq1 + freq2) * 0.1
        }
        return samples
    }

    func synthesize(
        text: String,
        language: Language,
        speaker: PresetVoice,
        instruction: String? = nil
    ) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        guard loadedCapabilities.contains(.customVoice) else {
            throw TTSError.capabilityNotLoaded(.customVoice)
        }

        state = .synthesizing(progress: 0)

        guard let talker = talkerModel else {
            throw TTSError.modelNotLoaded
        }

        let speakerInstruction = instruction ?? "Speak naturally as \(speaker.rawValue)."
        let tokens = self.tokenizer.encode(
            text: text,
            language: language,
            instruction: "<|speaker:\(speaker.embeddingId)|> \(speakerInstruction)"
        )
        
        return AsyncThrowingStream<AudioChunk, Error> { (continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation) in
            Task { @MainActor in
                await self.performSynthesisWithSpeaker(
                    tokens: tokens,
                    speaker: speaker,
                    talker: talker,
                    continuation: continuation
                )
            }
        }
    }
    
    private func performSynthesisWithSpeaker(
        tokens: [Int],
        speaker: PresetVoice,
        talker: MLXQwen3TTSModel,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        do {
            guard !tokens.isEmpty else {
                throw TTSError.tokenizationFailed
            }

            print("MLX: Synthesizing \(tokens.count) tokens with speaker \(speaker.rawValue)...")

            // Generate audio codes - talker is an actor, so call directly
            let inputIds = MLXArray(tokens.map { Int32($0) }).reshaped(1, tokens.count)
            let audioCodes = try await talker.generate(inputIds: inputIds)

            // Decode audio codes to waveform
            let samples: [Float]
            let sampleRate = 24000
            
            if let decoder = self.decoderModel {
                let waveform = try await decoder.decode(audioCodes)
                samples = Array(waveform.asArray(Float.self))
                print("✓ Decoded \(samples.count) audio samples")
            } else {
                let numSamples = Int(Float(tokens.count) * 0.05 * Float(sampleRate))
                samples = Self.generatePlaceholderSamples(count: numSamples, sampleRate: sampleRate)
                print("⚠️ Using placeholder audio (decoder not loaded)")
            }

            let chunk = AudioChunk(
                samples: samples,
                sampleRate: sampleRate,
                timestamp: Date().timeIntervalSince1970
            )

            continuation.yield(chunk)
            continuation.finish()
            self.state = .ready
        } catch {
            continuation.finish(throwing: error)
            self.state = .error(error.localizedDescription)
        }
    }

    func synthesize(
        text: String,
        language: Language,
        referenceAudio: Data,
        referenceText: String
    ) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        guard loadedCapabilities.contains(.voiceClone) else {
            throw TTSError.capabilityNotLoaded(.voiceClone)
        }

        // For now, fall back to voice design
        print("⚠️ MLX voice cloning not yet implemented, using voice design")
        return try await synthesize(
            text: text,
            language: language,
            instruction: "Speak naturally"
        )
    }

    func playStream(_ stream: AsyncThrowingStream<AudioChunk, Error>) async throws {
        try await audioEngine.playStream(stream)
        state = .ready
    }

    func stop() {
        audioEngine.stop()
        state = .ready
    }

    // MARK: - Helper Methods

    private func getDecoderPath() -> URL? {
        let modelName = "Qwen3TTS_Decoder"

        // 1) Application Support (macOS downloaded models) / Documents (iOS)
        let managedDir = ModelDownloadManager.modelsDirectory
            .appendingPathComponent(modelName, isDirectory: true)
        if fileExists(in: managedDir, config: "decoder_config.json", weights: "decoder_weights.safetensors") {
            print("✓ Using decoder from managed dir: \(managedDir.path)")
            return managedDir
        }

        // 2) Bundle resources
        if let configURL = Bundle.main.url(forResource: "decoder_config", withExtension: "json") {
            let bundleRoot = configURL.deletingLastPathComponent()
            if fileExists(in: bundleRoot, config: "decoder_config.json", weights: "decoder_weights.safetensors") {
                print("✓ Using decoder from Bundle root: \(bundleRoot.path)")
                return bundleRoot
            }
        }

        guard let resourcesRoot = Bundle.main.resourceURL else { return nil }

        for subpath in ["Resources/MLXModels/\(modelName)", "MLXModels/\(modelName)", modelName] {
            let dir = resourcesRoot.appendingPathComponent(subpath, isDirectory: true)
            if fileExists(in: dir, config: "decoder_config.json", weights: "decoder_weights.safetensors") {
                print("✓ Using decoder from Bundle subpath: \(dir.path)")
                return dir
            }
        }

        // 3) Developer override via environment variable (DEBUG only)
        #if DEBUG
        if let envBase = ProcessInfo.processInfo.environment["VOICECLONE_MODELS_DIR"] {
            let dir = URL(fileURLWithPath: envBase).appendingPathComponent(modelName)
            if fileExists(in: dir, config: "decoder_config.json", weights: "decoder_weights.safetensors") {
                print("✓ Using decoder from VOICECLONE_MODELS_DIR: \(dir.path)")
                return dir
            }
        }
        #endif

        return nil
    }

    private func fileExists(in dir: URL, config: String, weights: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(config).path) &&
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(weights).path)
    }

    private func getModelPath(for capability: TTSCapability) -> URL? {
        // Determine model name per capability
        let modelName: String
        switch capability {
        case .voiceDesign:
            modelName = "Qwen3TTS_FP16"
        case .customVoice:
            modelName = "Qwen3TTS_FP16"  // Same model for now
        case .voiceClone:
            modelName = "Qwen3TTS_FP16"  // Same model for now
        }

        // 1) Application Support (macOS) / Documents (iOS) — managed by ModelDownloadManager
        let managedDir = ModelDownloadManager.modelsDirectory
            .appendingPathComponent(modelName, isDirectory: true)
        if fileExists(in: managedDir, config: "talker_config.json", weights: "talker_weights.safetensors") {
            print("✓ Using talker from managed dir: \(managedDir.path)")
            return managedDir
        }

        // 2) Bundle resources (iOS development builds)
        if let configURL = Bundle.main.url(forResource: "talker_config", withExtension: "json") {
            let bundleRoot = configURL.deletingLastPathComponent()
            if fileExists(in: bundleRoot, config: "talker_config.json", weights: "talker_weights.safetensors") {
                print("✓ Using talker from Bundle root: \(bundleRoot.path)")
                return bundleRoot
            }
        }

        if let resourcesRoot = Bundle.main.resourceURL {
            for subpath in ["Resources/MLXModels/\(modelName)", "MLXModels/\(modelName)", modelName] {
                let dir = resourcesRoot.appendingPathComponent(subpath, isDirectory: true)
                if fileExists(in: dir, config: "talker_config.json", weights: "talker_weights.safetensors") {
                    print("✓ Using talker from Bundle subpath: \(dir.path)")
                    return dir
                }
            }
        }

        // 3) Developer override via environment variable (DEBUG only)
        #if DEBUG
        if let envBase = ProcessInfo.processInfo.environment["VOICECLONE_MODELS_DIR"] {
            let dir = URL(fileURLWithPath: envBase).appendingPathComponent(modelName)
            if fileExists(in: dir, config: "talker_config.json", weights: "talker_weights.safetensors") {
                print("✓ Using talker from VOICECLONE_MODELS_DIR: \(dir.path)")
                return dir
            }
        }
        #endif

        return nil
    }
}
