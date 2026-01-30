# VoiceClone - Remaining Work

**Last Updated**: 2026-01-30
**Status**: Build failing - MLX API compatibility issues

---

## 🔴 Critical - Blocking Build

### 1. Fix MLX API Compatibility Issues
The project uses mlx-swift 0.30.3 but code was written for an older API.

**Issues**:
- `Conv1d` parameter names changed: `inChannels` → `inputChannels`, `outChannels` → `outputChannels` ✅ FIXED
- `MLX.repeated()` API changed ✅ FIXED  
- No `MLXRandom` module - need to use different random API ⚠️ WORKAROUND (using zeros)
- Actor isolation issues with Swift 6 strict concurrency ⚠️ IN PROGRESS

**Files affected**:
- `VoiceClone/Core/ML/MLX/MLXQwen3TTSModel.swift` - Actor isolation errors
- `VoiceClone/Core/ML/MLX/Layers/ConvLayers.swift` - ✅ Fixed
- `VoiceClone/Core/ML/MLX/Layers/ResidualVectorQuantizer.swift` - ✅ Fixed
- `VoiceClone/Core/Storage/VoiceStorage.swift` - ✅ Fixed
- `VoiceClone/Core/Storage/CoreDataStack.swift` - Sendable closure error

**Estimated time**: 1-2 hours

---

## 🟡 High Priority - After Build Fixes

### 2. Bundle Decoder Model Properly
Decoder model exists but isn't bundled in app.

**Issue**: Both talker and decoder have `config.json` and `weights.npz`, causing Xcode copy conflicts.

**Solutions** (pick one):
- **A)** Keep models outside bundle, use dev path fallback (current workaround)
- **B)** Create proper folder references in Xcode that preserve directory structure
- **C)** On-demand download to Documents directory

**Recommendation**: Option A for development, Option C for production

**Estimated time**: 30 min - 2 hours depending on approach

---

### 3. Run E2E Tests
Once build succeeds:
- Unit tests for MLX layers (Snake, RVQ, Conv)
- Integration tests for MLXTTSService
- E2E synthesis tests (with real decoder)

**Estimated time**: 30 min

---

## 🟢 Optional - Post-Launch

### 4. Voice Cloning Implementation
Currently falls back to voice design mode.

**Needed**:
- Reference audio embedding extraction
- Pass embeddings to generation

**Estimated time**: 4-8 hours

---

### 5. Performance Optimization
- Memory optimization (currently ~1.5GB)
- Thermal throttling monitoring
- Battery impact measurement

**Estimated time**: 2-4 hours

---

### 6. Model Download UI
If using on-demand download approach for decoder.

**Estimated time**: 4-6 hours

---

## Current Blockers (In Priority Order)

1. **Actor isolation in `MLXQwen3TTSConfig.init(json:)`** - Need nonisolated init
2. **Sendable closure in `CoreDataStack.performBackgroundTask`** - Need @Sendable annotation
3. Build must succeed before any testing

---

## Quick Wins

These can be done immediately after build succeeds:

- Remove placeholder audio warnings from logs
- Update documentation to reflect real decoder usage
- Add performance metrics logging
- Create build/run instructions for new developers

---

## Files Status

| File | Status | Notes |
|------|--------|-------|
| MLX Models (talker) | ✅ Bundled | In `Resources/MLXModels/Qwen3TTS_INT4/` |
| MLX Models (decoder) | ⚠️ Not bundled | At `models/MLXModels/Qwen3TTS_Decoder/`, works via dev path |
| MLX Package | ✅ Installed | v0.30.3 |
| Conv Layers | ✅ Fixed | API updated |
| RVQ | ✅ Fixed | API updated |
| MLXQwen3TTSModel | ⚠️ Actor issue | Init isolation problem |
| MLXTTSService | ✅ Ready | With decoder integration |
| MLXSpeechDecoder | ✅ Complete | Full implementation |
| VoiceStorage | ⚠️ Actor issue | CoreDataStack sendable |
| Tests | ⏳ Pending | Can't run until build succeeds |

---

## Next Immediate Steps

1. Fix `MLXQwen3TTSConfig` actor isolation (5 min)
2. Fix `CoreDataStack` Sendable closure (5 min)
3. Build and verify compilation (2 min)
4. Run unit tests (5 min)
5. Test real synthesis with decoder (10 min)
6. Update documentation (10 min)

**Total estimated time to working state**: 30-45 minutes
