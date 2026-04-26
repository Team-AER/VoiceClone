//
//  IncrementalAudioWriter.swift
//  PolyJuiceVoice
//

import AVFoundation
import Foundation

/// Streams synthesized PCM samples to a Float32 mono WAV file as they arrive,
/// so the view model can drop the in-memory `[Float]` accumulators that were
/// the dominant memory hotspot before/around playback start.
///
/// Also maintains a small bounded peak buffer (capped at ~`maxPeaks` floats)
/// for live waveform rendering — replaces the previous "downsample the entire
/// cumulative sample array on every chunk" pattern.
@MainActor
final class IncrementalAudioWriter {

    let url: URL
    let sampleRate: Double

    private(set) var sampleCount: Int = 0
    private(set) var peaks: [Float] = []

    private var audioFile: AVAudioFile?
    private let bucketSize: Int
    private var bucketRemaining: Int = 0
    private var bucketMax: Float = 0

    private static let peaksPerSecond = 50
    private static let maxPeaks = 500

    enum WriterError: LocalizedError {
        case alreadyFinalized
        case bufferAllocFailed

        var errorDescription: String? {
            switch self {
            case .alreadyFinalized:    return "Audio writer already finalized."
            case .bufferAllocFailed:   return "Failed to allocate write buffer."
            }
        }
    }

    init(sampleRate: Int = 24000) throws {
        self.sampleRate = Double(sampleRate)
        self.bucketSize = max(1, sampleRate / Self.peaksPerSecond)
        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent("polyjuicevoice_\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.audioFile = try AVAudioFile(forWriting: url, settings: settings)
    }

    func append(_ samples: [Float]) throws {
        guard let audioFile else { throw WriterError.alreadyFinalized }
        guard !samples.isEmpty else { return }

        let format = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw WriterError.bufferAllocFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let dest = buffer.floatChannelData![0]
        samples.withUnsafeBytes { src in
            _ = memcpy(dest, src.baseAddress, src.count)
        }
        try audioFile.write(from: buffer)

        sampleCount += samples.count
        updatePeaks(samples)
    }

    /// Closes the underlying file (which writes the final WAV header) and
    /// returns the file URL. Subsequent `append` calls throw.
    @discardableResult
    func finalize() -> URL {
        audioFile = nil
        return url
    }

    /// Best-effort delete of the partial file. Call from a `catch` when
    /// synthesis fails so we don't leak temp files.
    func discard() {
        audioFile = nil
        try? FileManager.default.removeItem(at: url)
    }

    var duration: TimeInterval {
        Double(sampleCount) / sampleRate
    }

    // MARK: - Peaks

    /// Bucketed per-chunk: append peak-of-bucket every `bucketSize` samples,
    /// then halve the buffer (pairs → max) when it exceeds `maxPeaks` so we
    /// stay within ~`maxPeaks * 4` bytes regardless of utterance length.
    private func updatePeaks(_ samples: [Float]) {
        var idx = 0
        while idx < samples.count {
            if bucketRemaining == 0 {
                bucketRemaining = bucketSize
                bucketMax = 0
            }
            let take = min(bucketRemaining, samples.count - idx)
            for j in 0..<take {
                let v = abs(samples[idx + j])
                if v > bucketMax { bucketMax = v }
            }
            idx += take
            bucketRemaining -= take
            if bucketRemaining == 0 {
                peaks.append(bucketMax)
            }
        }

        if peaks.count > Self.maxPeaks {
            var compacted: [Float] = []
            compacted.reserveCapacity((peaks.count + 1) / 2)
            for k in stride(from: 0, to: peaks.count, by: 2) {
                let a = peaks[k]
                let b = k + 1 < peaks.count ? peaks[k + 1] : a
                compacted.append(max(a, b))
            }
            peaks = compacted
        }
    }
}
