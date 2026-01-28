//
//  TokenizerTests.swift
//  VoiceCloneTests
//

import XCTest
@testable import VoiceClone

final class TokenizerTests: XCTestCase {

    private var tokenizer: Qwen3Tokenizer!

    override func setUpWithError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenizer_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let vocabURL = tempDir.appendingPathComponent("vocab.json")
        let mergesURL = tempDir.appendingPathComponent("merges.txt")
        let specialURL = tempDir.appendingPathComponent("special_tokens.json")

        let vocab: [String: Int] = [
            "<|bos|>": 0,
            "<|eos|>": 1,
            "<|unk|>": 2,
            "<|lang:en|>": 3,
            "<|instruct_end|>": 4,
            "Ġ": 5,
            "H": 6,
            "e": 7,
            "l": 8,
            "o": 9
        ]

        let vocabData = try JSONSerialization.data(withJSONObject: vocab, options: [.prettyPrinted])
        try vocabData.write(to: vocabURL)
        try "#version: 0.2\n".write(to: mergesURL, atomically: true, encoding: .utf8)

        let special: [String: String] = [
            "bosToken": "<|bos|>",
            "eosToken": "<|eos|>",
            "padToken": "<|pad|>",
            "unkToken": "<|unk|>"
        ]
        let specialData = try JSONSerialization.data(withJSONObject: special, options: [.prettyPrinted])
        try specialData.write(to: specialURL)

        tokenizer = try Qwen3Tokenizer(vocabURL: vocabURL, mergesURL: mergesURL, specialTokensURL: specialURL)
    }

    func testBasicTokenization() {
        let text = "Hello"
        let tokens = tokenizer.encode(text: text, language: .english)

        XCTAssertFalse(tokens.isEmpty)
        XCTAssertEqual(tokens.first, tokenizer.bosTokenId)
        XCTAssertEqual(tokens.last, tokenizer.eosTokenId)
    }

    func testRoundTrip() {
        let text = "Hello"
        let tokens = tokenizer.encode(text: text, language: .english)
        let decoded = tokenizer.decode(tokens)

        XCTAssertTrue(decoded.contains("Hello"))
    }
}
