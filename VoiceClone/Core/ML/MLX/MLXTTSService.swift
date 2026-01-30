//
//  MLXTTSService.swift
//  VoiceClone
//
//  TTS service using MLX backend instead of CoreML
//

import Foundation
import MLX
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
    private var decoderModel: MLXQwen3TTSModel?  // Would be separate decoder
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
            guard let modelPath = getModelPath(for: capability) else {
                throw TTSError.modelNotFound(capability)
            }

            // Load talker model on background thread
            let model = try await Task.detached(priority: .userInitiated) {
                try await MLXQwen3TTSModel(modelPath: modelPath)
            }.value

            await MainActor.run {
                self.talkerModel = model
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

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Tokenize input
                    let tokens = self.tokenizer.encode(
                        text: text,
                        language: language,
                        instruction: instruction
                    )
                    guard !tokens.isEmpty else {
                        throw TTSError.tokenizationFailed
                    }

                    print("MLX: Synthesizing \(tokens.count) tokens...")

                    // Generate audio codes on background thread
                    let audioCodes = try await Task.detached(priority: .userInitiated) {
                        // Convert to MLX array [1, seq_len]
                        let inputIds = MLX.array(tokens.map { Int32($0) }).reshaped(1, tokens.count)

                        // Generate audio codes [1, 16, seq_len]
                        return try await talker.generate(inputIds: inputIds)
                    }.value

                    // Convert to AudioChunk and yield
                    // TODO: In real implementation, decode codes to waveform using speech decoder
                    // For now, create placeholder audio
                    let sampleRate = 24000
                    let duration = Float(tokens.count) * 0.05  // ~50ms per token
                    let numSamples = Int(Float(sampleRate) * duration)

                    // Generate placeholder sine wave (multi-tone for better sound)
                    let samples = (0..<numSamples).map { i -> Float in
                        let t = Float(i) / Float(sampleRate)
                        let freq1 = sin(Float(i) * 2.0 * .pi * 440.0 / Float(sampleRate))
                        let freq2 = sin(Float(i) * 2.0 * .pi * 554.0 / Float(sampleRate)) * 0.5
                        return (freq1 + freq2) * 0.1
                    }

                    let chunk = AudioChunk(
                        samples: samples,
                        sampleRate: sampleRate,
                        timestamp: Date().timeIntervalSince1970
                    )

                    continuation.yield(chunk)
                    continuation.finish()

                    await MainActor.run {
                        self.state = .ready
                    }
                } catch {
                    continuation.finish(throwing: error)
                    await MainActor.run {
                        self.state = .error(error.localizedDescription)
                    }
                }
            }
        }
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

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Tokenize with speaker embedding
                    let speakerInstruction = instruction ?? "Speak naturally as \(speaker.rawValue)."
                    let tokens = self.tokenizer.encode(
                        text: text,
                        language: language,
                        instruction: "<|speaker:\(speaker.embeddingId)|> \(speakerInstruction)"
                    )
                    guard !tokens.isEmpty else {
                        throw TTSError.tokenizationFailed
                    }

                    print("MLX: Synthesizing \(tokens.count) tokens with speaker \(speaker.rawValue)...")

                    // Generate audio codes
                    let audioCodes = try await Task.detached(priority: .userInitiated) {
                        let inputIds = MLX.array(tokens.map { Int32($0) }).reshaped(1, tokens.count)
                        return try await talker.generate(inputIds: inputIds)
                    }.value

                    // Convert to audio (placeholder)
                    let sampleRate = 24000
                    let duration = Float(tokens.count) * 0.05
                    let numSamples = Int(Float(sampleRate) * duration)

                    let samples = (0..<numSamples).map { i -> Float in
                        let t = Float(i) / Float(sampleRate)
                        let freq1 = sin(Float(i) * 2.0 * .pi * 440.0 / Float(sampleRate))
                        let freq2 = sin(Float(i) * 2.0 * .pi * 554.0 / Float(sampleRate)) * 0.5
                        return (freq1 + freq2) * 0.1
                    }

                    let chunk = AudioChunk(
                        samples: samples,
                        sampleRate: sampleRate,
                        timestamp: Date().timeIntervalSince1970
                    )

                    continuation.yield(chunk)
                    continuation.finish()

                    await MainActor.run {
                        self.state = .ready
                    }
                } catch {
                    continuation.finish(throwing: error)
                    await MainActor.run {
                        self.state = .error(error.localizedDescription)
                    }
                }
            }
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

    private func getModelPath(for capability: TTSCapability) -> URL? {
        // Determine model name per capability
        let modelName: String
        switch capability {
        case .voiceDesign:
            modelName = "Qwen3TTS_INT4"
        case .customVoice:
            modelName = "Qwen3TTS_INT4"  // Same model for now
        case .voiceClone:
            modelName = "Qwen3TTS_INT4"  // Same model for now
        }

        // 1) Prefer Documents directory (downloaded models)
        if let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let docPath = documentsDir
                .appendingPathComponent("MLXModels", isDirectory: true)
                .appendingPathComponent(modelName, isDirectory: true)

            let configURL = docPath.appendingPathComponent("config.json")
            let weightsURL = docPath.appendingPathComponent("weights.npz")
            if FileManager.default.fileExists(atPath: configURL.path) &&
                FileManager.default.fileExists(atPath: weightsURL.path) {
                print("✓ Using MLX model from Documents: \(docPath.path)")
                return docPath
            }
        }

        // 2) Search common bundle locations. We validate that both config.json and weights.npz exist in the candidate directory to avoid partial matches
        guard let resourcesRoot = Bundle.main.resourceURL else {
            return nil
        }

        let candidateSubpaths = [
            "Resources/MLXModels/\(modelName)",
            "MLXModels/\(modelName)",
            "Resources/\(modelName)",
            "\(modelName)"
        ]

        for subpath in candidateSubpaths {
            let candidateDir = resourcesRoot.appendingPathComponent(subpath, isDirectory: true)
            let configURL = candidateDir.appendingPathComponent("config.json")
            let weightsURL = candidateDir.appendingPathComponent("weights.npz")
            if FileManager.default.fileExists(atPath: configURL.path) &&
                FileManager.default.fileExists(atPath: weightsURL.path) {
                print("✓ Using MLX model from Bundle: \(candidateDir.path)")
                return candidateDir
            }
        }

        // Not found
        return nil
    }
}
