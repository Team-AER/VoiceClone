# Model Format Conversion

## Overview

This directory contains scripts to convert MLX model files from `.npz` format to `.safetensors` format, which is required by the MLX Swift API.

## Why Convert?

The Swift MLX API (`mlx-swift`) only supports:
- `.npy` - single array via `loadArray()`
- `.safetensors` - dictionary of arrays via `loadArrays()`
- `.npz` - **NOT SUPPORTED**

Since our Qwen3-TTS models are distributed in `.npz` format, we need to convert them to `.safetensors` for use in the iOS app.

## Usage

### Prerequisites

1. Install Python dependencies:
```bash
cd scripts
python3 -m venv .venv
source .venv/bin/activate
pip install numpy safetensors mlx
```

### Convert Models

Run the conversion script:
```bash
cd /Users/prakhar/Developer/AER/VoiceClone
source scripts/.venv/bin/activate
python scripts/convert_npz_to_safetensors.py
```

The script will automatically:
1. Find all `.npz` model files in:
   - `VoiceClone/Resources/MLXModels/Qwen3TTS_INT4/talker_weights.npz`
   - `VoiceClone/Resources/MLXModels/Qwen3TTS_Decoder/decoder_weights.npz`
   - `models/MLXModels/Qwen3TTS_INT4/talker_weights.npz`
   - `models/MLXModels/Qwen3TTS_Decoder/decoder_weights.npz`

2. Convert each `.npz` file to `.safetensors` in the same directory

3. Flatten nested MLX dictionaries into individual named tensors

### Output

For each model, you'll get a `.safetensors` file:
- Talker model: ~2.2GB → `talker_weights.safetensors`
- Decoder model: ~440MB → `decoder_weights.safetensors`

### Verification

After conversion, verify the Swift code can load the models:
1. Build the VoiceClone iOS app
2. Check console logs for "✓ Loaded MLX model from..."
3. Test synthesis to ensure models work correctly

## Technical Details

### MLX Array Conversion

The script handles MLX's nested dictionary format:
- MLX models store weights in nested dictionaries (e.g., `layers.0.self_attn.q_proj.weight`)
- The script flattens these into dot-separated keys for safetensors
- MLX arrays are converted to numpy arrays before saving

### Example Output

```
Loading talker_weights.npz...
  Flattening embed_tokens...
    embed_tokens.weight: (32000, 1024) (float32)
    embed_tokens.scales: (32000, 128) (float32)
  Flattening layers...
    layers.0.self_attn.q_proj.weight: (1024, 1024) (float32)
    ...
  Total tensors: 542
Done! 2198.4MB -> 2198.2MB
```

## Troubleshooting

### ImportError: No module named 'mlx'

Make sure you activated the virtual environment:
```bash
source scripts/.venv/bin/activate
```

### File not found

Ensure you have the `.npz` model files in the correct locations. Download them from HuggingFace if needed.

### Safetensor save error

If you see "dtype object is not covered", the script needs to handle a new MLX data type. File an issue with the error message.

## Files

- `convert_npz_to_safetensors.py` - Main conversion script
- `.venv/` - Python virtual environment (gitignored)
- `README_CONVERSION.md` - This file
