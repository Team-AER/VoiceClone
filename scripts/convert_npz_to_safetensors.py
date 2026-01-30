#!/usr/bin/env python3
"""
Convert MLX .npz weight files to .safetensors format.
mlx-swift only supports safetensors, not npz.
"""

import numpy as np
from safetensors.numpy import save_file
import os
import sys

try:
    import mlx.core as mx
    HAS_MLX = True
except ImportError:
    HAS_MLX = False
    print("Warning: MLX not installed. Will try to convert without MLX.")

def mlx_to_numpy(arr):
    """Convert MLX array to numpy array."""
    if HAS_MLX and isinstance(arr, mx.array):
        return np.array(arr)
    return arr

def flatten_nested_dict(d, parent_key='', sep='.'):
    """Recursively flatten a nested dictionary."""
    items = []
    for k, v in d.items():
        new_key = f"{parent_key}{sep}{k}" if parent_key else k
        if isinstance(v, dict):
            items.extend(flatten_nested_dict(v, new_key, sep=sep).items())
        elif isinstance(v, np.ndarray):
            items.append((new_key, v))
        elif HAS_MLX and hasattr(mx, 'array') and isinstance(v, mx.array):
            # Convert MLX array to numpy
            np_arr = mlx_to_numpy(v)
            items.append((new_key, np_arr))
        else:
            print(f"  Warning: Skipping {new_key} (type: {type(v)})")
    return dict(items)

def convert_npz_to_safetensors(npz_path: str, output_path: str = None):
    """Convert a .npz file to .safetensors format."""
    if output_path is None:
        output_path = npz_path.replace('.npz', '.safetensors')

    print(f"Loading {npz_path}...")
    data = np.load(npz_path, allow_pickle=True)

    # Convert to dict with proper dtypes for safetensors
    tensors = {}
    for name in data.files:
        obj = data[name]
        
        # Handle nested dictionaries (MLX format)
        if isinstance(obj, dict) or (isinstance(obj, np.ndarray) and obj.dtype == object):
            # Extract dict from numpy array wrapper if it's a scalar object array
            if isinstance(obj, np.ndarray) and obj.ndim == 0:
                obj = obj.item()
            
            if isinstance(obj, dict):
                print(f"  Flattening {name}...")
                flattened = flatten_nested_dict(obj, parent_key=name)
                for key, arr in flattened.items():
                    if not arr.flags['C_CONTIGUOUS']:
                        arr = np.ascontiguousarray(arr)
                    tensors[key] = arr
                    print(f"    {key}: {arr.shape} ({arr.dtype})")
            elif isinstance(obj, np.ndarray) and obj.ndim > 0:
                # It's an array of dicts, process each element
                print(f"  Processing array {name} with {len(obj)} elements...")
                for i, item in enumerate(obj.flat):
                    if isinstance(item, dict):
                        flattened = flatten_nested_dict(item, parent_key=f"{name}.{i}")
                        for key, arr in flattened.items():
                            if not arr.flags['C_CONTIGUOUS']:
                                arr = np.ascontiguousarray(arr)
                            tensors[key] = arr
                            print(f"    {key}: {arr.shape} ({arr.dtype})")
            else:
                print(f"  Skipping {name} (unexpected type: {type(obj)})")
        elif isinstance(obj, np.ndarray):
            # Direct numpy array
            arr = obj
            if not arr.flags['C_CONTIGUOUS']:
                arr = np.ascontiguousarray(arr)
            tensors[name] = arr
            print(f"  {name}: {arr.shape} ({arr.dtype})")
        else:
            print(f"  Skipping {name} (type: {type(obj)})")

    print(f"\nSaving {output_path}...")
    print(f"  Total tensors: {len(tensors)}")
    save_file(tensors, output_path)

    # Verify
    output_size = os.path.getsize(output_path)
    input_size = os.path.getsize(npz_path)
    print(f"Done! {input_size / 1e6:.1f}MB -> {output_size / 1e6:.1f}MB")

def main():
    # Convert talker model
    talker_paths = [
        "VoiceClone/Resources/MLXModels/Qwen3TTS_INT4/talker_weights.npz",
        "models/MLXModels/Qwen3TTS_INT4/talker_weights.npz",
    ]

    # Convert decoder model
    decoder_paths = [
        "VoiceClone/Resources/MLXModels/Qwen3TTS_Decoder/decoder_weights.npz",
        "models/MLXModels/Qwen3TTS_Decoder/decoder_weights.npz",
    ]

    for path in talker_paths + decoder_paths:
        if os.path.exists(path):
            print(f"\n=== Converting {path} ===")
            convert_npz_to_safetensors(path)
        else:
            print(f"Skipping {path} (not found)")

if __name__ == "__main__":
    main()
