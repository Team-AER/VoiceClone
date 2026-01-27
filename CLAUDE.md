# CLAUDE.md - VoiceClone Project Guide

This file provides context and guidelines for AI assistants (Claude) working on the VoiceClone iOS project.

---

## Project Overview

**VoiceClone** is an open-source iOS application for on-device text-to-speech synthesis with voice cloning and voice design capabilities. It uses Qwen3-TTS models converted to CoreML for fully offline operation.

### Key Facts
- **Platform**: iOS 17.0+ (iPhone/iPad)
- **Language**: Swift 6.0 with strict concurrency
- **UI Framework**: SwiftUI
- **ML Framework**: CoreML with ANE optimization
- **Models**: Qwen3-TTS-12Hz-1.7B (VoiceDesign, CustomVoice)
- **License**: Apache 2.0

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│                         App Layer                           │
│  SwiftUI Views → ViewModels → Services                      │
├─────────────────────────────────────────────────────────────┤
│                        Core Layer                           │
│  TTSService │ MLModelManager │ AudioEngine │ VoiceStorage   │
├─────────────────────────────────────────────────────────────┤
│                      Infrastructure                         │
│  CoreML │ AVFoundation │ CoreData │ FileManager            │
└─────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `TTSService` | `Core/TTS/TTSService.swift` | Main TTS orchestration |
| `MLModelManager` | `Core/ML/MLModelManager.swift` | Model loading/caching |
| `TTSInferenceEngine` | `Core/ML/Inference/TTSInferenceEngine.swift` | CoreML inference |
| `KVCache` | `Core/ML/Inference/KVCache.swift` | Attention KV cache |
| `Qwen3Tokenizer` | `Core/ML/Tokenizer/Qwen3Tokenizer.swift` | Text tokenization |
| `AudioEngine` | `Core/Audio/AudioEngine.swift` | Playback with streaming |

---

## Code Style Guidelines

### Swift Conventions

```swift
// ✅ DO: Use actors for thread-safe state
actor TTSService {
    private var state: State = .idle
}

// ✅ DO: Use @MainActor for UI-bound classes
@MainActor
final class SynthesisViewModel: ObservableObject { }

// ✅ DO: Use structured concurrency
func synthesize() async throws -> AsyncThrowingStream<AudioChunk, Error> { }

// ❌ DON'T: Use DispatchQueue for concurrency
// ❌ DON'T: Force unwrap optionals
// ❌ DON'T: Use implicitly unwrapped optionals except for @IBOutlet
```

### Naming Conventions

```swift
// Types: PascalCase
struct AudioChunk { }
enum Language { }
protocol TTSServiceProtocol { }

// Properties/Methods: camelCase
let sampleRate: Int
func loadModel(_ type: ModelType) async throws

// Constants: camelCase (not SCREAMING_CASE)
let maxSequenceLength = 2048

// Files: Match primary type name
// AudioEngine.swift contains `class AudioEngine`
```

### Error Handling

```swift
// ✅ DO: Define domain-specific errors
enum TTSError: LocalizedError {
    case modelNotLoaded
    case inferenceError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "TTS model is not loaded"
        case .inferenceError(let error):
            return "Inference failed: \(error.localizedDescription)"
        }
    }
}

// ✅ DO: Propagate errors with context
func synthesize() async throws {
    guard let model = loadedModel else {
        throw TTSError.modelNotLoaded
    }
}

// ❌ DON'T: Swallow errors silently
// ❌ DON'T: Use try! in production code
```

### SwiftUI Patterns

```swift
// ✅ DO: Use @StateObject for owned ViewModels
struct SynthesisView: View {
    @StateObject private var viewModel = SynthesisViewModel()
}

// ✅ DO: Use @EnvironmentObject for shared dependencies
struct ChildView: View {
    @EnvironmentObject var container: DIContainer
}

// ✅ DO: Extract subviews for readability
struct SynthesisView: View {
    var body: some View {
        VStack {
            textEditor      // Computed property
            controlButtons  // Computed property
        }
    }

    private var textEditor: some View {
        TextEditor(text: $viewModel.text)
    }
}

// ❌ DON'T: Put business logic in Views
// ❌ DON'T: Use @ObservedObject for ViewModels owned by the view
```

---

## Common Tasks

### Adding a New Feature

