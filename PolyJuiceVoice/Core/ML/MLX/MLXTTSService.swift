//
//  MLXTTSService.swift
//  PolyJuiceVoice
//
//  Thin wrapper around the vendored Qwen3TTSModel (`Core/ML/MLX/Qwen3TTS/`).
//  Handles snapshot selection (CustomVoice vs Base vs VoiceDesign), lazy
//  load + hot-swap, and adapts the package's MLXArray output into the app's
//  AudioChunk streaming API.
//
//  Two performance shapes worth knowing:
//
//  1. Synthesis runs OFF the MainActor.
//     `model.generate(...)` is declared `async` but is internally synchronous —
//     awaiting it from a `@MainActor` method drags the entire token-by-token
//     loop onto the main thread and freezes the UI for the duration of the
//     synthesis. We hop to a detached background task for the actual model
//     call and only return to the MainActor to publish state + yield audio.
//
//  2. Long text is split into chunks at sentence boundaries.
//     One generation = one growing KV cache = one giant final decode. For a
//     500-character input that's ~30 s of audio and several GB of transient
//     MLXArrays, plus the user waits for the whole thing before hearing
//     anything. Splitting on sentences via `TextChunker` gives:
//        - audio yields chunk-by-chunk → playback starts after sentence 1
//        - per-chunk KV cache is freed before the next chunk runs
//        - peak memory stays bounded by a single chunk regardless of length
//

@preconcurrency import Foundation
@preconcurrency import MLX
import AVFoundation

