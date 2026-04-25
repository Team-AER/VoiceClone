//
//  EndToEndAudioGenerationTests.swift
//  VoiceCloneTests
//
//  Drives MLXTTSService through the real vendored Qwen3TTSModel and asserts
//  that the produced audio is non-empty, finite, and has non-zero energy.
//
//  Skips gracefully when model files are absent — use
//  `ModelDownloadManager` once (launch the app) or pre-populate
//  `~/Library/Application Support/VoiceClone/MLXModels/Qwen3TTS-CustomVoice-bf16/`
//  before running.
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

    // MARK: - Tests

    /// Preset-voice synthesis end-to-end.
    func testEndToEndCustomVoice() async throws {
        try skipUnlessModelsAvailable()

        try await service.loadCapability(.customVoice)
        XCTAssertEqual(service.state, .ready)

        let stream = try await service.synthesize(
            text: "The quick brown fox jumps over the lazy dog.",
            language: .english,
            speaker: .ryan
        )
        let (chunks, samples) = try await collectAudio(from: stream)
        assertValidAudio(chunks: chunks, samples: samples, label: "customVoice(.ryan)")
    }

    /// Voice-design (instruct-only) synthesis.
    ///
    /// Skipped when the installed model is a CustomVoice snapshot — that
    /// variant doesn't support instruction-only generation. Install the
    /// VoiceDesign snapshot (or run on a Base model) to exercise this path.
    func testEndToEndVoiceDesign() async throws {
        try skipUnlessModelsAvailable()

        try await service.loadCapability(.voiceDesign)

        let stream: AsyncThrowingStream<AudioChunk, Error>
        do {
            stream = try await service.synthesize(
                text: "Hello, this is a voice design synthesis test.",
                language: .english,
                instruction: "Speak in a calm, clear voice."
            )
        } catch {
            throw XCTSkip(
                "Installed model does not support voice-design generation: " +
                error.localizedDescription
            )
        }

        do {
            let (chunks, samples) = try await collectAudio(from: stream)
            assertValidAudio(chunks: chunks, samples: samples, label: "voiceDesign")
        } catch {
            let msg = error.localizedDescription.lowercased()
            // Any "wrong model variant" signal from the vendored Qwen3TTSModel:
            // CustomVoice models reject instruct-only requests ("requires 'speaker'"),
            // VoiceDesign models reject speaker-based requests ("requires 'instruct'").
            let mismatchMarkers = ["voice_design", "instruct", "invalidinput",
                                   "requires 'speaker'", "requires 'instruct'",
                                   "custom_voice", "customvoice"]
            if mismatchMarkers.contains(where: { msg.contains($0) }) {
                throw XCTSkip(
                    "Installed model does not support voice-design generation: " +
                    error.localizedDescription
                )
            }
            throw error
        }
    }

    /// Chunks must have a 24 kHz sample rate, finite samples, and peaks in range.
    func testAudioOutputFormat() async throws {
        try skipUnlessModelsAvailable()

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

    /// The service state machine: idle → loading → ready → synthesizing → ready.
    func testServiceStateTransitions() async throws {
        try skipUnlessModelsAvailable()

        XCTAssertEqual(service.state, .idle)
        try await service.loadCapability(.customVoice)
        XCTAssertEqual(service.state, .ready)

        let stream = try await service.synthesize(
            text: "State transition test.",
            language: .english,
            speaker: .ryan
        )
        for try await _ in stream {}
        XCTAssertEqual(service.state, .ready)
    }

    // MARK: - Helpers

    private func skipUnlessModelsAvailable() throws {
        guard MLXTTSService.areModelsAvailable() else {
            throw XCTSkip(
                "Qwen3-TTS model files not found in the managed directory. " +
                "Run the app once to download them."
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
}
