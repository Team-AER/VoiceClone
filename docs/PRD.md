# VoiceClone iOS App — PRD & Technical Architecture

## Executive Summary

**VoiceClone** is a production-ready, open-source iOS application enabling on-device text-to-speech synthesis with voice cloning and voice design capabilities. Powered by Qwen3-TTS models running locally via CoreML/Metal, it requires no internet connection and keeps all voice data on-device.

**License**: Apache 2.0
**Platform**: iOS 17.0+ (iPhone/iPad)
**Models**: Qwen3-TTS-12Hz-1.7B-VoiceDesign, Qwen3-TTS-12Hz-1.7B-CustomVoice

---

## 1. Product Requirements

### 1.1 Core Features

| Feature | Description | Priority |
|---------|-------------|----------|
| **Text-to-Speech** | Convert text input to natural speech | P0 |
| **Voice Design** | Create custom voices from natural language descriptions | P0 |
| **Voice Cloning** | Clone voice from 3+ second audio reference | P0 |
| **Preset Voices** | Built-in voices (Vivian, Serena, Ryan, Aiden, etc.) | P0 |
| **Streaming Synthesis** | Real-time audio generation with 97ms latency target | P1 |
| **Multi-language** | 10 languages: EN, ZH, JA, KO, DE, FR, RU, PT, ES, IT | P1 |
| **Voice Library** | Save/manage custom and cloned voices locally | P1 |
| **Export Audio** | Export synthesized speech as WAV/M4A | P2 |
| **Batch Processing** | Queue multiple text segments for synthesis | P2 |

### 1.2 Non-Functional Requirements

| Requirement | Target | Notes |
|-------------|--------|-------|
| **First Token Latency** | <500ms | After model warm-up |
| **Streaming Latency** | <150ms | End-to-end on A17+ |
| **Model Load Time** | <8s | Cold start, quantized model |
| **Memory Footprint** | <3GB peak | During inference |
| **Storage** | ~2GB | Quantized models + app |
| **Offline Operation** | 100% | No network required post-download |
| **Battery Impact** | <5% per 10min synthesis | ANE-optimized |

### 1.3 Target Devices

| Tier | Devices | Experience |
|------|---------|------------|
| **Optimal** | iPhone 15 Pro+, iPad Pro M1+ | Full 1.7B, streaming |
| **Supported** | iPhone 13+, iPad Air M1+ | Quantized 1.7B, buffered |
| **Minimum** | iPhone 12, A14+ | 0.6B fallback model |

---

## 2. Technical Architecture

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        VoiceClone App                           │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │   SwiftUI   │  │  Voice      │  │   Audio                 │  │
│  │   Views     │◄─┤  Library    │  │   Playback              │  │
│  │             │  │  Manager    │  │   Engine                │  │
│  └──────┬──────┘  └──────┬──────┘  └───────────┬─────────────┘  │
│         │                │                     │                │
│  ┌──────▼────────────────▼─────────────────────▼──────────────┐ │
│  │                   TTSService (Actor)                       │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌────────────────────┐  │ │
│  │  │ Text        │  │ Voice       │  │ Audio              │  │ │
│  │  │ Processor   │  │ Embedder    │  │ Decoder            │  │ │
│  │  └──────┬──────┘  └──────┬──────┘  └─────────┬──────────┘  │ │
│  └─────────┼────────────────┼───────────────────┼─────────────┘ │
│            │                │                   │               │
│  ┌─────────▼────────────────▼───────────────────▼─────────────┐ │
│  │                 MLModelManager                             │ │
│  │  ┌──────────────────┐  ┌──────────────────────────────┐    │ │
│  │  │ CoreML Runtime   │  │ Metal Compute Pipeline       │    │ │
│  │  │ (ANE Optimized)  │  │ (Fallback / Hybrid)          │    │ │
│  │  └──────────────────┘  └──────────────────────────────┘    │ │
│  └────────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌────────────────┐   │
│  │ Model Storage   │  │ Voice Storage   │  │ Audio Cache    │   │
│  │ (App Bundle /   │  │ (Core Data +    │  │ (FileManager)  │   │
│  │  On-Demand)     │  │  Files)         │  │                │   │
│  └─────────────────┘  └─────────────────┘  └────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Model Architecture

#### Qwen3-TTS Pipeline

