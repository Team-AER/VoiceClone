//
//  AudioEngine.swift
//  PolyJuiceVoice
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
    /// Frame offset added to `playerNode.playerTime` when reporting `currentTime`.
    /// Used by file-based seek so a segment starting at file frame N still
    /// reports the correct wall-clock position.
    private var playbackStartOffset: TimeInterval = 0
    /// Held during file-based playback so the underlying file outlives the
    /// `AVAudioPlayerNode.scheduleFile/Segment` read window.
    private var currentFile: AVAudioFile?

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
        playbackStartOffset = 0

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
        playbackStartOffset = 0
        currentFile = nil
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

    /// Plays a previously-written WAV file from disk. The file streams via
    /// `AVAudioPlayerNode.scheduleFile` — no per-chunk PCM buffer allocations,
    /// so memory stays flat regardless of utterance length.
    func playFile(_ url: URL) async throws {
        try await playFile(url, from: 0)
    }

    /// Resumes playback of a previously-written WAV file at the given offset
    /// (in seconds, clamped to the file's duration).
    func playFile(_ url: URL, from time: TimeInterval) async throws {
        let file = try AVAudioFile(forReading: url)
        let processingFormat = file.processingFormat
        let totalFrames = file.length
        let totalDuration = Double(totalFrames) / processingFormat.sampleRate
        let clampedTime = max(0, min(time, totalDuration))
        let startFrame = AVAudioFramePosition(clampedTime * processingFormat.sampleRate)
        let frameCount = AVAudioFrameCount(max(0, totalFrames - startFrame))
        guard frameCount > 0 else { return }

        if isPlaying || engine.isRunning {
            stop()
        }

        configureAudioSessionIfNeeded()
        // The synthesis-time format and the file format match (Float32 mono
        // 24 kHz today), so the prebuilt connection set up in `init` is reused
        // as-is. If they ever diverge, reconnect playerNode here.

        try engine.start()
        playerNode.play()
        isPlaying = true

        duration = totalDuration
        currentTime = clampedTime
        playbackStartOffset = clampedTime
        currentFile = file
        startTimeTracking()

        await withCheckedContinuation { continuation in
            playerNode.scheduleSegment(file,
                                       startingFrame: startFrame,
                                       frameCount: frameCount,
                                       at: nil) {
                Task { @MainActor in continuation.resume() }
            }
        }

        stop()
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
        chunk.samples.withUnsafeBytes { src in
            _ = memcpy(channelData, src.baseAddress, src.count)
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
        // playerTime.sampleTime resets to 0 on each `playerNode.play()`, so we
        // add the offset captured at scheduleSegment time to report the true
        // file position when the user has seeked.
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        currentTime = playbackStartOffset + elapsed
    }

    private func decodeAudio(data: Data, format: AudioFormat) throws -> AVAudioPCMBuffer {
        let tempDir = FileManager.default.temporaryDirectory
        let ext = format == .wav ? "wav" : "m4a"
        let url = tempDir.appendingPathComponent("polyjuicevoice_decode_\(UUID().uuidString).\(ext)")
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
