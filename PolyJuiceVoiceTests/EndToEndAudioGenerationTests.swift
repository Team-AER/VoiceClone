//
//  EndToEndAudioGenerationTests.swift
//  PolyJuiceVoiceTests
//
//  Drives MLXTTSService through the real vendored Qwen3TTSModel for whichever
//  snapshots are present on disk. Tests skip gracefully when no compatible
//  snapshot is installed for the capability under test, so CI works against
//  any subset of the (family × capability × precision) matrix.
//
//  Snapshot install hint:
//    ~/Library/Application Support/PolyJuiceVoice/MLXModels/
//      Qwen3TTS-0.6B-CustomVoice-bf16/
//      Qwen3TTS-0.6B-Base-bf16/
//      Qwen3TTS-1.7B-VoiceDesign-bf16/
//    (or any of the 4/5/6/8-bit sibling directories)
//

import XCTest
@testable import PolyJuiceVoice

@available(macOS 15.0, iOS 18.0, *)
@MainActor
final class EndToEndAudioGenerationTests: XCTestCase {

    private var audioEngine: AudioEngine!
    private var service: MLXTTSService!

    override func setUp() async throws {
        try await super.setUp()
        audioEngine = AudioEngine()
        service = MLXTTSService(audioEngine: audioEngine)
    }

    override func tearDown() async throws {
        service.stop()
        service = nil
        audioEngine = nil
        try await super.tearDown()
    }

    // MARK: - Preset (CustomVoice) snapshot

    func testEndToEndCustomVoice() async throws {
        let snapshot = try installedSnapshot(for: .customVoice)
        try await service.load(snapshot)
        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(service.loadedSnapshot, snapshot)

        let stream = try await service.synthesize(
            text: "The quick brown fox jumps over the lazy dog.",
            language: .english,
            speaker: .ryan
        )
        let (chunks, samples) = try await collectAudio(from: stream)
        assertValidAudio(chunks: chunks, samples: samples, label: "customVoice(.ryan)")
    }

    func testCustomVoiceWithInstruct() async throws {
        let snapshot = try installedSnapshot(for: .customVoice)
        try await service.load(snapshot)
        let stream = try await service.synthesize(
            text: "Hello, this is a calm and warm sample.",
            language: .english,
            speaker: .ryan,
            instruction: "Speak in a calm, warm tone."
        )
        let (chunks, samples) = try await collectAudio(from: stream)
        assertValidAudio(chunks: chunks, samples: samples, label: "customVoice(.ryan)+instruct")
    }

    // MARK: - VoiceDesign snapshot

    func testEndToEndVoiceDesign() async throws {
        let snapshot = try installedSnapshot(for: .voiceDesign)
        try await service.load(snapshot)
        XCTAssertEqual(service.loadedSnapshot, snapshot)

        let stream = try await service.synthesize(
            text: "Hello, this is a voice design synthesis test.",
            language: .english,
            instruction: "A warm female voice with a friendly tone."
        )
        let (chunks, samples) = try await collectAudio(from: stream)
        assertValidAudio(chunks: chunks, samples: samples, label: "voiceDesign")
    }

    // MARK: - Voice Clone (Base) snapshot

    func testEndToEndVoiceCloning() async throws {
        let snapshot = try installedSnapshot(for: .voiceClone)
        // Step 1: produce a reference clip using the Base snapshot's preset path.
        try await service.load(snapshot)
        let refStream = try await service.synthesize(
            text: "This is a short reference recording for cloning.",
            language: .english,
            speaker: .ryan
        )
        let (_, refSamples) = try await collectAudio(from: refStream)
        XCTAssertGreaterThan(refSamples.count, 24_000, "Reference clip too short")
        let refData = try makeWav(samples: refSamples, sampleRate: 24_000)

        // Step 2: clone from that reference (same snapshot — Base covers both).
        XCTAssertEqual(service.loadedSnapshot, snapshot)
        let stream = try await service.synthesize(
            text: "Hello, this is my cloned voice speaking.",
            language: .english,
            referenceAudio: refData,
            referenceText: "This is a short reference recording for cloning."
        )
        let (chunks, samples) = try await collectAudio(from: stream)
        assertValidAudio(chunks: chunks, samples: samples, label: "voiceClone")
    }

    /// Regression: switching capability mid-flight (CustomVoice loaded → ask
    /// for voice cloning) must not throw "Capability not loaded: voiceClone".
    func testCapabilitySwapDoesNotRace() async throws {
        let baseSnapshot = try installedSnapshot(for: .voiceClone)
        // Load the snapshot once — Base satisfies both customVoice and
        // voiceClone, so no actual swap happens. (This regression mattered
        // most when the two capabilities mapped to different on-disk
        // snapshots — now the post-matrix view models route via the
        // selection store and the service stays put.)
        try await service.load(baseSnapshot)
        XCTAssertEqual(service.loadedSnapshot, baseSnapshot)

        let refStream = try await service.synthesize(
            text: "Reference clip.",
            language: .english,
            speaker: .ryan
        )
        let (_, refSamples) = try await collectAudio(from: refStream)
        let refData = try makeWav(samples: refSamples, sampleRate: 24_000)

        let stream = try await service.synthesize(
            text: "Cloned reply.",
            language: .english,
            referenceAudio: refData,
            referenceText: "Reference clip."
        )
        let (chunks, samples) = try await collectAudio(from: stream)
        assertValidAudio(chunks: chunks, samples: samples, label: "swap-race")
    }

