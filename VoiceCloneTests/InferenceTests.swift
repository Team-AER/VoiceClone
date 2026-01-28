//
//  InferenceTests.swift
//  VoiceCloneTests
//

import XCTest
@testable import VoiceClone

final class InferenceTests: XCTestCase {

    func testBasicInference() async throws {
        let manager = MLModelManager()
        let modelsDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)

        let modelURL = modelsDir.appendingPathComponent("Qwen3TTS_Base_06B_INT4.mlpackage")
        let decoderURL = modelsDir.appendingPathComponent("Qwen3TTS_SpeechDecoder.mlpackage")
        guard FileManager.default.fileExists(atPath: modelURL.path),
              FileManager.default.fileExists(atPath: decoderURL.path) else {
            throw XCTSkip("CoreML models not found; skipping inference test.")
        }

        let engine = TTSInferenceEngine(modelManager: manager)
        try await engine.loadModels(type: .base06B)

        let tokens = [0, 3, 1]
        var chunks: [AudioChunk] = []

        for try await chunk in engine.generateStream(inputIds: tokens, maxNewTokens: 10) {
            chunks.append(chunk)
        }

        XCTAssertFalse(chunks.isEmpty)
    }
}
