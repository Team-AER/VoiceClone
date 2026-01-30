//
//  AudioEngine.swift
//  VoiceClone
//

import AVFoundation
import Foundation
import UIKit

/// Manages audio playback with streaming support
@MainActor
final class AudioEngine: ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat

    private var displayLink: CADisplayLink?
    private var scheduledBuffers: Int = 0
    private var completedBuffers: Int = 0

    init(sampleRate: Double = 24000) {
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        setupEngine()
    }

    private func setupEngine() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    func playStream(_ stream: AsyncThrowingStream<AudioChunk, Error>) async throws {
        try configureAudioSession()
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

        try configureAudioSession()
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
        guard time >= 0, time <= totalDuration else {
            return
        }

        // Stop current playback
        stop()

        // Calculate which chunks to play from seek position
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

        // Create stream from remaining chunks
        let remainingStream = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in startChunkIndex..<chunks.count {
                    var chunk = chunks[index]

                    // Skip samples in first chunk if needed
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

        // Update current time to seek position
        currentTime = time

        // Play from new position
        try await playStream(remainingStream)
    }

    // MARK: - Private

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    private func createBuffer(from chunk: AudioChunk) throws -> AVAudioPCMBuffer {
        // Validate sample rate matches
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
        displayLink = CADisplayLink(target: self, selector: #selector(updateTime))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopTimeTracking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func updateTime() {
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
