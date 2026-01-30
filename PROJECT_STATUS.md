# VoiceClone Project Status

**Last Updated**: 2026-01-30  
**Status**: MLX Integration Complete, Decoder Implementation Pending

---

## Current Architecture

### Stack
- **Platform**: iOS 17.0+
- **Language**: Swift 6.0
- **UI**: SwiftUI
- **ML Backend**: MLX (Metal Learning eXtensions)
- **Models**: Qwen3-TTS 1.7B (INT4 quantized)

### Components
```
┌──────────────────────────────┐
│   SwiftUI Views              │
│   └─ View Models             │
│       └─ MLXTTSService       │
│           └─ MLXQwen3TTSModel│
│               └─ MLX         │
└──────────────────────────────┘
```

---

## Completed Work ✓

### MLX Backend Integration
- ✓ MLXQwen3TTSModel implemented
- ✓ MLXTTSService integrated
- ✓ All view models updated
- ✓ Tokenizer working (Qwen3Tokenizer with BPE)
- ✓ Audio engine streaming implemented
- ✓ Tests created (MLXTTSServiceTests)

### CoreML Removal
- ✓ All CoreML code removed (~3000 lines)
- ✓ TTSServiceProtocol simplified to TTSTypes
- ✓ MLModelManager removed
- ✓ TTSInferenceEngine removed
- ✓ KVCache removed
- ✓ All .mlpackage files removed
- ✓ Conversion scripts removed
- ✓ Documentation updated

### Scripts
- ✓ `convert_mlx.py` - PyTorch → MLX conversion
- ✓ `export_tokenizer.py` - Tokenizer export
- ✓ `quantize_int8_tensor.py` - Model quantization
- ✓ `test_mlx_inference.py` - Inference testing

---

## In Progress 🔨

### Speech Decoder Implementation
**Status**: Pending  
**Priority**: High  
**Estimated**: 2-3 days

The speech decoder converts audio codes [batch, 16, seq_len] to waveforms [batch, samples].

**Requirements**:
- 114M parameters
- Snake activation function
- Residual Vector Quantization (16 codebooks)
- Causal convolutions with dilation
- 1920x upsampling (12.5 Hz → 24000 Hz)

**Current Workaround**: Placeholder multi-tone sine wave audio

See `DECODER_STATUS.md` for full implementation details.

---

## Project Structure

```
VoiceClone/
├── VoiceClone/
│   ├── Core/
│   │   ├── TTS/
│   │   │   └── TTSTypes.swift          # State/capability enums
│   │   ├── ML/
│   │   │   ├── MLX/
│   │   │   │   ├── MLXTTSService.swift      # Main service
│   │   │   │   └── MLXQwen3TTSModel.swift   # Model wrapper
│   │   │   └── Tokenizer/
│   │   │       └── Qwen3Tokenizer.swift     # BPE tokenizer
│   │   ├── Audio/
│   │   │   ├── AudioEngine.swift       # Playback
│   │   │   ├── AudioRecorder.swift     # Recording
│   │   │   └── AudioExporter.swift     # Export
│   │   ├── Storage/
│   │   │   └── VoiceStorage.swift      # Voice persistence
│   │   └── Models/
│   │       └── AudioChunk.swift        # Data types
│   ├── Features/
│   │   ├── Synthesis/                  # Preset voices
│   │   ├── VoiceDesign/                # Custom instructions
│   │   ├── VoiceClone/                 # Voice cloning
│   │   └── VoiceLibrary/               # Saved voices
│   ├── App/
│   │   ├── VoiceCloneApp.swift
│   │   ├── ContentView.swift
│   │   └── Environment/
│   │       └── DIContainer.swift       # DI setup
│   └── Resources/
│       ├── MLXModels/
│       │   ├── Qwen3TTS_INT4/          # 1.0GB talker
│       └── Tokenizer/
│           ├── vocab.json
│           ├── merges.txt
│           └── special_tokens.json
├── VoiceCloneTests/
│   ├── MLXTTSServiceTests.swift
│   └── AudioEngineTests.swift
├── scripts/
│   ├── convert_mlx.py                  # Model conversion
│   ├── export_tokenizer.py             # Tokenizer export
│   ├── quantize_int8_tensor.py         # Quantization
│   ├── test_mlx_inference.py           # Testing
│   └── mlx_models/                     # Converted models
└── Documentation/
    ├── CLAUDE.md                       # Developer guide
    ├── PRD.md                          # Product requirements
    ├── plan.md                         # Implementation plan
    ├── DECODER_STATUS.md               # Decoder details
    ├── MLX_INTEGRATION_GUIDE.md        # MLX guide
    ├── MLX_QUICK_START.md              # Quick start
    ├── COREML_REMOVAL_SUMMARY.md       # Cleanup details
    └── PROJECT_STATUS.md               # This file
```

