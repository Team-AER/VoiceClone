#!/usr/bin/env python3
"""
Direct download of Qwen3-TTS model files from HuggingFace
and conversion to MLX format.
"""

import argparse
import json
import os
from pathlib import Path
import numpy as np
from safetensors.numpy import save_file
from safetensors import safe_open
import torch
from huggingface_hub import hf_hub_download, list_repo_files


def download_model_files(model_name: str, cache_dir: str = "./model_cache"):
    """Download all model files from HuggingFace."""
    print(f"\n{'='*60}")
    print(f"Downloading {model_name} files from HuggingFace")
    print(f"{'='*60}\n")
    
    # List all files in repo
    print("Listing files in repository...")
    try:
        files = list_repo_files(model_name)
        print(f"Found {len(files)} files in repository")
        
        # Filter for model weights and config
        model_files = [f for f in files if f.endswith(('.bin', '.safetensors', 'config.json'))]
        print(f"\nDownloading {len(model_files)} model files:")
        for f in model_files:
            print(f"  - {f}")
        
        # Download files
        downloaded = {}
        for file in model_files:
            print(f"\nDownloading {file}...")
            path = hf_hub_download(
                repo_id=model_name,
                filename=file,
                cache_dir=cache_dir
            )
            downloaded[file] = path
            print(f"  ✓ Saved to {path}")
        
        return downloaded
        
    except Exception as e:
        print(f"❌ Error listing/downloading files: {e}")
        raise


def load_and_convert_weights(model_files: dict, output_dir: Path):
    """Load weights from downloaded files and convert to MLX format."""
    print(f"\n{'='*60}")
    print("Loading and converting weights")
    print(f"{'='*60}\n")
    
    all_weights = {}
    
    # Load from .bin or .safetensors files
    for filename, filepath in model_files.items():
        if filename.endswith('.safetensors'):
            print(f"Loading {filename}...")
            with safe_open(filepath, framework="pt") as f:
                keys = f.keys()
                print(f"  Found {len(keys)} tensors")
                for key in keys:
                    tensor = f.get_tensor(key)
                    all_weights[key] = tensor
                    
        elif filename.endswith('.bin'):
            print(f"Loading {filename}...")
            weights = torch.load(filepath, map_location='cpu')
            print(f"  Found {len(weights)} tensors")
            all_weights.update(weights)
    
    print(f"\n✓ Loaded {len(all_weights)} total tensors")
    
    # Print first 30 keys to understand structure
    print("\nFirst 30 weight keys:")
    for i, key in enumerate(sorted(all_weights.keys())[:30]):
        shape = all_weights[key].shape
        dtype = all_weights[key].dtype
        print(f"  [{i}]: {key} -> {list(shape)} ({dtype})")
    
    # Show unique prefixes
    prefixes = set()
    for key in all_weights.keys():
        prefix = key.split('.')[0]
        prefixes.add(prefix)
    print(f"\nUnique top-level prefixes: {sorted(prefixes)}")
    
    # Convert to numpy FP16
    print("\nConverting to FP16 numpy arrays...")
    numpy_weights = {}
    for key, tensor in all_weights.items():
        numpy_weights[key] = tensor.detach().cpu().to(torch.float16).numpy()
        if len(numpy_weights) % 100 == 0:
            print(f"  Progress: {len(numpy_weights)}/{len(all_weights)}")
    
    total_size = sum(w.nbytes for w in numpy_weights.values())
    print(f"✓ Converted {len(numpy_weights)} tensors")
    print(f"  Total size: {total_size / 1024**3:.2f} GB")
    
    # Save all weights
    output_dir.mkdir(parents=True, exist_ok=True)
    weights_path = output_dir / "all_weights.safetensors"
    
    print(f"\nSaving to {weights_path}...")
    contiguous_weights = {}
    for key, value in numpy_weights.items():
        if not value.flags['C_CONTIGUOUS']:
            value = np.ascontiguousarray(value)
        contiguous_weights[key] = value
    
    save_file(contiguous_weights, str(weights_path))
    print(f"✓ Saved")
    
    return contiguous_weights


