#!/usr/bin/env python3
"""
Convert Qwen3-TTS to MLX format with quantization.

MLX is Apple's ML framework that works on Apple Silicon and supports
transformers natively - bypassing CoreML's limitations.
"""

import argparse
import json
import os
import shutil
import time
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import numpy as np

# Check MLX availability
print(f"MLX version: {mx.__version__}")
print(f"Metal available: {mx.metal.is_available()}")


def load_qwen3_tts_weights(model_name: str):
    """Load Qwen3-TTS weights from HuggingFace."""
    import torch

    print(f"Loading model: {model_name}")

    from qwen_tts import Qwen3TTSModel
    wrapper = Qwen3TTSModel.from_pretrained(
        model_name,
        torch_dtype=torch.float32,
        device_map="cpu",
    )

    # Get the inner model and talker
    model = wrapper.model
    talker = model.talker
    config = talker.config

    # Calculate actual codebook size from codec head
    codec_out_features = talker.codec_head.out_features
    num_code_groups = config.num_code_groups
    codebook_size = codec_out_features // num_code_groups

    # Add codebook_size to config for later use
    config.codebook_size = codebook_size

    print(f"  ✓ Model loaded")
    print(f"  Hidden size: {config.hidden_size}")
    print(f"  Layers: {config.num_hidden_layers}")
    print(f"  Attention heads: {config.num_attention_heads}")
    print(f"  KV heads: {config.num_key_value_heads}")
    print(f"  Codec head out: {codec_out_features} ({num_code_groups} x {codebook_size})")

    return talker, config


def convert_torch_to_mlx(torch_tensor):
    """Convert PyTorch tensor to MLX array."""
    np_array = torch_tensor.detach().cpu().numpy()
    return mx.array(np_array)


class MLXQwen3TTSEmbedding(nn.Module):
    """MLX implementation of Qwen3-TTS embedding layer."""

    def __init__(self, vocab_size: int, embed_dim: int):
        super().__init__()
        self.embed_tokens = nn.Embedding(vocab_size, embed_dim)

    def __call__(self, input_ids):
        return self.embed_tokens(input_ids)


class MLXQwen3Attention(nn.Module):
    """MLX implementation of Qwen3 attention."""

    def __init__(self, hidden_size: int, num_heads: int, num_kv_heads: int, head_dim: int):
        super().__init__()
        self.num_heads = num_heads
        self.num_kv_heads = num_kv_heads
        self.head_dim = head_dim
        self.scale = head_dim ** -0.5

        self.q_proj = nn.Linear(hidden_size, num_heads * head_dim, bias=False)
        self.k_proj = nn.Linear(hidden_size, num_kv_heads * head_dim, bias=False)
        self.v_proj = nn.Linear(hidden_size, num_kv_heads * head_dim, bias=False)
        self.o_proj = nn.Linear(num_heads * head_dim, hidden_size, bias=False)

    def __call__(self, x, mask=None, cache=None):
        B, L, _ = x.shape

        queries = self.q_proj(x)
        keys = self.k_proj(x)
        values = self.v_proj(x)

        # Reshape for attention
        queries = queries.reshape(B, L, self.num_heads, self.head_dim).transpose(0, 2, 1, 3)
        keys = keys.reshape(B, L, self.num_kv_heads, self.head_dim).transpose(0, 2, 1, 3)
        values = values.reshape(B, L, self.num_kv_heads, self.head_dim).transpose(0, 2, 1, 3)

        # Repeat KV heads if needed (GQA)
        if self.num_kv_heads < self.num_heads:
            n_rep = self.num_heads // self.num_kv_heads
            keys = mx.repeat(keys, n_rep, axis=1)
            values = mx.repeat(values, n_rep, axis=1)

        # Scaled dot-product attention
        scores = (queries @ keys.transpose(0, 1, 3, 2)) * self.scale

        if mask is not None:
            scores = scores + mask

        weights = mx.softmax(scores, axis=-1)
        output = weights @ values

        # Reshape back
        output = output.transpose(0, 2, 1, 3).reshape(B, L, -1)
        return self.o_proj(output)


class MLXQwen3MLP(nn.Module):
    """MLX implementation of Qwen3 MLP."""

    def __init__(self, hidden_size: int, intermediate_size: int):
        super().__init__()
        self.gate_proj = nn.Linear(hidden_size, intermediate_size, bias=False)
        self.up_proj = nn.Linear(hidden_size, intermediate_size, bias=False)
        self.down_proj = nn.Linear(intermediate_size, hidden_size, bias=False)

    def __call__(self, x):
        return self.down_proj(nn.silu(self.gate_proj(x)) * self.up_proj(x))


