//
//  MLXTTSService.swift
//  VoiceClone
//
//  Thin wrapper around the vendored Qwen3TTSModel (`Core/ML/MLX/Qwen3TTS/`).
//  Handles snapshot selection (CustomVoice vs Base vs VoiceDesign), lazy
//  load + hot-swap, and adapts the package's MLXArray output into the app's
//  AudioChunk streaming API.
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
    @Published private(set) var loadedSnapshot: ModelSnapshot?

    // MARK: - Private state

    private var model: Qwen3TTSModel?
    private let audioEngine: AudioEngine

    // MARK: - Init

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }

    // MARK: - Capability loading

    /// Load (and hot-swap if needed) the model snapshot that backs `capability`.
    /// Subsequent `synthesize(...)` calls require a matching capability load.
    func loadCapability(_ capability: TTSCapability) async throws {
        let target = capability.requiredSnapshot

        // Already loaded the right snapshot? Nothing to do.
        if let current = loadedSnapshot, current == target, model != nil {
            loadedCapabilities.insert(capability)
            state = .ready
            return
        }

        // Need to swap. Surface "not installed" up front so the UI can prompt
        // the user to download instead of failing inside MLX.
        guard ModelDownloadManager.isInstalled(target) else {
            state = .idle
            throw TTSError.snapshotNotInstalled(target)
        }

        state = .loading
        do {
            // Drop the previous model first so two snapshots are never
            // resident simultaneously (the 1.7B + 0.6B combo would be ~6 GB).
            unloadModel()

            let dir = ModelDownloadManager.directory(for: target)
            let loaded = try await Qwen3TTSModel.fromPretrained(dir.path)
            self.model = loaded
            self.loadedSnapshot = target
            // Record every capability the new snapshot covers — this avoids
            // an unnecessary reload if the user immediately switches tabs.
            self.loadedCapabilities = target.capabilities
            self.state = .ready
        } catch {
            self.model = nil
            self.loadedSnapshot = nil
            self.loadedCapabilities = []
            self.state = .idle
            throw TTSError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Drop the in-memory model. Cheap to call; safe to call when no model is
    /// loaded. The next `loadCapability(...)` will reload from disk.
    func unloadModel() {
        model = nil
        loadedSnapshot = nil
        loadedCapabilities = []
        // Free MLX-side caches too.
        GPU.clearCache()
    }

    // MARK: - Synthesis — voice design

    func synthesize(
        text: String,
        language: Language,
        instruction: String
    ) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        try requireCapability(.voiceDesign)
        return makeStream { [weak self] continuation in
            await self?.runDesign(
                text: text,
                language: language,
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
            await self?.runPreset(
                text: text,
                language: language,
                speaker: speaker.rawValue,
                instruction: instruction,
                continuation: continuation
            )
        }
    }

    /// Synthesize using a previously cloned voice (loaded from VoiceStorage).
    /// The reference audio + transcript are required because the Base model
    /// re-extracts ICL conditioning on every generation — we don't persist
    /// extracted embeddings yet.
    func synthesize(
        text: String,
        language: Language,
        referenceAudio: Data,
        referenceText: String
    ) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        try requireCapability(.voiceClone)
        return makeStream { [weak self] continuation in
            await self?.runClone(
                text: text,
                language: language,
                referenceAudioData: referenceAudio,
                referenceText: referenceText,
                continuation: continuation
            )
        }
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

    /// True when at least the required CustomVoice snapshot is on disk —
    /// i.e. the launch gate would let the app open.
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

    // MARK: - Run paths

    private func runPreset(
        text: String,
        language: Language,
        speaker: String,
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
            // Both CustomVoice and Base snapshots route preset synthesis
            // through `generate(...)`, which dispatches by tts_model_type.
            let audio = try await model.generate(
                text: text,
                speaker: speaker,
                instruct: instruction,
                language: language.qwenLanguageCode
            )
            try yieldAudio(audio, sampleRate: model.sampleRate, to: continuation)
            state = .ready
        } catch {
            continuation.finish(throwing: error)
            state = .error(error.localizedDescription)
        }
    }

    private func runDesign(
        text: String,
        language: Language,
        instruction: String,
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
            // VoiceDesign snapshot ignores `speaker`; passing nil routes to
            // generateVoiceDesign() inside the dispatcher.
            let audio = try await model.generate(
                text: text,
                speaker: nil,
                instruct: instruction,
                language: language.qwenLanguageCode
            )
            try yieldAudio(audio, sampleRate: model.sampleRate, to: continuation)
            state = .ready
        } catch {
            continuation.finish(throwing: error)
            state = .error(error.localizedDescription)
        }
    }

    private func runClone(
        text: String,
        language: Language,
        referenceAudioData: Data,
        referenceText: String,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRef = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !trimmedRef.isEmpty else {
            continuation.finish(throwing: TTSError.tokenizationFailed)
            state = .error("Text and reference transcript are required")
            return
        }
        guard let model = model else {
            continuation.finish(throwing: TTSError.modelNotLoaded)
            state = .error("Model not loaded")
            return
        }
        guard model.supportsVoiceCloning else {
            continuation.finish(throwing: TTSError.synthesisError(
                "The loaded model snapshot (\(model.ttsModelType)) does not support voice cloning. " +
                "Install the Base snapshot from the Model Manager."
            ))
            state = .error("Snapshot does not support cloning")
            return
        }

        state = .synthesizing(progress: 0)
        do {
            let refSamples = try Self.loadReferenceAudio(referenceAudioData)
            let refArray = MLXArray(refSamples)
            let audio = try model.generateVoiceClone(
                text: trimmedText,
                referenceAudio: refArray,
                referenceText: trimmedRef,
                language: language.qwenLanguageCode
            )
            try yieldAudio(audio, sampleRate: model.sampleRate, to: continuation)
            state = .ready
        } catch {
            continuation.finish(throwing: error)
            state = .error(error.localizedDescription)
        }
    }

    private func yieldAudio(
        _ audio: MLXArray,
        sampleRate: Int,
        to continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) throws {
        eval(audio)
        let samples = audio.asArray(Float.self)
        let chunk = AudioChunk(
            samples: samples,
            sampleRate: sampleRate,
            timestamp: Date().timeIntervalSince1970
        )
        continuation.yield(chunk)
        continuation.finish()
    }

    // MARK: - Reference audio decoding

    /// Decode a recorded WAV blob into a 24 kHz mono Float32 sample array
    /// suitable for `Qwen3TTSModel.generateVoiceClone`. The recorder writes
    /// 24 kHz mono PCM16 little-endian WAVs (`AudioRecorder.startRecording`),
    /// but this helper resamples + downmixes anyway so that "import from
    /// file" paths added later don't have to care.
    static func loadReferenceAudio(_ data: Data) throws -> [Float] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc_ref_\(UUID().uuidString).wav")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: tmp)
        } catch {
            throw TTSError.invalidReferenceAudio(
                "Could not open recording: \(error.localizedDescription)"
            )
        }

        let inFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else {
            throw TTSError.invalidReferenceAudio("Recording is empty.")
        }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else {
            throw TTSError.invalidReferenceAudio("Could not allocate input buffer.")
        }
        do {
            try file.read(into: inBuffer)
        } catch {
            throw TTSError.invalidReferenceAudio(
                "Could not read recording: \(error.localizedDescription)"
            )
        }

        // Convert to 24 kHz mono Float32.
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ) else {
            throw TTSError.invalidReferenceAudio("Could not build target format.")
        }

        let needsConversion = inFormat.sampleRate != target.sampleRate
            || inFormat.channelCount != target.channelCount
            || inFormat.commonFormat != target.commonFormat

        let outBuffer: AVAudioPCMBuffer
        if needsConversion {
            guard let converter = AVAudioConverter(from: inFormat, to: target) else {
                throw TTSError.invalidReferenceAudio("Could not build converter.")
            }
            let ratio = target.sampleRate / inFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 64)
            guard let buf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else {
                throw TTSError.invalidReferenceAudio("Could not allocate output buffer.")
            }
            var supplied = false
            var err: NSError?
            converter.convert(to: buf, error: &err) { _, status in
                if supplied {
                    status.pointee = .endOfStream
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return inBuffer
            }
            if let err = err {
                throw TTSError.invalidReferenceAudio(err.localizedDescription)
            }
            outBuffer = buf
        } else {
            outBuffer = inBuffer
        }

        guard let channelData = outBuffer.floatChannelData?[0] else {
            throw TTSError.invalidReferenceAudio("No float channel data after conversion.")
        }
        let count = Int(outBuffer.frameLength)
        guard count > 0 else {
            throw TTSError.invalidReferenceAudio("Converted recording is empty.")
        }
        return Array(UnsafeBufferPointer(start: channelData, count: count))
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
