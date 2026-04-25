//
//  AudioEngine.swift
//  VoiceClone
//

import AVFoundation
import Foundation

/// Manages audio playback with streaming support.
///
/// Handles `AVAudioSession.interruptionNotification` on iOS so a phone call,
/// alarm, or Siri prompt cleanly pauses playback (instead of silently dropping
/// audio or crashing). Also reacts to `mediaServicesWereResetNotification`
/// (rare; mostly headphone-driver crashes) by tearing the engine down so the
/// next `playStream(...)` rebuilds from scratch.
@MainActor
final class AudioEngine: ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// True after an interruption (phone call etc.) paused us; used by
    /// view models to know whether `resume()` is meaningful.
    @Published private(set) var isInterrupted = false

    private lazy var playerNode = AVAudioPlayerNode()
    private lazy var engine: AVAudioEngine = {
        let e = AVAudioEngine()
        e.attach(playerNode)
        e.connect(playerNode, to: e.mainMixerNode, format: format)
        return e
    }()
    private let format: AVAudioFormat

    private var ticker: PlaybackTimeTicker?
    private var scheduledBuffers: Int = 0
    private var completedBuffers: Int = 0
    private var interruptionObservers: [NSObjectProtocol] = []

    init(sampleRate: Double = 24000) {
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        registerForInterruptions()
    }
    // No deinit-time observer removal: NotificationCenter.default holds weak
    // refs (iOS 9+/macOS 10.11+) so observers fall away when self is freed.

    func playStream(_ stream: AsyncThrowingStream<AudioChunk, Error>) async throws {
        configureAudioSessionIfNeeded()
        try engine.start()
        playerNode.play()
        isPlaying = true

        duration = 0
        scheduledBuffers = 0
        completedBuffers = 0

        startTimeTracking()

        do {
            for try await chunk in stream {
                let buffer = try createBuffer(from: chunk)
                duration += Double(buffer.frameLength) / buffer.format.sampleRate
                scheduleBuffer(buffer)
            }

            await waitForPlaybackCompletion()
        } catch {
            stop()
            throw error
        }

        stop()
    }

    func play(audio: Data, format: AudioFormat) async throws {
        let buffer = try decodeAudio(data: audio, format: format)

        configureAudioSessionIfNeeded()
        try engine.start()
        playerNode.play()
        isPlaying = true

        duration = Double(buffer.frameLength) / buffer.format.sampleRate
        startTimeTracking()

        await withCheckedContinuation { continuation in
            playerNode.scheduleBuffer(buffer) {
                Task { @MainActor in
                    continuation.resume()
                }
            }
        }

        stop()
    }

    func stop() {
        playerNode.stop()
        engine.stop()
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTimeTracking()
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
    }

    func resume() {
        playerNode.play()
        isPlaying = true
    }

    func seek(to time: TimeInterval, totalDuration: TimeInterval, chunks: [AudioChunk]) async throws {
        guard time >= 0, time <= totalDuration else { return }

        stop()

        var elapsed: TimeInterval = 0
        var startChunkIndex = 0
        var offsetInChunk = 0

        for (index, chunk) in chunks.enumerated() {
            let chunkDuration = Double(chunk.samples.count) / Double(chunk.sampleRate)
            if elapsed + chunkDuration >= time {
                startChunkIndex = index
                offsetInChunk = Int((time - elapsed) * Double(chunk.sampleRate))
                break
            }
            elapsed += chunkDuration
        }

        let remainingStream = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in startChunkIndex..<chunks.count {
                    var chunk = chunks[index]
                    if index == startChunkIndex && offsetInChunk > 0 {
                        let remainingSamples = Array(chunk.samples[offsetInChunk...])
                        chunk = AudioChunk(
                            samples: remainingSamples,
                            sampleRate: chunk.sampleRate,
                            timestamp: chunk.timestamp
                        )
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }

        currentTime = time
        try await playStream(remainingStream)
    }

    // MARK: - Private

    private func configureAudioSessionIfNeeded() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
        // macOS: AVAudioEngine handles device routing automatically; no session setup needed.
    }

    // MARK: - Interruption handling

    private func registerForInterruptions() {
        #if os(iOS)
        let center = NotificationCenter.default

        // Phone call, Siri, alarm, etc.
        // Important (Swift 6 strict concurrency): `Notification` is not
        // Sendable, so we extract the primitive UInts we need from
        // `note.userInfo` synchronously *before* the Task hop, then pass
        // those across the actor boundary instead of the whole notification.
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                self?.handleInterruption(typeRaw: typeRaw, optsRaw: optsRaw)
            }
        }
        interruptionObservers.append(interruption)

        // Driver reset (rare but recoverable). Tear the engine down; next
        // playStream() rebuilds from scratch.
        let reset = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                AppLog.warning("Audio media services were reset — rebuilding engine.", "audio")
                self?.stop()
            }
        }
        interruptionObservers.append(reset)

        // Headphones unplugged → pause (Apple HIG)
        let route = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        }
        interruptionObservers.append(route)

        // App backgrounded → pause (we don't claim background audio).
        let bg = center.addObserver(
            forName: .appWillBackground,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                AppLog.info("App backgrounding — pausing playback.", "audio")
                self?.pauseForInterruption()
            }
        }
        interruptionObservers.append(bg)
        #endif
    }

    #if os(iOS)
    private func handleInterruption(typeRaw: UInt?, optsRaw: UInt?) {
        guard let raw = typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            AppLog.info("Audio session interrupted — pausing playback.", "audio")
            pauseForInterruption()
        case .ended:
            let opts = optsRaw.map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if opts.contains(.shouldResume) {
                AppLog.info("Interruption ended — resuming playback.", "audio")
                resumeAfterInterruption()
            } else {
                AppLog.info("Interruption ended; staying paused per system hint.", "audio")
            }
        @unknown default: break
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        guard let raw = reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable {
            AppLog.info("Audio output device unplugged — pausing.", "audio")
            pauseForInterruption()
        }
    }
    #endif

    private func pauseForInterruption() {
        guard isPlaying else { return }
        playerNode.pause()
        isPlaying = false
        isInterrupted = true
    }

    private func resumeAfterInterruption() {
        guard isInterrupted else { return }
        playerNode.play()
        isPlaying = true
        isInterrupted = false
    }

    private func createBuffer(from chunk: AudioChunk) throws -> AVAudioPCMBuffer {
        guard abs(Double(chunk.sampleRate) - format.sampleRate) < 0.1 else {
            throw AudioError.sampleRateMismatch(
                expected: format.sampleRate,
                got: Double(chunk.sampleRate)
            )
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(chunk.samples.count)
        ) else {
            throw AudioError.bufferCreationFailed
        }

        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)

        let channelData = buffer.floatChannelData![0]
        for (i, sample) in chunk.samples.enumerated() {
            channelData[i] = sample
        }

        return buffer
    }

    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        scheduledBuffers += 1

        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                self?.completedBuffers += 1
            }
        }
    }

    private func waitForPlaybackCompletion() async {
        while completedBuffers < scheduledBuffers {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func startTimeTracking() {
        let t = PlaybackTimeTicker { [weak self] in
            self?.updateTime()
        }
        t.start()
        ticker = t
    }

    private func stopTimeTracking() {
        ticker?.stop()
        ticker = nil
    }

    private func updateTime() {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return
        }
        currentTime = Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func decodeAudio(data: Data, format: AudioFormat) throws -> AVAudioPCMBuffer {
        let tempDir = FileManager.default.temporaryDirectory
        let ext = format == .wav ? "wav" : "m4a"
        let url = tempDir.appendingPathComponent("voiceclone_decode_\(UUID().uuidString).\(ext)")
        try data.write(to: url)

        let audioFile = try AVAudioFile(forReading: url)
        let processingFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            throw AudioError.decodingFailed
        }

        try audioFile.read(into: buffer)
        try? FileManager.default.removeItem(at: url)
        return buffer
    }
}

// MARK: - Types

enum AudioFormat {
    case wav
    case m4a
}

enum AudioError: LocalizedError {
    case bufferCreationFailed
    case decodingFailed
    case sessionConfigurationFailed
    case sampleRateMismatch(expected: Double, got: Double)

    var errorDescription: String? {
        switch self {
        case .bufferCreationFailed:
            return "Failed to create audio buffer"
        case .decodingFailed:
            return "Failed to decode audio data"
        case .sessionConfigurationFailed:
            return "Failed to configure audio session"
        case .sampleRateMismatch(let expected, let got):
            return "Sample rate mismatch: expected \(expected) Hz, got \(got) Hz"
        }
    }
}
