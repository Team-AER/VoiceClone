//
//  Qwen3Tokenizer.swift
//  VoiceClone
//

import Foundation

/// BPE tokenizer for Qwen3-TTS
final class Qwen3Tokenizer: @unchecked Sendable {

    private let vocab: [String: Int]
    private let reverseVocab: [Int: String]
    private let merges: [(String, String)]
    private let mergeRanks: [String: Int]
    private let specialTokens: SpecialTokens

    struct SpecialTokens: Codable {
        let bosToken: String
        let eosToken: String
        let padToken: String?
        let unkToken: String
    }

    var bosTokenId: Int? { vocab[specialTokens.bosToken] }
    var eosTokenId: Int? { vocab[specialTokens.eosToken] }
    var unkTokenId: Int? { vocab[specialTokens.unkToken] }

    init(vocabURL: URL, mergesURL: URL, specialTokensURL: URL) throws {
        let vocabData = try Data(contentsOf: vocabURL)
        self.vocab = try JSONDecoder().decode([String: Int].self, from: vocabData)
        self.reverseVocab = Dictionary(uniqueKeysWithValues: vocab.map { ($1, $0) })

        let mergesContent = try String(contentsOf: mergesURL, encoding: .utf8)
        var mergesList: [(String, String)] = []
        var mergeRanksDict: [String: Int] = [:]

        for (index, line) in mergesContent.components(separatedBy: .newlines).dropFirst().enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            let pair = (String(parts[0]), String(parts[1]))
            mergesList.append(pair)

            let key = "\(pair.0) \(pair.1)"
            mergeRanksDict[key] = index
        }
        self.merges = mergesList
        self.mergeRanks = mergeRanksDict

        let specialData = try Data(contentsOf: specialTokensURL)
        self.specialTokens = try JSONDecoder().decode(SpecialTokens.self, from: specialData)
    }

    func encode(text: String, language: Language, instruction: String? = nil) -> [Int] {
        var tokens: [Int] = []

        if let bosId = vocab[specialTokens.bosToken] {
            tokens.append(bosId)
        }

        let langTag = "<|lang:\(language.code)|>"
        if let langId = vocab[langTag] {
            tokens.append(langId)
        }

        if let instruction = instruction {
            let instructTokens = tokenize(instruction)
            tokens.append(contentsOf: instructTokens)

            if let sepId = vocab["<|instruct_end|>"] {
                tokens.append(sepId)
            }
        }

        let textTokens = tokenize(text)
        tokens.append(contentsOf: textTokens)

        if let eosId = vocab[specialTokens.eosToken] {
            tokens.append(eosId)
        }

        return tokens
    }

    func decode(_ tokens: [Int]) -> String {
        tokens
            .compactMap { reverseVocab[$0] }
            .joined()
            .replacingOccurrences(of: "Ġ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func tokenize(_ text: String) -> [Int] {
        let words = preTokenize(text)

        var tokens: [Int] = []
        for word in words {
            let wordTokens = bpe(word)
            tokens.append(contentsOf: wordTokens)
        }

        return tokens
    }

    private func preTokenize(_ text: String) -> [String] {
        var words: [String] = []
        var currentWord = ""

        for char in text {
            if char.isWhitespace {
                if !currentWord.isEmpty {
                    words.append(currentWord)
                    currentWord = ""
                }
                currentWord = "Ġ"
            } else {
                currentWord.append(char)
            }
        }

        if !currentWord.isEmpty {
            words.append(currentWord)
        }

        return words
    }

    private func bpe(_ word: String) -> [Int] {
        var chars = word.map { String($0) }

        while chars.count > 1 {
            var bestMerge: (Int, (String, String))? = nil

            for i in 0..<(chars.count - 1) {
                let pair = (chars[i], chars[i + 1])
                if let rank = mergeRank(pair) {
                    if bestMerge == nil || rank < bestMerge!.0 {
                        bestMerge = (rank, pair)
                    }
                }
            }

            guard let (_, (first, second)) = bestMerge else { break }

            var newChars: [String] = []
            var i = 0
            while i < chars.count {
                if i < chars.count - 1 && chars[i] == first && chars[i + 1] == second {
                    newChars.append(first + second)
                    i += 2
                } else {
                    newChars.append(chars[i])
                    i += 1
                }
            }
            chars = newChars
        }

        return chars.compactMap { vocab[$0] ?? vocab[specialTokens.unkToken] }
    }

    private func mergeRank(_ pair: (String, String)) -> Int? {
        let key = "\(pair.0) \(pair.1)"
        return mergeRanks[key]  // O(1) lookup
    }
}
