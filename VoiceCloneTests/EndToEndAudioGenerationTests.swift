//
//  EndToEndAudioGenerationTests.swift
//  VoiceCloneTests
//
//  Drives MLXTTSService through the real vendored Qwen3TTSModel for each
//  installed snapshot. Tests skip gracefully when a particular snapshot is
//  not present so CI works against any subset of downloaded models.
//
//  Snapshot install hint:
//    ~/Library/Application Support/VoiceClone/MLXModels/
//      Qwen3TTS-CustomVoice-bf16/   (required for Speak tab)
//      Qwen3TTS-Base-bf16/          (required for Clone tab)
//      Qwen3TTS-VoiceDesign-bf16/   (required for Design tab)
//

import XCTest
@testable import VoiceClone

@available(macOS 15.0, iOS 18.0, *)
@MainActor
final class EndToEndAudioGenerationTests: XCTestCase {

    private var audioEngine: AudioEngine!
    private var service: MLXTTSService!

    override func setUp() async throws {
        try await super.setUp()
        audioEngine = AudioEngine()
        service = MLXTTSService(audioEngine: audioEngine)
    }

    override func tearDown() async throws {
        service.stop()
        service = nil
        audioEngine = nil
        try await super.tearDown()
    }

    // MARK: - Preset (CustomVoice) snapshot

    /// Preset-voice synthesis end-to-end against the CustomVoice snapshot.
    func testEndToEndCustomVoice() async throws {
        try skipUnlessInstalled(.customVoice)

        try await service.loadCapability(.customVoice)
        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(service.loadedSnapshot, .customVoice)

        let stream = try await service.synthesize(
            text: "The quick brown fox jumps over the lazy dog.",
            language: .english,
            speaker: .ryan
        )
        let (chunks, samples) = try await collectAudio(from: stream)
        assertValidAudio(chunks: chunks, samples: samples, label: "customVoice(.ryan)")
    }

    /// CustomVoice with an instruct overlay — same snapshot, but routes
    /// through the model's emotion/style path.
    func testCustomVoiceWithInstruct() async throws {
        try skipUnlessInstalled(.customVoice)

        try await service.loadCapability(.customVoice)
        let stream = try await service.synthesize(
            text: "Hello, this is a calm and warm sample.",
            language: .english,
            speaker: .ryan,
            instruction: "Speak in a calm, warm tone."
        )
        let (chunks, samples) = try await collectAudio(from: stream)
        assertValidAudio(chunks: chunks, samples: samples, label: "customVoice(.ryan)+instruct")
    }

    // MARK: - VoiceDesign snapshot

    /// Pure description-driven synthesis — requires the VoiceDesign-1.7B snapshot.
    func testEndToEndVoiceDesign() async throws {
        try skipUnlessInstalled(.voiceDesign)

        try await service.loadCapability(.voiceDesign)
        XCTAssertEqual(service.loadedSnapshot, .voiceDesign)

        let stream = try await service.synthesize(
            text: "Hello, this is a voice design synthesis test.",
            language: .english,
            instruction: "A warm female voice with a friendly tone."
        )
        let (chunks, samples) = try await collectAudio(from: stream)
        assertValidAudio(chunks: chunks, samples: samples, label: "voiceDesign")
    }

    // MARK: - Voice Clone (Base) snapshot

    /// Voice cloning end-to-end. Synthesizes a short sample with the Base
    /// snapshot's preset path and feeds it back as the reference, so the
    /// test is hermetic — no microphone needed.
    func testEndToEndVoiceClone() async throws {
        try skipUnlessInstalled(.base)

        // Step 1: produce a reference clip using the Base snapshot's preset path.
        try await service.loadCapability(.customVoice)  // Base also covers .customVoice
        let refStream = try await service.synthesize(
            text: "This is a short reference recording for cloning.",
            language: .english,
            speaker: .ryan
        )
        let (_, refSamples) = try await collectAudio(from: refStream)
        XCTAssertGreaterThan(refSamples.count, 24_000, "Reference clip too short")
        let refData = try makeWav(samples: refSamples, sampleRate: 24_000)

        // Step 2: clone from that reference.
        try await service.loadCapability(.voiceClone)
        XCTAssertEqual(service.loadedSnapshot, .base)

        let stream = try await service.synthesize(
            text: "Hello, this is my cloned voice speaking.",
            language: .english,
            referenceAudio: refData,
            referenceText: "This is a short reference recording for cloning."
        )
        let (chunks, samples) = try await collectAudio(from: stream)
        assertValidAudio(chunks: chunks, samples: samples, label: "voiceClone")
    }

    // MARK: - Common audio output asserts

    /// Chunks must have a 24 kHz sample rate, finite samples, and peaks in range.
    func testAudioOutputFormat() async throws {
        try skipUnlessInstalled(.customVoice)

        try await service.loadCapability(.customVoice)
        let stream = try await service.synthesize(
            text: "Format check.",
            language: .english,
            speaker: .ryan
        )
        for try await chunk in stream {
            XCTAssertEqual(chunk.sampleRate, 24000, "Sample rate must be 24 kHz")
            XCTAssertFalse(chunk.samples.isEmpty, "Chunk must not be empty")
            for sample in chunk.samples {
                XCTAssertTrue(sample.isFinite, "Non-finite sample: \(sample)")
            }
            let peak = chunk.samples.map(abs).max() ?? 0
            XCTAssertLessThanOrEqual(peak, 2.0, "Peak amplitude \(peak) out of range")
        }
    }

