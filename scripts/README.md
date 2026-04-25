# PolyJuiceVoice Scripts

Utility scripts for the PolyJuiceVoice app. **No Python is required to run the app** — models are downloaded by `ModelDownloadManager` at first launch directly from HuggingFace.

## Model Weights

The Qwen3-TTS model weights live on HuggingFace and are consumed as-is (no conversion):

- https://huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/talker_config.json
- https://huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/talker_weights.safetensors
- https://huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/decoder_config.json
- https://huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/decoder_weights.safetensors

See `PolyJuiceVoice/Core/ML/ModelDownloadManager.swift` for the download manifest.

### Dev setup (optional)

To avoid downloading 4GB on first launch, set the `POLYJUICEVOICE_MODELS_DIR` env var in your Xcode scheme to a directory containing `Qwen3TTS_FP16/` and `Qwen3TTS_Decoder/` subdirs with the files above.

```bash
# One-time manual download
mkdir -p ~/models/PolyJuiceVoice/{Qwen3TTS_FP16,Qwen3TTS_Decoder}
cd ~/models/PolyJuiceVoice/Qwen3TTS_FP16
curl -LO https://huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/talker_config.json
curl -LO https://huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/talker_weights.safetensors
cd ../Qwen3TTS_Decoder
curl -LO https://huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/decoder_config.json
curl -LO https://huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/decoder_weights.safetensors
```

Then set `POLYJUICEVOICE_MODELS_DIR=/Users/you/models/PolyJuiceVoice` in the scheme environment.

## Utilities

Two Python scripts are kept here as one-off dev utilities. They are NOT part of the runtime path and are not run during build:

- `export_tokenizer.py` — produced the bundled `PolyJuiceVoice/Resources/Tokenizer/*` files. The output files are already committed; you only need to re-run this if Qwen ships a tokenizer update.
- `update_xcode_settings.py` — helper for batch-editing Xcode project settings.

## Tensor-key audit

When the HuggingFace model format changes, the Swift weight-key mapping in `PolyJuiceVoice/Core/ML/MLX/WeightKeyMap.swift` may drift. Verify by running:

```bash
xcodebuild test -project ../PolyJuiceVoice.xcodeproj -scheme PolyJuiceVoice \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PolyJuiceVoiceTests/WeightKeyAuditTests
```

If `testTalkerRequiredKeysPresent` fails, update `WeightKeyMap.swift` to match the new state_dict. Inspect the raw keys with:

```bash
python3 -c '
import json, struct, sys
with open(sys.argv[1], "rb") as f:
    n = struct.unpack("<Q", f.read(8))[0]
    h = json.loads(f.read(n))
for k in sorted(k for k in h if k != "__metadata__"):
    print(k, h[k]["shape"])
' /path/to/talker_weights.safetensors | head
```

## Legacy output directories

The directories below are leftover from the old Python conversion pipeline and can be deleted when you no longer need them (each is several GB):

- `mlx_models_fp16/` — FP16 conversion output
- `mlx_models_fp16_base/` — base variant
- `mlx_models_fp16_custom/` — custom variant
- `model_cache/` — HuggingFace cache
