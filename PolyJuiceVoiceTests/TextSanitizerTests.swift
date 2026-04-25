//
//  TextSanitizerTests.swift
//  PolyJuiceVoiceTests
//

import XCTest
@testable import PolyJuiceVoice

final class TextSanitizerTests: XCTestCase {

    func testRejectsEmpty() {
        let r = TextSanitizer.sanitize("")
        XCTAssertFalse(r.passes)
        XCTAssertNotNil(r.message)
    }

    func testRejectsWhitespaceOnly() {
        let r = TextSanitizer.sanitize("   \n\t   ")
        XCTAssertFalse(r.passes)
    }

    func testRejectsSingleChar() {
        let r = TextSanitizer.sanitize("a")
        XCTAssertFalse(r.passes)
    }

    func testAcceptsNormalSentence() {
        let r = TextSanitizer.sanitize("Hello, world!")
        XCTAssertTrue(r.passes)
        XCTAssertEqual(r.sanitized, "Hello, world!")
    }

    func testCollapsesWhitespace() {
        let r = TextSanitizer.sanitize("Hello,    world\n\n with    spaces.")
        XCTAssertTrue(r.passes)
        XCTAssertEqual(r.sanitized, "Hello, world with spaces.")
    }

    func testStripsControlCharsButKeepsNewlineAndTab() {
        let withControls = "Hello\u{0007}\u{0008}world\n\tnext"
        let r = TextSanitizer.sanitize(withControls)
        XCTAssertTrue(r.passes)
        // Bell + backspace removed; newline + tab collapse to space via the
        // post-strip whitespace pass.
        XCTAssertFalse(r.sanitized!.contains("\u{0007}"))
        XCTAssertFalse(r.sanitized!.contains("\u{0008}"))
    }

    func testWarnsOnLongInput() {
        let long = String(repeating: "Lorem ipsum dolor sit amet. ", count: 80)  // ~2240 chars
        let r = TextSanitizer.sanitize(long)
        XCTAssertTrue(r.passes)
        if case .warning = r {
            // ok
        } else {
            XCTFail("Expected .warning for long input")
        }
    }

    func testRejectsAboveHardCap() {
        let huge = String(repeating: "x", count: TextSanitizer.maxCharacterCount + 1)
        let r = TextSanitizer.sanitize(huge)
        XCTAssertFalse(r.passes)
    }

    func testEmojiPassThroughIsNotRejected() {
        let r = TextSanitizer.sanitize("Hello 👋 world 🚀")
        XCTAssertTrue(r.passes)
    }
}
