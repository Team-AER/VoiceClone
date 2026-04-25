//
//  TextChunker.swift
//  VoiceClone
//
//  Splits long input text into model-friendly chunks at sentence boundaries.
//
//  Why chunk at all:
//    The Qwen3-TTS autoregressive talker generates ~12 codec tokens per second
//    of audio at 12 Hz, so 30 seconds of speech costs ~360 sequential GPU
//    forward passes — each one extending the KV cache by one row. For long
//    paragraphs (>~250 chars), this means:
//      - many seconds of latency before the first sample is audible,
//      - several GB of accumulated MLXArray scratch held in RAM,
//      - the orchestration thread is blocked on `eval()` the entire time.
//
//  Splitting on sentence boundaries lets `MLXTTSService` synthesize each
//  chunk independently, yield it through the AsyncStream, and free the
//  per-chunk KV cache before the next chunk runs. Audio plays as soon as
//  the first sentence is ready, and peak memory becomes bounded by a
//  single chunk's footprint regardless of how long the input is.
//

import Foundation
import NaturalLanguage

enum TextChunker {

    /// Default chunk cap. Tuned so a sentence stays under ~12 seconds of
    /// audio (well under the model's 1200-token default `maxTokens`), while
    /// still being long enough to keep prosody natural.
    static let defaultMaxCharacters = 220

    /// Split `text` into chunks of at most `maxCharacters` characters,
    /// preferring sentence boundaries (then commas, then word boundaries).
    /// Returns one chunk for short input — never an empty array unless the
    /// trimmed input itself is empty.
    static func chunk(_ text: String,
                      maxCharacters: Int = defaultMaxCharacters) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count <= maxCharacters { return [trimmed] }

        // 1. Sentence-level split via NLTokenizer (handles abbreviations,
        //    decimals, multi-language punctuation correctly).
        let sentences = splitIntoSentences(trimmed)
        if sentences.isEmpty { return [trimmed] }

        // 2. Greedy pack sentences into chunks under the cap.
        var chunks: [String] = []
        var buffer = ""
        for sentence in sentences {
            if buffer.isEmpty {
                buffer = sentence
            } else if buffer.count + 1 + sentence.count <= maxCharacters {
                buffer += " " + sentence
            } else {
                chunks.append(buffer)
                buffer = sentence
            }
            // 3. If a single sentence is itself longer than the cap, force-split
            //    on commas/whitespace inside it before continuing.
            if buffer.count > maxCharacters {
                let pieces = forceSplit(buffer, maxCharacters: maxCharacters)
                if pieces.count > 1 {
                    chunks.append(contentsOf: pieces.dropLast())
                    buffer = pieces.last ?? ""
                }
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        return chunks
    }

    // MARK: - Private

    private static func splitIntoSentences(_ text: String) -> [String] {
        var result: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { result.append(s) }
            return true
        }
        return result
    }

    /// Last-resort splitter for a single overflowing sentence. Tries comma
    /// boundaries first, then falls back to word boundaries. Never returns
    /// chunks longer than `maxCharacters` unless a single word is itself
    /// too long (in which case that word is preserved intact).
    private static func forceSplit(_ text: String, maxCharacters: Int) -> [String] {
        // Try commas first to keep clausal phrasing.
        let commaPieces = text.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) + "," }
        let usingCommas = commaPieces.count >= 2
        let units: [String] = usingCommas
            ? commaPieces.map { String($0) }
            : text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        let separator = usingCommas ? " " : " "
        var chunks: [String] = []
        var buffer = ""
        for unit in units {
            if buffer.isEmpty {
                buffer = unit
            } else if buffer.count + separator.count + unit.count <= maxCharacters {
                buffer += separator + unit
            } else {
                chunks.append(buffer)
                buffer = unit
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        // Drop trailing comma we artificially added.
        return chunks.map { $0.hasSuffix(",") ? String($0.dropLast()) : $0 }
    }
}
