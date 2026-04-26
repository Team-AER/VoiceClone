//
//  VoiceCloningViewModel.swift
//  PolyJuiceVoice
//

import Combine
import Foundation

@MainActor
final class VoiceCloningViewModel: ObservableObject {

    @Published var targetText: String = ""
    @Published var referenceText: String = ""
    @Published var language: Language = .english

    @Published private(set) var isRecording = false
    @Published private(set) var recordingTime: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var hasReferenceAudio = false

    @Published private(set) var isSynthesizing = false
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackProgress: Double = 0
    @Published private(set) var waveformSamples: [Float] = []
    @Published private(set) var error: String?
    @Published private(set) var exportURL: URL?

    /// When non-nil, the user hasn't configured a model for voice cloning yet
    /// (or the one they picked has been deleted). View shows
    /// `MissingCapabilityPrompt(capability:)` instead of the cloning UI.
    @Published private(set) var unconfiguredCapability: TTSCapability?

    /// Set after a successful clone synthesis so the view can show "Save voice".
    @Published private(set) var canSaveVoice = false

    private let recorder = AudioRecorder()
    private var ttsService: MLXTTSService?
    private var audioEngine: AudioEngine?
    private var voiceStorage: VoiceStorage?
    private weak var downloadManager: ModelDownloadManager?
    private var selectionStore: ModelSelectionStore?
    private var referenceAudioURL: URL?
    private var referenceAudioData: Data?
    /// Disk-backed canonical state for the most recent synthesis. Replaces
    /// the per-chunk in-memory `[Float]` accumulators that were the dominant
    /// memory hotspot during/after generation.
    private var audioFileURL: URL?
    private var cancellables = Set<AnyCancellable>()

    var canSynthesize: Bool {
        unconfiguredCapability == nil &&
        !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        hasReferenceAudio &&
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

        recorder.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isRecording = value
            }
            .store(in: &cancellables)

        recorder.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.recordingTime = value
            }
            .store(in: &cancellables)

        recorder.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.audioLevel = value
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
        if let snap = store.selected(for: .voiceClone),
           ModelDownloadManager.isInstalled(snap) {
            unconfiguredCapability = nil
        } else {
            unconfiguredCapability = .voiceClone
        }
    }

    func retrySetup() {
        Task { await loadCapability() }
    }

    private func loadCapability() async {
        guard let tts = ttsService, let store = selectionStore else { return }
        do {
            try await tts.loadCapability(.voiceClone, using: store)
            unconfiguredCapability = nil
        } catch TTSError.capabilityNotConfigured {
            unconfiguredCapability = .voiceClone
        } catch TTSError.snapshotNotInstalled {
            unconfiguredCapability = .voiceClone
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggleRecording() {
        Task {
            if isRecording {
                do {
                    let result = try recorder.stopRecording()
                    referenceAudioURL = result.url
                    referenceAudioData = try? Data(contentsOf: result.url)
                    hasReferenceAudio = true
                } catch {
                    self.error = error.localizedDescription
                }
            } else {
                do {
                    referenceAudioURL = try await recorder.startRecording()
                    hasReferenceAudio = false
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func synthesize() async {
        guard let tts = ttsService, let audioData = referenceAudioData else { return }

        // Pre-flight: validate target text + reference transcript.
        let targetResult = TextSanitizer.sanitize(targetText)
        guard let cleanedTarget = targetResult.sanitized else {
            self.error = targetResult.message
            return
        }
        let refResult = TextSanitizer.sanitize(referenceText)
        guard let cleanedRef = refResult.sanitized else {
            self.error = "Reference transcript: " + (refResult.message ?? "invalid")
            return
        }
        self.targetText = cleanedTarget
        self.referenceText = cleanedRef

        // Defensive: ensure the user's selected snapshot is loaded.
        // Idempotent when already loaded. Same race-fix as the Speak tab:
        // prevents "Capability not loaded: voiceClone" errors when the user
        // records, types, and taps Clone before setup completes.
        guard let store = selectionStore else { return }
        isSynthesizing = true
        do {
            try await tts.loadCapability(.voiceClone, using: store)
            unconfiguredCapability = nil
        } catch TTSError.capabilityNotConfigured {
            unconfiguredCapability = .voiceClone
            isSynthesizing = false
            return
        } catch TTSError.snapshotNotInstalled {
            unconfiguredCapability = .voiceClone
            isSynthesizing = false
            return
        } catch {
            self.error = error.localizedDescription
            isSynthesizing = false
            return
        }
        canSaveVoice = false
        waveformSamples = []
        exportURL = nil
        if let previous = audioFileURL {
            try? FileManager.default.removeItem(at: previous)
            audioFileURL = nil
        }

        let writer: IncrementalAudioWriter
        do {
            writer = try IncrementalAudioWriter(sampleRate: 24000)
        } catch {
            self.error = error.localizedDescription
            isSynthesizing = false
            return
        }

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
                text: targetText,
                language: language,
                referenceAudio: audioData,
                referenceText: referenceText
            )

            for try await chunk in stream {
                try writer.append(chunk.samples)
                waveformSamples = writer.peaks
                playbackContinuation?.yield(chunk)
            }

            playbackContinuation?.finish()
            if let playbackTask {
                do {
                    try await playbackTask.value
                } catch {
                    self.error = error.localizedDescription
                }
            }

            if writer.sampleCount > 0 {
                audioFileURL = writer.finalize()
                canSaveVoice = true
            } else {
                writer.discard()
            }
        } catch {
            writer.discard()
            playbackContinuation?.finish(throwing: error)
            playbackTask?.cancel()
            self.error = error.localizedDescription
        }

        isSynthesizing = false
    }

    /// Persist this clone (reference audio + transcript) to the library so the
    /// user can re-synthesize new text later in the same voice.
    /// VoiceStorage copies the recording to its managed `Voices/` directory.
    func saveVoice(name: String) async {
        guard let storage = voiceStorage,
              let refURL = referenceAudioURL else {
            self.error = "Reference recording is no longer available."
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let voice = Voice(
            id: UUID(),
            name: trimmed,
            type: .cloned,
            language: language,
            createdAt: Date(),
            instruction: referenceText,   // reused as the reference transcript
            referenceAudioURL: refURL,
            embeddingData: nil
        )
        do {
            try await storage.saveVoice(voice)
            canSaveVoice = false
        } catch {
            self.error = error.localizedDescription
            return
        }

        // Extract and persist the voice embedding so repeat synthesis in the
        // Voice Library skips the speech-tokenizer encoder step (~200–400 ms
        // saved per call, ~250 MB peak memory avoided on iOS).
        let voiceID = voice.id
        let refData = try? await storage.referenceAudioData(for: voiceID)
        if let refData, let model = ttsService?.currentModel {
            Task.detached(priority: .utility) { [weak storage] in
                guard let embedding = try? MLXTTSService.extractVoiceEmbedding(
                    model: model,
                    referenceAudio: refData
                ) else { return }
                try? await storage?.updateEmbedding(embedding, for: voiceID)
                AppLog.info("Voice embedding cached for \(voiceID).", "cloning")
            }
        }
    }

    func togglePlayback() {
        guard let engine = audioEngine else { return }
        if isPlaying {
            engine.stop()
        } else if let url = audioFileURL {
            Task {
                try? await engine.playFile(url)
            }
        }
    }

    func clearError() {
        error = nil
    }

    func export() {
        guard let url = audioFileURL else {
            self.error = "No audio to export."
            return
        }
        do {
            exportURL = try AudioExporter.exportWav(from: url)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
