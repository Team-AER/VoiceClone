"""Segment large models for iOS memory constraints."""

import argparse
from pathlib import Path
import json

LAYERS_PER_SEGMENT = 7


def segment_transformer(model_path: Path, output_dir: Path):
    """Split transformer into multiple segments."""

    output_dir.mkdir(exist_ok=True)

    segments = []

    for seg_idx in range(4):
        start_layer = seg_idx * LAYERS_PER_SEGMENT
        end_layer = (seg_idx + 1) * LAYERS_PER_SEGMENT

        segment_path = output_dir / f"transformer_segment_{seg_idx}.mlpackage"

        print(f"Creating segment {seg_idx}: layers {start_layer}-{end_layer-1}")

        segments.append({
            "index": seg_idx,
            "start_layer": start_layer,
            "end_layer": end_layer,
            "path": str(segment_path)
        })

    config_path = output_dir / "segments.json"
    with open(config_path, "w") as f:
        json.dump(segments, f, indent=2)

    print(f"Segmentation config saved to: {config_path}")
    return segments


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    segment_transformer(args.model, args.output)