1. Create feature folder: `Features/NewFeature/`
2. Add View: `Features/NewFeature/Views/NewFeatureView.swift`
3. Add ViewModel: `Features/NewFeature/ViewModels/NewFeatureViewModel.swift`
4. Add to tab navigation in `ContentView.swift`
5. Write tests in `Tests/UnitTests/NewFeatureTests.swift`

### Adding a New Model Type

1. Add case to `MLModelManager.ModelType` enum
2. Add model file to `Resources/Models/`
3. Update `modelURL(for:)` in `MLModelManager`
4. Add loading logic in `TTSService.loadCapability()`

### Modifying the Tokenizer

1. Update vocab/merges files in `Resources/Tokenizer/`
2. Modify encoding logic in `Qwen3Tokenizer.encode()`
3. Add tests for new tokenization behavior
4. Verify round-trip encoding/decoding works

### Optimizing Performance

1. Profile with Instruments (Time Profiler, Allocations)
2. Check memory warnings in `MemoryAwareLoader`
3. Verify ANE utilization with `coremltools` profiler
4. Reduce batch sizes if thermal throttling occurs

---

## File Locations

### Core Files
```
Core/
├── TTS/
│   ├── TTSService.swift          # Main service
│   ├── TTSConfiguration.swift    # Config options
│   └── TTSError.swift            # Error types
├── ML/
│   ├── MLModelManager.swift      # Model lifecycle
│   ├── Tokenizer/
│   │   └── Qwen3Tokenizer.swift  # BPE tokenizer
│   └── Inference/
│       ├── TTSInferenceEngine.swift
│       └── KVCache.swift
├── Audio/
│   ├── AudioEngine.swift         # Playback
│   ├── AudioRecorder.swift       # Recording
│   └── AudioExporter.swift       # File export
└── Storage/
    ├── VoiceStorage.swift        # Voice persistence
    └── CoreDataStack.swift       # Core Data
```

### Resource Files
```
Resources/
├── Models/                       # CoreML models (downloaded)
│   ├── Qwen3TTS_VoiceDesign_INT4.mlpackage
│   ├── Qwen3TTS_CustomVoice_INT4.mlpackage
│   └── Qwen3TTS_SpeechDecoder.mlpackage
├── Tokenizer/
│   ├── vocab.json               # Token vocabulary
│   ├── merges.txt               # BPE merges
│   └── special_tokens.json      # Special tokens
└── PresetVoices/
    └── voices.json              # Built-in voice metadata
```

### Conversion Scripts
```
scripts/
├── export_onnx.py               # PyTorch → ONNX
├── convert_coreml.py            # ONNX → CoreML
├── quantize_int4.py             # CoreML quantization
├── segment_model.py             # Model segmentation
└── export_tokenizer.py          # Tokenizer export
```

---

## Testing Guidelines

### Unit Tests

```swift
// Test file naming: {Component}Tests.swift
// Test method naming: test{Behavior}

final class TokenizerTests: XCTestCase {

    func testBasicTokenization() {
        // Arrange
        let tokenizer = makeTokenizer()
        let text = "Hello, world!"

        // Act
        let tokens = tokenizer.encode(text: text, language: .english)

        // Assert
        XCTAssertFalse(tokens.isEmpty)
    }

    func testRoundTrip() {
        // Test encode → decode preserves meaning
    }
}
```

### Integration Tests

```swift
// Use @MainActor for tests involving UI or services
@MainActor
final class TTSServiceTests: XCTestCase {

    func testSynthesisProducesAudio() async throws {
        // Given
        let service = makeTTSService()
        try await service.loadCapability(.customVoice)

        // When
        var chunks: [AudioChunk] = []
        for try await chunk in try await service.synthesize(
            text: "Hello",
            language: .english,
            speaker: .ryan
        ) {
            chunks.append(chunk)
        }

        // Then
        XCTAssertFalse(chunks.isEmpty)
    }
}
```

### Test Fixtures

- Place test audio files in `Tests/Fixtures/Audio/`
- Place test models in `Tests/Fixtures/Models/`
- Use `Bundle(for: type(of: self))` to locate fixtures

---

## Dependencies

### Swift Package Manager

```swift
// Package.swift dependencies
dependencies: [
    // Async utilities
    .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),

    // Collections
    .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),

    // Dependency injection
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.2.0"),

    // Tokenizer support (optional)
    .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.0"),
]
```

### System Frameworks

- **CoreML**: Model inference
- **AVFoundation**: Audio playback/recording
- **CoreData**: Voice persistence
- **Accelerate**: SIMD operations for audio processing

