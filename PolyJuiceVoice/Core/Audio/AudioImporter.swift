//
//  AudioImporter.swift
//  PolyJuiceVoice
//

@preconcurrency import AVFoundation
import Foundation

/// Normalizes an arbitrary audio file (drag-and-drop, file picker) into the
/// same 24 kHz mono PCM16 WAV layout that `AudioRecorder` produces, so the
/// cloning pipeline can consume both sources interchangeably.
enum AudioImporter {

    enum ImportError: LocalizedError {
        case unreadable(String)
        case empty
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let msg): return "Couldn't read audio: \(msg)"
            case .empty:                return "The audio file is empty."
            case .writeFailed(let msg): return "Couldn't save converted audio: \(msg)"
            }
        }
    }

    /// Decode `sourceURL`, resample/downmix to 24 kHz mono Float32, then
    /// re-encode to a PCM16 WAV in the temp directory. Returns the WAV
    /// destination URL and its raw bytes.
    static func importAsReferenceWAV(from sourceURL: URL) throws -> (url: URL, data: Data) {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let inFile: AVAudioFile
        do {
            inFile = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }

        let inFormat = inFile.processingFormat
        let inFrames = AVAudioFrameCount(inFile.length)
        guard inFrames > 0 else { throw ImportError.empty }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inFrames) else {
            throw ImportError.unreadable("Couldn't allocate input buffer.")
        }
        do { try inFile.read(into: inBuffer) }
        catch { throw ImportError.unreadable(error.localizedDescription) }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ) else {
            throw ImportError.unreadable("Couldn't build target format.")
        }

        let needsConversion = inFormat.sampleRate != target.sampleRate
            || inFormat.channelCount != target.channelCount
            || inFormat.commonFormat != target.commonFormat

        let outBuffer: AVAudioPCMBuffer
        if needsConversion {
            guard let converter = AVAudioConverter(from: inFormat, to: target) else {
                throw ImportError.unreadable("Couldn't build audio converter.")
            }
            let ratio = target.sampleRate / inFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 1024)
            guard let buf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else {
                throw ImportError.unreadable("Couldn't allocate output buffer.")
            }
            // Same single-shot supply pattern as MLXTTSService.loadReferenceAudio.
            class _SupplyOnce: @unchecked Sendable { var fired = false }
            let supply = _SupplyOnce()
            var err: NSError?
            converter.convert(to: buf, error: &err) { _, status in
                if supply.fired { status.pointee = .endOfStream; return nil }
                supply.fired = true
                status.pointee = .haveData
                return inBuffer
            }
            if let err { throw ImportError.unreadable(err.localizedDescription) }
            outBuffer = buf
        } else {
            outBuffer = inBuffer
        }

        guard outBuffer.frameLength > 0 else { throw ImportError.empty }

        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("polyjuicevoice_imported_\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey:           Int(kAudioFormatLinearPCM),
            AVSampleRateKey:         24_000,
            AVNumberOfChannelsKey:   1,
            AVLinearPCMBitDepthKey:  16,
            AVLinearPCMIsFloatKey:   false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let outFile: AVAudioFile
        do {
            outFile = try AVAudioFile(forWriting: destURL, settings: settings)
        } catch {
            throw ImportError.writeFailed(error.localizedDescription)
        }
        do { try outFile.write(from: outBuffer) }
        catch { throw ImportError.writeFailed(error.localizedDescription) }

        let data: Data
        do { data = try Data(contentsOf: destURL) }
        catch { throw ImportError.writeFailed(error.localizedDescription) }

        return (destURL, data)
    }
}
