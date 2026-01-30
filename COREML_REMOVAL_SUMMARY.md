# CoreML Removal Summary

This document summarizes the complete removal of CoreML code and infrastructure from the VoiceClone project, transitioning to a pure MLX-based implementation.

## Date
2026-01-30

## Removed Files

### Swift Source Files
- `VoiceClone/Core/ML/MLModelManager.swift` - CoreML model lifecycle management
- `VoiceClone/Core/ML/Inference/TTSInferenceEngine.swift` - CoreML inference engine
- `VoiceClone/Core/ML/Inference/KVCache.swift` - KV cache for CoreML transformer models
- `VoiceClone/Core/TTS/TTSService.swift` - Old CoreML-based TTS service
- `VoiceClone/Core/TTS/TTSServiceProtocol.swift` - Renamed to TTSTypes.swift (protocol removed, kept enums)

### Test Files
- `VoiceCloneTests/TTSServiceIntegrationTests.swift` - CoreML service tests

### Python Scripts
- `scripts/convert_coreml.py` - ONNX to CoreML conversion
- `scripts/export_onnx.py` - PyTorch to ONNX export
- `scripts/quantize_int4.py` - CoreML model quantization
- `scripts/segment_model.py` - CoreML model segmentation
- `scripts/convert_decoder_mlx.py` - Decoder conversion (obsolete)

### Model Directories
- `scripts/coreml_models/` - All CoreML .mlpackage files
- `scripts/onnx_models/` - ONNX intermediate files
- `scripts/test_output/` - Test output artifacts

### Documentation
- `FINAL_STATUS.md`
- `E2E_TEST_RESULTS.md`
- `IMPLEMENTATION_SUMMARY.md`
- `VERIFICATION_CHECKLIST.md`
- `ARCHITECTURE_SIMPLIFICATION_FINDINGS.md`

## Modified Files

### Architecture Changes

**TTSServiceProtocol.swift → TTSTypes.swift**
- Removed `TTSServiceProtocol` protocol (only one implementation exists)
- Kept `TTSServiceState` and `TTSCapability` enums
- These are now just type definitions, not protocol requirements

**MLXTTSService.swift**
- Removed conformance to `TTSServiceProtocol`
- Changed from `final class MLXTTSService: ObservableObject, TTSServiceProtocol`
- To: `final class MLXTTSService: ObservableObject`
- Updated MARK comments from "TTSServiceProtocol" to "Published Properties" and "Public Methods"

**DIContainer.swift**
- Changed `let ttsService: any TTSServiceProtocol` 
- To: `let ttsService: MLXTTSService`
- Removed dependency on `modelManager: MLModelManager`

**View Models**
- `SynthesisViewModel.swift`
- `VoiceDesignViewModel.swift`
- `VoiceCloneViewModel.swift`
- All changed from `private var ttsService: any TTSServiceProtocol?`
- To: `private var ttsService: MLXTTSService?`
- All `setup()` methods updated to accept `MLXTTSService` directly

### Test Updates

**MLXTTSServiceTests.swift**
- Removed `testConformsToProtocol()` test
- All other tests remain functional

### Documentation Updates

**CLAUDE.md**
- Completely rewritten to focus on MLX backend
- Removed all CoreML references
- Updated architecture diagram
- Changed key components table
- Updated model conversion commands
- Replaced CoreML debugging tips with MLX tips
- Updated dependencies section

## Architecture Simplification

### Before (CoreML)
```
App Layer
  ↓
TTSServiceProtocol (abstraction for multiple backends)
  ↓
TTSService (CoreML) or MLXTTSService
  ↓
MLModelManager + TTSInferenceEngine + KVCache
  ↓
CoreML (.mlpackage models)
```

### After (MLX Only)
```
App Layer
  ↓
MLXTTSService (single implementation)
  ↓
MLXQwen3TTSModel
  ↓
MLX (.npz models)
```

## Benefits

1. **Simpler Architecture**: Removed protocol abstraction layer since only one backend exists
2. **Cleaner Codebase**: Eliminated ~3000 lines of CoreML-specific code
3. **Reduced Dependencies**: No longer depends on CoreML framework
4. **Better Performance**: MLX provides JIT compilation and Metal acceleration
5. **Smaller Binary**: Removed CoreML conversion and quantization tools

## Remaining Work

1. **Speech Decoder**: Implement real speech decoder (currently placeholder audio)
   - See `DECODER_STATUS.md` for details
   - 114M parameter model with Snake activation, RVQ, upsampling
   
2. **Model Download**: Add UI for downloading MLX models if not bundled

3. **Testing**: Verify all features work with MLX backend on device

## Migration Notes

For anyone working on this codebase:

- All TTS functionality now goes through `MLXTTSService` directly
- No protocol abstraction exists anymore
- Models are in `.npz` format (MLX), not `.mlpackage` (CoreML)
- Use `convert_mlx.py` for model conversion, not `convert_coreml.py`
- Audio currently uses placeholder sine waves (decoder implementation pending)

## Verification

To verify CoreML is completely removed:

```bash
# No CoreML imports should exist
grep -r "import CoreML" VoiceClone --include="*.swift"

# No CoreML files should exist
find . -name "*.mlpackage"

# No ONNX files should exist
find . -name "*.onnx"

# No CoreML conversion scripts
ls scripts/convert_coreml.py  # Should not exist
ls scripts/export_onnx.py    # Should not exist
```

All commands above should return no results or "No such file" errors.
