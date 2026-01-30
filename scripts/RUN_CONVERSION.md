# Quick Reference: Model Conversion

This guide shows how to convert the Qwen3-TTS models to CoreML with all the bug fixes applied.

---

## Prerequisites

```bash
cd scripts

# Create Python environment (if not exists)
python3.12 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Install Qwen3-TTS (if not already installed)
pip install git+https://github.com/QwenLM/Qwen3-TTS.git
```

---

## Step 1: Convert Talker Model (CRITICAL - Contains Multi-Codebook Fix)

```bash
python convert_coreml.py \
    --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
    --simple \
    --output ./coreml_models/Qwen3TTS_VoiceDesign_FP16.mlpackage \
    --compute-units CPU_AND_NE \
    --attn-impl eager
```

**Expected Output**:
- Model downloads from HuggingFace
- Conversion takes 5-10 minutes
- Final model size: ~3.2GB
- ✓ Saved successfully
- ✓ Model validation passed

**If conversion fails**:
- Check error message for "aten::__ior__" → PyTorch version issue
- Try with `--compute-units CPU_ONLY` for debugging
- Check available disk space (need ~10GB free)

---

## Step 2: Convert Speech Decoder

```bash
python convert_coreml.py \
    --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
    --decoder \
    --output ./coreml_models/Qwen3TTS_SpeechDecoder_FP16.mlpackage \
    --compute-units CPU_AND_NE
```

**Expected Output**:
- Conversion takes 2-3 minutes
- Final model size: ~50MB
- ✓ Saved successfully

---

## Step 3: Validate Converted Models (REQUIRED!)

```bash
python test_model_outputs.py \
    --talker ./coreml_models/Qwen3TTS_VoiceDesign_FP16.mlpackage \
    --decoder ./coreml_models/Qwen3TTS_SpeechDecoder_FP16.mlpackage
```

**Expected Output**:
```
Testing talker model: ./coreml_models/Qwen3TTS_VoiceDesign_FP16.mlpackage
============================================================
✓ Model loaded successfully
✓ Inference completed
✓ Shape is correct: [batch=1, codebooks=16, frames=5]
✓ Codebooks 0 and 1 are different (correct)
  Codebook 0: [123, 456, 789, ...]
  Codebook 1: [234, 567, 890, ...]
  Code value range: [0, 2047]
  Found 16 unique codebook patterns out of 16 codebooks
✓ Good diversity - 16/16 unique patterns
✓ Talker model PASSED all tests

Testing decoder model: ./coreml_models/Qwen3TTS_SpeechDecoder_FP16.mlpackage
============================================================
✓ Model loaded successfully
✓ Inference completed
✓ Waveform generated with 12000 samples
✓ Decoder model PASSED

============================================================
✓ ALL TESTS PASSED
============================================================
```

**CRITICAL CHECK**:
- ✅ "Codebooks 0 and 1 are different (correct)"
- ❌ If it says "Codebooks are IDENTICAL - bug not fixed!" → conversion failed, check convert_coreml.py

---

## Step 4: Export Tokenizer

```bash
python export_tokenizer.py \
    --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
    --output ../VoiceClone/Resources/Tokenizer
```

**Expected Output**:
```
Loading tokenizer from: Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign
✓ Tokenizer loaded successfully
Exporting vocabulary...
✓ Exported 151936 tokens to: ../VoiceClone/Resources/Tokenizer/vocab.json
Exporting BPE merges...
✓ Exported 151000 mergeable ranks
Exporting special tokens...
✓ Exported special tokens to: ../VoiceClone/Resources/Tokenizer/special_tokens.json
✓ Tokenizer export complete!
```

**Verify**:
```bash
wc -l ../VoiceClone/Resources/Tokenizer/merges.txt
# Should output: >1000 lines
```

---

## Step 5: Copy Models to iOS Project

```bash
# Create models directory
mkdir -p ../VoiceClone/Resources/Models

# Copy converted models
cp -r ./coreml_models/Qwen3TTS_VoiceDesign_FP16.mlpackage \
      ../VoiceClone/Resources/Models/

cp -r ./coreml_models/Qwen3TTS_SpeechDecoder_FP16.mlpackage \
      ../VoiceClone/Resources/Models/

# Verify
ls -lh ../VoiceClone/Resources/Models/
# Should show:
# Qwen3TTS_VoiceDesign_FP16.mlpackage/    (~3.2GB)
# Qwen3TTS_SpeechDecoder_FP16.mlpackage/  (~50MB)
```

