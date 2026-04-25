//
//  SynthesisViewModel.swift
//  VoiceClone
//

import Combine
import Foundation

/// One pickable item in the Speak tab's voice selector. Wraps either a
/// built-in preset or a user-saved Voice from the library.
enum VoiceOption: Identifiable, Hashable {
    case preset(PresetVoice)
    case saved(Voice)

    var id: String {
        switch self {
        case .preset(let p): return "preset:\(p.rawValue)"
        case .saved(let v):  return "saved:\(v.id.uuidString)"
        }
    }

    var name: String {
        switch self {
        case .preset(let p): return p.rawValue
        case .saved(let v):  return v.name
        }
    }

    /// The TTS capability needed to synthesize this option.
    var requiredCapability: TTSCapability {
        switch self {
        case .preset:
            return .customVoice
        case .saved(let v):
            switch v.type {
            case .preset, .custom: return .voiceDesign
            case .cloned:          return .voiceClone
            }
        }
    }
}

@MainActor
final class SynthesisViewModel: ObservableObject {

    @Published var text: String = ""
    @Published var language: Language = .english
    @Published var instruction: String = ""

    /// All pickable voices: built-in presets + saved custom/cloned voices.
    @Published private(set) var voiceOptions: [VoiceOption] = PresetVoice.allCases.map { .preset($0) }
    @Published var selectedOption: VoiceOption = .preset(.ryan)

    @Published private(set) var isSynthesizing = false
    @Published private(set) var isPlaying = false
    @Published private(set) var hasAudio = false
    @Published private(set) var playbackProgress: Double = 0
    @Published private(set) var waveformSamples: [Float] = []
    @Published private(set) var error: String?
    @Published private(set) var exportURL: URL?

    /// When non-nil, the selected option needs a snapshot we don't have yet.
    @Published private(set) var missingSnapshot: ModelSnapshot?

    private var ttsService: MLXTTSService?
    private var audioEngine: AudioEngine?
    private var voiceStorage: VoiceStorage?
    private weak var downloadManager: ModelDownloadManager?
    private var generatedChunks: [AudioChunk] = []
    private var generatedSamples: [Float] = []
    private var cancellables = Set<AnyCancellable>()

    var canSynthesize: Bool {
        missingSnapshot == nil &&
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSynthesizing &&
        ttsService?.state == .ready
    }

