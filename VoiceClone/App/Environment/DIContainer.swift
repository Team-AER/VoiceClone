//
//  DIContainer.swift
//  VoiceClone
//

import Combine
import SwiftUI

@MainActor
final class DIContainer: ObservableObject {
    let ttsService: MLXTTSService
    let audioEngine: AudioEngine
    let voiceStorage: VoiceStorage

    init() {
        self.audioEngine = AudioEngine()
        self.voiceStorage = VoiceStorage()

        // Load tokenizer
        let tokenizer = Self.loadTokenizer()

        // Use MLX backend
        self.ttsService = MLXTTSService(
            tokenizer: tokenizer,
            audioEngine: audioEngine
        )
    }

    private static func loadTokenizer() -> Qwen3Tokenizer {
        let bundle = Bundle.main
        let subdirectories: [String?] = ["Tokenizer", "Resources/Tokenizer", "Resources", nil]
        for subdirectory in subdirectories {
            if let vocabURL = bundle.url(forResource: "vocab", withExtension: "json", subdirectory: subdirectory),
               let mergesURL = bundle.url(forResource: "merges", withExtension: "txt", subdirectory: subdirectory),
               let specialURL = bundle.url(forResource: "special_tokens", withExtension: "json", subdirectory: subdirectory),
               let tokenizer = try? Qwen3Tokenizer(vocabURL: vocabURL, mergesURL: mergesURL, specialTokensURL: specialURL) {
                return tokenizer
            }
        }

        // Create minimal fallback tokenizer
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TokenizerFallback", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let vocabURL = tempDir.appendingPathComponent("vocab.json")
        let mergesURL = tempDir.appendingPathComponent("merges.txt")
        let specialURL = tempDir.appendingPathComponent("special_tokens.json")

        if !FileManager.default.fileExists(atPath: vocabURL.path) {
            let vocab: [String: Int] = [
                "<|bos|>": 0,
                "<|eos|>": 1,
                "<|unk|>": 2,
                "<|lang:en|>": 3
            ]
            let vocabData = try? JSONSerialization.data(withJSONObject: vocab, options: [])
            try? vocabData?.write(to: vocabURL)

            try? "#version: 0.2\n".write(to: mergesURL, atomically: true, encoding: .utf8)

            let special: [String: String] = [
                "bosToken": "<|bos|>",
                "eosToken": "<|eos|>",
                "unkToken": "<|unk|>"
            ]
            let specialData = try? JSONSerialization.data(withJSONObject: special, options: [])
            try? specialData?.write(to: specialURL)
        }

        return try! Qwen3Tokenizer(vocabURL: vocabURL, mergesURL: mergesURL, specialTokensURL: specialURL)
    }
}

private struct DIContainerKey: EnvironmentKey {
    static let defaultValue = DIContainer()
}

extension EnvironmentValues {
    var container: DIContainer {
        get { self[DIContainerKey.self] }
        set { self[DIContainerKey.self] = newValue }
    }
}

