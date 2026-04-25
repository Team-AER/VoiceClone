# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

PolyJuiceVoice is a **macOS-first** (also iOS) app for on-device text-to-speech synthesis with voice cloning and voice design capabilities. It uses MLX (Apple's machine learning framework) to run Qwen3-TTS models locally via Metal acceleration.

**Platform**: macOS 26+ (primary), iOS 26+ (secondary — maintained via `#if os(...)` conditionals)
**Language**: Swift 6.0 (strict concurrency enabled)
**ML Framework**: MLX via mlx-swift package
**Architecture**: MVVM with SwiftUI

## Build Commands

### Building the Project

```bash
# Build for macOS (primary target — runs directly, no device needed)
xcodebuild build \
  -project PolyJuiceVoice.xcodeproj \
  -scheme PolyJuiceVoice \
  -destination 'platform=macOS,arch=arm64'

# Build for physical iOS device (MLX needs Metal hardware)
xcodebuild build \
  -project PolyJuiceVoice.xcodeproj \
  -scheme PolyJuiceVoice \
  -destination 'generic/platform=iOS'
```

**IMPORTANT**: iOS Simulator does NOT work — MLX requires Metal hardware. macOS builds run directly on your Mac (no device needed).

### Model Setup for Development (macOS)

Set `POLYJUICEVOICE_MODELS_DIR` in your Xcode scheme's environment variables to the directory containing `Qwen3TTS_FP16/` and `Qwen3TTS_Decoder/` subdirectories:

```
POLYJUICEVOICE_MODELS_DIR=/path/to/models/MLXModels
```

In production the app downloads models on first launch to `~/Library/Application Support/PolyJuiceVoice/MLXModels/`.

### Running Tests

```bash
# Run tests on macOS (preferred — no device needed)
xcodebuild test \
  -project PolyJuiceVoice.xcodeproj \
  -scheme PolyJuiceVoice \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PolyJuiceVoiceTests

# Run tests on physical iOS device
xcodebuild test \
  -project PolyJuiceVoice.xcodeproj \
  -scheme PolyJuiceVoice \
  -destination 'platform=iOS,name=Your Device Name'
```

### Model Verification

```bash
# Verify model files are NOT bundled in app (should be empty output)
./verify_bundle_size.sh
```

## Architecture

### Core Components

1. **MLX Integration** (`PolyJuiceVoice/Core/ML/MLX/`)
   - `MLXTTSService.swift`: Main TTS service actor (MainActor isolated)
   - `MLXQwen3TTSModel.swift`: MLX-based transformer implementation (actor isolated)
   - `MLXSpeechDecoder.swift`: Audio decoder (Snake activation + ResidualVectorQuantizer)
   - `ConvLayers.swift`, `SnakeActivation.swift`, `ResidualVectorQuantizer.swift`: Neural network layers

2. **Audio Pipeline** (`PolyJuiceVoice/Core/Audio/`)
   - `AudioEngine.swift`: AVAudioEngine wrapper for playback
   - `AudioRecorder.swift`: Recording for voice cloning
   - `AudioExporter.swift`: Export to WAV/M4A

3. **Storage** (`PolyJuiceVoice/Core/Storage/`)
   - `CoreDataStack.swift`: Core Data setup
   - `VoiceStorage.swift`: Voice library persistence
   - `VoiceEntity.swift`: Core Data entity

4. **Features** (`PolyJuiceVoice/Features/`)
   - `Synthesis/`: Text-to-speech synthesis UI
   - `VoiceDesign/`: Create voices from text descriptions
   - `VoiceCloning/`: Clone voices from audio samples
   - `VoiceLibrary/`: Manage saved voices

### Model Loading Architecture

Models are loaded from filesystem paths with a platform-aware fallback strategy (see `MLXTTSService.swift`):

**macOS path priority:**
1. `~/Library/Application Support/PolyJuiceVoice/MLXModels/` — managed by `ModelDownloadManager` (production)
2. App bundle resources (development only)
3. `$POLYJUICEVOICE_MODELS_DIR/<ModelName>/` — DEBUG env var override for Xcode development

**iOS path priority:**
1. Documents directory — managed by `ModelDownloadManager`
2. App bundle resources (physical device development builds)
3. `$POLYJUICEVOICE_MODELS_DIR/<ModelName>/` — DEBUG env var override

**Model Format**: MLX Swift API uses `.safetensors` format. The app consumes the HuggingFace `Qwen/Qwen3-TTS-0.6B` safetensors **directly** — no Python conversion step. `ModelDownloadManager` fetches them at first launch. Tensor-key ↔ Swift coupling is encoded in `PolyJuiceVoice/Core/ML/MLX/WeightKeyMap.swift`; `PolyJuiceVoiceTests/WeightKeyAuditTests` verifies that coupling stays in sync with the downloaded weights.

**File Naming Convention**:
- Talker model files: `talker_config.json`, `talker_weights.safetensors` (FP16, 3.6GB, 404 tensors)
- Decoder model files: `decoder_config.json`, `decoder_weights.safetensors` (FP16, 436MB)

**Production (both platforms)**: `ModelDownloadManager` downloads models on first launch and caches them. No ODR is used. The download gate UI (`ModelDownloadView`) blocks the main UI until models are present.
- See `docs/ODR_IMPLEMENTATION_STATUS.md` for current progress

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

### Model File Management
- **Development**: Models MUST be in `PolyJuiceVoice/Resources/MLXModels/` for testing on physical devices (required for MLX/Metal). Physical devices cannot access the Mac's filesystem.
- **Production**: Models are downloaded via ODR (On-Demand Resources) to Documents directory, NOT bundled in the IPA.
- **Git**: `.gitignore` excludes `.safetensors`, `.npz`, and `.pkl` files to prevent large files from being committed.
- **File naming**: Models use unique prefixes (`talker_*`, `decoder_*`) to prevent Xcode build conflicts when multiple models are bundled.
- **Format**: MLX Swift API requires `.safetensors` format (supports dictionary of arrays via `loadArrays()`). `.npz` format is NOT supported.

### Core Data
- Schema defined in `VoiceEntity.swift`
- Access via `VoiceStorage` actor wrapper, NOT directly

## Common Development Tasks

### Adding a New MLX Layer
1. Create in `PolyJuiceVoice/Core/ML/MLX/Layers/`
2. Use `nonisolated` functions for stateless operations
3. Use `nonisolated(unsafe)` for stored properties if needed (e.g., `Conv1d` modules)
4. Ensure all MLXArray operations are thread-safe

### Modifying Audio Pipeline
1. Edit `AudioEngine.swift` for playback changes
2. Use `AVAudioPCMBuffer` with 24kHz mono Float32 format
3. Always configure audio session: `.playback` category, `.spokenAudio` mode

### Adding New Voice Presets
1. Update `PresetVoice` enum in `PolyJuiceVoice/Core/Models/PresetVoice.swift`
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
2. **Large Model Files**: 4GB total (FP16 models), must be downloaded separately (not in git repo)
3. **Voice Cloning**: Currently falls back to voice design mode (reference audio embedding extraction not implemented)
4. **Memory Usage**: ~3GB during inference on device (FP16 models)
5. **Physical Device Required**: MLX requires Metal hardware, iOS Simulator will not work

## Dependencies

- **mlx-swift** v0.30.3: Apple MLX framework bindings
- **SwiftUI**: UI framework
- **Core Data**: Voice library persistence
- **AVFoundation**: Audio playback and recording

## Models: direct from HuggingFace (no conversion)

The app consumes `Qwen/Qwen3-TTS-0.6B` safetensors straight from HuggingFace — there is no Python conversion step. `ModelDownloadManager` downloads the four files below at first launch; `$POLYJUICEVOICE_MODELS_DIR` is the dev-time alternative (see `scripts/README.md`).

| File | Source |
|---|---|
| `talker_config.json` | `huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/talker_config.json` |
| `talker_weights.safetensors` (~3.6 GB) | `huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/talker_weights.safetensors` |
| `decoder_config.json` | `huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/decoder_config.json` |
| `decoder_weights.safetensors` (~436 MB) | `huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/decoder_weights.safetensors` |

The coupling between the Swift inference code and the HuggingFace tensor names lives in `PolyJuiceVoice/Core/ML/MLX/WeightKeyMap.swift`. `PolyJuiceVoiceTests/WeightKeyAuditTests` asserts every key referenced by `generate()` is present in the loaded safetensors — run it when upgrading to a new model release:

```bash
xcodebuild test -project PolyJuiceVoice.xcodeproj -scheme PolyJuiceVoice \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PolyJuiceVoiceTests/WeightKeyAuditTests
```

If the audit fails, update `WeightKeyMap.swift` to match the new tensor names.

## Production Deployment

**Using On-Demand Resources (ODR)** - Planned:
- Models will be tagged as ODR assets in Xcode
- Downloaded from Apple's CDN after initial install
- Managed by `ODRManager` actor
- UI prompts user to download on first launch

**Challenges:**
- Apple has 2GB per-tag limit, talker model is 3.6GB
- Need to split model or use alternative delivery method

**Alternative: Self-Hosted Downloads**:
1. Host models on server (e.g., HuggingFace, S3)
2. Download to Documents directory on first launch
3. Verify checksums after download

## Documentation References

- `BUILD_AND_RUN.md`: Detailed build instructions
- `REMAINING_WORK.md`: Current status and next steps
- `PRD.md`: Product requirements and technical architecture
- `docs/ODR_IMPLEMENTATION_PLAN.md`: ODR setup guide
- `docs/ODR_IMPLEMENTATION_STATUS.md`: ODR implementation progress