```
┌──────────────────────────────────────────────────────────────────┐
│                    Qwen3-TTS Inference Pipeline                  │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  INPUT                                                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐   │
│  │ Text        │  │ Language    │  │ Voice Condition         │   │
│  │ "Hello..."  │  │ "English"   │  │ (Instruct/Ref Audio/ID) │   │
│  └──────┬──────┘  └──────┬──────┘  └───────────┬─────────────┘   │
│         │                │                     │                 │
│         ▼                ▼                     ▼                 │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                    Text Tokenizer                          │  │
│  │            (Qwen3 Tokenizer, vocab=151936)                 │  │
│  └─────────────────────────┬──────────────────────────────────┘  │
│                            ▼                                     │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │              Transformer LM (1.7B params)                  │  │
│  │  ┌──────────────────────────────────────────────────────┐  │  │
│  │  │ 28 Layers, 2048 hidden, 16 heads, RoPE, SwiGLU       │  │  │
│  │  │ Multi-codebook output heads (16 codebooks × 2048)    │  │  │
│  │  └──────────────────────────────────────────────────────┘  │  │
│  └─────────────────────────┬──────────────────────────────────┘  │
│                            ▼                                     │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │           Speech Tokenizer Decoder (12Hz)                  │  │
│  │    Discrete codes → Waveform @ 24kHz sample rate           │  │
│  └─────────────────────────┬──────────────────────────────────┘  │
│                            ▼                                     │
│  OUTPUT                                                          │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │              Audio Waveform (Float32 PCM)                  │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

#### Model Variants

| Model | Use Case | Size (FP16) | Size (INT4) | iOS Target |
|-------|----------|-------------|-------------|------------|
| VoiceDesign-1.7B | Voice from description | ~3.4GB | ~1.1GB | Pro devices |
| CustomVoice-1.7B | Preset voices + instruct | ~3.4GB | ~1.1GB | Pro devices |
| Base-0.6B | Voice cloning (fallback) | ~1.2GB | ~400MB | All devices |

### 2.3 CoreML Conversion Strategy

#### Conversion Pipeline

```
PyTorch (BF16) → ONNX → CoreML (FP16) → CoreML (INT4-AWQ/GPTQ)
                                              ↓
                                    ANE-Optimized .mlpackage
```

#### Model Segmentation (Critical for iOS)

The 1.7B model must be split for iOS memory constraints:

```
┌─────────────────────────────────────────────────────────────┐
│                    Model Segments                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Segment 1: Embedding + Layers 0-6    (~300MB INT4)         │
│  Segment 2: Layers 7-13               (~300MB INT4)         │
│  Segment 3: Layers 14-20              (~300MB INT4)         │
│  Segment 4: Layers 21-27 + LM Heads   (~300MB INT4)         │
│  Segment 5: Speech Decoder            (~100MB FP16)         │
│                                                             │
│  Total: ~1.3GB on disk, <3GB runtime memory                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

#### Quantization Strategy

```python
# Conversion pseudocode
import coremltools as ct
from coremltools.optimize.coreml import (
    OptimizationConfig,
    OpLinearQuantizerConfig,
    quantize_weights
)

# INT4 block-wise quantization (preserve quality)
config = OptimizationConfig(
    global_config=OpLinearQuantizerConfig(
        mode="linear_symmetric",
        dtype="int4",
        granularity="per_block",
        block_size=32
    )
)

quantized_model = quantize_weights(fp16_model, config)
quantized_model.save("Qwen3TTS_INT4.mlpackage")
```

### 2.4 iOS Project Structure

