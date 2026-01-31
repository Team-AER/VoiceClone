#!/usr/bin/env python3
"""
Simple script to download Qwen3-TTS model directly from HuggingFace
without complex dependencies.
"""

import argparse
import json
import os
from pathlib import Path
import numpy as np
from safetensors.numpy import save_file
import torch
from transformers import AutoModel, AutoConfig


def download_and_convert(model_name: str, output_dir: str):
    """Download and convert Qwen3-TTS model."""
    print(f"\n{'='*60}")
    print(f"Downloading {model_name}")
    print(f"{'='*60}\n")
    
    try:
        # Load model using transformers directly
        print("Loading model with transformers.AutoModel...")
        model = AutoModel.from_pretrained(
            model_name,
            torch_dtype=torch.float16,
            trust_remote_code=True,  # Required for Qwen models
            device_map="cpu",
        )
        
        print(f"✓ Model loaded successfully")
        print(f"  Model type: {type(model)}")
        
        # Try to access the talker component
        if hasattr(model, 'talker'):
            talker = model.talker
            print("✓ Found talker component")
        elif hasattr(model, 'model') and hasattr(model.model, 'talker'):
            talker = model.model.talker
            print("✓ Found talker at model.talker")
        else:
            print("⚠️  Could not find talker component, using full model")
            talker = model
        
        # Extract state dict
        print("\nExtracting weights...")
        state_dict = talker.state_dict()
        print(f"✓ Found {len(state_dict)} tensors")
        
        # Print first 20 keys to see structure
        print("\nFirst 20 weight keys:")
        for i, key in enumerate(sorted(state_dict.keys())[:20]):
            shape = state_dict[key].shape
            print(f"  [{i}]: {key} -> {shape}")
        
        # Convert to numpy FP16
        print("\nConverting to numpy FP16...")
        weights = {}
        for key, tensor in state_dict.items():
            weights[key] = tensor.detach().cpu().to(torch.float16).numpy()
            if len(weights) % 100 == 0:
                print(f"  Progress: {len(weights)}/{len(state_dict)}")
        
        print(f"✓ Converted {len(weights)} tensors")
        total_size = sum(w.nbytes for w in weights.values())
        print(f"  Total size: {total_size / 1024**3:.2f} GB")
        
        # Save weights
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        
        weights_path = output_dir / "talker_weights.safetensors"
        print(f"\nSaving to {weights_path}...")
        
        # Make arrays contiguous
        contiguous_weights = {}
        for key, value in weights.items():
            if not value.flags['C_CONTIGUOUS']:
                value = np.ascontiguousarray(value)
            contiguous_weights[key] = value
        
        save_file(contiguous_weights, str(weights_path))
        print(f"✓ Saved {len(contiguous_weights)} tensors")
        
        # Try to extract config
        print("\nExtracting config...")
        try:
            config = AutoConfig.from_pretrained(model_name, trust_remote_code=True)
            
            # Try to get talker config if available
            if hasattr(config, 'text_config'):
                config = config.text_config
            
            config_dict = {
                "model_type": "qwen3_tts_talker",
                "hidden_size": getattr(config, 'hidden_size', 1024),
                "num_hidden_layers": getattr(config, 'num_hidden_layers', 12),
                "num_attention_heads": getattr(config, 'num_attention_heads', 16),
                "num_key_value_heads": getattr(config, 'num_key_value_heads', 16),
                "intermediate_size": getattr(config, 'intermediate_size', 4096),
                "vocab_size": getattr(config, 'vocab_size', 151936),
                "rms_norm_eps": getattr(config, 'rms_norm_eps', 1e-6),
                "num_code_groups": getattr(config, 'num_code_groups', 16),
                "codebook_size": getattr(config, 'codebook_size', 192),
            }
            
            config_path = output_dir / "talker_config.json"
            with open(config_path, 'w') as f:
                json.dump(config_dict, f, indent=2)
            print(f"✓ Config saved to {config_path}")
            
        except Exception as e:
            print(f"⚠️  Could not extract config: {e}")
        
        print(f"\n{'='*60}")
        print("✓ CONVERSION COMPLETE")
        print(f"{'='*60}")
        print(f"Output directory: {output_dir}")
        print(f"\nNext steps:")
        print(f"1. Copy {weights_path.name} to VoiceClone/Resources/MLXModels/Qwen3TTS_FP16/")
        print(f"2. Copy talker_config.json to VoiceClone/Resources/MLXModels/Qwen3TTS_FP16/")
        print(f"3. Build and test on device")
        print(f"{'='*60}\n")
        
    except Exception as e:
        print(f"\n❌ ERROR: {e}")
        import traceback
        traceback.print_exc()
        return 1
    
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign")
    parser.add_argument("--output", default="./mlx_models_fp16")
    args = parser.parse_args()
    
    exit(download_and_convert(args.model, args.output))