    // MARK: - Common audio output asserts

    func testAudioOutputFormat() async throws {
        let snapshot = try installedSnapshot(for: .customVoice)
        try await service.load(snapshot)
        let stream = try await service.synthesize(
            text: "Format check.",
            language: .english,
            speaker: .ryan
        )
        for try await chunk in stream {
            XCTAssertEqual(chunk.sampleRate, 24000, "Sample rate must be 24 kHz")
            XCTAssertFalse(chunk.samples.isEmpty, "Chunk must not be empty")
            for sample in chunk.samples {
                XCTAssertTrue(sample.isFinite, "Non-finite sample: \(sample)")
            }
            let peak = chunk.samples.map(abs).max() ?? 0
            XCTAssertLessThanOrEqual(peak, 2.0, "Peak amplitude \(peak) out of range")
        }
    }

    func testServiceStateTransitions() async throws {
        let snapshot = try installedSnapshot(for: .customVoice)
        XCTAssertEqual(service.state, .idle)
        try await service.load(snapshot)
        XCTAssertEqual(service.state, .ready)
        XCTAssertTrue(service.loadedCapabilities.contains(.customVoice))

        let stream = try await service.synthesize(
            text: "State transition test.",
            language: .english,
            speaker: .ryan
        )
        for try await _ in stream {}
        XCTAssertEqual(service.state, .ready)
    }

    // MARK: - Chunked synthesis & responsiveness

    func testLongTextProducesMultipleChunks() async throws {
        let snapshot = try installedSnapshot(for: .customVoice)
        try await service.load(snapshot)
        let longText = String(repeating:
            "The quick brown fox jumps over the lazy dog. " +
            "Pack my box with five dozen liquor jugs. " +
            "How vexingly quick daft zebras jump. ", count: 4)

        let stream = try await service.synthesize(
            text: longText,
            language: .english,
            speaker: .ryan
        )
        let (chunks, samples) = try await collectAudio(from: stream)
        assertValidAudio(chunks: chunks, samples: samples, label: "longText")

        XCTAssertGreaterThan(chunks.count, 1,
                             "Long text should yield more than one AudioChunk")
        XCTAssertEqual(service.lastSynthesisChunkCount, chunks.count,
                       "Reported chunk count should match yielded chunk count")
    }

    func testMainActorStaysResponsiveDuringSynthesis() async throws {
        let snapshot = try installedSnapshot(for: .customVoice)
        try await service.load(snapshot)
        let longText = String(repeating:
            "The quick brown fox jumps over the lazy dog. ", count: 8)

        let beats = MainActorCounter()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                beats.increment()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { heartbeat.cancel() }

        let start = Date()
        let stream = try await service.synthesize(
            text: longText,
            language: .english,
            speaker: .ryan
        )
        for try await _ in stream {}
        let elapsed = Date().timeIntervalSince(start)
        heartbeat.cancel()

        let beatCount = beats.value
        let expectedMin = max(1, Int(elapsed * 0.5))
        XCTAssertGreaterThanOrEqual(
            beatCount, expectedMin,
            "MainActor heartbeat fired only \(beatCount) times in \(elapsed)s — synthesis is blocking the main thread."
        )
    }

    // MARK: - Inference throughput regression

    func testInferenceThroughputAcceptable() async throws {
        let snapshot = try installedSnapshot(for: .customVoice)
        try await service.load(snapshot)
        let stream = try await service.synthesize(
            text: "The quick brown fox jumps over the lazy dog.",
            language: .english,
            speaker: .ryan
        )
        let (_, samples) = try await collectAudio(from: stream)

        let audioSeconds = Double(samples.count) / 24_000.0
        let genSeconds = service.lastSynthesisDuration
        let realtimeFactor = genSeconds / audioSeconds

        XCTAssertLessThan(
            realtimeFactor, 4.0,
            "Generation took \(String(format: "%.2f", realtimeFactor))× realtime " +
            "(\(String(format: "%.2f", genSeconds))s for \(String(format: "%.2f", audioSeconds))s of audio). " +
            "Inner-loop GPU syncs may have been reintroduced."
        )
    }

    // MARK: - GPU usage proof