```
VoiceClone/
├── App/
│   ├── VoiceCloneApp.swift              # @main entry
│   ├── AppState.swift                   # Global app state
│   └── Environment/
│       ├── DIContainer.swift            # Dependency injection
│       └── AppConfiguration.swift       # Feature flags, settings
│
├── Features/
│   ├── Synthesis/
│   │   ├── Views/
│   │   │   ├── SynthesisView.swift      # Main TTS interface
│   │   │   ├── TextInputView.swift      # Text editor component
│   │   │   ├── VoiceSelectorView.swift  # Voice picker
│   │   │   └── AudioPlayerView.swift    # Playback controls
│   │   ├── ViewModels/
│   │   │   └── SynthesisViewModel.swift # Synthesis orchestration
│   │   └── Models/
│   │       └── SynthesisRequest.swift   # Request DTOs
│   │
│   ├── VoiceDesign/
│   │   ├── Views/
│   │   │   ├── VoiceDesignView.swift    # Design new voices
│   │   │   └── InstructionEditor.swift  # NL instruction input
│   │   └── ViewModels/
│   │       └── VoiceDesignViewModel.swift
│   │
│   ├── VoiceClone/
│   │   ├── Views/
│   │   │   ├── VoiceCloneView.swift     # Clone from audio
│   │   │   ├── AudioRecorderView.swift  # Record reference
│   │   │   └── AudioImportView.swift    # Import from files
│   │   └── ViewModels/
│   │       └── VoiceCloneViewModel.swift
│   │
│   └── Library/
│       ├── Views/
│       │   ├── VoiceLibraryView.swift   # Saved voices list
│       │   └── VoiceDetailView.swift    # Voice preview/edit
│       └── ViewModels/
│           └── VoiceLibraryViewModel.swift
│
├── Core/
│   ├── TTS/
│   │   ├── TTSService.swift             # Main TTS actor
│   │   ├── TTSConfiguration.swift       # Model/inference config
│   │   ├── TTSError.swift               # Domain errors
│   │   └── StreamingAudioBuffer.swift   # Ring buffer for streaming
│   │
│   ├── ML/
│   │   ├── MLModelManager.swift         # Model lifecycle
│   │   ├── ModelLoader.swift            # Async model loading
│   │   ├── ModelCache.swift             # LRU model caching
│   │   ├── Tokenizer/
│   │   │   ├── Qwen3Tokenizer.swift     # Text tokenization
│   │   │   └── TokenizerVocab.swift     # Vocab handling
│   │   └── Inference/
│   │       ├── TTSInferenceEngine.swift # CoreML inference
│   │       ├── KVCache.swift            # Attention KV cache
│   │       └── SpeechDecoder.swift      # Audio decoding
│   │
│   ├── Audio/
│   │   ├── AudioEngine.swift            # AVAudioEngine wrapper
│   │   ├── AudioRecorder.swift          # Voice recording
│   │   ├── AudioExporter.swift          # WAV/M4A export
│   │   └── AudioProcessor.swift         # Resampling, normalization
│   │
│   └── Storage/
│       ├── VoiceStorage.swift           # Voice persistence
│       ├── CoreDataStack.swift          # Core Data setup
│       └── FileStorage.swift            # Audio file management
│
├── Shared/
│   ├── Extensions/
│   │   ├── MLMultiArray+Extensions.swift
│   │   ├── AVAudioPCMBuffer+Extensions.swift
│   │   └── Data+Audio.swift
│   ├── Components/
│   │   ├── WaveformView.swift           # Audio visualization
│   │   ├── LoadingOverlay.swift         # Model loading UI
│   │   └── LanguagePicker.swift         # Language selector
│   └── Utilities/
│       ├── PerformanceMonitor.swift     # FPS, memory tracking
│       └── HapticFeedback.swift         # Haptic patterns
│
├── Resources/
│   ├── Models/                          # CoreML models (downloaded)
│   │   ├── Qwen3TTS_VoiceDesign_INT4.mlpackage
│   │   ├── Qwen3TTS_CustomVoice_INT4.mlpackage
│   │   └── Qwen3TTS_SpeechDecoder.mlpackage
│   ├── Tokenizer/
│   │   ├── vocab.json
│   │   └── merges.txt
│   └── PresetVoices/
│       └── voices.json                  # Built-in voice metadata
│
└── Tests/
    ├── UnitTests/
    │   ├── TokenizerTests.swift
    │   ├── TTSServiceTests.swift
    │   └── AudioProcessorTests.swift
    └── IntegrationTests/
        └── InferenceTests.swift
```

### 2.5 Core Components

#### TTSService (Main Actor)

