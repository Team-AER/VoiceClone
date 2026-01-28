//
//  MemoryTests.swift
//  VoiceCloneTests
//

import XCTest
import Darwin
@testable import VoiceClone

final class MemoryTests: XCTestCase {

    func testMemoryFootprint() async throws {
        let modelsDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)

        let modelURL = modelsDir.appendingPathComponent("Qwen3TTS_CustomVoice_INT4.mlpackage")
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("CoreML models not found; skipping memory test.")
        }

        let modelManager = MLModelManager()

        let baselineMemory = currentMemoryUsage()
        _ = try await modelManager.loadModel(.customVoice)
        let loadedMemory = currentMemoryUsage()
        let memoryIncrease = loadedMemory - baselineMemory

        XCTAssertLessThan(memoryIncrease, 3_000_000_000)
    }

    private func currentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
