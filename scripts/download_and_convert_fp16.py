#!/usr/bin/env python3
"""
Convert Qwen3-TTS to MLX FP16 format (Apple MLX Standard Approach)

This follows Apple's MLX conversion pattern:
1. Load model with transformers/HuggingFace
2. Extract state_dict() for all weights
3. Convert PyTorch tensors to numpy
4. Save as .npz or .safetensors

Usage:
    python download_and_convert_fp16_v2.py [--model MODEL_NAME] [--output OUTPUT_DIR]
"""

import argparse
import json
import os
from pathlib import Path
import numpy as np
from safetensors.numpy import save_file

print("Importing MLX and PyTorch (this may take a moment)...")
import torch


def download_model(model_name: str):
    """Download Qwen3-TTS model from HuggingFace."""
    print(f"\n{'='*60}")
    print(f"Downloading {model_name}")
    print(f"{'='*60}")
    
    from qwen_tts import Qwen3TTSModel
    
    print("Loading model (this will download ~3GB if not cached)...")
    wrapper = Qwen3TTSModel.from_pretrained(
        model_name,
        torch_dtype=torch.float16,  # Use FP16
        device_map="cpu",
    )
    
    print("✓ Model downloaded successfully")
    return wrapper


def extract_config_from_state(model, model_type="talker"):
    """Extract configuration from model."""
    if model_type == "talker":
        config = model.config
        codec_out_features = model.codec_head.out_features
        num_code_groups = config.num_code_groups
        codebook_size = codec_out_features // num_code_groups
        
        config_dict = {
            "model_type": "qwen3_tts_talker",
            "hidden_size": config.hidden_size,
            "num_hidden_layers": config.num_hidden_layers,
            "num_attention_heads": config.num_attention_heads,
            "num_key_value_heads": getattr(config, 'num_key_value_heads', config.num_attention_heads),
            "intermediate_size": config.intermediate_size,
            "vocab_size": getattr(config, 'vocab_size', 151936),
            "rms_norm_eps": getattr(config, 'rms_norm_eps', 1e-6),
            "num_code_groups": num_code_groups,
            "codebook_size": codebook_size,
            "audio_vocab_size": codebook_size,
        }
        
        print(f"\nTalker Configuration:")
        print(f"  Hidden size: {config_dict['hidden_size']}")
        print(f"  Layers: {config_dict['num_hidden_layers']}")
        print(f"  Attention heads: {config_dict['num_attention_heads']}")
        print(f"  Code groups: {config_dict['num_code_groups']}")
        print(f"  Codebook size: {config_dict['codebook_size']}")
        
        return config_dict
    else:
        # Decoder config (if we can access it)
        return {
            "model_type": "qwen3_tts_decoder",
            "hidden_size": 512,
            "num_hidden_layers": 6,
            "latent_dim": 1024,
            "codebook_dim": 512,
            "num_quantizers": 16,
            "codebook_size": 2048,
        }


