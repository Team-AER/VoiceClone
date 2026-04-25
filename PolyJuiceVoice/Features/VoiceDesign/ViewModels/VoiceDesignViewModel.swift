//
//  VoiceDesignViewModel.swift
//  PolyJuiceVoice
//

import Combine
import Foundation

@MainActor
final class VoiceDesignViewModel: ObservableObject {

    @Published var text: String = ""
    @Published var language: Language = .english
    @Published var instruction: String = ""

    @Published private(set) var isSynthesizing = false
    @Published private(set) var isPlaying = false
    @Published private(set) var hasAudio = false
    @Published private(set) var playbackProgress: Double = 0
    @Published private(set) var waveformSamples: [Float] = []
    @Published private(set) var error: String?
    @Published private(set) var exportURL: URL?

    /// When non-nil, the user hasn't configured a model for voice design yet
    /// (or the one they picked has been deleted). View shows
    /// `MissingCapabilityPrompt(capability:)` instead of the synth UI.
    @Published private(set) var unconfiguredCapability: TTSCapability?

    /// Set after a successful synthesis so the view can show "Save voice".
    @Published private(set) var canSaveVoice = false

    private var ttsService: MLXTTSService?
    private var audioEngine: AudioEngine?
    private var voiceStorage: VoiceStorage?
    private weak var downloadManager: ModelDownloadManager?
    private var selectionStore: ModelSelectionStore?
    private var generatedChunks: [AudioChunk] = []
    private var generatedSamples: [Float] = []
    private var cancellables = Set<AnyCancellable>()

    var canSynthesize: Bool {
        unconfiguredCapability == nil &&
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSynthesizing
    }

    func setup(ttsService: MLXTTSService,
               audioEngine: AudioEngine,
               voiceStorage: VoiceStorage,
               downloadManager: ModelDownloadManager,
               selectionStore: ModelSelectionStore) async {
        self.ttsService = ttsService
        self.audioEngine = audioEngine
        self.voiceStorage = voiceStorage
        self.downloadManager = downloadManager
        self.selectionStore = selectionStore

        refreshUnconfiguredCapability()

        ttsService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .loading, .synthesizing:
                    self?.isSynthesizing = true
                case .ready, .idle:
                    self?.isSynthesizing = false
                case .error(let msg):
                    self?.error = msg
                    self?.isSynthesizing = false
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

        // Re-attempt capability load whenever the user's selection or any
        // snapshot install state changes — flips the UI from "needs setup"
        // → "ready" automatically once the chosen variant lands.
        downloadManager.$snapshotStates
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshUnconfiguredCapability()
            }
            .store(in: &cancellables)

        selectionStore.$selections
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshUnconfiguredCapability()
            }
            .store(in: &cancellables)
    }

    private func refreshUnconfiguredCapability() {
        guard let store = selectionStore else { return }
        if let snap = store.selected(for: .voiceDesign),
           ModelDownloadManager.isInstalled(snap) {
            unconfiguredCapability = nil
        } else {
            unconfiguredCapability = .voiceDesign
        }
    }

    /// Re-attempt model load — call after the user dismisses the Model
    /// Manager sheet so the tab unblocks immediately if the download landed.
    func retrySetup() {
        Task { await loadCapability() }
    }

    private func loadCapability() async {
        guard let tts = ttsService, let store = selectionStore else { return }
        do {
            try await tts.loadCapability(.voiceDesign, using: store)
            unconfiguredCapability = nil
        } catch TTSError.capabilityNotConfigured {
            unconfiguredCapability = .voiceDesign
        } catch TTSError.snapshotNotInstalled {
            unconfiguredCapability = .voiceDesign
        } catch {
            self.error = error.localizedDescription
        }
    }

    func synthesize() async {
        guard let tts = ttsService else { return }

        // Pre-flight: validate text + instruction before model load.
        let textResult = TextSanitizer.sanitize(text)
        guard let cleanedText = textResult.sanitized else {
            self.error = textResult.message
            return
        }
        let instrResult = TextSanitizer.sanitize(instruction)
        guard let cleanedInstr = instrResult.sanitized else {
            self.error = "Voice description: " + (instrResult.message ?? "invalid")
            return
        }
        self.text = cleanedText
        self.instruction = cleanedInstr

        // Defensive: ensure the user's selected snapshot is loaded.
        // Idempotent when already loaded; closes any race with the setup
        // load still being in flight (e.g. the user navigated to this tab
        // and tapped Generate before the model finished swapping in).
        guard let store = selectionStore else { return }
        do {
            try await tts.loadCapability(.voiceDesign, using: store)
            unconfiguredCapability = nil
        } catch TTSError.capabilityNotConfigured {
            unconfiguredCapability = .voiceDesign
            return
        } catch TTSError.snapshotNotInstalled {
            unconfiguredCapability = .voiceDesign
            return
        } catch {
            self.error = error.localizedDescription
            return
        }

        isSynthesizing = true
        canSaveVoice = false
        waveformSamples = []
        generatedChunks = []
        generatedSamples = []
        exportURL = nil

        var playbackContinuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
        var playbackTask: Task<Void, Error>?

        do {
            let playbackStream = AsyncThrowingStream<AudioChunk, Error> { continuation in
                playbackContinuation = continuation
            }
            playbackTask = Task {
                try await tts.playStream(playbackStream)
            }

            let stream = try await tts.synthesize(
                text: text,
                language: language,
                instruction: instruction
            )

            for try await chunk in stream {
                generatedChunks.append(chunk)
                generatedSamples.append(contentsOf: chunk.samples)
                waveformSamples = downsample(generatedSamples, to: 100)
                playbackContinuation?.yield(chunk)
            }

            hasAudio = !generatedChunks.isEmpty
            canSaveVoice = hasAudio

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

    /// Persist this designed voice (instruction-only) to the library so the
    /// user can re-synthesize new text later with the same vocal style.
    func saveVoice(name: String) async {
        guard let storage = voiceStorage else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let voice = Voice(
            id: UUID(),
            name: trimmed,
            type: .custom,
            language: language,
            createdAt: Date(),
            instruction: instruction,
            referenceAudioURL: nil,
            embeddingData: nil
        )
        do {
            try await storage.saveVoice(voice)
            canSaveVoice = false
        } catch {
            self.error = error.localizedDescription
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

    func clearError() {
        error = nil
    }

    func export() {
        do {
            exportURL = try AudioExporter.exportWav(samples: generatedSamples, sampleRate: 24000)
        } catch {
            self.error = error.localizedDescription
        }
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
