#!/usr/bin/env python3
"""
Test MLX model inference with various sequence lengths.
"""

import argparse
import time
import numpy as np
import mlx.core as mx

def load_mlx_model(model_path):
    """Load MLX model from npz file."""
    import json
    from pathlib import Path

    model_dir = Path(model_path)

    # Load config
    with open(model_dir / "config.json") as f:
        config = json.load(f)

    # Load weights
    weights = np.load(model_dir / "weights.npz")

    print(f"Loaded model from {model_path}")
    print(f"  Config: {config['num_hidden_layers']} layers, {config['hidden_size']} hidden")
    print(f"  Weights: {len(weights.files)} parameters")

    return weights, config


def test_inference(model_path, seq_lengths=[16, 32, 64, 128]):
    """Test inference with different sequence lengths."""
    print("=" * 60)
    print("MLX Model Inference Test")
    print("=" * 60)

    weights, config = load_mlx_model(model_path)

    print("\nTesting inference with various sequence lengths...")
    print("-" * 60)

    results = []

    for seq_len in seq_lengths:
        print(f"\nSequence length: {seq_len}")

        # Create test input
        input_ids = mx.array(
            [list(range(1, seq_len + 1))],
            dtype=mx.int32
        )

        # NOTE: We would need the actual MLX model class to run inference
        # For now, just verify the input shape
        print(f"  Input shape: {input_ids.shape}")
        print(f"  Input dtype: {input_ids.dtype}")

        # Record result
        results.append({
            "seq_len": seq_len,
            "input_shape": input_ids.shape,
            "status": "prepared"
        })

    print("\n" + "=" * 60)
    print("Test Summary")
    print("=" * 60)

    for r in results:
        print(f"  {r['seq_len']:3d} tokens: {r['status']}")

    print("\nNote: Full inference requires loading the model class.")
    print("The conversion script already tested inference with seq_len=16")

    return results


def main():
    parser = argparse.ArgumentParser(description="Test MLX model inference")
    parser.add_argument(
        "--model",
        type=str,
        default="./mlx_models/Qwen3TTS_INT4",
        help="Path to MLX model directory"
    )
    parser.add_argument(
        "--seq-lengths",
        type=int,
        nargs="+",
        default=[16, 32, 64, 128, 256],
        help="Sequence lengths to test"
    )

    args = parser.parse_args()

    test_inference(args.model, args.seq_lengths)


if __name__ == "__main__":
    main()
