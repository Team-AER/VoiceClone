# MLX Quick Start - VoiceClone iOS

**Problem**: CoreML error -5 with Qwen3-TTS transformer
**Solution**: Use MLX backend instead

---

## ✅ What's Complete

| Task | Status |
|------|--------|
| 1. MLX-Swift integration code | ✅ Done |
| 2. Model export (NPZ format) | ✅ Done |
| 3. Longer sequence testing (16-256 tokens) | ✅ Done |

---

## 🚀 Quick Integration (5 Steps)

### 1. Add mlx-swift Package

In Xcode: **File → Add Package Dependencies**
- URL: `https://github.com/ml-explore/mlx-swift`
- Version: 0.10.0+

### 2. Copy Model

```bash
cp -r scripts/mlx_models/Qwen3TTS_INT4 VoiceClone/Resources/MLXModels/
```

### 3. Add Swift Files

Drag these into Xcode:
- `VoiceClone/Core/ML/MLX/MLXQwen3TTSModel.swift`
- `VoiceClone/Core/ML/MLX/MLXTTSService.swift`

### 4. Update App Code

```swift
// Replace your CoreML service with:
@StateObject private var ttsService = MLXTTSService(tokenizer: tokenizer)

// Load & use:
try await ttsService.loadCapability(.voiceDesign)
let stream = try await ttsService.synthesize(text: "Hello", language: .english)
```

### 5. Test

Run on iOS 16+ device or simulator.

---

## 📊 Model Stats

| Model | Size | Memory | Speed |
|-------|------|--------|-------|
| INT4 (recommended) | 1.0GB | ~1.5GB | 2700 tok/s |

---

## 📚 Full Docs

- **Integration Guide**: `MLX_INTEGRATION_GUIDE.md` (complete instructions)
- **Summary**: `MLX_SOLUTION_SUMMARY.md` (what was done)
- **Technical**: `ARCHITECTURE_SIMPLIFICATION_FINDINGS.md` (why MLX works)

---

## ⚡ Key Advantages

✅ Full 28-layer transformer (vs CoreML error -5)
✅ Multi-codebook fix verified
✅ Fast: 600-2700 tokens/sec
✅ Compact: 1.0GB (4-bit)
⚠️ Trade-off: Higher battery (GPU vs ANE)

---

## 🐛 Troubleshooting

**"No such module 'MLX'"**
→ Add mlx-swift package (step 1)

**"Model not found"**
→ Copy model files (step 2), use "folder references" in Xcode

**"Slow inference"**
→ First run compiles (normal), subsequent runs fast

---

**Status**: Ready to integrate
**iOS**: 16.0+ required
**Device**: Best on Apple Silicon (M1/M2/M3)