```swift
/// Thread-safe TTS service managing inference lifecycle
@globalActor actor TTSService {
    static let shared = TTSService()

    private let modelManager: MLModelManager
    private let tokenizer: Qwen3Tokenizer
    private let audioEngine: AudioEngine
    private let inferenceQueue = DispatchQueue(label: "tts.inference", qos: .userInitiated)

    enum State {
        case idle
        case loading
        case ready
        case synthesizing(progress: Double)
        case error(TTSError)
    }

    @Published private(set) var state: State = .idle

    // MARK: - Voice Design

    func synthesize(
        text: String,
        language: Language,
        instruction: String
    ) async throws -> AsyncStream<AudioChunk> {
        guard case .ready = state else {
            throw TTSError.modelNotLoaded
        }

        state = .synthesizing(progress: 0)

        return AsyncStream { continuation in
            Task {
                do {
                    let tokens = try tokenizer.encode(
                        text: text,
                        language: language,
                        instruction: instruction
                    )

                    for await chunk in try modelManager.streamInference(tokens: tokens) {
                        continuation.yield(chunk)
                    }

                    continuation.finish()
                    state = .ready
                } catch {
                    continuation.finish()
                    state = .error(.inferenceError(error))
                }
            }
        }
    }

    // MARK: - Voice Cloning

    func synthesize(
        text: String,
        language: Language,
        referenceAudio: Data,
        referenceText: String
    ) async throws -> AsyncStream<AudioChunk> {
        // Extract voice embedding from reference
        let voiceEmbedding = try await extractVoiceEmbedding(
            audio: referenceAudio,
            transcript: referenceText
        )

        return try await synthesize(
            text: text,
            language: language,
            voiceEmbedding: voiceEmbedding
        )
    }

    // MARK: - Preset Voices

    func synthesize(
        text: String,
        language: Language,
        speaker: PresetVoice,
        instruction: String? = nil
    ) async throws -> AsyncStream<AudioChunk> {
        let voiceId = speaker.embeddingId
        return try await synthesize(
            text: text,
            language: language,
            voiceId: voiceId,
            instruction: instruction
        )
    }
}
```

#### MLModelManager

```swift
/// Manages CoreML model loading, caching, and inference
final class MLModelManager: @unchecked Sendable {

    private var loadedModels: [ModelType: MLModel] = [:]
    private let modelCache = NSCache<NSString, MLModel>()
    private let loadLock = NSLock()

    enum ModelType: String, CaseIterable {
        case voiceDesign = "Qwen3TTS_VoiceDesign_INT4"
        case customVoice = "Qwen3TTS_CustomVoice_INT4"
        case speechDecoder = "Qwen3TTS_SpeechDecoder"
        case base06B = "Qwen3TTS_Base_06B_INT4"  // Fallback
    }

    struct ModelConfiguration {
        let computeUnits: MLComputeUnits
        let allowLowPrecision: Bool
        let useKVCache: Bool
        let maxSequenceLength: Int

        static let `default` = ModelConfiguration(
            computeUnits: .cpuAndNeuralEngine,
            allowLowPrecision: true,
            useKVCache: true,
            maxSequenceLength: 2048
        )

        static let memoryConstrained = ModelConfiguration(
            computeUnits: .cpuAndNeuralEngine,
            allowLowPrecision: true,
            useKVCache: true,
            maxSequenceLength: 1024
        )
    }

    func loadModel(_ type: ModelType, config: ModelConfiguration = .default) async throws -> MLModel {
        // Check cache first
        if let cached = loadedModels[type] {
            return cached
        }

        let modelURL = try modelURL(for: type)

        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = config.computeUnits
        mlConfig.allowLowPrecisionAccumulationOnGPU = config.allowLowPrecision

        // Compile model if needed (first launch)
        let compiledURL = try await compileIfNeeded(modelURL)

        let model = try await MLModel.load(contentsOf: compiledURL, configuration: mlConfig)

        loadLock.lock()
        loadedModels[type] = model
        loadLock.unlock()

        return model
    }

    func streamInference(
        tokens: [Int],
        model: MLModel,
        kvCache: KVCache
    ) -> AsyncThrowingStream<MLMultiArray, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                var position = 0

                while position < tokens.count {
                    let inputFeatures = try self.prepareInput(
                        tokens: tokens,
                        position: position,
                        kvCache: kvCache
                    )

                    let output = try model.prediction(from: inputFeatures)

                    guard let audioTokens = output.featureValue(for: "audio_tokens")?.multiArrayValue else {
                        throw TTSError.invalidOutput
                    }

                    continuation.yield(audioTokens)

                    // Update KV cache
                    kvCache.update(with: output)
                    position += 1
                }

                continuation.finish()
            }
        }
    }
}
```

#### KV Cache for Efficient Inference