    func testGPUWasActuallyUsed() async throws {
        let snapshot = try installedSnapshot(for: .customVoice)
        try await service.load(snapshot)
        let stream = try await service.synthesize(
            text: "GPU usage check.",
            language: .english,
            speaker: .ryan
        )
        for try await _ in stream {}

        let peakMB = Double(service.lastSynthesisPeakGPUBytes) / (1024.0 * 1024.0)
        XCTAssertGreaterThan(
            peakMB, 100.0,
            "GPU peak only \(peakMB) MB — looks like inference fell back to CPU."
        )
        XCTAssertGreaterThan(service.lastSynthesisDuration, 0.0,
                             "Synthesis duration was not recorded.")
    }

    // MARK: - Snapshot gate semantics

    /// Asking to load a missing snapshot should throw `snapshotNotInstalled`.
    func testMissingSnapshotThrows() async throws {
        let absent = ModelSnapshot.allCases.first { !ModelDownloadManager.isInstalled($0) }
        guard let target = absent else {
            throw XCTSkip("All snapshots are installed; no negative case to exercise.")
        }
        do {
            try await service.load(target)
            XCTFail("Expected snapshotNotInstalled error for \(target.directoryName)")
        } catch let TTSError.snapshotNotInstalled(snap) {
            XCTAssertEqual(snap, target)
        } catch {
            XCTFail("Expected snapshotNotInstalled, got \(error)")
        }
    }

    // MARK: - Helpers

    /// Pick any installed snapshot whose capability matches `capability`.
    /// Skips when nothing is installed for it.
    private func installedSnapshot(for capability: TTSCapability) throws -> ModelSnapshot {
        let candidates = capability.compatibleSnapshots
        if let installed = candidates.first(where: { ModelDownloadManager.isInstalled($0) }) {
            return installed
        }
        throw XCTSkip(
            "No installed snapshot satisfies \(capability.displayName). " +
            "Run the app and download one from the Model Manager."
        )
    }

    private func collectAudio(
        from stream: AsyncThrowingStream<AudioChunk, Error>
    ) async throws -> (chunks: [AudioChunk], samples: [Float]) {
        var chunks: [AudioChunk] = []
        var samples: [Float] = []
        for try await chunk in stream {
            chunks.append(chunk)
            samples.append(contentsOf: chunk.samples)
        }
        return (chunks, samples)
    }

    private func assertValidAudio(chunks: [AudioChunk], samples: [Float], label: String) {
        XCTAssertFalse(chunks.isEmpty, "[\(label)] No AudioChunk produced")
        XCTAssertFalse(samples.isEmpty, "[\(label)] No audio samples")
        XCTAssertEqual(chunks[0].sampleRate, 24000, "[\(label)] Sample rate must be 24 kHz")

        let durationSec = Float(samples.count) / 24_000.0
        XCTAssertGreaterThan(durationSec, 0.1, "[\(label)] Audio too short (\(durationSec)s)")

        let nonFinite = samples.filter { !$0.isFinite }.count
        XCTAssertEqual(nonFinite, 0, "[\(label)] \(nonFinite) non-finite samples")

        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        XCTAssertGreaterThan(rms, 1e-4, "[\(label)] Audio appears silent (RMS=\(rms))")
    }

    @MainActor private final class MainActorCounter {
        private(set) var value: Int = 0
        func increment() { value += 1 }
    }

    private func makeWav(samples: [Float], sampleRate: Int) throws -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate * Int(channels) * Int(bitsPerSample) / 8)
        let blockAlign = UInt16(Int(channels) * Int(bitsPerSample) / 8)

        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            let v = Int16(clamped * 32767.0)
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }

        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        var totalSize = UInt32(36 + pcm.count).littleEndian
        withUnsafeBytes(of: &totalSize) { wav.append(contentsOf: $0) }
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        var fmtChunkSize = UInt32(16).littleEndian
        withUnsafeBytes(of: &fmtChunkSize) { wav.append(contentsOf: $0) }
        var audioFormat = UInt16(1).littleEndian
        withUnsafeBytes(of: &audioFormat) { wav.append(contentsOf: $0) }
        var ch = channels.littleEndian
        withUnsafeBytes(of: &ch) { wav.append(contentsOf: $0) }
        var sr = UInt32(sampleRate).littleEndian
        withUnsafeBytes(of: &sr) { wav.append(contentsOf: $0) }
        var br = byteRate.littleEndian
        withUnsafeBytes(of: &br) { wav.append(contentsOf: $0) }
        var ba = blockAlign.littleEndian
        withUnsafeBytes(of: &ba) { wav.append(contentsOf: $0) }
        var bps = bitsPerSample.littleEndian
        withUnsafeBytes(of: &bps) { wav.append(contentsOf: $0) }
        wav.append("data".data(using: .ascii)!)
        var dataChunkSize = UInt32(pcm.count).littleEndian
        withUnsafeBytes(of: &dataChunkSize) { wav.append(contentsOf: $0) }
        wav.append(pcm)
        return wav
    }
}
