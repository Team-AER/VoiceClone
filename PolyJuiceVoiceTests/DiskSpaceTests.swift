//
//  DiskSpaceTests.swift
//  PolyJuiceVoiceTests
//

import XCTest
@testable import PolyJuiceVoice

final class DiskSpaceTests: XCTestCase {

    func testAvailableBytesForKnownDir() {
        let tmp = FileManager.default.temporaryDirectory
        let bytes = DiskSpace.availableBytes(at: tmp)
        XCTAssertNotNil(bytes)
        XCTAssertGreaterThan(bytes ?? 0, 0)
    }

    func testHasRoomForSmallAmount() {
        let tmp = FileManager.default.temporaryDirectory
        // 1 KB will always fit on a working machine.
        XCTAssertTrue(DiskSpace.hasRoomFor(1024, at: tmp))
    }

    func testHasRoomForRefusesAbsurdAmount() {
        let tmp = FileManager.default.temporaryDirectory
        // 1 PB is unlikely to fit on any test machine.
        XCTAssertFalse(DiskSpace.hasRoomFor(1_000_000_000_000_000, at: tmp))
    }

    func testFormatProducesHumanString() {
        let s = DiskSpace.format(4_500_000_000)
        XCTAssertTrue(s.contains("GB") || s.contains("MB"))
    }

    func testWalksUpForNonExistentURL() {
        let tmp = FileManager.default.temporaryDirectory
        let bogus = tmp.appendingPathComponent("does_not_exist_yet/even_deeper/file.bin")
        let bytes = DiskSpace.availableBytes(at: bogus)
        XCTAssertNotNil(bytes, "Should walk up to an existing parent")
    }
}