def convert_model_mlx_style(model, output_dir: Path, model_name: str, config_dict: dict):
    """
    Convert model weights following Apple MLX pattern.
    
    Steps:
    1. Get state_dict() from PyTorch model
    2. Convert tensors to numpy FP16
    3. Save as safetensors
    """
    print(f"\nExtracting {model_name} weights (MLX standard approach)...")
    
    # Step 1: Get state_dict - this is the Apple MLX way
    state_dict = model.state_dict()
    print(f"✓ Extracted state_dict with {len(state_dict)} tensors")
    
    # Step 2: Convert to numpy FP16
    weights = {}
    for key, tensor in state_dict.items():
        # Convert to numpy and ensure FP16
        numpy_array = tensor.detach().cpu().to(torch.float16).numpy()
        weights[key] = numpy_array
        
        if len(weights) % 50 == 0:
            print(f"  Progress: {len(weights)}/{len(state_dict)} tensors")
    
    print(f"✓ Converted {len(weights)} tensors to numpy FP16")
    
    # Calculate total size
    total_size = sum(w.nbytes for w in weights.values())
    print(f"  Total size: {total_size / 1024**3:.2f} GB")
    
    # Step 3: Save as safetensors
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    weights_path = output_dir / f"{model_name}_weights.safetensors"
    print(f"\nSaving weights to {weights_path}...")
    
    # Ensure all arrays are contiguous
    contiguous_weights = {}
    for key, value in weights.items():
        if not value.flags['C_CONTIGUOUS']:
            value = np.ascontiguousarray(value)
        contiguous_weights[key] = value
    
    save_file(contiguous_weights, str(weights_path))
    print(f"✓ Saved {len(contiguous_weights)} tensors")
    
    # Save config
    config_path = output_dir / f"{model_name}_config.json"
    print(f"Saving config to {config_path}...")
    with open(config_path, 'w') as f:
        json.dump(config_dict, f, indent=2)
    print(f"✓ Config saved")
    
    # Print summary
    file_size = os.path.getsize(weights_path)
    print(f"\n{'='*60}")
    print(f"✓ {model_name.upper()} CONVERSION COMPLETE")
    print(f"{'='*60}")
    print(f"  Weights: {weights_path}")
    print(f"  Config: {config_path}")
    print(f"  Size: {file_size / 1024**3:.2f} GB")
    print(f"  Tensors: {len(contiguous_weights)}")
    print(f"{'='*60}\n")
    
    return weights_path


def main():
    parser = argparse.ArgumentParser(description="Convert Qwen3-TTS to MLX FP16 (Apple MLX Standard)")
    parser.add_argument(
        "--model",
        type=str,
        default="Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign",
        help="HuggingFace model name"
    )
    parser.add_argument(
        "--output",
        type=str,
        default="./mlx_models_fp16",
        help="Output directory"
    )
    parser.add_argument(
        "--talker-only",
        action="store_true",
        help="Only convert talker model"
    )
    
    args = parser.parse_args()
    
    print(f"\n{'='*60}")
    print("Qwen3-TTS FP16 Converter (Apple MLX Standard)")
    print("Following Apple's MLX conversion pattern")
    print(f"{'='*60}\n")
    
    # Download model
    wrapper = download_model(args.model)
    
    # Access talker model
    # The structure is: wrapper.model.talker for Qwen3TTSForConditionalGeneration
    if hasattr(wrapper, 'model') and hasattr(wrapper.model, 'talker'):
        talker = wrapper.model.talker
        print(f"✓ Found talker at wrapper.model.talker")
    else:
        raise AttributeError("Could not find talker in model structure")
    
    # Convert talker
    talker_config = extract_config_from_state(talker, "talker")
    talker_weights_path = convert_model_mlx_style(
        talker, 
        args.output, 
        "talker",
        talker_config
    )
    
    # Note: The decoder/vocoder is typically a separate model (BigVGAN) 
    # that needs to be downloaded separately or may already be converted
    print("\n" + "="*60)
    print("ℹ️  DECODER/VOCODER NOTE")
    print("="*60)
    print("The speech decoder (BigVGAN vocoder) is typically a separate")
    print("model. If you already have decoder_weights.safetensors in")
    print("VoiceClone/Resources/MLXModels/Qwen3TTS_Decoder/, you can use that.")
    print("Otherwise, the decoder may need to be downloaded separately.")
    print("="*60 + "\n")
    
    print("\n" + "="*60)
    print("✓ CONVERSION COMPLETE")
    print("="*60)
    print(f"Output directory: {args.output}")
    print("\nNext steps:")
    print("1. Copy talker_weights.safetensors to VoiceClone/Resources/MLXModels/Qwen3TTS_FP16/")
    print("2. Copy talker_config.json to VoiceClone/Resources/MLXModels/Qwen3TTS_FP16/")
    print("3. Verify decoder files are in VoiceClone/Resources/MLXModels/Qwen3TTS_Decoder/")
    print("4. Build and test on device")
    print("="*60 + "\n")


if __name__ == "__main__":
    main()
