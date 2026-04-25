//
//  VoiceCloneViewModel.swift
//  VoiceClone
//

import Combine
import Foundation

@MainActor
final class VoiceCloneViewModel: ObservableObject {

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

    /// When non-nil, the Base snapshot is missing. The view should render
    /// `MissingSnapshotPrompt(snapshot:)` instead of the cloning UI.
    @Published private(set) var missingSnapshot: ModelSnapshot?

    /// Set after a successful clone synthesis so the view can show "Save voice".
    @Published private(set) var canSaveVoice = false

    private let recorder = AudioRecorder()
    private var ttsService: MLXTTSService?
    private var audioEngine: AudioEngine?
    private var voiceStorage: VoiceStorage?
    private weak var downloadManager: ModelDownloadManager?
    private var referenceAudioURL: URL?
    private var referenceAudioData: Data?
    private var generatedChunks: [AudioChunk] = []
    private var generatedSamples: [Float] = []
    private var cancellables = Set<AnyCancellable>()

    var canSynthesize: Bool {
        missingSnapshot == nil &&
        !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        hasReferenceAudio &&
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

        await loadCapability()

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

        downloadManager.$snapshotStates
            .map { $0[ModelSnapshot.base] }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if case .installed = state, self.missingSnapshot != nil {
                    Task { await self.loadCapability() }
                }
            }
            .store(in: &cancellables)
    }

    func retrySetup() {
        Task { await loadCapability() }
    }

    private func loadCapability() async {
        guard let tts = ttsService else { return }
        do {
            try await tts.loadCapability(.voiceClone)
            missingSnapshot = nil
        } catch let TTSError.snapshotNotInstalled(snap) {
            missingSnapshot = snap
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

        isSynthesizing = true
        canSaveVoice = false
        generatedChunks = []
        generatedSamples = []
        waveformSamples = []
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
                text: targetText,
                language: language,
                referenceAudio: audioData,
                referenceText: referenceText
            )

            for try await chunk in stream {
                generatedChunks.append(chunk)
                generatedSamples.append(contentsOf: chunk.samples)
                waveformSamples = downsample(generatedSamples, to: 100)
                playbackContinuation?.yield(chunk)
            }

            canSaveVoice = !generatedChunks.isEmpty

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
