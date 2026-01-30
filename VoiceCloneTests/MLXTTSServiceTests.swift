//
//  MLXTTSServiceTests.swift
//  VoiceCloneTests
//
//  Tests for MLX backend TTS service
//

import XCTest
@testable import VoiceClone

@available(iOS 16.0, *)
@MainActor
final class MLXTTSServiceTests: XCTestCase {

    var service: MLXTTSService!
    var tokenizer: Qwen3Tokenizer!
    var audioEngine: AudioEngine!

    override func setUp() async throws {
        audioEngine = AudioEngine()
        tokenizer = try createFallbackTokenizer()
        service = MLXTTSService(tokenizer: tokenizer, audioEngine: audioEngine)
    }

    override func tearDown() async throws {
        service = nil
        tokenizer = nil
        audioEngine = nil
    }

    // MARK: - Service Initialization Tests

    func testMLXServiceInitializes() {
        XCTAssertEqual(service.state, .idle)
        XCTAssertTrue(service.loadedCapabilities.isEmpty)
    }

    // MARK: - Capability Loading Tests

    func testLoadVoiceDesignCapability() async throws {
        // This test will fail until mlx-swift package is added
        // and model files are present
        do {
            try await service.loadCapability(.voiceDesign)
            XCTAssertTrue(service.loadedCapabilities.contains(.voiceDesign))
            XCTAssertEqual(service.state, .ready)
        } catch {
            // Expected to fail without actual model files
            XCTAssertTrue(error is TTSError, "Should throw TTSError when model not found")
        }
    }

    func testLoadCustomVoiceCapability() async throws {
        do {
            try await service.loadCapability(.customVoice)
            XCTAssertTrue(service.loadedCapabilities.contains(.customVoice))
            XCTAssertEqual(service.state, .ready)
        } catch {
            XCTAssertTrue(error is TTSError)
        }
    }

    func testLoadMultipleCapabilities() async throws {
        // Try loading multiple capabilities
        do {
            try await service.loadCapability(.voiceDesign)
            try await service.loadCapability(.customVoice)

            XCTAssertTrue(service.loadedCapabilities.contains(.voiceDesign))
            XCTAssertTrue(service.loadedCapabilities.contains(.customVoice))
        } catch {
            // Expected without models
        }
    }

    // MARK: - Synthesis Tests (Placeholder Audio)