---

## Step 6: Update Xcode Project

1. Open `VoiceClone.xcodeproj` in Xcode
2. In Project Navigator, right-click on `VoiceClone/Resources/Models`
3. Select "Add Files to VoiceClone..."
4. Navigate to `Resources/Models/`
5. Select both `.mlpackage` folders
6. Ensure "Copy items if needed" is UNCHECKED (they're already in the right place)
7. Click "Add"

---

## Troubleshooting

### Issue: "ModuleNotFoundError: No module named 'qwen_tts'"

**Solution**:
```bash
pip install git+https://github.com/QwenLM/Qwen3-TTS.git
```

### Issue: "RuntimeError: aten::__ior__ is not supported"

**Cause**: PyTorch 2.3 masking issue

**Solution**:
```bash
pip install torch>=2.4.0
# OR use the workaround already in convert_coreml.py (line 241)
```

### Issue: "CoreML error -5: Failed to create execution plan"

**Causes**:
- Model too large for available memory
- Incompatible operations

**Solutions**:
1. Try `--compute-units CPU_ONLY`:
   ```bash
   python convert_coreml.py \
       --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
       --simple \
       --output ./coreml_models/Qwen3TTS_VoiceDesign_CPU.mlpackage \
       --compute-units CPU_ONLY \
       --attn-impl eager
   ```

2. Check model file is valid:
   ```bash
   du -sh ./coreml_models/Qwen3TTS_VoiceDesign_FP16.mlpackage
   # Should be ~3.2GB, not KB
   ```

3. Verify Python can load it:
   ```python
   import coremltools as ct
   model = ct.models.MLModel('./coreml_models/Qwen3TTS_VoiceDesign_FP16.mlpackage')
   print("Loaded OK!")
   ```

### Issue: Test shows "Codebooks are IDENTICAL"

**This is critical!** The multi-codebook fix didn't apply.

**Solution**:
1. Check `convert_coreml.py` lines 277-296 match IMPLEMENTATION_SUMMARY.md
2. Verify you're running the fixed version:
   ```bash
   grep -A 5 "codec_logits.view" convert_coreml.py
   # Should show the reshape logic
   ```
3. Re-run conversion from Step 1

### Issue: "No such file or directory: vocab.json"

**Cause**: Tokenizer export failed or didn't run

**Solution**:
```bash
# Run export again
python export_tokenizer.py \
    --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
    --output ../VoiceClone/Resources/Tokenizer

# Check output
ls ../VoiceClone/Resources/Tokenizer/
# Should show: vocab.json, merges.txt, special_tokens.json, tokenizer_config.json
```

---

## Verification Checklist

Before moving to iOS testing:

- [ ] Talker model converted successfully (~3.2GB)
- [ ] Decoder model converted successfully (~50MB)
- [ ] `test_model_outputs.py` shows codebooks are different
- [ ] Codebook diversity is 16/16 unique patterns
- [ ] Tokenizer exported (vocab.json exists, merges.txt >1000 lines)
- [ ] Models copied to `VoiceClone/Resources/Models/`
- [ ] Models added to Xcode project

---

## Quick Commands Summary

```bash
# Full conversion pipeline
cd scripts
source .venv/bin/activate

# Convert talker
python convert_coreml.py --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign --simple --output ./coreml_models/Qwen3TTS_VoiceDesign_FP16.mlpackage --compute-units CPU_AND_NE --attn-impl eager

# Convert decoder
python convert_coreml.py --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign --decoder --output ./coreml_models/Qwen3TTS_SpeechDecoder_FP16.mlpackage --compute-units CPU_AND_NE

# Validate
python test_model_outputs.py --talker ./coreml_models/Qwen3TTS_VoiceDesign_FP16.mlpackage --decoder ./coreml_models/Qwen3TTS_SpeechDecoder_FP16.mlpackage

# Export tokenizer
python export_tokenizer.py --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign --output ../VoiceClone/Resources/Tokenizer

# Copy to project
mkdir -p ../VoiceClone/Resources/Models
cp -r ./coreml_models/*.mlpackage ../VoiceClone/Resources/Models/
```

---

## Next Steps

After successful conversion:
1. Build iOS app in Xcode
2. Run unit tests: `⌘U`
3. Run on simulator/device
4. Test synthesis with sample text
5. Verify audio is intelligible
6. Check memory usage (<3GB)

See `IMPLEMENTATION_SUMMARY.md` for full testing checklist.
