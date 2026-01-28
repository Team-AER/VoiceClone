"""Export Qwen3-TTS models to ONNX format."""

import torch
import argparse
from pathlib import Path
from qwen_tts import Qwen3TTSModel
from transformers import AutoTokenizer
from transformers import masking_utils


def export_model(
    model_name: str,
    output_dir: Path,
    opset_version: int = 17,
    simple: bool = False,
):
    print(f"Loading model: {model_name}")

    model = Qwen3TTSModel.from_pretrained(
        model_name,
        torch_dtype=torch.float16,
        device_map="cpu"
    )
    core_model = resolve_core_model(model)
    if hasattr(core_model, "eval"):
        core_model.eval()

    tokenizer = AutoTokenizer.from_pretrained(model_name)

    if simple:
        return export_simple_talker(core_model, tokenizer, output_dir, opset_version)

    batch_size = 1
    seq_len = 128

    transformer = resolve_transformer(core_model)

    vocab_size = None
    if hasattr(transformer, "get_input_embeddings"):
        try:
            embeddings = transformer.get_input_embeddings()
            if embeddings is not None and hasattr(embeddings, "num_embeddings"):
                vocab_size = embeddings.num_embeddings
        except Exception:
            vocab_size = None
    if vocab_size is None and hasattr(transformer, "codec_embedding") and hasattr(transformer.codec_embedding, "num_embeddings"):
        vocab_size = transformer.codec_embedding.num_embeddings
    if vocab_size is None and hasattr(transformer, "model"):
        try:
            text_embedding = transformer.model.text_embedding
            if hasattr(text_embedding, "num_embeddings"):
                vocab_size = text_embedding.num_embeddings
        except Exception:
            vocab_size = None
    if vocab_size is None and hasattr(core_model, "get_input_embeddings"):
        try:
            embeddings = core_model.get_input_embeddings()
            if embeddings is not None and hasattr(embeddings, "num_embeddings"):
                vocab_size = embeddings.num_embeddings
        except NotImplementedError:
            vocab_size = None
    if vocab_size is None and hasattr(core_model, "config") and hasattr(core_model.config, "vocab_size"):
        vocab_size = core_model.config.vocab_size
    if vocab_size is None:
        vocab_size = tokenizer.vocab_size

    dummy_input_ids = torch.randint(0, vocab_size, (batch_size, seq_len))
    dummy_attention_mask = torch.ones(batch_size, seq_len, dtype=torch.long)

    output_path = output_dir / f"{model_name.split('/')[-1]}.onnx"

    torch.onnx.export(
        transformer,
        (dummy_input_ids, dummy_attention_mask),
        output_path,
        input_names=["input_ids", "attention_mask"],
        output_names=["logits", "audio_tokens"],
        dynamic_axes={
            "input_ids": {0: "batch", 1: "sequence"},
            "attention_mask": {0: "batch", 1: "sequence"},
            "logits": {0: "batch", 1: "sequence"},
            "audio_tokens": {0: "batch", 1: "sequence"}
        },
        opset_version=opset_version,
        do_constant_folding=True
    )

    print(f"Exported to: {output_path}")

    decoder_path = output_dir / "speech_decoder.onnx"
    speech_decoder = resolve_speech_decoder(core_model)
    export_speech_decoder(speech_decoder, decoder_path)

    return output_path, decoder_path


def export_speech_decoder(decoder, output_path: Path):
    """Export the speech tokenizer decoder."""
    num_quantizers = getattr(decoder, "config", None)
    if num_quantizers is not None and hasattr(decoder.config, "num_quantizers"):
        codebooks = decoder.config.num_quantizers
    else:
        codebooks = 16
    dummy_codes = torch.randint(0, 2048, (1, codebooks, 100), dtype=torch.int32)

    torch.onnx.export(
        decoder,
        dummy_codes,
        output_path,
        input_names=["audio_codes"],
        output_names=["waveform"],
        dynamic_axes={
            "audio_codes": {2: "frames"},
            "waveform": {1: "samples"}
        },
        opset_version=17
    )

    print(f"Exported decoder to: {output_path}")


def export_dummy(output_dir: Path, opset_version: int = 17):
    class DummyTalker(torch.nn.Module):
        def __init__(self, vocab_size=256, hidden=64, codebooks=16, frames=12):
            super().__init__()
            self.embed = torch.nn.Embedding(vocab_size, hidden)
            self.proj = torch.nn.Linear(hidden, vocab_size)
            self.codebooks = codebooks
            self.frames = frames

        def forward(self, input_ids, attention_mask=None):
            hidden = self.embed(input_ids)
            logits = self.proj(hidden)
            batch = input_ids.shape[0]
            audio_codes = torch.zeros((batch, self.codebooks, self.frames), dtype=torch.int32)
            return logits, audio_codes

    class DummyDecoder(torch.nn.Module):
        def __init__(self, codebooks=16, frames=12):
            super().__init__()
            self.codebooks = codebooks
            self.frames = frames
            self.proj = torch.nn.Linear(codebooks, 1)

        def forward(self, audio_codes):
            codes = audio_codes.float()
            summed = codes.mean(dim=2)  # [B, codebooks]
            waveform = self.proj(summed).repeat(1, self.frames)
            return waveform

    output_dir.mkdir(exist_ok=True)

    talker = DummyTalker()
    decoder = DummyDecoder()

    dummy_input_ids = torch.randint(0, 256, (1, 8))
    dummy_attention_mask = torch.ones(1, 8, dtype=torch.long)

    talker_path = output_dir / "Qwen3TTS_Dummy.onnx"
    torch.onnx.export(
        talker,
        (dummy_input_ids, dummy_attention_mask),
        talker_path,
        input_names=["input_ids", "attention_mask"],
        output_names=["logits", "audio_codes"],
        dynamic_axes={
            "input_ids": {0: "batch", 1: "sequence"},
            "attention_mask": {0: "batch", 1: "sequence"},
            "logits": {0: "batch", 1: "sequence"},
        },
        opset_version=opset_version,
        do_constant_folding=True,
    )

    decoder_path = output_dir / "speech_decoder.onnx"
    dummy_codes = torch.zeros((1, 16, 12), dtype=torch.int32)
    torch.onnx.export(
        decoder,
        dummy_codes,
        decoder_path,
        input_names=["audio_codes"],
        output_names=["waveform"],
        dynamic_axes={
            "audio_codes": {0: "batch", 2: "frames"},
            "waveform": {0: "batch", 1: "samples"},
        },
        opset_version=opset_version,
    )

    print(f"Exported dummy models to: {output_dir}")
    return talker_path, decoder_path