```swift
/// Key-Value cache for transformer attention
final class KVCache {
    private var keyCache: [MLMultiArray]
    private var valueCache: [MLMultiArray]
    private let numLayers: Int
    private let maxLength: Int
    private var currentLength: Int = 0

    init(numLayers: Int = 28, numHeads: Int = 16, headDim: Int = 128, maxLength: Int = 2048) {
        self.numLayers = numLayers
        self.maxLength = maxLength

        // Pre-allocate cache buffers
        keyCache = (0..<numLayers).map { _ in
            try! MLMultiArray(shape: [1, numHeads, maxLength, headDim] as [NSNumber], dataType: .float16)
        }
        valueCache = (0..<numLayers).map { _ in
            try! MLMultiArray(shape: [1, numHeads, maxLength, headDim] as [NSNumber], dataType: .float16)
        }
    }

    func update(with output: MLFeatureProvider) {
        // Extract and append new KV entries
        for layer in 0..<numLayers {
            if let newK = output.featureValue(for: "key_\(layer)")?.multiArrayValue,
               let newV = output.featureValue(for: "value_\(layer)")?.multiArrayValue {
                appendToCache(layer: layer, key: newK, value: newV)
            }
        }
        currentLength += 1
    }

    func reset() {
        currentLength = 0
    }

    var cacheSlice: (keys: [MLMultiArray], values: [MLMultiArray]) {
        // Return only the filled portion
        return (keyCache, valueCache)
    }
}
```

#### Audio Engine

```swift
/// Manages audio playback with streaming support
final class AudioEngine: ObservableObject {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let mixerNode: AVAudioMixerNode

    private let sampleRate: Double = 24000
    private let bufferSize: AVAudioFrameCount = 4096

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0

    init() {
        mixerNode = engine.mainMixerNode
        engine.attach(playerNode)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        engine.connect(playerNode, to: mixerNode, format: format)
    }

    func playStream(_ stream: AsyncStream<AudioChunk>) async throws {
        try configureAudioSession()
        try engine.start()
        playerNode.play()
        isPlaying = true

        for await chunk in stream {
            let buffer = try createBuffer(from: chunk)
            playerNode.scheduleBuffer(buffer)
        }

        // Wait for playback to complete
        await withCheckedContinuation { continuation in
            playerNode.scheduleBuffer(AVAudioPCMBuffer(pcmFormat: playerNode.outputFormat(forBus: 0), frameCapacity: 1)!) {
                continuation.resume()
            }
        }

        isPlaying = false
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    private func createBuffer(from chunk: AudioChunk) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)) else {
            throw AudioError.bufferCreationFailed
        }

        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        let channelData = buffer.floatChannelData![0]

        for (index, sample) in chunk.samples.enumerated() {
            channelData[index] = sample
        }

        return buffer
    }
}
```

### 2.6 Data Models

```swift
// MARK: - Voice Models

struct Voice: Identifiable, Codable {
    let id: UUID
    var name: String
    var type: VoiceType
    var language: Language
    var createdAt: Date
    var instruction: String?           // For designed voices
    var referenceAudioURL: URL?        // For cloned voices
    var embeddingData: Data?           // Cached voice embedding

    enum VoiceType: String, Codable {
        case preset
        case designed
        case cloned
    }
}

enum PresetVoice: String, CaseIterable, Codable {
    case vivian = "Vivian"
    case serena = "Serena"
    case ryan = "Ryan"
    case aiden = "Aiden"
    // ... more presets

    var embeddingId: String { rawValue.lowercased() }
}

enum Language: String, CaseIterable, Codable {
    case english = "English"
    case chinese = "Chinese"
    case japanese = "Japanese"
    case korean = "Korean"
    case german = "German"
    case french = "French"
    case russian = "Russian"
    case portuguese = "Portuguese"
    case spanish = "Spanish"
    case italian = "Italian"

    var code: String {
        switch self {
        case .english: return "en"
        case .chinese: return "zh"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .german: return "de"
        case .french: return "fr"
        case .russian: return "ru"
        case .portuguese: return "pt"
        case .spanish: return "es"
        case .italian: return "it"
        }
    }
}

// MARK: - Audio Models

struct AudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let timestamp: TimeInterval
}

struct SynthesisRequest {
    let text: String
    let language: Language
    let voice: VoiceSelection
    let streaming: Bool

    enum VoiceSelection {
        case preset(PresetVoice, instruction: String?)
        case designed(instruction: String)
        case cloned(referenceAudio: Data, referenceText: String)
        case saved(Voice)
    }
}

struct SynthesisResult {
    let audio: Data
    let format: AudioFormat
    let duration: TimeInterval
    let sampleRate: Int

    enum AudioFormat {
        case wav
        case m4a
    }
}
```

### 2.7 Model Download & Management

