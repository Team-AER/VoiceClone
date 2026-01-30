//
//  VoiceDesignViewModel.swift
//  VoiceClone
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

    private var ttsService: MLXTTSService?
    private var audioEngine: AudioEngine?
    private var generatedChunks: [AudioChunk] = []
    private var generatedSamples: [Float] = []
    private var cancellables = Set<AnyCancellable>()

    var canSynthesize: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSynthesizing &&
        ttsService?.state == .ready
    }

    func setup(ttsService: MLXTTSService, audioEngine: AudioEngine) async {
        self.ttsService = ttsService
        self.audioEngine = audioEngine

        do {
            try await ttsService.loadCapability(.voiceDesign)
        } catch {
            self.error = error.localizedDescription
        }

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
    }

    func synthesize() async {
        guard let tts = ttsService else { return }

        isSynthesizing = true
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
