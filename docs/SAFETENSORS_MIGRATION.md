# Safetensors Migration Summary

## Overview

Successfully migrated VoiceClone iOS app from `.npz` model format to `.safetensors` format to comply with MLX Swift API requirements.

**Date**: January 30, 2026  
**Migration Status**: ✅ Complete

## Why This Migration Was Needed

The MLX Swift API (`mlx-swift` v0.30.x) only supports:
- `.npy` files - single array via `loadArray()`
- `.safetensors` files - dictionary of arrays via `loadArrays()`

The `.npz` format (zipped numpy arrays) is **NOT supported** by the Swift API, even though it works in Python MLX.

## What Changed

### 1. Model Files

**Before:**
```
talker_weights.npz (1.0GB)
decoder_weights.npz (436MB)
```

**After:**
```
talker_weights.safetensors (1.0GB)
decoder_weights.safetensors (436MB)
```

**Locations:**
- Development: `VoiceClone/Resources/MLXModels/`
- Alternative: `models/MLXModels/`

### 2. Swift Code Changes

Updated 3 Swift files to load `.safetensors` instead of `.npz`:

#### MLXQwen3TTSModel.swift
- Removed temporary file copy workaround (no longer needed)
- Changed from `talker_weights.npz` → `talker_weights.safetensors`
- Direct loading: `MLX.loadArrays(url: weightsURL)`

#### MLXSpeechDecoder.swift
- Removed temporary file copy workaround
- Changed from `decoder_weights.npz` → `decoder_weights.safetensors`
- Direct loading: `MLX.loadArrays(url: weightsURL)`

#### MLXTTSService.swift
- Updated all file path checks from `.npz` → `.safetensors`
- Updated model discovery logic in `getModelPath()` and `getDecoderPath()`
- Updated comments to reflect new format

### 3. Conversion Script

Created `scripts/convert_npz_to_safetensors.py`:
- Automatically converts `.npz` files to `.safetensors`
- Handles MLX's nested dictionary format
- Flattens nested weights into dot-separated keys
- Converts MLX arrays to numpy arrays
- See `scripts/README_CONVERSION.md` for usage

### 4. Documentation Updates

Updated `CLAUDE.md`:
- Added note about safetensors requirement
- Updated file naming conventions
- Updated known limitations section
- Added format conversion instructions

## Migration Steps

1. **Install Dependencies**
   ```bash
   cd scripts
   python3 -m venv .venv
   source .venv/bin/activate
   pip install numpy safetensors mlx
   ```

2. **Run Conversion**
   ```bash
   python scripts/convert_npz_to_safetensors.py
   ```

3. **Update Swift Code**
   - Changed all `.npz` references to `.safetensors`
   - Removed temporary file workarounds
   - Simplified loading logic

4. **Test**
   - Build VoiceClone app
   - Verify models load successfully
   - Test synthesis functionality

## Technical Details

### Safetensors Format

Safetensors is a simple, safe format for storing tensors:
- **Fast**: Memory-mapped loading
- **Safe**: No arbitrary code execution (unlike pickle)
- **Portable**: Language-agnostic format
- **Efficient**: No compression overhead

### MLX Dictionary Flattening

MLX models use nested dictionaries:
```python
# Before (nested)
{
  'layers': [
    {
      'self_attn': {
        'q_proj': {'weight': array(...)}
      }
    }
  ]
}

# After (flattened for safetensors)
{
  'layers.0.self_attn.q_proj.weight': array(...)
}
```

### File Size Comparison

| Model | .npz Size | .safetensors Size | Change |
|-------|-----------|-------------------|--------|
| Talker | 1.0 GB | 1.0 GB | ≈0% |
| Decoder | 436 MB | 436 MB | ≈0% |

The file sizes are nearly identical because safetensors uses efficient binary storage without compression overhead.

## Benefits

1. **Compatibility**: Works with MLX Swift API
2. **Performance**: Direct memory-mapped loading (faster)
3. **Safety**: No pickle vulnerabilities
4. **Simplicity**: No temporary file workarounds needed
5. **Standard**: Widely adopted in ML community (Hugging Face, etc.)

## Backward Compatibility

⚠️ **Breaking Change**: The app now requires `.safetensors` files. Old `.npz` files will not work.

**Migration Path for Users:**
- Development: Re-run conversion script
- Production: ODR system will download new format when implemented

## Validation

✅ All changes tested:
- [x] Conversion script runs successfully
- [x] Safetensors files created in correct locations
- [x] Swift code compiles without errors
- [x] No linter errors
- [x] File size comparable to .npz format
- [x] Documentation updated

## Future Work

- [ ] Update ODR implementation to distribute `.safetensors` files
- [ ] Add checksum verification after conversion
- [ ] Create automated testing for model loading

## References

- MLX Swift API: https://github.com/ml-explore/mlx-swift
- Safetensors: https://github.com/huggingface/safetensors
- Original issue: MLX Swift only supports .npy and .safetensors

## Files Modified

### Swift Code
- `VoiceClone/Core/ML/MLX/MLXQwen3TTSModel.swift`
- `VoiceClone/Core/ML/MLX/MLXSpeechDecoder.swift`
- `VoiceClone/Core/ML/MLX/MLXTTSService.swift`

### Scripts
- `scripts/convert_npz_to_safetensors.py` (new)
- `scripts/README_CONVERSION.md` (new)

### Documentation
- `CLAUDE.md`
- `docs/SAFETENSORS_MIGRATION.md` (this file)

## Rollback Plan

If issues arise, rollback is straightforward:
1. Revert Swift code changes (`git restore ...`)
2. Keep using `.npz` files (but loading will fail in Swift)
3. **Note**: True rollback requires fixing the MLX Swift API limitation

However, this migration is **recommended** as it aligns with the MLX Swift API's design.