```swift
/// Handles on-demand model downloading and updates
actor ModelDownloadManager {

    static let shared = ModelDownloadManager()

    private let fileManager = FileManager.default
    private let session: URLSession

    struct ModelInfo: Codable {
        let name: String
        let version: String
        let size: Int64
        let checksum: String
        let url: URL
    }

    private let modelManifestURL = URL(string: "https://huggingface.co/YourOrg/VoiceClone-iOS/resolve/main/manifest.json")!

    @Published private(set) var downloadProgress: [String: Double] = [:]

    func ensureModelsAvailable(for capability: ModelCapability) async throws {
        let requiredModels = capability.requiredModels

        for model in requiredModels {
            if !isModelDownloaded(model) {
                try await downloadModel(model)
            }
        }
    }

    private func downloadModel(_ info: ModelInfo) async throws {
        let destinationURL = modelStorageURL(for: info.name)

        let (tempURL, response) = try await session.download(from: info.url) { progress in
            Task { @MainActor in
                self.downloadProgress[info.name] = progress.fractionCompleted
            }
        }

        // Verify checksum
        let downloadedChecksum = try computeSHA256(of: tempURL)
        guard downloadedChecksum == info.checksum else {
            throw ModelError.checksumMismatch
        }

        // Move to final location
        try fileManager.moveItem(at: tempURL, to: destinationURL)

        downloadProgress[info.name] = nil
    }

    func deleteModel(_ name: String) throws {
        let url = modelStorageURL(for: name)
        try fileManager.removeItem(at: url)
    }

    var totalModelSize: Int64 {
        // Calculate total size of downloaded models
        // ...
    }
}

enum ModelCapability {
    case voiceDesign
    case voiceClone
    case customVoice

    var requiredModels: [ModelDownloadManager.ModelInfo] {
        switch self {
        case .voiceDesign:
            return [.voiceDesign17B, .speechDecoder]
        case .voiceClone:
            return [.base17B, .speechDecoder]
        case .customVoice:
            return [.customVoice17B, .speechDecoder]
        }
    }
}
```

---

## 3. UI/UX Design

### 3.1 Navigation Structure

```
┌─────────────────────────────────────────┐
│              Tab Bar                    │
├─────────┬─────────┬─────────┬───────────┤
│ Speak   │ Design  │ Clone   │ Library   │
│  🎤     │   ✨    │   🎙    │    📚     │
└─────────┴─────────┴─────────┴───────────┘
```

### 3.2 Key Screens

#### Speak Tab (Main TTS)
```
┌─────────────────────────────────┐
│ ◀ Voice: Ryan ▼                │
├─────────────────────────────────┤
│                                 │
│  ┌───────────────────────────┐  │
│  │                           │  │
│  │   Enter text to speak...  │  │
│  │                           │  │
│  │                           │  │
│  └───────────────────────────┘  │
│                                 │
│  Language: English ▼            │
│                                 │
│  ┌─────────────────────────┐    │
│  │ ░░░░░░░░░░░░░░░░░░░░░░░ │    │  ← Waveform
│  └─────────────────────────┘    │
│                                 │
│       ◀◀   ▶   ▶▶   ↓          │  ← Controls
│                    Export       │
│                                 │
│  [ Speak ]                      │
│                                 │
└─────────────────────────────────┘
```

#### Design Tab (Voice Design)
```
┌─────────────────────────────────┐
│ Create a New Voice              │
├─────────────────────────────────┤
│                                 │
│  Describe the voice:            │
│  ┌───────────────────────────┐  │
│  │ A warm, friendly female   │  │
│  │ voice with a slight       │  │
│  │ British accent...         │  │
│  └───────────────────────────┘  │
│                                 │
│  Test text:                     │
│  ┌───────────────────────────┐  │
│  │ Hello, welcome to our     │  │
│  │ app!                      │  │
│  └───────────────────────────┘  │
│                                 │
│  [ Preview Voice ]              │
│                                 │
│  ┌─────────────────────────┐    │
│  │ ▶  Preview playback...  │    │
│  └─────────────────────────┘    │
│                                 │
│  [ Save to Library ]            │
│                                 │
└─────────────────────────────────┘
```

#### Clone Tab (Voice Cloning)
```
┌─────────────────────────────────┐
│ Clone a Voice                   │
├─────────────────────────────────┤
│                                 │
│  Reference Audio (3+ seconds):  │
│  ┌───────────────────────────┐  │
│  │  🎙 Record   📁 Import    │  │
│  └───────────────────────────┘  │
│                                 │
│  ┌───────────────────────────┐  │
│  │ ▶ 0:05.2 ████████░░░░░░  │  │  ← Recorded audio
│  └───────────────────────────┘  │
│                                 │
│  Transcript of reference:       │
│  ┌───────────────────────────┐  │
│  │ This is a sample of my   │  │
│  │ voice for cloning.       │  │
│  └───────────────────────────┘  │
│                                 │
│  [ Clone Voice ]                │
│                                 │
│  Processing... ████████░░ 80%   │
│                                 │
└─────────────────────────────────┘
```

