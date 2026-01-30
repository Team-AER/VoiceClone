# VoiceClone - Remaining Work

**Last Updated**: 2026-01-30
**Status**: ✅ BUILD SUCCEEDS (device only - MLX requires Metal hardware)

---

## ✅ Completed - Build Fixes

### 1. Fix MLX API Compatibility Issues
All Swift 6 strict concurrency issues have been resolved.

**Fixed Issues**:
- `Conv1d` parameter names changed: `inChannels` → `inputChannels`, `outChannels` → `outputChannels` ✅
- `MLX.repeated()` API changed ✅  
- No `MLXRandom` module - using zeros as workaround ✅
- Actor isolation issues with Swift 6 strict concurrency ✅
- `SpeechDecoderConfig` Codable MainActor isolation ✅
- `SnakeActivation` and `ResidualVectorQuantizer` nonisolated properties ✅
- `MLXArray` Sendable crossing actor boundaries ✅
- Type-checking timeout in complex closures ✅

**Key Patterns Used**:
- `nonisolated(unsafe)` for stored properties that need cross-isolation access
- `@unchecked Sendable` for data-holding structs
- `@preconcurrency import MLX` to suppress Sendable warnings for MLXArray
- Manual JSON parsing instead of Codable for nonisolated contexts
- Simplified closures to avoid type-checking timeouts

---

## ⚠️ Important: Simulator Limitation

**MLX does not work on iOS Simulator** - it requires Metal hardware features that are only available on physical iOS devices. The build will fail with linker errors on simulator:

```
Undefined symbols for architecture arm64:
  "_MTLIOErrorDomain", referenced from: ...
  "_MTLTensorDomain", referenced from: ...
```

**Solution**: Build and run on a physical iOS device.

---

## 🟡 High Priority - Next Steps

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

### 3. Run E2E Tests on Device
Requires physical iOS device:
- Unit tests for MLX layers (Snake, RVQ, Conv)
- Integration tests for MLXTTSService
- E2E synthesis tests (with real decoder)

**Estimated time**: 30 min (with device)

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

## Files Status

| File | Status | Notes |
|------|--------|-------|
| MLX Models (talker) | ✅ Bundled | In `Resources/MLXModels/Qwen3TTS_INT4/` |
| MLX Models (decoder) | ⚠️ Not bundled | At `models/MLXModels/Qwen3TTS_Decoder/`, works via dev path |
| MLX Package | ✅ Installed | v0.30.3 |
| Conv Layers | ✅ Fixed | API updated |
| RVQ | ✅ Fixed | API updated, nonisolated |
| SnakeActivation | ✅ Fixed | nonisolated(unsafe) properties |
| MLXQwen3TTSModel | ✅ Fixed | nonisolated init |
| MLXSpeechDecoder | ✅ Fixed | Manual JSON parsing, nonisolated |
| MLXTTSService | ✅ Fixed | @preconcurrency import MLX |
| CoreDataStack | ✅ Fixed | nonisolated performBackgroundTask |
| VoiceStorage | ✅ Fixed | Works with CoreDataStack |
| TTSTypes | ✅ Fixed | Added TTSError enum |
| Tests | ⏳ Pending | Requires physical device |

---

## Build Commands

```bash
# Build for device (WORKS)
xcodebuild build \
  -project VoiceClone.xcodeproj \
  -scheme VoiceClone \
  -destination 'generic/platform=iOS'

# Build for simulator (WILL FAIL - MLX needs Metal hardware)
# xcodebuild build \
#   -project VoiceClone.xcodeproj \
#   -scheme VoiceClone \
#   -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Run tests (requires physical device)
xcodebuild test \
  -project VoiceClone.xcodeproj \
  -scheme VoiceClone \
  -destination 'platform=iOS,name=Your Device Name'
```

---

## Next Immediate Steps

1. ~~Fix `MLXQwen3TTSConfig` actor isolation~~ ✅
2. ~~Fix `CoreDataStack` Sendable closure~~ ✅
3. ~~Build and verify compilation~~ ✅
4. Run unit tests on physical device (requires device)
5. Test real synthesis with decoder (requires device)
6. Update documentation

**Current state**: Build succeeds, ready for device testing