---

## Build Commands

```bash
# Build for simulator
xcodebuild build \
    -project VoiceClone.xcodeproj \
    -scheme VoiceClone \
    -destination 'platform=iOS Simulator,name=iPhone 15 Pro'

# Run tests
xcodebuild test \
    -project VoiceClone.xcodeproj \
    -scheme VoiceClone \
    -destination 'platform=iOS Simulator,name=iPhone 15 Pro'

# Build for device
xcodebuild build \
    -project VoiceClone.xcodeproj \
    -scheme VoiceClone \
    -destination 'generic/platform=iOS' \
    -configuration Release

# Archive for distribution
xcodebuild archive \
    -project VoiceClone.xcodeproj \
    -scheme VoiceClone \
    -archivePath ./build/VoiceClone.xcarchive
```

---

## Model Conversion Commands

```bash
# Set up Python environment
cd scripts
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Export to ONNX
python export_onnx.py \
    --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
    --output ./onnx_models

# Convert to CoreML
python convert_coreml.py \
    --onnx ./onnx_models/Qwen3-TTS-12Hz-1.7B-VoiceDesign.onnx \
    --output ./coreml_models/Qwen3TTS_VoiceDesign.mlpackage

# Quantize to INT4
python quantize_int4.py \
    --input ./coreml_models/Qwen3TTS_VoiceDesign.mlpackage \
    --output ./coreml_models/Qwen3TTS_VoiceDesign_INT4.mlpackage
```

---

## Debugging Tips

### CoreML Issues

```swift
// Enable CoreML debug logging
UserDefaults.standard.set(true, forKey: "com.apple.CoreML.mlmodel.debugOutput")

// Check compute unit assignment
let config = MLModelConfiguration()
config.computeUnits = .cpuAndNeuralEngine
// vs .cpuOnly for debugging
```

### Memory Issues

```swift
// Track memory usage
func logMemory() {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    print("Memory: \(info.resident_size / 1_000_000) MB")
}
```

### Audio Issues

```swift
// Verify audio session
let session = AVAudioSession.sharedInstance()
print("Category: \(session.category)")
print("Mode: \(session.mode)")
print("Sample Rate: \(session.sampleRate)")
```

---

## Performance Targets

| Metric | Target | Maximum |
|--------|--------|---------|
| First token latency | <500ms | 1000ms |
| Streaming latency | <150ms | 300ms |
| Memory peak | <3GB | 3.5GB |
| Model load time | <8s | 15s |
| Battery per 10min | <5% | 8% |

---

## Security Considerations

1. **No network required**: All inference is local
2. **No data collection**: Voice data never leaves device
3. **Secure storage**: Use Keychain for sensitive preferences
4. **Input validation**: Sanitize all user text input
5. **Model integrity**: Verify checksums on model downloads

---

## Known Limitations

1. **Model size**: 1.7B models require ~2GB storage
2. **Memory**: Peak usage can hit 3GB during inference
3. **Thermal**: Extended use may cause throttling on older devices
4. **Languages**: Limited to 10 supported languages
5. **Audio quality**: INT4 quantization may slightly reduce quality

---

## Related Documentation

- [PRD.md](./PRD.md) - Product requirements and full technical architecture
- [plan.md](./plan.md) - Step-by-step implementation plan
- [agents.md](./agents.md) - AI agent workflows for development
- [Qwen3-TTS GitHub](https://github.com/QwenLM/Qwen3-TTS) - Original model repository
- [CoreML Documentation](https://developer.apple.com/documentation/coreml) - Apple's ML framework

---

## Quick Reference

### Adding a new preset voice

```swift
// 1. Add to PresetVoice enum
enum PresetVoice: String, CaseIterable {
    case vivian, ryan, newVoice  // Add here
}

// 2. Update voices.json
{
    "newVoice": {
        "name": "New Voice",
        "language": "English",
        "style": "Friendly"
    }
}
```

### Adding a new language

```swift
// 1. Add to Language enum
enum Language: String, CaseIterable {
    case newLanguage = "NewLanguage"

    var code: String {
        switch self {
        case .newLanguage: return "xx"
        }
    }
}

// 2. Ensure model supports the language
// 3. Add to language picker UI
```

### Changing model quantization

```python
# In quantize_int4.py, change bits parameter
config = OptimizationConfig(
    global_config=OpPalettizerConfig(
        nbits=8,  # Change from 4 to 8 for higher quality
    )
)
```