def export_simple_talker(
    core_model,
    tokenizer,
    output_dir: Path,
    opset_version: int = 17,
):
    masking_utils._is_torch_greater_or_equal_than_2_5 = True
    class SimpleTalkerWrapper(torch.nn.Module):
        def __init__(self, talker, num_code_groups: int):
            super().__init__()
            self.talker = talker
            self.num_code_groups = num_code_groups

        def forward(self, input_ids):
            input_ids = input_ids.to(torch.long)

            text_embeds = self.talker.text_projection(
                self.talker.get_text_embeddings()(input_ids)
            )
            outputs = self.talker.model(
                input_ids=None,
                attention_mask=None,
                inputs_embeds=text_embeds,
                use_cache=False,
            )
            logits = self.talker.codec_head(outputs.last_hidden_state)
            codes = torch.argmax(logits, dim=-1).to(torch.int32)
            audio_codes = codes.unsqueeze(1).repeat(1, self.num_code_groups, 1)
            return audio_codes

    talker = resolve_transformer(core_model)
    num_code_groups = getattr(talker.config, "num_code_groups", 16)
    text_vocab_size = getattr(talker.config, "text_vocab_size", tokenizer.vocab_size)

    wrapper = SimpleTalkerWrapper(talker, num_code_groups)
    wrapper.eval()

    batch_size = 1
    seq_len = 64
    dummy_input_ids = torch.randint(0, text_vocab_size, (batch_size, seq_len), dtype=torch.int32)

    name_hint = getattr(core_model.config, "name_or_path", None) if hasattr(core_model, "config") else None
    if not name_hint:
        name_hint = "Qwen3TTS"
    output_path = output_dir / f"{name_hint.split('/')[-1]}_simple.onnx"

    torch.onnx.export(
        wrapper,
        dummy_input_ids,
        output_path,
        input_names=["input_ids"],
        output_names=["audio_codes"],
        dynamic_axes={
            "input_ids": {0: "batch", 1: "sequence"},
            "audio_codes": {0: "batch", 2: "frames"}
        },
        opset_version=opset_version,
        do_constant_folding=True
    )

    print(f"Exported simplified talker to: {output_path}")

    decoder_path = output_dir / "speech_decoder.onnx"
    speech_decoder = resolve_speech_decoder(core_model)
    export_speech_decoder(speech_decoder, decoder_path)

    return output_path, decoder_path


def resolve_core_model(wrapper):
    candidates = [
        wrapper,
        getattr(wrapper, "model", None),
        getattr(wrapper, "tts_model", None),
        getattr(wrapper, "core_model", None),
    ]

    for candidate in candidates:
        if candidate is None:
            continue
        if hasattr(candidate, "transformer") and hasattr(candidate, "speech_decoder"):
            return candidate
        if hasattr(candidate, "talker") and hasattr(candidate, "speech_tokenizer"):
            return candidate

    attrs = sorted({attr for candidate in candidates if candidate is not None for attr in dir(candidate)})
    raise AttributeError(
        "Could not locate core model with transformer/speech_decoder. "
        f"Available attributes: {attrs}"
    )


def resolve_transformer(core_model):
    if hasattr(core_model, "transformer"):
        return core_model.transformer
    if hasattr(core_model, "talker"):
        return core_model.talker
    raise AttributeError("Core model has no transformer/talker module.")


def resolve_speech_decoder(core_model):
    if hasattr(core_model, "speech_decoder"):
        return core_model.speech_decoder
    if hasattr(core_model, "speech_tokenizer"):
        speech_tokenizer = core_model.speech_tokenizer
        if hasattr(speech_tokenizer, "model") and hasattr(speech_tokenizer.model, "decoder"):
            return speech_tokenizer.model.decoder
        if hasattr(speech_tokenizer, "model"):
            return speech_tokenizer.model
        return speech_tokenizer
    raise AttributeError("Core model has no speech_decoder/speech_tokenizer module.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--output", type=Path, default=Path("./onnx_models"))
    parser.add_argument("--dummy", action="store_true")
    parser.add_argument("--simple", action="store_true", help="Export a simplified talker that outputs audio_codes directly.")
    args = parser.parse_args()

    args.output.mkdir(exist_ok=True)
    if args.dummy:
        export_dummy(args.output)
    else:
        export_model(args.model, args.output, simple=args.simple)
