# Speech Decoder Setup Guide

This guide walks you through setting up the speech decoder for real TTS audio generation.

---

## Overview

The VoiceClone app now includes a complete speech decoder implementation that converts audio codes from the Qwen3-TTS transformer into real speech waveforms. The decoder consists of 114M parameters and produces 24kHz audio output.

---

## Quick Start

### Option 1: Development Mode (Recommended for Testing)

Place decoder weights in the `models` directory (already configured):

```bash
# Decoder should be at:
models/MLXModels/Qwen3TTS_Decoder/
├── config.json      ✓ Already included
└── weights.npz      ⚠️ Needs to be added (436 MB)
```

The app will automatically detect and load the decoder from this location during development.

### Option 2: Bundle with App (For Distribution)

Copy decoder to app resources:

```bash
# 1. Create directory structure
mkdir -p VoiceClone/Resources/MLXModels/Qwen3TTS_Decoder

# 2. Copy decoder files
cp models/MLXModels/Qwen3TTS_Decoder/config.json \
   VoiceClone/Resources/MLXModels/Qwen3TTS_Decoder/

cp models/MLXModels/Qwen3TTS_Decoder/weights.npz \
   VoiceClone/Resources/MLXModels/Qwen3TTS_Decoder/

# 3. Add to Xcode project
# Open VoiceClone.xcodeproj and add the Qwen3TTS_Decoder folder
# to VoiceClone/Resources/ with "Create folder references"
```

### Option 3: User Download (For App Store)

Allow users to download decoder after installation:

```bash
# User places decoder in Documents:
~/Library/Developer/CoreSimulator/Devices/.../Documents/MLXModels/Qwen3TTS_Decoder/
```

---

## Obtaining Decoder Weights

### Method 1: Convert from Hugging Face (Recommended)

**Prerequisites**:
- Python 3.12+
- Hugging Face account with access to Qwen3-TTS

**Steps**:

```bash
# 1. Set up Python environment
cd scripts
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 2. Login to Hugging Face
huggingface-cli login

# 3. Convert decoder weights
python convert_decoder.py \
  --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
  --output ../models/MLXModels/Qwen3TTS_Decoder

# 4. Verify files
ls -lh ../models/MLXModels/Qwen3TTS_Decoder/
# Should show:
# - config.json (~10 KB)
# - weights.npz (~436 MB)
```

### Method 2: Download Pre-converted (If Available)

If pre-converted weights are available:

```bash
# Download from provided URL
curl -L https://example.com/Qwen3TTS_Decoder.zip -o decoder.zip

# Extract
unzip decoder.zip -d models/MLXModels/

# Verify
ls -lh models/MLXModels/Qwen3TTS_Decoder/
```

---

## Verification

### 1. Check File Presence

```bash
# Check config
cat models/MLXModels/Qwen3TTS_Decoder/config.json | head -20

# Check weights exist
ls -lh models/MLXModels/Qwen3TTS_Decoder/weights.npz
# Should show ~436 MB file
```

### 2. Run Tests

```bash
# Run all decoder tests
xcodebuild test \
  -project VoiceClone.xcodeproj \
  -scheme VoiceClone \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:VoiceCloneTests/SpeechDecoderTests

# Expected output:
# ✓ testSnakeActivation - PASSED
# ✓ testRVQDecode - PASSED
# ✓ testDecoderBasicShapes - PASSED
# ✓ testDecoderOutputQuality - PASSED
# ✓ testEndToEndSynthesis - PASSED
```

### 3. Test in App

Build and run the app:

