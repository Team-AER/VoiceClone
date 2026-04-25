//
//  AudioExporter.swift
//  PolyJuiceVoice
//

import Foundation

enum AudioExporter {

    enum ExportError: LocalizedError {
        case noSamples
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .noSamples:
                return "No audio samples to export"
            case .writeFailed:
                return "Failed to write audio file"
            }
        }
    }

    static func exportWav(samples: [Float], sampleRate: Int) throws -> URL {
        guard !samples.isEmpty else { throw ExportError.noSamples }

        let pcm16 = samples.map { sample -> Int16 in
            let clamped = max(-1, min(1, sample))
            return Int16(clamped * Float(Int16.max))
        }

        var data = Data()

        func append(_ value: UInt32) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: MemoryLayout<UInt32>.size))
        }

        func append(_ value: UInt16) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: MemoryLayout<UInt16>.size))
        }

        let bytesPerSample = UInt16(MemoryLayout<Int16>.size)
        let byteRate = UInt32(sampleRate) * UInt32(bytesPerSample)
        let blockAlign = bytesPerSample
        let dataSize = UInt32(pcm16.count * MemoryLayout<Int16>.size)

        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36) + dataSize)
        data.append("WAVE".data(using: .ascii)!)

        data.append("fmt ".data(using: .ascii)!)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(byteRate))
        append(UInt16(blockAlign))
        append(UInt16(16))

        data.append("data".data(using: .ascii)!)
        append(dataSize)

        pcm16.withUnsafeBytes { buffer in
            data.append(buffer.bindMemory(to: UInt8.self))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("polyjuicevoice_\(UUID().uuidString).wav")

        do {
            try data.write(to: url)
            return url
        } catch {
            throw ExportError.writeFailed
        }
    }
}
