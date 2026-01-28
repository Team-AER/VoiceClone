"""Quantize CoreML models to INT4 for mobile deployment."""

import argparse
from pathlib import Path
import coremltools as ct
from coremltools.optimize.coreml import (
    OptimizationConfig,
    OpLinearQuantizerConfig,
    OpPalettizerConfig,
    palettize_weights,
    linear_quantize_weights
)


def quantize_model(
    input_path: Path,
    output_path: Path,
    bits: int = 4,
    granularity: str = "per_block",
    block_size: int = 32
):
    print(f"Loading model from: {input_path}")
    model = ct.models.MLModel(str(input_path))

    print(f"Quantizing to INT{bits} with {granularity} granularity...")

    if bits == 4:
        pal_granularity = "per_tensor"

        config = OptimizationConfig(
            global_config=OpPalettizerConfig(
                mode="kmeans",
                nbits=4,
                granularity=pal_granularity,
                group_size=block_size if granularity == "per_block" else 32
            )
        )
        quantized = palettize_weights(model, config)
    else:
        config = OptimizationConfig(
            global_config=OpLinearQuantizerConfig(
                mode="linear_symmetric",
                dtype=f"int{bits}",
                granularity=granularity,
                block_size=block_size if granularity == "per_block" else None
            )
        )
        quantized = linear_quantize_weights(model, config)

    print("Validating quantized model...")

    quantized.save(str(output_path))
    print(f"Saved quantized model to: {output_path}")

    original_size = sum(f.stat().st_size for f in input_path.rglob("*") if f.is_file())
    quantized_size = sum(f.stat().st_size for f in output_path.rglob("*") if f.is_file())

    print(f"Size reduction: {original_size / 1e6:.1f}MB -> {quantized_size / 1e6:.1f}MB "
          f"({(1 - quantized_size/original_size) * 100:.1f}% smaller)")

    return quantized


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bits", type=int, default=4, choices=[4, 8])
    parser.add_argument("--granularity", default="per_block", choices=["per_tensor", "per_channel", "per_block"])
    parser.add_argument("--block-size", type=int, default=32)
    args = parser.parse_args()

    quantize_model(args.input, args.output, args.bits, args.granularity, args.block_size)
