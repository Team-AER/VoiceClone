"""Export tokenizer for iOS."""

import argparse
import json
from pathlib import Path
from transformers import AutoTokenizer


def export_tokenizer(model_name: str, output_dir: Path):
    output_dir.mkdir(exist_ok=True)

    tokenizer = AutoTokenizer.from_pretrained(model_name)

    vocab = tokenizer.get_vocab()
    vocab_path = output_dir / "vocab.json"
    with open(vocab_path, "w", encoding="utf-8") as f:
        json.dump(vocab, f, ensure_ascii=False, indent=2)

    if hasattr(tokenizer, "bpe_ranks"):
        merges = list(tokenizer.bpe_ranks.keys())
        merges_path = output_dir / "merges.txt"
        with open(merges_path, "w", encoding="utf-8") as f:
            f.write("#version: 0.2\n")
            for merge in merges:
                f.write(f"{merge[0]} {merge[1]}\n")

    special_tokens = {
        "bos_token": tokenizer.bos_token,
        "eos_token": tokenizer.eos_token,
        "pad_token": tokenizer.pad_token,
        "unk_token": tokenizer.unk_token,
    }
    special_path = output_dir / "special_tokens.json"
    with open(special_path, "w") as f:
        json.dump(special_tokens, f, indent=2)

    config = {
        "vocab_size": len(vocab),
        "model_max_length": tokenizer.model_max_length,
        "padding_side": tokenizer.padding_side,
        "truncation_side": tokenizer.truncation_side,
    }
    config_path = output_dir / "tokenizer_config.json"
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)

    print(f"Tokenizer exported to: {output_dir}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign")
    parser.add_argument("--output", type=Path, default=Path("./tokenizer"))
    args = parser.parse_args()

    export_tokenizer(args.model, args.output)
