# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VoiceClone is an iOS app for on-device text-to-speech synthesis with voice cloning and voice design capabilities. It uses MLX (Apple's machine learning framework) to run Qwen3-TTS models locally on iOS devices via Metal acceleration.

**Platform**: iOS 17.0+
**Language**: Swift 6.0 (strict concurrency enabled)
**ML Framework**: MLX via mlx-swift package
**Architecture**: MVVM with SwiftUI

## Build Commands

### Building the Project

```bash
# Build for physical device (REQUIRED - MLX needs Metal hardware)
xcodebuild build \
  -project VoiceClone.xcodeproj \
  -scheme VoiceClone \
  -destination 'generic/platform=iOS'

# Or in Xcode: Cmd+B (with physical device selected)
```

**IMPORTANT**: This project does NOT work on iOS Simulator. MLX requires Metal hardware features only available on physical devices. Simulator builds will fail with Metal linker errors.

### Running Tests

```bash
# Run all tests (requires physical iOS device)
xcodebuild test \
  -project VoiceClone.xcodeproj \
  -scheme VoiceClone \
  -destination 'platform=iOS,name=Your Device Name'

# Run specific test suite
xcodebuild test \
  -project VoiceClone.xcodeproj \
  -scheme VoiceClone \
  -only-testing:VoiceCloneTests/MLXTTSServiceTests \
  -destination 'platform=iOS,name=Your Device Name'
```

### Model Verification

```bash
# Verify model files are NOT bundled in app (should be empty output)
./verify_bundle_size.sh
```

## Architecture

### Core Components

1. **MLX Integration** (`VoiceClone/Core/ML/MLX/`)
   - `MLXTTSService.swift`: Main TTS service actor (MainActor isolated)
   - `MLXQwen3TTSModel.swift`: MLX-based transformer implementation (actor isolated)
   - `MLXSpeechDecoder.swift`: Audio decoder (Snake activation + ResidualVectorQuantizer)
   - `ConvLayers.swift`, `SnakeActivation.swift`, `ResidualVectorQuantizer.swift`: Neural network layers

2. **Audio Pipeline** (`VoiceClone/Core/Audio/`)
   - `AudioEngine.swift`: AVAudioEngine wrapper for playback
   - `AudioRecorder.swift`: Recording for voice cloning
   - `AudioExporter.swift`: Export to WAV/M4A

3. **Storage** (`VoiceClone/Core/Storage/`)
   - `CoreDataStack.swift`: Core Data setup
   - `VoiceStorage.swift`: Voice library persistence
   - `VoiceEntity.swift`: Core Data entity

4. **Features** (`VoiceClone/Features/`)
   - `Synthesis/`: Text-to-speech synthesis UI
   - `VoiceDesign/`: Create voices from text descriptions
   - `VoiceClone/`: Clone voices from audio samples
   - `VoiceLibrary/`: Manage saved voices

### Model Loading Architecture

Models are loaded from filesystem paths with a fallback strategy:

1. Documents directory (for production downloaded models)
2. App bundle (currently NOT used - models too large)
3. Development paths (for running from Xcode):
   - `VoiceClone/Resources/MLXModels/Qwen3TTS_INT4/`
   - `models/MLXModels/Qwen3TTS_INT4/` (talker model)
   - `models/MLXModels/Qwen3TTS_Decoder/` (decoder model)

**Critical**: The talker model (`weights.npz` 1.0GB, `weights.pkl` 1.2GB) and decoder model (`weights.npz` 436MB) are NOT bundled in the app to avoid bloating the IPA. They are kept outside the Xcode project in `models/MLXModels/` and loaded via development path fallback during local development.

## Swift 6 Concurrency Patterns

This codebase uses Swift 6 strict concurrency. Key patterns:

### Actor Isolation
- `MLXTTSService`: `@MainActor` for UI updates
- `MLXQwen3TTSModel`, `MLXSpeechDecoder`: Actors for thread-safe model inference
- Use `nonisolated` for initializers that don't access mutable state

### Sendability
- Use `@unchecked Sendable` for data-holding structs that are immutable
- Use `nonisolated(unsafe)` for stored properties needing cross-isolation access (use sparingly)
- Use `@preconcurrency import MLX` to suppress Sendable warnings for `MLXArray`

### Example Pattern
```swift
// Config structs: @unchecked Sendable + nonisolated init
struct MyConfig: @unchecked Sendable {
    let value: Int
    nonisolated init(json: [String: Any]) { ... }
}

// Actors with nonisolated init
actor MyModel {
    nonisolated init(modelPath: URL) async throws { ... }
}

// MainActor services
@MainActor
final class MyService: ObservableObject {
    @Published var state: State = .idle
}
```

## MLX API Compatibility

Using mlx-swift v0.30.3. Key API differences from older versions:

- `Conv1d`: Use `inputChannels`/`outputChannels` (not `inChannels`/`outChannels`)
- No `MLXRandom` module available - use `MLX.zeros()` for placeholder tensors
- `MLX.repeated()` signature changed - check current API docs

## File Organization Rules

### DO NOT Bundle Large Files
- Model weights (`.npz`, `.pkl`, `.safetensors`, `.bin`) should NEVER be in `VoiceClone/Resources/` or added to "Copy Bundle Resources" build phase
- Keep models in `models/MLXModels/` directory (outside Xcode project)
- `.gitignore` excludes these files

### Core Data
- Schema defined in `VoiceEntity.swift`
- Access via `VoiceStorage` actor wrapper, NOT directly

## Common Development Tasks

### Adding a New MLX Layer
1. Create in `VoiceClone/Core/ML/MLX/Layers/`
2. Use `nonisolated` functions for stateless operations
3. Use `nonisolated(unsafe)` for stored properties if needed (e.g., `Conv1d` modules)
4. Ensure all MLXArray operations are thread-safe

### Modifying Audio Pipeline
1. Edit `AudioEngine.swift` for playback changes
2. Use `AVAudioPCMBuffer` with 24kHz mono Float32 format
3. Always configure audio session: `.playback` category, `.spokenAudio` mode

### Adding New Voice Presets
1. Update `PresetVoice` enum in `VoiceClone/Core/Models/PresetVoice.swift`
2. Add voice metadata to tokenizer prompt templates if needed

## Testing Strategy

### Unit Tests
- Test MLX layers (Snake, RVQ, Conv) independently
- Mock `MLXArray` operations where possible
- Requires physical device (no simulator support)

### Integration Tests
- Test full synthesis pipeline with small test inputs
- Verify model loading from all fallback paths
- Check audio output format (24kHz, Float32, mono)

## Known Limitations

1. **No Simulator Support**: MLX requires Metal, which isn't fully supported on simulator
2. **Large Model Files**: 2.6GB total, must be downloaded separately (not in git repo)
3. **Voice Cloning**: Currently falls back to voice design mode (reference audio embedding extraction not implemented)
4. **Memory Usage**: ~1.5GB during inference on device

## Dependencies

- **mlx-swift** v0.30.3: Apple MLX framework bindings
- **SwiftUI**: UI framework
- **Core Data**: Voice library persistence
- **AVFoundation**: Audio playback and recording

## Production Deployment

For production, implement on-demand model download:
1. Host models on server (e.g., HuggingFace, S3)
2. Download to Documents directory on first launch
3. Show progress UI during download
4. Verify checksums after download
5. Update `getModelPath()` to prioritize Documents directory

## Documentation References

- `BUILD_AND_RUN.md`: Detailed build instructions
- `REMAINING_WORK.md`: Current status and next steps
- `PRD.md`: Product requirements and technical architecture