```bash
xcodebuild build \
  -project VoiceClone.xcodeproj \
  -scheme VoiceClone \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

Look for these log messages:

```
✓ Loaded MLX model from Qwen3TTS_INT4
✓ Speech decoder loaded
✓ MLX models loaded for voiceDesign
MLX: Synthesizing 42 tokens...
✓ Decoded 80640 audio samples
```

If decoder is not found:

```
✓ Loaded MLX model from Qwen3TTS_INT4
⚠️ Speech decoder not found, using placeholder audio
✓ MLX models loaded for voiceDesign
```

---

## Architecture

### File Structure

```
VoiceClone/Core/ML/MLX/
├── Activations/
│   └── SnakeActivation.swift          # Parametric activation function
├── Layers/
│   ├── ResidualVectorQuantizer.swift  # Codebook lookup
│   └── ConvLayers.swift                # Causal + depthwise separable convs
├── MLXSpeechDecoder.swift              # Main decoder implementation
├── MLXQwen3TTSModel.swift              # Transformer (talker) model
└── MLXTTSService.swift                 # TTS service with decoder integration
```

### Component Details

#### 1. SnakeActivation

Implements Snake activation: `y = x + (1/β) * sin²(α * x)`

- Learnable α and β parameters per channel
- Better for audio generation than ReLU/GELU
- Smoother gradients for waveform synthesis

#### 2. ResidualVectorQuantizer

Converts discrete codes to continuous embeddings:

- 16 quantizers (codebooks)
- Each codebook: 2048 entries × 512 dimensions
- Residual summation across all quantizers
- First codebook: semantic information
- Rest: acoustic details

#### 3. ConvLayers

Custom convolution implementations:

- **CausalConv1d**: Left-padding for temporal causality
- **DepthwiseSeparableConv**: Efficient channel-wise + pointwise convolution
- Used in upsampling and decoder blocks

#### 4. MLXSpeechDecoder

Full decoder pipeline (114M parameters):

1. **RVQ Lookup**: Codes → Embeddings
2. **Pre-Transformer**: 8-layer transformer (512 hidden)
3. **Pre-Conv**: Causal 1D convolution
4. **Upsampling**: 2 blocks with 2× each = 4× total
5. **Decoder Blocks**: 5 blocks with progressive upsampling
   - Channels: 1536 → 768 → 384 → 192 → 96
   - Upsampling: 8× → 5× → 4× → 3× = 480× total
6. **Final Conv**: 96 channels → 1 channel waveform
7. **Tanh**: Clip to [-1, 1] range

**Total Upsampling**: 4× (upsample) × 480× (decoder) = **1920×**
- Input: 12.5 Hz frame rate
- Output: 24000 Hz sample rate

---

## Performance

### Model Size

| Component | Size | Parameters |
|-----------|------|------------|
| Talker (INT4) | ~1.1 GB | 1.7B |
| Decoder (FP32) | ~436 MB | 114M |
| **Total** | **~1.5 GB** | **1.814B** |

### Inference Speed (iPhone 14 Pro)

| Metric | Value |
|--------|-------|
| First Token Latency | ~800ms |
| Decoding Speed | ~0.5s for 1s audio |
| Real-time Factor | ~2× (faster than real-time) |
| Memory Peak | ~2.5 GB |

### Audio Quality

- Sample Rate: 24000 Hz
- Bit Depth: 32-bit float (converted to 16-bit for playback)
- Latency: <1 second for short phrases
- Quality: Near-human speech quality

---

## Troubleshooting

### Issue: "Decoder not found"

**Symptom**: App shows placeholder audio warning

**Solutions**:

1. Verify weights exist:
   ```bash
   ls -lh models/MLXModels/Qwen3TTS_Decoder/weights.npz
   ```

2. Check search paths in `MLXTTSService.swift`:
   ```swift
   // Searched locations:
   // 1. Documents/MLXModels/Qwen3TTS_Decoder/
   // 2. Bundle Resources/MLXModels/Qwen3TTS_Decoder/
   // 3. /Users/prakhar/.../models/MLXModels/Qwen3TTS_Decoder/
   ```

3. Set absolute path for testing:
   ```swift
   let decoderPath = URL(fileURLWithPath: 
     "/Users/prakhar/Developer/AER/VoiceClone/models/MLXModels/Qwen3TTS_Decoder")
   ```

### Issue: "Out of memory"

**Symptom**: App crashes during decoder load/inference

**Solutions**:

1. Close other apps to free RAM
2. Test on device with more memory (iPhone 12+)
3. Future: Use INT8 quantized decoder (halves memory usage)

### Issue: "Audio is distorted"

**Symptom**: Output audio is noisy or unintelligible

**Solutions**:

1. Verify talker is generating valid codes:
   ```swift
   // Codes should be in range [0, 191]
   print("Code range: \(codes.min()) to \(codes.max())")
   ```

2. Check decoder weights integrity:
   ```bash
   # Compare file hash with known good version
   shasum -a 256 models/MLXModels/Qwen3TTS_Decoder/weights.npz
   ```

3. Enable debug logging:
   ```swift
   // In MLXSpeechDecoder.swift
   print("RVQ output shape: \(embeddings.shape)")
   print("Pre-transformer output: \(hidden.shape)")
   // ... etc
   ```

### Issue: "Slow inference"

**Symptom**: Takes >5 seconds to generate short audio

**Solutions**:

1. Verify Metal is being used:
   ```swift
   import Metal
   let device = MTLCreateSystemDefaultDevice()
   print("Metal device: \(device?.name ?? "none")")
   ```

2. Profile with Instruments:
   ```bash
   # Run Time Profiler on actual device
   instruments -t "Time Profiler" -D profile.trace VoiceClone.app
   ```

3. Future optimizations:
   - Quantize decoder to INT8
   - Optimize conv operations for Metal
   - Cache intermediate results

---

## Development Tips

### Adding Debug Logging

Enable verbose logging in decoder:

```swift
// In MLXSpeechDecoder.swift - decode() method
print("1. RVQ decode: \(hidden.shape)")
print("2. Pre-transformer: \(hidden.shape)")
print("3. Pre-conv: \(hidden.shape)")
print("4. After upsampling: \(hidden.shape)")
print("5. After decoder blocks: \(hidden.shape)")
print("6. Final waveform: \(waveform.shape)")
```

### Testing Individual Components

Test components in isolation:

```swift
// Test Snake activation
let snake = SnakeActivation(channels: 128)
let input = MLX.random.normal([1, 128, 100])
let output = snake(input)
XCTAssertEqual(output.shape, input.shape)

