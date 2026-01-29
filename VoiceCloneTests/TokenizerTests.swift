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

    func testEncodingWithLanguage() {
        let tokens = tokenizer.encode(text: "Hello", language: .english)

        // Should contain BOS, language tag, text tokens, EOS
        XCTAssertGreaterThanOrEqual(tokens.count, 3)
        XCTAssertEqual(tokens[0], 0) // BOS
        XCTAssertEqual(tokens[1], 3) // <|lang:en|>
    }

    func testEncodingWithInstruction() {
        let tokensWithoutInstruction = tokenizer.encode(
            text: "Hello",
            language: .english,
            instruction: nil
        )

        let tokensWithInstruction = tokenizer.encode(
            text: "Hello",
            language: .english,
            instruction: "Speak warmly"
        )

        XCTAssertGreaterThan(
            tokensWithInstruction.count,
            tokensWithoutInstruction.count,
            "Tokens with instruction should have more tokens"
        )
    }

    func testEmptyText() {
        let tokens = tokenizer.encode(text: "", language: .english)

        // Should still have BOS and EOS
        XCTAssertGreaterThanOrEqual(tokens.count, 2)
        XCTAssertEqual(tokens.first, 0) // BOS
        XCTAssertEqual(tokens.last, 1) // EOS
    }

    func testMultipleLanguages() {
        let languages: [Language] = [.english, .chinese, .spanish, .french, .german, .japanese, .korean]

        for language in languages {
            let tokens = tokenizer.encode(text: "Test", language: language)
            XCTAssertFalse(tokens.isEmpty, "Should tokenize for \(language)")
            XCTAssertGreaterThanOrEqual(tokens.count, 2)
        }
    }

    func testUnknownTokenHandling() {
        // Text with characters not in vocab should use UNK token
        let tokens = tokenizer.encode(text: "XYZ123", language: .english)

        XCTAssertFalse(tokens.isEmpty)
        // Should contain some unknown tokens (id: 2)
        XCTAssertTrue(tokens.contains(2), "Should contain UNK token for unknown characters")
    }

    func testLongText() {
        let longText = String(repeating: "Hello ", count: 100)
        let tokens = tokenizer.encode(text: longText, language: .english)

        XCTAssertFalse(tokens.isEmpty)
        XCTAssertGreaterThan(tokens.count, 10)
    }
}