def extract_talker_weights(all_weights: dict, output_dir: Path):
    """Extract talker model weights specifically."""
    print(f"\n{'='*60}")
    print("Extracting talker model weights")
    print(f"{'='*60}\n")
    
    # Try to find talker weights by common prefixes
    talker_prefixes = ['model.talker.', 'talker.', 'text_encoder.', 'model.']
    
    talker_weights = {}
    for key in all_weights.keys():
        for prefix in talker_prefixes:
            if key.startswith(prefix):
                # Remove prefix
                new_key = key[len(prefix):]
                talker_weights[new_key] = all_weights[key]
                break
        else:
            # If no prefix matches, include it anyway
            talker_weights[key] = all_weights[key]
    
    print(f"Extracted {len(talker_weights)} talker weights")
    
    # Save talker weights separately
    weights_path = output_dir / "talker_weights.safetensors"
    print(f"Saving talker weights to {weights_path}...")
    
    save_file(talker_weights, str(weights_path))
    print(f"✓ Saved")
    
    return talker_weights


def create_config(model_files: dict, output_dir: Path):
    """Create config file."""
    print(f"\n{'='*60}")
    print("Creating config")
    print(f"{'='*60}\n")
    
    # Try to load existing config
    config_dict = {
        "model_type": "qwen3_tts_talker",
        "hidden_size": 1024,
        "num_hidden_layers": 12,
        "num_attention_heads": 16,
        "num_key_value_heads": 16,
        "intermediate_size": 4096,
        "vocab_size": 151936,
        "rms_norm_eps": 1e-6,
        "num_code_groups": 16,
        "codebook_size": 192,
    }
    
    for filename, filepath in model_files.items():
        if 'config.json' in filename:
            print(f"Loading config from {filename}...")
            try:
                with open(filepath, 'r') as f:
                    loaded_config = json.load(f)
                print(f"  Config keys: {list(loaded_config.keys())}")
                
                # Update with loaded values
                if 'text_config' in loaded_config:
                    text_config = loaded_config['text_config']
                    config_dict.update({
                        "hidden_size": text_config.get('hidden_size', config_dict['hidden_size']),
                        "num_hidden_layers": text_config.get('num_hidden_layers', config_dict['num_hidden_layers']),
                        "num_attention_heads": text_config.get('num_attention_heads', config_dict['num_attention_heads']),
                    })
                
                # Copy relevant top-level keys
                for key in ['vocab_size', 'num_code_groups', 'codebook_size']:
                    if key in loaded_config:
                        config_dict[key] = loaded_config[key]
                        
            except Exception as e:
                print(f"  Warning: Could not parse config: {e}")
    
    config_path = output_dir / "talker_config.json"
    with open(config_path, 'w') as f:
        json.dump(config_dict, f, indent=2)
    print(f"✓ Config saved to {config_path}")
    
    return config_dict


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign")
    parser.add_argument("--output", default="./mlx_models_fp16")
    parser.add_argument("--cache", default="./model_cache")
    args = parser.parse_args()
    
    try:
        # Download files
        model_files = download_model_files(args.model, args.cache)
        
        output_dir = Path(args.output)
        
        # Load and convert all weights
        all_weights = load_and_convert_weights(model_files, output_dir)
        
        # Extract talker weights specifically
        talker_weights = extract_talker_weights(all_weights, output_dir)
        
        # Create config
        config = create_config(model_files, output_dir)
        
        print(f"\n{'='*60}")
        print("✓ DOWNLOAD AND CONVERSION COMPLETE")
        print(f"{'='*60}")
        print(f"Output directory: {output_dir}")
        print(f"\nFiles created:")
        print(f"  - all_weights.safetensors ({len(all_weights)} tensors)")
        print(f"  - talker_weights.safetensors ({len(talker_weights)} tensors)")
        print(f"  - talker_config.json")
        print(f"\nNext steps:")
        print(f"1. Copy talker_weights.safetensors to VoiceClone/Resources/MLXModels/Qwen3TTS_FP16/")
        print(f"2. Copy talker_config.json to VoiceClone/Resources/MLXModels/Qwen3TTS_FP16/")
        print(f"3. Review the weight keys in all_weights.safetensors to understand structure")
        print(f"4. Update MLXQwen3TTSModel.swift to match the actual key names")
        print(f"{'='*60}\n")
        
        return 0
        
    except Exception as e:
        print(f"\n❌ ERROR: {e}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    exit(main())