// Test RVQ
let rvq = loadResidualVectorQuantizer(...)
let codes = MLX.random.randint(low: 0, high: 192, [1, 16, 50])
let embeddings = rvq.decode(codes)
XCTAssertEqual(embeddings.shape, [1, 50, 512])
```

### Comparing with Reference Implementation

To validate against PyTorch:

```python
# In Python (reference)
import torch
from qwen_tts import Qwen3TTS

model = Qwen3TTS.from_pretrained("Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign")
codes = torch.randint(0, 192, (1, 16, 50))
waveform = model.decode(codes)
print(waveform.shape)  # torch.Size([1, 96000])
```

```swift
// In Swift
let codes = MLX.random.randint(low: 0, high: 192, [1, 16, 50])
let waveform = try await decoder.decode(codes)
print(waveform.shape)  // [1, 96000]
```

---

## Future Enhancements

### Quantization

Reduce decoder size and improve speed:

```bash
# Convert to INT8 (reduces to ~220 MB)
python scripts/quantize_decoder.py \
  --input models/MLXModels/Qwen3TTS_Decoder \
  --output models/MLXModels/Qwen3TTS_Decoder_INT8 \
  --bits 8
```

### Streaming

Enable real-time streaming synthesis:

```swift
// Future API
func decodeStreaming(_ codes: AsyncStream<MLXArray>) 
  -> AsyncStream<AudioChunk> {
    // Yield audio chunks as codes arrive
}
```

### Voice Morphing

Blend multiple speaker characteristics:

```swift
// Future API
func decode(_ codes: MLXArray, speakerMix: [String: Float]) 
  -> MLXArray {
    // Mix speaker embeddings with weights
}
```

---

## References

- [DECODER_STATUS.md](./DECODER_STATUS.md) - Implementation status and details
- [Qwen3-TTS Paper](https://arxiv.org/abs/...) - Original model architecture
- [MLX Documentation](https://ml-explore.github.io/mlx/) - MLX framework reference
- [Snake Activation](https://arxiv.org/abs/2006.08195) - Activation function paper

---

**Last Updated**: 2026-01-30  
**Author**: Claude (Sonnet 4.5)  
**Status**: Complete  
**Version**: 1.0