    func setup(ttsService: MLXTTSService,
               audioEngine: AudioEngine,
               voiceStorage: VoiceStorage,
               downloadManager: ModelDownloadManager) async {
        self.ttsService = ttsService
        self.audioEngine = audioEngine
        self.voiceStorage = voiceStorage
        self.downloadManager = downloadManager

        await reloadVoiceOptions()
        await loadCapabilityForSelection()

        ttsService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .synthesizing:
                    self?.isSynthesizing = true
                case .ready:
                    self?.isSynthesizing = false
                case .error(let msg):
                    self?.error = msg
                    self?.isSynthesizing = false
                default:
                    break
                }
            }
            .store(in: &cancellables)

        audioEngine.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isPlaying = value
            }
            .store(in: &cancellables)

        audioEngine.$currentTime
            .combineLatest(audioEngine.$duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] current, duration in
                guard duration > 0 else {
                    self?.playbackProgress = 0
                    return
                }
                self?.playbackProgress = min(1, max(0, current / duration))
            }
            .store(in: &cancellables)

        // Re-attempt capability load whenever a snapshot finishes downloading.
        downloadManager.$snapshotStates
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.missingSnapshot != nil {
                    Task { await self.loadCapabilityForSelection() }
                }
            }
            .store(in: &cancellables)

        // When the user picks a different voice, immediately update
        // `missingSnapshot` (cheap disk check) so the UI can render the
        // download prompt right away. The actual model load is deferred
        // until `synthesize()` runs — see comment there for why.
        $selectedOption
            .removeDuplicates()
            .dropFirst()  // initial value handled by setup
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMissingSnapshot()
            }
            .store(in: &cancellables)
    }

    /// Cheap, synchronous: just checks the filesystem for the snapshot the
    /// current selection needs. Used to show / hide the download prompt
    /// without kicking off a model load.
    private func refreshMissingSnapshot() {
        let needed = selectedOption.requiredCapability.requiredSnapshot
        missingSnapshot = ModelDownloadManager.isInstalled(needed) ? nil : needed
    }

    /// Refresh the voice picker — call after the Library tab adds/removes a
    /// voice, or after the Design/Clone tabs save a new one.
    func reloadVoiceOptions() async {
        guard let storage = voiceStorage else { return }
        do {
            let saved = try await storage.fetchVoices()
            var opts: [VoiceOption] = PresetVoice.allCases.map { .preset($0) }
            opts.append(contentsOf: saved.map { .saved($0) })
            self.voiceOptions = opts
            // If the currently selected saved voice was deleted, fall back.
            if !opts.contains(selectedOption) {
                selectedOption = .preset(.ryan)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func retrySetup() {
        Task { await loadCapabilityForSelection() }
    }

    private func loadCapabilityForSelection() async {
        guard let tts = ttsService else { return }
        let needed = selectedOption.requiredCapability
        do {
            try await tts.loadCapability(needed)
            missingSnapshot = nil
        } catch let TTSError.snapshotNotInstalled(snap) {
            missingSnapshot = snap
        } catch {
            self.error = error.localizedDescription
        }
    }

    func synthesize() async {
        guard let tts = ttsService else { return }

        // Make sure the snapshot for the selected voice is loaded before we
        // try to synthesize. Selecting a saved cloned voice triggers a Base
        // snapshot swap (~1.8 GB → ~5 s) that previously raced with the
        // user tapping Speak; awaiting it here closes the race. The call is
        // a cheap no-op when the right snapshot is already loaded.
        do {
            try await tts.loadCapability(selectedOption.requiredCapability)
            missingSnapshot = nil
        } catch let TTSError.snapshotNotInstalled(snap) {
            missingSnapshot = snap
            return
        } catch {
            self.error = error.localizedDescription
            return
        }

        isSynthesizing = true
        waveformSamples = []
        exportURL = nil
        generatedChunks = []
        generatedSamples = []

        var playbackContinuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
        var playbackTask: Task<Void, Error>?

        do {
            let playbackStream = AsyncThrowingStream<AudioChunk, Error> { continuation in
                playbackContinuation = continuation
            }
            playbackTask = Task {
                try await tts.playStream(playbackStream)
            }

            let stream = try await openSynthesisStream(tts: tts)

            for try await chunk in stream {
                generatedChunks.append(chunk)
                generatedSamples.append(contentsOf: chunk.samples)
                waveformSamples = downsample(generatedSamples, to: 100)
                playbackContinuation?.yield(chunk)
            }

            hasAudio = !generatedChunks.isEmpty

            playbackContinuation?.finish()
            if let playbackTask {
                do {
                    try await playbackTask.value
                } catch {
                    self.error = error.localizedDescription
                }
            }

        } catch {
            playbackContinuation?.finish(throwing: error)
            playbackTask?.cancel()
            self.error = error.localizedDescription
        }

        isSynthesizing = false
    }

    /// Pick the right `synthesize(...)` overload based on the selected option.
    /// Saved cloned voices need to load their reference audio off disk first.
    private func openSynthesisStream(tts: MLXTTSService) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        switch selectedOption {
        case .preset(let preset):
            return try await tts.synthesize(
                text: text,
                language: language,
                speaker: preset,
                instruction: instruction.isEmpty ? nil : instruction
            )

        case .saved(let voice):
            switch voice.type {
            case .preset, .custom:
                // Designed (instruction-only) voice — instruction stored on `voice.instruction`.
                let style = (voice.instruction ?? instruction)
                return try await tts.synthesize(
                    text: text,
                    language: language,
                    instruction: style
                )

            case .cloned:
                guard let storage = voiceStorage,
                      let refData = try await storage.referenceAudioData(for: voice.id) else {
                    throw TTSError.invalidReferenceAudio(
                        "Saved voice \"\(voice.name)\" is missing its reference recording."
                    )
                }
                return try await tts.synthesize(
                    text: text,
                    language: language,
                    referenceAudio: refData,
                    referenceText: voice.instruction ?? ""
                )
            }
        }
    }

    func togglePlayback() {
        guard let engine = audioEngine else { return }
        if isPlaying {
            engine.stop()
        } else if !generatedChunks.isEmpty {
            Task { [generatedChunks] in
                let playbackStream = AsyncThrowingStream<AudioChunk, Error> { continuation in
                    for chunk in generatedChunks {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                }
                try? await engine.playStream(playbackStream)
            }
        }
    }

    func seekForward() {
        guard let engine = audioEngine, !generatedChunks.isEmpty else {
            error = "No audio to seek."
            return
        }

        let seekAmount: TimeInterval = 5.0
        let totalDuration = Double(generatedSamples.count) / 24000.0
        let newTime = min(engine.currentTime + seekAmount, totalDuration)

        Task {
            do {
                try await engine.seek(
                    to: newTime,
                    totalDuration: totalDuration,
                    chunks: generatedChunks
                )
            } catch {
                self.error = "Seeking failed: \(error.localizedDescription)"
            }
        }
    }

    func seekBackward() {
        guard let engine = audioEngine, !generatedChunks.isEmpty else {
            error = "No audio to seek."
            return
        }

        let seekAmount: TimeInterval = 5.0
        let totalDuration = Double(generatedSamples.count) / 24000.0
        let newTime = max(engine.currentTime - seekAmount, 0)

        Task {
            do {
                try await engine.seek(
                    to: newTime,
                    totalDuration: totalDuration,
                    chunks: generatedChunks
                )
            } catch {
                self.error = "Seeking failed: \(error.localizedDescription)"
            }
        }
    }

    func export() {
        do {
            exportURL = try AudioExporter.exportWav(samples: generatedSamples, sampleRate: 24000)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearError() {
        error = nil
    }

    private func downsample(_ samples: [Float], to count: Int) -> [Float] {
        guard samples.count > count else { return samples }

        let chunkSize = samples.count / count
        return stride(from: 0, to: samples.count, by: chunkSize).map { start in
            let end = min(start + chunkSize, samples.count)
            let chunk = samples[start..<end]
            return chunk.max() ?? 0
        }
    }
}