---

## Models

### Talker Model (Qwen3-TTS)
- **Location**: `Resources/MLXModels/Qwen3TTS_INT4/`
- **Size**: ~1.0GB (INT4 quantized)
- **Format**: MLX (.npz)
- **Purpose**: Text → Audio codes [batch, 16, seq_len]
- **Status**: ✓ Working

### Speech Decoder
- **Location**: `models/MLXModels/Qwen3TTS_Decoder/` (not bundled)
- **Size**: 436MB
- **Format**: MLX (.npz)
- **Purpose**: Audio codes → Waveform [batch, samples]
- **Status**: ⚠️ Weights converted, Swift implementation pending

---

## Development Commands

### Build & Test
```bash
# Build
xcodebuild build \
    -project VoiceClone.xcodeproj \
    -scheme VoiceClone \
    -destination 'platform=iOS Simulator,name=iPhone 15 Pro'

# Test
xcodebuild test \
    -project VoiceClone.xcodeproj \
    -scheme VoiceClone \
    -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

### Model Conversion
```bash
cd scripts
source .venv/bin/activate

# Convert model
python convert_mlx.py \
    --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
    --output ./mlx_models/Qwen3TTS_INT4 \
    --quantize

# Export tokenizer
python export_tokenizer.py \
    --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
    --output ./tokenizer_output
```

---

## Next Steps

### 1. Implement Speech Decoder (HIGH PRIORITY)
- [ ] Implement Snake activation in Swift
- [ ] Implement RVQ decoder (16 codebooks)
- [ ] Implement upsampling layers
- [ ] Test decoder output quality
- [ ] Integrate into MLXTTSService

**Dependencies**: None, can start immediately  
**Estimated**: 2-3 days  
**Impact**: Enables real speech synthesis

### 2. Bundle MLX Models
- [ ] Add models to Xcode project
- [ ] Configure build settings for large files
- [ ] Test model loading from bundle
- [ ] Add model download UI (optional)

### 3. Device Testing
- [ ] Test on iPhone (A14+)
- [ ] Profile memory usage
- [ ] Check thermal throttling
- [ ] Verify ANE utilization

### 4. Documentation Updates
- [ ] Update plan.md with MLX architecture
- [ ] Add decoder implementation guide
- [ ] Create performance benchmarks
- [ ] Write user documentation

---

## Known Issues

1. **Audio Quality**: Currently placeholder sine waves (decoder pending)
2. **Voice Cloning**: Falls back to voice design (no reference audio support yet)
3. **Model Size**: 1GB+ models not bundled in project yet

---

## Performance Targets

| Metric | Target | Current | Status |
|--------|--------|---------|--------|
| Model load time | <5s | ~3s | ✓ |
| First token latency | <500ms | TBD | ⏳ |
| Streaming latency | <150ms | TBD | ⏳ |
| Memory peak | <2GB | ~1.5GB | ✓ |
| Battery (10min) | <5% | TBD | ⏳ |

---

## Recent Changes

### 2026-01-30: Complete CoreML Removal
- Removed all CoreML code and infrastructure
- Simplified to MLX-only architecture
- Updated documentation
- Created cleanup summaries

### 2026-01-30: MLX Backend Integration
- Implemented MLXQwen3TTSModel
- Integrated MLXTTSService
- Fixed mlx-swift API issues
- Added comprehensive tests

### Earlier: Project Setup
- Initial iOS project structure
- SwiftUI views and view models
- Audio engine implementation
- Tokenizer integration

---

## References

- **Qwen3-TTS**: https://github.com/QwenLM/Qwen3-TTS
- **MLX**: https://ml-explore.github.io/mlx/
- **mlx-swift**: https://github.com/ml-explore/mlx-swift

---

**For detailed architecture and coding guidelines, see [CLAUDE.md](./CLAUDE.md)**

**For decoder implementation details, see [DECODER_STATUS.md](./DECODER_STATUS.md)**

**For CoreML removal details, see [COREML_REMOVAL_SUMMARY.md](./COREML_REMOVAL_SUMMARY.md)**