class MLXQwen3Layer(nn.Module):
    """MLX implementation of a Qwen3 transformer layer."""

    def __init__(self, hidden_size: int, num_heads: int, num_kv_heads: int,
                 head_dim: int, intermediate_size: int, rms_norm_eps: float):
        super().__init__()
        self.self_attn = MLXQwen3Attention(hidden_size, num_heads, num_kv_heads, head_dim)
        self.mlp = MLXQwen3MLP(hidden_size, intermediate_size)
        self.input_layernorm = nn.RMSNorm(hidden_size, eps=rms_norm_eps)
        self.post_attention_layernorm = nn.RMSNorm(hidden_size, eps=rms_norm_eps)

    def __call__(self, x, mask=None, cache=None):
        # Self-attention with residual
        h = x + self.self_attn(self.input_layernorm(x), mask, cache)
        # MLP with residual
        out = h + self.mlp(self.post_attention_layernorm(h))
        return out


class MLXQwen3TTSTalker(nn.Module):
    """MLX implementation of Qwen3-TTS talker model."""

    def __init__(self, config):
        super().__init__()

        self.hidden_size = config.hidden_size
        self.num_layers = config.num_hidden_layers
        self.num_heads = config.num_attention_heads
        self.num_kv_heads = getattr(config, 'num_key_value_heads', self.num_heads)
        self.head_dim = getattr(config, 'head_dim', self.hidden_size // self.num_heads)
        self.intermediate_size = config.intermediate_size
        self.vocab_size = getattr(config, 'text_vocab_size', 151936)
        self.rms_norm_eps = getattr(config, 'rms_norm_eps', 1e-6)
        self.num_code_groups = getattr(config, 'num_code_groups', 16)
        # Use codebook_size from config (calculated from codec_head during loading)
        self.codebook_size = getattr(config, 'codebook_size', 192)

        # Embeddings
        self.embed_tokens = nn.Embedding(self.vocab_size, self.hidden_size)

        # Text projection (if exists)
        self.text_projection = nn.Linear(self.hidden_size, self.hidden_size, bias=False)

        # Transformer layers
        self.layers = [
            MLXQwen3Layer(
                self.hidden_size,
                self.num_heads,
                self.num_kv_heads,
                self.head_dim,
                self.intermediate_size,
                self.rms_norm_eps,
            )
            for _ in range(self.num_layers)
        ]

        # Final norm
        self.norm = nn.RMSNorm(self.hidden_size, eps=self.rms_norm_eps)

        # Codec head for audio codes
        # Output size: num_code_groups * codebook_size
        self.codec_head = nn.Linear(
            self.hidden_size,
            self.num_code_groups * self.codebook_size,
            bias=True  # Codec head may have bias
        )

    def __call__(self, input_ids, mask=None):
        # Embeddings
        h = self.embed_tokens(input_ids)
        h = self.text_projection(h)

        # Create causal mask if not provided
        if mask is None:
            L = input_ids.shape[1]
            mask = nn.MultiHeadAttention.create_additive_causal_mask(L)

        # Transformer layers
        for layer in self.layers:
            h = layer(h, mask)

        # Final norm
        h = self.norm(h)

        # Codec head
        codec_logits = self.codec_head(h)

        # Reshape for multi-codebook: [batch, seq, 16*2048] -> [batch, seq, 16, 2048]
        B, L, _ = codec_logits.shape
        codec_logits = codec_logits.reshape(B, L, self.num_code_groups, self.codebook_size)

        # Get codes via argmax
        codes = mx.argmax(codec_logits, axis=-1)

        # Transpose to [batch, 16, seq]
        codes = codes.transpose(0, 2, 1)

        return codes


def copy_weights(mlx_model, talker, config):
    """Copy weights from PyTorch talker to MLX model."""
    print("Copying weights...")

    # talker is Qwen3TTSTalkerForConditionalGeneration
    # talker.model is Qwen3TTSTalkerModel (the transformer)
    transformer = talker.model

    # Copy text embedding weights
    if hasattr(transformer, 'text_embedding'):
        mlx_model.embed_tokens.weight = convert_torch_to_mlx(transformer.text_embedding.weight)
    elif hasattr(transformer, 'embed_tokens'):
        mlx_model.embed_tokens.weight = convert_torch_to_mlx(transformer.embed_tokens.weight)

    # Copy text projection (it's a MLP, we just use the first linear)
    if hasattr(talker, 'text_projection'):
        text_proj = talker.text_projection
        # Check if it's a simple linear or a ResizeMLP
        if hasattr(text_proj, 'weight'):
            mlx_model.text_projection.weight = convert_torch_to_mlx(text_proj.weight)
        elif hasattr(text_proj, 'fc'):
            mlx_model.text_projection.weight = convert_torch_to_mlx(text_proj.fc.weight)
        elif hasattr(text_proj, 'linear'):
            mlx_model.text_projection.weight = convert_torch_to_mlx(text_proj.linear.weight)
        else:
            # Try to find any linear layer
            for name, child in text_proj.named_children():
                if hasattr(child, 'weight') and child.weight.dim() == 2:
                    mlx_model.text_projection.weight = convert_torch_to_mlx(child.weight)
                    break

    # Copy layer weights
    layers = transformer.layers
    for i, (mlx_layer, torch_layer) in enumerate(zip(mlx_model.layers, layers)):
        print(f"  Copying layer {i+1}/{len(mlx_model.layers)}")

        # Attention
        attn = torch_layer.self_attn
        mlx_layer.self_attn.q_proj.weight = convert_torch_to_mlx(attn.q_proj.weight)
        mlx_layer.self_attn.k_proj.weight = convert_torch_to_mlx(attn.k_proj.weight)
        mlx_layer.self_attn.v_proj.weight = convert_torch_to_mlx(attn.v_proj.weight)
        mlx_layer.self_attn.o_proj.weight = convert_torch_to_mlx(attn.o_proj.weight)

        # MLP
        mlp = torch_layer.mlp
        mlx_layer.mlp.gate_proj.weight = convert_torch_to_mlx(mlp.gate_proj.weight)
        mlx_layer.mlp.up_proj.weight = convert_torch_to_mlx(mlp.up_proj.weight)
        mlx_layer.mlp.down_proj.weight = convert_torch_to_mlx(mlp.down_proj.weight)

        # LayerNorms
        mlx_layer.input_layernorm.weight = convert_torch_to_mlx(torch_layer.input_layernorm.weight)
        mlx_layer.post_attention_layernorm.weight = convert_torch_to_mlx(torch_layer.post_attention_layernorm.weight)

    # Copy final norm
    if hasattr(transformer, 'norm'):
        mlx_model.norm.weight = convert_torch_to_mlx(transformer.norm.weight)

    # Copy codec head
    if hasattr(talker, 'codec_head'):
        mlx_model.codec_head.weight = convert_torch_to_mlx(talker.codec_head.weight)
        if hasattr(talker.codec_head, 'bias') and talker.codec_head.bias is not None:
            mlx_model.codec_head.bias = convert_torch_to_mlx(talker.codec_head.bias)

    print("✓ Weight copy complete")
    return mlx_model


def quantize_model(model, bits: int = 8, group_size: int = 64):
    """Quantize MLX model to specified bits."""
    print(f"Quantizing model to {bits}-bit...")

    # Use MLX's built-in quantization
    nn.quantize(model, group_size=group_size, bits=bits)

    print(f"✓ Quantization complete ({bits}-bit, group_size={group_size})")
    return model


def save_mlx_model(model, config, output_path: str):
    """Save MLX model to disk."""
    output_path = Path(output_path)
    output_path.mkdir(parents=True, exist_ok=True)

    # Get all weights and convert to numpy
    weights = dict(model.parameters())

    # Evaluate all arrays
    for v in weights.values():
        mx.eval(v)

    # Convert to numpy arrays (works for both quantized and non-quantized)
    np_weights = {k: np.array(v) for k, v in weights.items()}

    # Save as NPZ (most compatible)
    model_path = output_path / "weights.npz"
    np.savez(str(model_path), **np_weights)
    print(f"✓ Saved weights to {model_path}")

    # Calculate total size
    total_size = sum(v.nbytes for v in np_weights.values())
    print(f"  Model size: {total_size / 1024**3:.2f} GB ({len(np_weights)} parameters)")

    # Save config
    config_dict = {
        "hidden_size": config.hidden_size,
        "num_hidden_layers": config.num_hidden_layers,
        "num_attention_heads": config.num_attention_heads,
        "num_key_value_heads": getattr(config, 'num_key_value_heads', config.num_attention_heads),
        "intermediate_size": config.intermediate_size,
        "vocab_size": config.vocab_size,
        "rms_norm_eps": config.rms_norm_eps,
        "num_code_groups": getattr(config, 'num_code_groups', 16),
        "audio_vocab_size": getattr(config, 'audio_vocab_size', 2048),
        "model_type": "qwen3_tts",
    }

    config_path = output_path / "config.json"
    with open(config_path, "w") as f:
        json.dump(config_dict, f, indent=2)
    print(f"✓ Saved config to {config_path}")

    return output_path


def test_mlx_model(model, seq_len: int = 16):
    """Test MLX model inference."""
    print(f"\nTesting MLX model with sequence length {seq_len}...")

    # Create test input
    test_tokens = list(range(1, min(seq_len + 1, 1000)))[:seq_len]
    input_ids = mx.array([test_tokens], dtype=mx.int32)

    # Run inference
    mx.eval(input_ids)  # Ensure input is evaluated

    try:
        start_time = time.time()
        codes = model(input_ids)
        mx.eval(codes)  # Force evaluation
        elapsed = time.time() - start_time

        print(f"✓ Inference successful!")
        print(f"  Input shape: {input_ids.shape}")
        print(f"  Output shape: {codes.shape}")
        print(f"  Output dtype: {codes.dtype}")
        print(f"  Time: {elapsed:.3f}s ({seq_len/elapsed:.1f} tokens/sec)")

        # Check codebook diversity
        codes_np = np.array(codes)
        if codes_np.shape[1] >= 2:
            codebook_0 = codes_np[0, 0, :]
            codebook_1 = codes_np[0, 1, :]
            if np.array_equal(codebook_0, codebook_1):
                print("  ⚠ Codebooks are identical (bug!)")
            else:
                print("  ✓ Codebooks are different (correct!)")

        return True
    except Exception as e:
        print(f"✗ Inference failed: {e}")
        import traceback
        traceback.print_exc()
        return False


def main():
    parser = argparse.ArgumentParser(description="Convert Qwen3-TTS to MLX format")
    parser.add_argument(
        "--model",
        type=str,
        default="Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign",
        help="HuggingFace model name or path"
    )
    parser.add_argument(
        "--output",
        type=str,
        default="./mlx_models/Qwen3TTS",
        help="Output directory"
    )
    parser.add_argument(
        "--bits",
        type=int,
        default=8,
        choices=[4, 8],
        help="Quantization bits (4 or 8)"
    )
    parser.add_argument(
        "--group-size",
        type=int,
        default=64,
        help="Quantization group size"
    )
    parser.add_argument(
        "--no-quantize",
        action="store_true",
        help="Skip quantization (keep FP16)"
    )
    parser.add_argument(
        "--test",
        action="store_true",
        help="Test model after conversion"
    )
    parser.add_argument(
        "--test-lengths",
        type=int,
        nargs="+",
        default=[16],
        help="Sequence lengths to test (default: 16)"
    )

    args = parser.parse_args()

    print("=" * 60)
    print("Qwen3-TTS to MLX Converter")
    print("=" * 60)

    # Load PyTorch model (returns talker and config)
    talker, config = load_qwen3_tts_weights(args.model)

    # Create MLX model
    print("\nCreating MLX model...")
    mlx_model = MLXQwen3TTSTalker(config)

    # Copy weights
    mlx_model = copy_weights(mlx_model, talker, config)

    # Quantize if requested
    output_suffix = "FP16"
    if not args.no_quantize:
        mlx_model = quantize_model(mlx_model, bits=args.bits, group_size=args.group_size)
        output_suffix = f"INT{args.bits}"

    # Test model
    if args.test:
        print("\n" + "=" * 60)
        print("Testing Model Inference")
        print("=" * 60)
        for seq_len in args.test_lengths:
            test_mlx_model(mlx_model, seq_len=seq_len)
            print()

    # Save model
    output_path = f"{args.output}_{output_suffix}"
    save_mlx_model(mlx_model, config, output_path)

    print("\n" + "=" * 60)
    print(f"✓ Conversion complete!")
    print(f"  Output: {output_path}")
    print("=" * 60)


if __name__ == "__main__":
    main()
