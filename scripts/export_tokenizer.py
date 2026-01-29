"""Export tokenizer for iOS with error handling."""

import argparse
import json
from pathlib import Path
from transformers import AutoTokenizer
import sys


def export_tokenizer(model_name: str, output_dir: Path):
    """Export tokenizer vocabulary, merges, and config for iOS app."""
    output_dir.mkdir(exist_ok=True, parents=True)

    print(f"Loading tokenizer from: {model_name}")
    try:
        tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
        print(f"✓ Tokenizer loaded successfully")
    except Exception as e:
        print(f"✗ Failed to load tokenizer: {e}")
        sys.exit(1)

    # Export vocabulary
    print("Exporting vocabulary...")
    vocab = tokenizer.get_vocab()
    vocab_path = output_dir / "vocab.json"
    with open(vocab_path, "w", encoding="utf-8") as f:
        json.dump(vocab, f, ensure_ascii=False, indent=2)
    print(f"✓ Exported {len(vocab)} tokens to: {vocab_path}")

    # Export BPE merges (if available)
    print("Exporting BPE merges...")
    merges_path = output_dir / "merges.txt"
    merges_exported = False

    # Try different attributes for different tokenizer types
    if hasattr(tokenizer, "bpe_ranks"):
        # Standard BPE tokenizer
        merges = list(tokenizer.bpe_ranks.keys())
        with open(merges_path, "w", encoding="utf-8") as f:
            f.write("#version: 0.2\n")
            for merge in merges:
                f.write(f"{merge[0]} {merge[1]}\n")
        merges_exported = True
        print(f"✓ Exported {len(merges)} BPE merges")

    elif hasattr(tokenizer, "mergeable_ranks"):
        # Qwen-style tokenizer
        try:
            merges = list(tokenizer.mergeable_ranks.keys())
            with open(merges_path, "w", encoding="utf-8") as f:
                f.write("#version: 0.2\n")
                for merge_bytes in merges:
                    # Convert bytes to string representation
                    try:
                        merge_str = merge_bytes.decode('utf-8')
                        # Split on spaces or use the bytes representation
                        parts = merge_str.split()
                        if len(parts) >= 2:
                            f.write(f"{parts[0]} {parts[1]}\n")
                        else:
                            # Use the full string as-is
                            f.write(f"{merge_str}\n")
                    except:
                        # If can't decode, skip this merge
                        continue
            merges_exported = True
            print(f"✓ Exported {len(merges)} mergeable ranks")
        except Exception as e:
            print(f"⚠ Could not export mergeable_ranks: {e}")

    if not merges_exported:
        # Create empty merges file for compatibility
        with open(merges_path, "w", encoding="utf-8") as f:
            f.write("#version: 0.2\n")
        print("⚠ No BPE merges found, created empty merges file")

    # Export special tokens
    print("Exporting special tokens...")
    special_tokens = {
        "bosToken": tokenizer.bos_token if tokenizer.bos_token else "<|bos|>",
        "eosToken": tokenizer.eos_token if tokenizer.eos_token else "<|eos|>",
        "padToken": tokenizer.pad_token if tokenizer.pad_token else "<|pad|>",
        "unkToken": tokenizer.unk_token if tokenizer.unk_token else "<|unk|>",
    }
    special_path = output_dir / "special_tokens.json"
    with open(special_path, "w") as f:
        json.dump(special_tokens, f, indent=2)
    print(f"✓ Exported special tokens to: {special_path}")

    # Export tokenizer config
    print("Exporting tokenizer config...")
    config = {
        "vocab_size": len(vocab),
        "model_max_length": tokenizer.model_max_length if hasattr(tokenizer, "model_max_length") else 2048,
        "padding_side": tokenizer.padding_side if hasattr(tokenizer, "padding_side") else "right",
        "truncation_side": tokenizer.truncation_side if hasattr(tokenizer, "truncation_side") else "right",
    }
    config_path = output_dir / "tokenizer_config.json"
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    print(f"✓ Exported config to: {config_path}")

    # Summary
    print(f"\n✓ Tokenizer export complete!")
    print(f"  Output directory: {output_dir}")
    print(f"  Vocabulary size: {len(vocab)}")
    print(f"  Files created:")
    print(f"    - vocab.json")
    print(f"    - merges.txt")
    print(f"    - special_tokens.json")
    print(f"    - tokenizer_config.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign")
    parser.add_argument("--output", type=Path, default=Path("./tokenizer"))
    args = parser.parse_args()

    export_tokenizer(args.model, args.output)