### 3.3 Design Tokens

```swift
extension Color {
    static let vcPrimary = Color("VCPrimary")       // #6366F1 Indigo
    static let vcSecondary = Color("VCSecondary")   // #8B5CF6 Purple
    static let vcAccent = Color("VCAccent")         // #06B6D4 Cyan
    static let vcBackground = Color("VCBackground") // System background
    static let vcSurface = Color("VCSurface")       // Elevated surface
}

extension Font {
    static let vcTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let vcHeadline = Font.system(.headline, design: .rounded, weight: .semibold)
    static let vcBody = Font.system(.body, design: .default)
    static let vcCaption = Font.system(.caption, design: .default)
}
```

---

## 4. Performance Optimization

### 4.1 Memory Management

```swift
/// Memory-aware model loading strategy
final class MemoryAwareLoader {

    private let memoryPressureSource: DispatchSourceMemoryPressure

    init() {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )

        memoryPressureSource.setEventHandler { [weak self] in
            self?.handleMemoryPressure()
        }

        memoryPressureSource.resume()
    }

    func selectModelConfiguration() -> MLModelManager.ModelConfiguration {
        let availableMemory = ProcessInfo.processInfo.physicalMemory
        let usedMemory = mach_task_basic_info().resident_size
        let freeMemory = availableMemory - usedMemory

        if freeMemory > 4_000_000_000 {  // >4GB free
            return .default
        } else if freeMemory > 2_000_000_000 {  // >2GB free
            return .memoryConstrained
        } else {
            return .minimal  // Use 0.6B model
        }
    }

    private func handleMemoryPressure() {
        // Evict cached models, reduce buffer sizes
        MLModelManager.shared.evictLRUModels()
        KVCache.shared.truncate(to: 512)
    }
}
```

### 4.2 Thermal Management

```swift
/// Monitors thermal state and adjusts inference
final class ThermalManager: ObservableObject {

    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    private var observer: NSObjectProtocol?

    init() {
        thermalState = ProcessInfo.processInfo.thermalState

        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    var shouldThrottle: Bool {
        thermalState == .serious || thermalState == .critical
    }

    var recommendedBatchSize: Int {
        switch thermalState {
        case .nominal: return 8
        case .fair: return 4
        case .serious: return 2
        case .critical: return 1
        @unknown default: return 4
        }
    }
}
```

### 4.3 Background Processing

```swift
extension TTSService {

    /// Process long text in background with progress updates
    func synthesizeInBackground(
        text: String,
        voice: Voice
    ) async throws -> URL {

        let taskId = UIApplication.shared.beginBackgroundTask {
            // Handle expiration
        }

        defer {
            UIApplication.shared.endBackgroundTask(taskId)
        }

        // Split text into chunks
        let chunks = text.splitIntoSentences()
        var audioSegments: [Data] = []

        for (index, chunk) in chunks.enumerated() {
            let audio = try await synthesize(text: chunk, voice: voice)
            audioSegments.append(audio)

            // Post progress
            NotificationCenter.default.post(
                name: .synthesisProgress,
                object: nil,
                userInfo: ["progress": Double(index + 1) / Double(chunks.count)]
            )
        }

        // Concatenate and save
        let outputURL = try AudioExporter.concatenate(audioSegments)
        return outputURL
    }
}
```

---

## 5. Testing Strategy

### 5.1 Test Categories

| Category | Coverage Target | Tools |
|----------|-----------------|-------|
| Unit Tests | 80% | XCTest |
| Integration Tests | Key flows | XCTest + fixtures |
| UI Tests | Critical paths | XCUITest |
| Performance Tests | Latency, memory | XCTest Metrics |
| Snapshot Tests | UI components | swift-snapshot-testing |

### 5.2 Sample Test Cases

