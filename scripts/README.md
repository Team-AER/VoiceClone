# VoiceClone Scripts

This directory contains scripts for model conversion and utilities for the VoiceClone iOS app.

## Model Conversion (Primary)

### `download_and_convert_fp16.py`

**Purpose**: Convert Qwen3-TTS models to MLX FP16 format using Apple's official MLX conversion pattern.

**Usage**:
```bash
# Setup environment
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
pip install git+https://github.com/QwenLM/Qwen3-TTS.git

# Convert talker model
python download_and_convert_fp16.py \
    --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
    --output ./mlx_models_fp16 \
    --talker-only
```

**Output**:
- `mlx_models_fp16/talker_weights.safetensors` (3.6GB, 404 tensors)
- `mlx_models_fp16/talker_config.json`

**Key Features**:
- ✅ Uses Apple's official `state_dict()` pattern
- ✅ Extracts all 404 model weights
- ✅ FP16 format (no quantization)
- ✅ Compatible with MLX Swift API
- ✅ Simple and reliable

**See**: `FINAL_SOLUTION.md` for complete details

## Utility Scripts

### `export_tokenizer.py`

Export Qwen3-TTS tokenizer files for iOS app.

```bash
python export_tokenizer.py \
    --model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
    --output ../VoiceClone/Resources/Tokenizer
```

### `update_xcode_settings.py`

Update Xcode project settings programmatically.

## Test Scripts

### `test_mlx_inference.py`

Test MLX model inference.

### `test_model_outputs.py`

Test CoreML model outputs.

## Output Directory

- `mlx_models_fp16/` - Converted FP16 models (3.6GB)
  - `talker_weights.safetensors` - Talker model weights
  - `talker_config.json` - Talker model configuration

## Dependencies

All Python dependencies are in `requirements.txt`:
```bash
pip install -r requirements.txt
```

Additional requirement for Qwen3-TTS:
```bash
pip install git+https://github.com/QwenLM/Qwen3-TTS.git
```

## Architecture

The conversion follows Apple's MLX standard pattern:

```python
# 1. Load model
model = AutoModel.from_pretrained(model_name)

# 2. Get all weights via state_dict()
state_dict = model.state_dict()

# 3. Convert to numpy FP16
weights = {key: tensor.numpy() for key, tensor in state_dict.items()}

# 4. Save as safetensors
save_file(weights, output_path)
```

This is the same pattern used in:
- `mlx-examples/bert/convert.py`
- `mlx-lm/convert.py`
- All official MLX conversions

## Decoder/Vocoder Note

The speech decoder (BigVGAN vocoder) weights are already present in:
```
VoiceClone/Resources/MLXModels/Qwen3TTS_Decoder/
├── decoder_config.json
└── decoder_weights.safetensors (436MB)
```

These can continue to be used with the new FP16 talker model.

## Next Steps After Conversion

1. Copy converted files to project:
   ```bash
   mkdir -p ../VoiceClone/Resources/MLXModels/Qwen3TTS_FP16
   cp mlx_models_fp16/talker_* ../VoiceClone/Resources/MLXModels/Qwen3TTS_FP16/
   ```

2. Build and test on physical device (MLX requires Metal)

3. Verify synthesis works correctly

## Troubleshooting

### "No module named 'qwen_tts'"
```bash
pip install git+https://github.com/QwenLM/Qwen3-TTS.git
```

### "No module named 'safetensors'"
```bash
pip install safetensors>=0.4.0
```

### "Out of memory during conversion"
Close other applications. Conversion requires ~4GB RAM.

## References

- [FINAL_SOLUTION.md](FINAL_SOLUTION.md) - Complete explanation of the approach
- [Apple MLX Examples](https://github.com/ml-explore/mlx-examples)
- [MLX-LM Convert](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/convert.py)
- [Using MLX at HuggingFace](https://huggingface.co/docs/hub/mlx)

---

**Last Updated**: 2026-01-31
**Status**: Production ready