    /// idle → loading → ready → synthesizing → ready, plus capability flag.
    func testServiceStateTransitions() async throws {
        try skipUnlessInstalled(.customVoice)

        XCTAssertEqual(service.state, .idle)
        try await service.loadCapability(.customVoice)
        XCTAssertEqual(service.state, .ready)
        XCTAssertTrue(service.loadedCapabilities.contains(.customVoice))

        let stream = try await service.synthesize(
            text: "State transition test.",
            language: .english,
            speaker: .ryan
        )
        for try await _ in stream {}
        XCTAssertEqual(service.state, .ready)
    }

    // MARK: - Snapshot gate semantics

    /// Asking for a missing snapshot should throw `snapshotNotInstalled`.
    func testMissingSnapshotThrows() async throws {
        let absent = ModelSnapshot.allCases.first { !ModelDownloadManager.isInstalled($0) }
        guard let target = absent else {
            throw XCTSkip("All snapshots are installed; no negative case to exercise.")
        }
        let cap: TTSCapability
        switch target {
        case .customVoice: cap = .customVoice
        case .base:        cap = .voiceClone
        case .voiceDesign: cap = .voiceDesign
        }

        do {
            try await service.loadCapability(cap)
            XCTFail("Expected snapshotNotInstalled error for \(target.rawValue)")
        } catch let TTSError.snapshotNotInstalled(snap) {
            XCTAssertEqual(snap, target)
        } catch {
            XCTFail("Expected snapshotNotInstalled, got \(error)")
        }
    }

    // MARK: - Helpers

    private func skipUnlessInstalled(_ snapshot: ModelSnapshot) throws {
        guard ModelDownloadManager.isInstalled(snapshot) else {
            throw XCTSkip(
                "\(snapshot.displayName) snapshot is not installed at " +
                "\(ModelDownloadManager.directory(for: snapshot).path). " +
                "Run the app once and download from the Model Manager."
            )
        }
    }

    private func collectAudio(
        from stream: AsyncThrowingStream<AudioChunk, Error>
    ) async throws -> (chunks: [AudioChunk], samples: [Float]) {
        var chunks: [AudioChunk] = []
        var samples: [Float] = []
        for try await chunk in stream {
            chunks.append(chunk)
            samples.append(contentsOf: chunk.samples)
        }
        return (chunks, samples)
    }

    private func assertValidAudio(chunks: [AudioChunk], samples: [Float], label: String) {
        XCTAssertFalse(chunks.isEmpty, "[\(label)] No AudioChunk produced")
        XCTAssertFalse(samples.isEmpty, "[\(label)] No audio samples")
        XCTAssertEqual(chunks[0].sampleRate, 24000, "[\(label)] Sample rate must be 24 kHz")

        let durationSec = Float(samples.count) / 24_000.0
        XCTAssertGreaterThan(durationSec, 0.1, "[\(label)] Audio too short (\(durationSec)s)")

        let nonFinite = samples.filter { !$0.isFinite }.count
        XCTAssertEqual(nonFinite, 0, "[\(label)] \(nonFinite) non-finite samples")

        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        XCTAssertGreaterThan(rms, 1e-4, "[\(label)] Audio appears silent (RMS=\(rms))")
    }

    /// Encode `samples` as a 16-bit PCM mono WAV `Data` blob — same format
    /// `AudioRecorder` produces, so it round-trips cleanly through
    /// `MLXTTSService.loadReferenceAudio(_:)`.
    private func makeWav(samples: [Float], sampleRate: Int) throws -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate * Int(channels) * Int(bitsPerSample) / 8)
        let blockAlign = UInt16(Int(channels) * Int(bitsPerSample) / 8)

        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            let v = Int16(clamped * 32767.0)
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }

        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        var totalSize = UInt32(36 + pcm.count).littleEndian
        withUnsafeBytes(of: &totalSize) { wav.append(contentsOf: $0) }
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        var fmtChunkSize = UInt32(16).littleEndian
        withUnsafeBytes(of: &fmtChunkSize) { wav.append(contentsOf: $0) }
        var audioFormat = UInt16(1).littleEndian
        withUnsafeBytes(of: &audioFormat) { wav.append(contentsOf: $0) }
        var ch = channels.littleEndian
        withUnsafeBytes(of: &ch) { wav.append(contentsOf: $0) }
        var sr = UInt32(sampleRate).littleEndian
        withUnsafeBytes(of: &sr) { wav.append(contentsOf: $0) }
        var br = byteRate.littleEndian
        withUnsafeBytes(of: &br) { wav.append(contentsOf: $0) }
        var ba = blockAlign.littleEndian
        withUnsafeBytes(of: &ba) { wav.append(contentsOf: $0) }
        var bps = bitsPerSample.littleEndian
        withUnsafeBytes(of: &bps) { wav.append(contentsOf: $0) }
        wav.append("data".data(using: .ascii)!)
        var dataChunkSize = UInt32(pcm.count).littleEndian
        withUnsafeBytes(of: &dataChunkSize) { wav.append(contentsOf: $0) }
        wav.append(pcm)
        return wav
    }
}