```swift
final class TTSServiceTests: XCTestCase {

    var sut: TTSService!

    override func setUp() async throws {
        sut = TTSService()
        try await sut.loadModel(.customVoice)
    }

    func testSynthesisWithPresetVoice() async throws {
        // Given
        let text = "Hello, world!"
        let voice = PresetVoice.ryan

        // When
        var chunks: [AudioChunk] = []
        for try await chunk in sut.synthesize(text: text, voice: .preset(voice, instruction: nil)) {
            chunks.append(chunk)
        }

        // Then
        XCTAssertFalse(chunks.isEmpty)
        let totalSamples = chunks.reduce(0) { $0 + $1.samples.count }
        XCTAssertGreaterThan(totalSamples, 0)
    }

    func testFirstTokenLatency() async throws {
        // Given
        let text = "Quick test"

        // When
        let start = CFAbsoluteTimeGetCurrent()
        var firstChunkTime: CFAbsoluteTime?

        for try await _ in sut.synthesize(text: text, voice: .preset(.vivian, instruction: nil)) {
            if firstChunkTime == nil {
                firstChunkTime = CFAbsoluteTimeGetCurrent()
            }
        }

        // Then
        let latency = (firstChunkTime! - start) * 1000  // ms
        XCTAssertLessThan(latency, 500, "First token latency should be under 500ms")
    }
}
```

---

## 6. Release Plan

### 6.1 Milestones

| Milestone | Deliverables | Duration |
|-----------|--------------|----------|
| **M1: Foundation** | Project setup, CoreML conversion pipeline, basic inference | 2 weeks |
| **M2: Core TTS** | Streaming synthesis, preset voices, audio playback | 2 weeks |
| **M3: Voice Features** | Voice design, voice cloning, library management | 2 weeks |
| **M4: Polish** | Performance optimization, UI refinement, error handling | 1 week |
| **M5: Release** | Testing, documentation, App Store submission | 1 week |

### 6.2 Model Conversion Pipeline

```bash
# 1. Export to ONNX
python export_onnx.py \
    --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
    --output qwen3_tts_voicedesign.onnx

# 2. Convert to CoreML
python -m coremltools.converters.onnx \
    qwen3_tts_voicedesign.onnx \
    --output Qwen3TTS_VoiceDesign.mlpackage \
    --minimum-deployment-target iOS17

# 3. Quantize to INT4
python quantize_coreml.py \
    --input Qwen3TTS_VoiceDesign.mlpackage \
    --output Qwen3TTS_VoiceDesign_INT4.mlpackage \
    --bits 4 \
    --granularity per_block
```

### 6.3 Open Source Deliverables

```
VoiceClone/
├── LICENSE                    # Apache 2.0
├── README.md                  # Setup & usage guide
├── CONTRIBUTING.md            # Contribution guidelines
├── CHANGELOG.md               # Version history
├── docs/
│   ├── ARCHITECTURE.md        # This document
│   ├── MODEL_CONVERSION.md    # CoreML conversion guide
│   └── API_REFERENCE.md       # Swift API docs
├── scripts/
│   ├── convert_models.py      # ONNX → CoreML conversion
│   ├── quantize.py            # INT4 quantization
│   └── benchmark.py           # Performance benchmarks
└── VoiceClone.xcodeproj/      # iOS app project
```

---

## 7. Risk Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| 1.7B model too large for device | High | INT4 quantization, 0.6B fallback, model segmentation |
| CoreML conversion issues | High | Hybrid CoreML + Metal compute, ONNX Runtime fallback |
| Audio quality degradation | Medium | Preserve FP16 for speech decoder, A/B testing |
| Memory pressure crashes | High | Aggressive memory monitoring, graceful degradation |
| Thermal throttling | Medium | Adaptive batch size, background processing limits |

---

## 8. Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| App Store Rating | ≥4.5 stars | App Store Connect |
| Crash-free Rate | ≥99.5% | Firebase Crashlytics |
| First Synthesis Latency | <500ms | In-app analytics |
| User Retention (D7) | ≥40% | Analytics |
| Model Download Success | ≥98% | Backend metrics |

---

## References

- [Qwen3-TTS GitHub Repository](https://github.com/QwenLM/Qwen3-TTS)
- [Qwen3-TTS Technical Report](https://arxiv.org/html/2601.15621v1)
- [Qwen3-TTS-12Hz-1.7B-VoiceDesign](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign)
- [Qwen3-TTS-12Hz-1.7B-CustomVoice](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice)
- [FluidAudio CoreML Framework](https://github.com/FluidInference/FluidAudio)
- [Apple CoreML Documentation](https://developer.apple.com/documentation/coreml)
- [ONNX Runtime CoreML Execution Provider](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)