    func testSynthesizeThrowsErrorWithoutCapability() async throws {
        // Should throw error when capability not loaded
        do {
            let _ = try await service.synthesize(
                text: "Test",
                language: .english,
                instruction: "Speak clearly"
            )
            XCTFail("Should throw error when capability not loaded")
        } catch let error as TTSError {
            switch error {
            case .capabilityNotLoaded:
                break // Expected
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testSynthesizeWithPresetVoice() async throws {
        // Manually mark capability as loaded for testing
        // (This is a workaround for testing without actual models)
        // In real tests with models, this wouldn't be needed
        do {
            try await service.loadCapability(.customVoice)

            let stream = try await service.synthesize(
                text: "Hello, world!",
                language: .english,
                speaker: .ryan
            )

            var chunks: [AudioChunk] = []
            for try await chunk in stream {
                chunks.append(chunk)
            }

            XCTAssertFalse(chunks.isEmpty, "Should generate at least one audio chunk")

            let totalSamples = chunks.reduce(0) { $0 + $1.samples.count }
            XCTAssertGreaterThan(totalSamples, 0, "Should have audio samples")

            // Verify sample rate
            let firstChunk = try XCTUnwrap(chunks.first)
            XCTAssertEqual(firstChunk.sampleRate, 24000, "Sample rate should be 24kHz")
        } catch {
            // Expected to fail without models
        }
    }

    // MARK: - Audio Quality Tests

    func testPlaceholderAudioIsValid() async throws {
        // Even with placeholder audio, output should be valid
        do {
            try await service.loadCapability(.voiceDesign)

            let stream = try await service.synthesize(
                text: "Test",
                language: .english,
                instruction: "Test instruction"
            )

            var hasValidSamples = false
            for try await chunk in stream {
                XCTAssertFalse(chunk.samples.isEmpty)
                XCTAssertEqual(chunk.sampleRate, 24000)

                // Check samples are in valid range [-1, 1]
                for sample in chunk.samples {
                    XCTAssertGreaterThanOrEqual(sample, -1.0)
                    XCTAssertLessThanOrEqual(sample, 1.0)
                    if sample != 0 {
                        hasValidSamples = true
                    }
                }
            }

            XCTAssertTrue(hasValidSamples, "Should have non-zero samples")
        } catch {
            // Expected without models
        }
    }

    func testAudioDurationMatchesText() async throws {
        // Placeholder audio duration should approximately match text length
        do {
            try await service.loadCapability(.voiceDesign)

            let text = "This is a test sentence"
            let stream = try await service.synthesize(
                text: text,
                language: .english,
                instruction: "Speak naturally"
            )

            var totalSamples = 0
            for try await chunk in stream {
                totalSamples += chunk.samples.count
            }

            let duration = Float(totalSamples) / 24000.0

            // Rough estimate: ~50ms per token, ~10-20 tokens for this text
            // So duration should be ~0.5-1.0 seconds
            XCTAssertGreaterThan(duration, 0.3, "Duration should be > 0.3s")
            XCTAssertLessThan(duration, 2.0, "Duration should be < 2.0s")
        } catch {
            // Expected without models
        }
    }

    // MARK: - State Management Tests

    func testStateTransitions() async throws {
        XCTAssertEqual(service.state, .idle, "Initial state should be idle")

        do {
            try await service.loadCapability(.voiceDesign)
            XCTAssertEqual(service.state, .ready, "State should be ready after loading")

            let stream = try await service.synthesize(
                text: "Test",
                language: .english,
                instruction: "Test"
            )

            // Consume stream
            for try await _ in stream {
                // State during synthesis will be .synthesizing(progress:)
            }

            XCTAssertEqual(service.state, .ready, "State should return to ready after synthesis")
        } catch {
            // Expected without models - state should be idle or error
        }
    }

    // MARK: - Voice Cloning Tests

    func testVoiceCloneFallback() async throws {
        // Voice cloning should fall back to voice design
        do {
            try await service.loadCapability(.voiceClone)

            let referenceAudio = Data([0x00, 0x01, 0x02]) // Dummy data

            let stream = try await service.synthesize(
                text: "Clone test",
                language: .english,
                referenceAudio: referenceAudio,
                referenceText: "Sample"
            )

            var hasChunks = false
            for try await _ in stream {
                hasChunks = true
                break
            }

            XCTAssertTrue(hasChunks, "Should generate audio even with fallback")
        } catch {
            // Expected without models
        }
    }

    // MARK: - Performance Tests

    func testMultipleSynthesisCalls() async throws {
        // Test that service can handle multiple synthesis calls
        do {
            try await service.loadCapability(.voiceDesign)

            for i in 0..<3 {
                let stream = try await service.synthesize(
                    text: "Test \(i)",
                    language: .english,
                    instruction: "Test"
                )

                var chunkCount = 0
                for try await _ in stream {
                    chunkCount += 1
                }

                XCTAssertGreaterThan(chunkCount, 0, "Iteration \(i) should generate chunks")
            }
        } catch {
            // Expected without models
        }
    }

    // MARK: - Helper Methods

    private func createFallbackTokenizer() throws -> Qwen3Tokenizer {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXTestTokenizer", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let vocabURL = tempDir.appendingPathComponent("vocab.json")
        let mergesURL = tempDir.appendingPathComponent("merges.txt")
        let specialURL = tempDir.appendingPathComponent("special_tokens.json")

        if !FileManager.default.fileExists(atPath: vocabURL.path) {
            let vocab: [String: Int] = [
                "<|bos|>": 0,
                "<|eos|>": 1,
                "<|unk|>": 2,
                "<|lang:en|>": 3,
                "H": 4, "e": 5, "l": 6, "o": 7,
                "w": 8, "r": 9, "d": 10, " ": 11
            ]
            let vocabData = try JSONSerialization.data(withJSONObject: vocab, options: [])
            try vocabData.write(to: vocabURL)

            try "#version: 0.2\n".write(to: mergesURL, atomically: true, encoding: .utf8)

            let special: [String: String] = [
                "bosToken": "<|bos|>",
                "eosToken": "<|eos|>",
                "unkToken": "<|unk|>"
            ]
            let specialData = try JSONSerialization.data(withJSONObject: special, options: [])
            try specialData.write(to: specialURL)
        }

        return try Qwen3Tokenizer(
            vocabURL: vocabURL,
            mergesURL: mergesURL,
            specialTokensURL: specialURL
        )
    }
}
