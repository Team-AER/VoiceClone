//
//  MLXTTSService.swift
//  VoiceClone
//
//  Thin wrapper around the vendored Qwen3TTSModel (`Core/ML/MLX/Qwen3TTS/`).
//  The vendored package handles model loading, tokenization (via
//  swift-transformers AutoTokenizer), autoregressive talker generation, and
//  speech-tokenizer decoding end-to-end. This service only adapts the app's
//  existing API (capabilities, streaming AudioChunks, state machine) to that
//  package's entry points.
//

import Foundation
import MLX
import AVFoundation

/// TTS service backed by the vendored Qwen3TTS implementation.
@available(iOS 18.0, macOS 15.0, *)
@MainActor
final class MLXTTSService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var state: TTSServiceState = .idle
    @Published private(set) var loadedCapabilities: Set<TTSCapability> = []

    // MARK: - Private state

    private var model: Qwen3TTSModel?
    private let audioEngine: AudioEngine

    // MARK: - Init

    /// The model directory is determined by `ModelDownloadManager.currentModelDirectory`
    /// and the tokenizer lives inside that directory; the service therefore no
    /// longer takes a tokenizer argument.
    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }

    // MARK: - Capability loading

    func loadCapability(_ capability: TTSCapability) async throws {
        // The mlx-community CustomVoice snapshot covers voiceDesign (via instruct),
        // customVoice (via speaker) and voiceClone (via reference audio). We load
        // the same model for any capability and record that it's available.
        state = .loading
        do {
            if model == nil {
                let dir = ModelDownloadManager.currentModelDirectory
                guard FileManager.default.fileExists(atPath: dir.path) else {
                    throw TTSError.modelNotFound(capability)
                }
                model = try await Qwen3TTSModel.fromPretrained(dir.path)
            }
            loadedCapabilities.insert(capability)
            state = .ready
        } catch {
            state = .idle
            throw TTSError.modelLoadFailed(error.localizedDescription)
        }
    }

    // MARK: - Synthesis — voice design

    func synthesize(
        text: String,
        language: Language,
        instruction: String
    ) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        try requireCapability(.voiceDesign)
        return makeStream { [weak self] continuation in
            await self?.run(
                text: text,
                language: language,
                speaker: nil,
                instruction: instruction,
                continuation: continuation
            )
        }
    }

    // MARK: - Synthesis — preset/custom voice

    func synthesize(
        text: String,
        language: Language,
        speaker: PresetVoice,
        instruction: String? = nil
    ) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        try requireCapability(.customVoice)
        return makeStream { [weak self] continuation in
            await self?.run(
                text: text,
                language: language,
                speaker: speaker.rawValue,
                instruction: instruction,
                continuation: continuation
            )
        }
    }

    // MARK: - Synthesis — voice cloning

    func synthesize(
        text: String,
        language: Language,
        referenceAudio: Data,
        referenceText: String
    ) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        try requireCapability(.voiceClone)
        // Voice cloning requires the Base model; the CustomVoice snapshot does
        // not support it. Surface the limitation explicitly rather than silently
        // falling back.
        throw TTSError.modelLoadFailed(
            "Voice cloning requires the Qwen3-TTS-Base model, which is not installed."
        )
    }

    // MARK: - Playback

    func playStream(_ stream: AsyncThrowingStream<AudioChunk, Error>) async throws {
        try await audioEngine.playStream(stream)
        state = .ready
    }

    func stop() {
        audioEngine.stop()
        state = .ready
    }

    // MARK: - Availability probe

    /// True when the required files for synthesis are on disk. Safe to call
    /// from any isolation context.
    nonisolated static func areModelsAvailable() -> Bool {
        ModelDownloadManager.areModelsAvailable()
    }

    // MARK: - Private helpers

    private func requireCapability(_ capability: TTSCapability) throws {
        guard loadedCapabilities.contains(capability) else {
            throw TTSError.capabilityNotLoaded(capability)
        }
        guard model != nil else {
            throw TTSError.modelNotLoaded
        }
    }

    private func makeStream(
        _ body: @escaping @MainActor (AsyncThrowingStream<AudioChunk, Error>.Continuation) async -> Void
    ) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                await body(continuation)
            }
        }
    }

    private func run(
        text: String,
        language: Language,
        speaker: String?,
        instruction: String?,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continuation.finish(throwing: TTSError.tokenizationFailed)
            state = .error("Empty text")
            return
        }
        guard let model = model else {
            continuation.finish(throwing: TTSError.modelNotLoaded)
            state = .error("Model not loaded")
            return
        }

        state = .synthesizing(progress: 0)
        do {
            let audio = try await model.generate(
                text: text,
                speaker: speaker,
                instruct: instruction,
                language: language.qwenLanguageCode
            )
            eval(audio)
            let samples = audio.asArray(Float.self)

            let chunk = AudioChunk(
                samples: samples,
                sampleRate: model.sampleRate,
                timestamp: Date().timeIntervalSince1970
            )
            continuation.yield(chunk)
            continuation.finish()
            state = .ready
        } catch {
            continuation.finish(throwing: error)
            state = .error(error.localizedDescription)
        }
    }
}

private extension Language {
    /// Map the app's `Language` enum to the codes the Qwen3 config expects.
    /// "auto" is the model's default for anything we don't map explicitly.
    var qwenLanguageCode: String {
        switch self {
        case .english:  return "english"
        case .chinese:  return "chinese"
        case .japanese: return "japanese"
        case .korean:   return "korean"
        case .spanish, .french, .german: return "auto"
        }
    }
}
