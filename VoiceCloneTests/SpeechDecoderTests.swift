//
//  SpeechDecoderTests.swift
//  VoiceCloneTests
//
//  Tests for MLXSpeechDecoder
//

import XCTest
import MLX
@testable import VoiceClone

@available(iOS 16.0, *)
final class SpeechDecoderTests: XCTestCase {

    // MARK: - Snake Activation Tests

    func testSnakeActivation() {
        let snake = SnakeActivation(channels: 3, alphaInit: 1.0, betaInit: 1.0)
        
        // Test 2D input [batch, channels]
        let input2D = MLX.array([[1.0, 2.0, 3.0]])
        let output2D = snake(input2D)
        
        XCTAssertEqual(output2D.ndim, 2)
        XCTAssertEqual(output2D.shape[0], 1)
        XCTAssertEqual(output2D.shape[1], 3)
        
        // Test 3D input [batch, channels, time]
        let input3D = MLX.array([[[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]])
        let output3D = snake(input3D)
        
        XCTAssertEqual(output3D.ndim, 3)
        XCTAssertEqual(output3D.shape[0], 1)
        XCTAssertEqual(output3D.shape[1], 3)
        XCTAssertEqual(output3D.shape[2], 2)
    }

    func testSnakeActivationFormula() {
        // Test that Snake follows the formula: y = x + (1/β) * sin²(α * x)
        let alpha: Float = 1.0
        let beta: Float = 1.0
        
        let snake = SnakeActivation(
            alpha: MLX.array([alpha]),
            beta: MLX.array([beta])
        )
        
        let x = MLX.array([[0.5]])
        let output = snake(x)
        
        // Expected: y = 0.5 + sin²(1.0 * 0.5) / 1.0
        let expectedSin = sin(0.5)
        let expected = 0.5 + (expectedSin * expectedSin)
        
        let outputValue = output.asArray(Float.self)[0]
        XCTAssertEqual(outputValue, expected, accuracy: 0.001)
    }

    // MARK: - Residual Vector Quantizer Tests

    func testRVQDecode() {
        // Create dummy codebooks
        let numQuantizers = 4
        let codebookSize = 8
        let codebookDim = 16
        
        var codebooks: [MLXArray] = []
        for _ in 0..<numQuantizers {
            codebooks.append(MLX.random.normal([codebookSize, codebookDim]))
        }
        
        let rvq = ResidualVectorQuantizer(
            numQuantizers: numQuantizers,
            codebookSize: codebookSize,
            codebookDim: codebookDim,
            codebooks: codebooks
        )
        
        // Test codes: [batch, num_quantizers, seq_len]
        let codes = MLX.array([[[0, 1, 2], [3, 4, 5], [6, 7, 0], [1, 2, 3]]])
        let embeddings = rvq.decode(codes)
        
        // Expected output: [batch, seq_len, codebook_dim]
        XCTAssertEqual(embeddings.ndim, 3)
        XCTAssertEqual(embeddings.shape[0], 1)  // batch
        XCTAssertEqual(embeddings.shape[1], 3)  // seq_len
        XCTAssertEqual(embeddings.shape[2], codebookDim)
    }

    // MARK: - Decoder Integration Tests

    func testDecoderBasicShapes() async throws {
        // This test assumes decoder weights are available
        let decoderPath = getTestDecoderPath()
        
        guard FileManager.default.fileExists(atPath: decoderPath.path) else {
            throw XCTSkip("Decoder model not available for testing")
        }
        
        let decoder = try await MLXSpeechDecoder(modelPath: decoderPath)
        
        // Create test audio codes [batch, num_codebooks, seq_len]
        let batchSize = 1
        let numCodebooks = 16
        let seqLen = 10
        
        let codes = MLX.random.randint(low: 0, high: 192, [batchSize, numCodebooks, seqLen])
        
        // Decode
        let waveform = try await decoder.decode(codes)
        
        // Expected output: [batch, num_samples]
        XCTAssertEqual(waveform.ndim, 2)
        XCTAssertEqual(waveform.shape[0], batchSize)
        
        // Expected upsampling: seq_len * 1920 = 19200 samples
        let expectedSamples = seqLen * 1920
        XCTAssertEqual(waveform.shape[1], expectedSamples)
        
        // Check range [-1, 1]
        let samples = waveform.asArray(Float.self)
        XCTAssertTrue(samples.allSatisfy { $0 >= -1.0 && $0 <= 1.0 })
    }

    func testDecoderOutputQuality() async throws {
        let decoderPath = getTestDecoderPath()
        
        guard FileManager.default.fileExists(atPath: decoderPath.path) else {
            throw XCTSkip("Decoder model not available for testing")
        }
        
        let decoder = try await MLXSpeechDecoder(modelPath: decoderPath)
        
        // Generate codes
        let codes = MLX.random.randint(low: 0, high: 192, [1, 16, 50])
        let waveform = try await decoder.decode(codes)
        
        // Check output is not all zeros
        let samples = waveform.asArray(Float.self)
        XCTAssertFalse(samples.allSatisfy { $0 == 0.0 }, "Output should not be all zeros")
        
        // Check output has variation (not constant)
        let mean = samples.reduce(0, +) / Float(samples.count)
        let variance = samples.map { pow($0 - mean, 2) }.reduce(0, +) / Float(samples.count)
        XCTAssertGreaterThan(variance, 0.001, "Output should have variation")
    }

    // MARK: - End-to-End Tests

    @MainActor
    func testEndToEndSynthesis() async throws {
        // Load tokenizer
        guard let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "json", subdirectory: "Resources/Tokenizer"),
              let mergesURL = Bundle.main.url(forResource: "merges", withExtension: "txt", subdirectory: "Resources/Tokenizer") else {
            throw XCTSkip("Tokenizer resources not found")
        }
        
        let tokenizer = try Qwen3Tokenizer(vocabURL: vocabURL, mergesURL: mergesURL)
        let audioEngine = AudioEngine()
        
        // Create TTS service
        let service = MLXTTSService(tokenizer: tokenizer, audioEngine: audioEngine)
        
        // Load models
        try await service.loadCapability(.voiceDesign)
        
        // Synthesize
        let text = "Hello world"
        let audioStream = try await service.synthesize(
            text: text,
            language: .english,
            instruction: "Speak clearly"
        )
        
        // Collect chunks
        var allSamples: [Float] = []
        for try await chunk in audioStream {
            allSamples.append(contentsOf: chunk.samples)
            XCTAssertEqual(chunk.sampleRate, 24000)
        }
        
        // Verify we got audio
        XCTAssertFalse(allSamples.isEmpty, "Should produce audio samples")
        
        // Verify duration is reasonable (roughly 50ms per token)
        let tokens = tokenizer.encode(text: text, language: .english)
        let expectedDuration = Float(tokens.count) * 0.05
        let actualDuration = Float(allSamples.count) / 24000.0
        
        // Allow ±1 second tolerance
        XCTAssertEqual(actualDuration, expectedDuration, accuracy: 1.0)
    }

    // MARK: - Helper Methods

    private func getTestDecoderPath() -> URL {
        // Try multiple possible locations
        let candidates = [
            "/Users/prakhar/Developer/AER/VoiceClone/models/MLXModels/Qwen3TTS_Decoder",
            "/tmp/Qwen3TTS_Decoder",
            FileManager.default.temporaryDirectory.appendingPathComponent("Qwen3TTS_Decoder").path
        ]
        
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        
        // Default to models directory
        return URL(fileURLWithPath: candidates[0])
    }

    // MARK: - Performance Tests

    func testDecoderPerformance() async throws {
        let decoderPath = getTestDecoderPath()
        
        guard FileManager.default.fileExists(atPath: decoderPath.path) else {
            throw XCTSkip("Decoder model not available for testing")
        }
        
        let decoder = try await MLXSpeechDecoder(modelPath: decoderPath)
        
        // Measure decoding time
        measure {
            Task {
                let codes = MLX.random.randint(low: 0, high: 192, [1, 16, 100])
                _ = try await decoder.decode(codes)
            }
        }
    }
}
