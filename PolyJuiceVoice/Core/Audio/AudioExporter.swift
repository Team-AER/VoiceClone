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
                return "No audio to export"
            case .writeFailed:
                return "Failed to write audio file"
            }
        }
    }

    /// Copies the synthesis-time WAV from `sourceURL` into a fresh export-named
    /// temp file. The synthesis writer already produces a valid Float32 mono
    /// WAV, so export is a file copy — no second encode pass, no second full
    /// `[Float]` allocation.
    static func exportWav(from sourceURL: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ExportError.noSamples
        }

        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("polyjuicevoice_export_\(UUID().uuidString).wav")

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            return destURL
        } catch {
            throw ExportError.writeFailed
        }
    }
}