/// TTS service backed by the vendored Qwen3TTS implementation.
@available(iOS 18.0, macOS 15.0, *)
@MainActor
final class MLXTTSService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var state: TTSServiceState = .idle
    @Published private(set) var loadedCapabilities: Set<TTSCapability> = []
    @Published private(set) var loadedSnapshot: ModelSnapshot?

    /// GPU peak memory observed during the last completed synthesis, in
    /// bytes. Zero until the first generation finishes. Useful as a runtime
    /// sanity check that inference is hitting the GPU — a value of 0 here
    /// after a non-trivial synthesis means MLX silently fell back to CPU.
    @Published private(set) var lastSynthesisPeakGPUBytes: Int = 0
    /// Wall-clock seconds for the last completed synthesis (model time
    /// only — excludes WAV decode / playback start).
    @Published private(set) var lastSynthesisDuration: TimeInterval = 0
    /// Number of text chunks the most recent synthesis was split into.
    @Published private(set) var lastSynthesisChunkCount: Int = 0

    // MARK: - Private state

    private var model: Qwen3TTSModel?
    private let audioEngine: AudioEngine

    // MARK: - Init

    private var memoryPressureObserver: NSObjectProtocol?

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        // React to OS memory warnings (iOS) / explicit pressure events:
        // drop the model and clear MLX caches so the app survives.
        self.memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: .appMemoryPressure,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                AppLog.warning("Memory pressure — unloading model and clearing GPU cache.", "synthesis")
                self?.unloadModel()
            }
        }
    }

    // NotificationCenter.default holds observers weakly — no deinit cleanup needed.

    // MARK: - Snapshot loading

    /// Load (and hot-swap if needed) the given snapshot. Caller — typically
    /// a feature view model — resolves the snapshot from `ModelSelectionStore`
    /// before this call. The service tracks `loadedSnapshot` and derives
    /// `loadedCapabilities` from `snapshot.capabilities`, so a Base snapshot
    /// covers both `voiceClone` and `customVoice` after one load.
    func load(_ snapshot: ModelSnapshot) async throws {
        // Already loaded the right snapshot? Nothing to do.
        if let current = loadedSnapshot, current == snapshot, model != nil {
            state = .ready
            return
        }

        // Surface "not installed" up front so the UI can prompt the user to
        // download instead of failing inside MLX.
        guard ModelDownloadManager.isInstalled(snapshot) else {
            state = .idle
            throw TTSError.snapshotNotInstalled(snapshot)
        }

        state = .loading
        do {
            // Drop the previous model first so two snapshots are never
            // resident simultaneously (the 1.7B + 0.6B combo would be ~6 GB).
            unloadModel()

            let dir = ModelDownloadManager.directory(for: snapshot)
            let loaded = try await Qwen3TTSModel.fromPretrained(dir.path)
            self.model = loaded
            self.loadedSnapshot = snapshot
            // Record every capability the new snapshot covers — avoids an
            // unnecessary reload when the user switches between, say, the
            // Speak and Clone tabs while a Base snapshot is loaded.
            self.loadedCapabilities = snapshot.capabilities
            self.state = .ready
        } catch {
            self.model = nil
            self.loadedSnapshot = nil
            self.loadedCapabilities = []
            self.state = .idle
            throw TTSError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Higher-level convenience: resolve the snapshot for `capability` via
    /// the given selection store and load it. Throws
    /// `capabilityNotConfigured` when the user hasn't picked a snapshot yet.
    func loadCapability(_ capability: TTSCapability,
                        using store: ModelSelectionStore) async throws {
        guard let snapshot = store.selected(for: capability) else {
            state = .idle
            throw TTSError.capabilityNotConfigured(capability)
        }
        try await load(snapshot)
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

    /// True when at least one snapshot is installed — i.e. the launch gate
    /// would let the app open.
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
        let chunks = TextChunker.chunk(text)
        guard !chunks.isEmpty else {
            continuation.finish(throwing: TTSError.tokenizationFailed)
            state = .error("Empty text")
            return
        }
        guard let model = model else {
            continuation.finish(throwing: TTSError.modelNotLoaded)
            state = .error("Model not loaded")
            return
        }

        await runChunks(
            chunks: chunks,
            sampleRate: model.sampleRate,
            continuation: continuation
        ) { chunkText in
            try await Self.generatePreset(
                model: model,
                text: chunkText,
                speaker: speaker,
                instruction: instruction,
                language: language.qwenLanguageCode
            )
        }
    }

    private func runDesign(
        text: String,
        language: Language,
        instruction: String,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        let chunks = TextChunker.chunk(text)
        guard !chunks.isEmpty else {
            continuation.finish(throwing: TTSError.tokenizationFailed)
            state = .error("Empty text")
            return
        }
        guard let model = model else {
            continuation.finish(throwing: TTSError.modelNotLoaded)
            state = .error("Model not loaded")
            return
        }

        await runChunks(
            chunks: chunks,
            sampleRate: model.sampleRate,
            continuation: continuation
        ) { chunkText in
            try await Self.generateDesign(
                model: model,
                text: chunkText,
                instruction: instruction,
                language: language.qwenLanguageCode
            )
        }
    }

    private func runClone(
        text: String,
        language: Language,
        referenceAudioData: Data,
        referenceText: String,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async {
        let trimmedRef = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cloning chunks slightly larger because each chunk re-runs the
        // whole ICL setup — fewer chunks means less overhead.
        let chunks = TextChunker.chunk(text, maxCharacters: 320)
        guard !chunks.isEmpty, !trimmedRef.isEmpty else {
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

        // Decode reference audio once, before the loop — it's the same for
        // every chunk.
        let refSamples: [Float]
        do {
            refSamples = try Self.loadReferenceAudio(referenceAudioData)
        } catch {
            continuation.finish(throwing: error)
            state = .error(error.localizedDescription)
            return
        }

        await runChunks(
            chunks: chunks,
            sampleRate: model.sampleRate,
            continuation: continuation
        ) { chunkText in
            try await Self.generateClone(
                model: model,
                text: chunkText,
                referenceSamples: refSamples,
                referenceText: trimmedRef,
                language: language.qwenLanguageCode
            )
        }
    }

    /// Shared chunked-synthesis driver. Runs each chunk's `generate(...)` on
    /// a detached task (off the MainActor), yields its audio, frees the GPU
    /// cache, then proceeds to the next chunk. Updates `state.synthesizing`
    /// progress between chunks.
    private func runChunks(
        chunks: [String],
        sampleRate: Int,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation,
        generate: @escaping @Sendable (String) async throws -> [Float]
    ) async {
        state = .synthesizing(progress: 0)
        let probe = startGenerationProbe()
        lastSynthesisChunkCount = chunks.count

        for (index, chunkText) in chunks.enumerated() {
            do {
                // Heavy lift on a detached task — keeps the MainActor free
                // so SwiftUI redraws and user input keep responding.
                let samples = try await Task.detached(priority: .userInitiated) {
                    try await generate(chunkText)
                }.value

                let chunk = AudioChunk(
                    samples: samples,
                    sampleRate: sampleRate,
                    timestamp: Date().timeIntervalSince1970
                )
                continuation.yield(chunk)

                // Release MLX scratch buffers from this chunk's KV cache so
                // the next chunk doesn't compound peak memory.
                GPU.clearCache()

                // Progress = fraction of chunks completed.
                let progress = Double(index + 1) / Double(chunks.count)
                state = .synthesizing(progress: progress)
            } catch {
                continuation.finish(throwing: error)
                finishGenerationProbe(probe)
                state = .error(error.localizedDescription)
                return
            }
        }

        continuation.finish()
        finishGenerationProbe(probe)
        state = .ready
    }

    // MARK: - Off-actor generators
    //
    // `nonisolated static` so they can be called from a `Task.detached`
    // without dragging MainActor isolation along. The model is passed in
    // explicitly so the closure capture list stays Sendable-clean.

    nonisolated private static func generatePreset(
        model: Qwen3TTSModel,
        text: String,
        speaker: String,
        instruction: String?,
        language: String
    ) async throws -> [Float] {
        let audio = try await model.generate(
            text: text,
            speaker: speaker,
            instruct: instruction,
            language: language
        )
        return materialize(audio)
    }

    nonisolated private static func generateDesign(
        model: Qwen3TTSModel,
        text: String,
        instruction: String,
        language: String
    ) async throws -> [Float] {
        let audio = try await model.generate(
            text: text,
            speaker: nil,
            instruct: instruction,
            language: language
        )
        return materialize(audio)
    }

    nonisolated private static func generateClone(
        model: Qwen3TTSModel,
        text: String,
        referenceSamples: [Float],
        referenceText: String,
        language: String
    ) throws -> [Float] {
        let refArray = MLXArray(referenceSamples)
        let audio = try model.generateClonedVoice(
            text: text,
            referenceAudio: refArray,
            referenceText: referenceText,
            language: language
        )
        return materialize(audio)
    }

    /// Force MLX to materialise the array on the GPU and pull the resulting
    /// samples back as a Swift `[Float]`. This is the single sync point
    /// per chunk.
    nonisolated private static func materialize(_ audio: MLXArray) -> [Float] {
        eval(audio)
        return audio.asArray(Float.self)
    }

    // MARK: - GPU diagnostics

    /// Reset MLX peak-memory tracking and capture a wall-clock start time.
    /// Used to verify each generation actually hit the GPU.
    private func startGenerationProbe() -> (start: CFAbsoluteTime, baseline: Int) {
        let baseline = GPU.peakMemory
        GPU.resetPeakMemory()
        return (CFAbsoluteTimeGetCurrent(), baseline)
    }

    /// Read the GPU peak after generation, log it, and publish for the UI.
    /// A non-zero peak proves the work landed on Metal; a zero peak after
    /// a non-trivial synthesis means we silently fell back to CPU.
    private func finishGenerationProbe(_ probe: (start: CFAbsoluteTime, baseline: Int)) {
        let elapsed = CFAbsoluteTimeGetCurrent() - probe.start
        let peak = GPU.peakMemory
        lastSynthesisDuration = elapsed
        lastSynthesisPeakGPUBytes = peak
        let mb = Double(peak) / (1024.0 * 1024.0)
        AppLog.notice(String(
            format: "synthesis done in %.2fs over %d chunks — GPU peak %.1f MB",
            elapsed, lastSynthesisChunkCount, mb
        ), "synthesis")
    }

    // MARK: - Reference audio decoding

    /// Decode a recorded WAV blob into a 24 kHz mono Float32 sample array
    /// suitable for `Qwen3TTSModel.generateClonedVoice`. The recorder writes
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
