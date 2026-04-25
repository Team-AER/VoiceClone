//
//  TextChunkerTests.swift
//  VoiceCloneTests
//
//  Verifies the sentence-splitter that gates per-chunk synthesis. These
//  rules matter because chunking too aggressively produces choppy prosody
//  and chunking too lazily defeats the windowing — both regressions that
//  are easy to introduce when tweaking `maxCharacters` or the splitter.
//

import XCTest
@testable import VoiceClone

final class TextChunkerTests: XCTestCase {

    func testEmptyInputProducesNoChunks() {
        XCTAssertEqual(TextChunker.chunk("").count, 0)
        XCTAssertEqual(TextChunker.chunk("   \n\t  ").count, 0)
    }

    func testShortTextStaysAsOneChunk() {
        let s = "Hello world. How are you?"
        let chunks = TextChunker.chunk(s)
        XCTAssertEqual(chunks, [s])
    }

    func testLongTextSplitsAtSentenceBoundaries() {
        // Three short sentences that together exceed the default 220-char cap.
        let s1 = String(repeating: "This is sentence one. ", count: 6)  // ~132 chars
        let s2 = String(repeating: "Sentence two follows. ", count: 6)  // ~132 chars
        let chunks = TextChunker.chunk(s1 + s2)

        XCTAssertGreaterThan(chunks.count, 1, "Expected the long text to be split.")
        for c in chunks {
            XCTAssertLessThanOrEqual(c.count, TextChunker.defaultMaxCharacters * 2,
                                     "Chunk grew unexpectedly large: \(c.count) chars")
        }
        // No data loss — every original sentence fragment must reappear.
        let rejoined = chunks.joined(separator: " ")
        XCTAssertTrue(rejoined.contains("sentence one"))
        XCTAssertTrue(rejoined.contains("Sentence two"))
    }

    func testRespectsCustomMaxCharacters() {
        let s = "One. Two. Three. Four. Five. Six. Seven. Eight. Nine. Ten."
        let chunks = TextChunker.chunk(s, maxCharacters: 20)
        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks {
            // Can be a touch over because we never split mid-sentence.
            XCTAssertLessThanOrEqual(c.count, 40)
        }
    }

    func testForceSplitsWhenSingleSentenceExceedsCap() {
        // No sentence terminators — the splitter must fall back to commas/words.
        let monster = String(repeating: "word ", count: 200) // 1000 chars, no punctuation
        let chunks = TextChunker.chunk(monster, maxCharacters: 100)

        XCTAssertGreaterThan(chunks.count, 5)
        for c in chunks {
            XCTAssertLessThanOrEqual(c.count, 110, "Force-split chunk too large: \(c.count)")
        }
    }

    func testPreservesAbbreviations() {
        // NLTokenizer should keep "Dr. Smith" together rather than splitting on the period.
        let s = "Dr. Smith met Mr. Jones at 3.14 PM. They discussed the U.S. economy."
        let chunks = TextChunker.chunk(s)
        XCTAssertEqual(chunks.count, 1, "Short abbreviation-heavy text should stay as one chunk")
    }

    func testHandlesTrailingWhitespace() {
        let s = "  First sentence.   Second sentence.   "
        let chunks = TextChunker.chunk(s)
        XCTAssertFalse(chunks.contains { $0.hasPrefix(" ") || $0.hasSuffix(" ") },
                       "Chunks must be trimmed")
    }
}
