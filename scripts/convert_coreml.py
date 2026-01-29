"""Convert ONNX models to CoreML format with robust error handling."""

import argparse
from pathlib import Path
import coremltools as ct
import numpy as np
import torch
import warnings
import sys

# Try to import qwen_tts, fall back to transformers if unavailable
try:
    from qwen_tts import Qwen3TTSModel
    HAS_QWEN_TTS = True
except ImportError:
    from transformers import AutoModel
    HAS_QWEN_TTS = False
    print("Warning: qwen_tts package not found, using transformers")

try:
    from transformers import masking_utils
    HAS_MASKING_UTILS = True
except ImportError:
    HAS_MASKING_UTILS = False
    print("Warning: masking_utils not found")

# Suppress CoreML warnings for cleaner output
warnings.filterwarnings("ignore", category=DeprecationWarning)


def convert_to_coreml(
    onnx_path: Path | None,
    output_path: Path,
    compute_units: str = "ALL",
    dummy_kind: str | None = None,
    model_name: str | None = None,
    simple: bool = False,
    decoder: bool = False,
    attn_impl: str | None = None,
    validate: bool = True,
):
    """Convert models to CoreML with error handling and validation."""
    print(f"CoreML Tools version: {ct.__version__}")

    try:
        if simple or decoder:
            if model_name is None:
                raise ValueError("--model is required when using --simple or --decoder.")
            if simple:
                print(f"Converting simplified talker from: {model_name}")
                model = convert_simple_talker(model_name, compute_units, attn_impl)
            else:
                print(f"Converting speech decoder from: {model_name}")
                model = convert_speech_decoder(model_name, compute_units)
            resolved_output = output_path
        elif dummy_kind:
            print(f"Converting dummy {dummy_kind} to CoreML")
            model = convert_dummy(dummy_kind, compute_units)
            resolved_output = output_path
        else:
            if onnx_path is None:
                raise ValueError("--onnx is required unless using --simple, --decoder, or --dummy.")
            print(f"Converting: {onnx_path}")
            model, resolved_output = convert_with_coremltools(onnx_path, output_path, compute_units)

        # Set metadata
        model.author = "VoiceClone"
        model.license = "Apache 2.0"
        model.short_description = "Qwen3-TTS model for on-device speech synthesis"

        # Ensure output directory exists
        resolved_output.parent.mkdir(parents=True, exist_ok=True)

        # Save model
        print(f"Saving model to: {resolved_output}")
        model.save(str(resolved_output))
        print(f"✓ Saved successfully")

        # Validate if requested
        if validate:
            print("Validating converted model...")
            if validate_model(resolved_output, model):
                print("✓ Model validation passed")
            else:
                print("⚠ Model validation had warnings")

        return model

    except Exception as e:
        print(f"✗ Conversion failed: {e}")
        print(f"  Error type: {type(e).__name__}")
        if "CoreML" in str(e) or "error -5" in str(e).lower():
            print("  This appears to be a CoreML execution plan error.")
            print("  Try using --dummy instead to generate a test model.")
        raise


def validate_model(model_path: Path, model: ct.models.MLModel) -> bool:
    """Validate that the converted CoreML model can be loaded and executed."""
    try:
        print(f"  Loading model from {model_path}...")
        # Try to load the saved model
        loaded_model = ct.models.MLModel(str(model_path))

        print(f"  Model spec: {loaded_model.get_spec().description.input}")

        # Try to create a prediction (with dummy inputs)
        if hasattr(loaded_model, "_spec"):
            spec = loaded_model._spec
            if hasattr(spec, "description"):
                inputs = spec.description.input
                if inputs:
                    print(f"  Model has {len(inputs)} input(s)")
                    # Create dummy inputs based on spec
                    dummy_input = {}
                    for input_desc in inputs:
                        name = input_desc.name
                        if hasattr(input_desc.type, "multiArrayType"):
                            shape = input_desc.type.multiArrayType.shape
                            dummy_input[name] = np.zeros([int(d) if d > 0 else 1 for d in shape], dtype=np.int32)

                    if dummy_input:
                        print(f"  Testing prediction with dummy inputs...")
                        try:
                            output = loaded_model.predict(dummy_input)
                            print(f"  ✓ Prediction successful, outputs: {list(output.keys())}")
                        except Exception as e:
                            print(f"  ⚠ Prediction failed (this may be expected): {e}")
                            return False

        return True

    except Exception as e:
        print(f"  ✗ Validation failed: {e}")
        return False


def convert_with_coremltools(
    onnx_path: Path,
    output_path: Path,
    compute_units: str
) -> tuple[ct.models.MLModel, Path]:
    """Convert ONNX model to CoreML with error handling."""
    if not hasattr(ct.converters, "onnx"):
        raise RuntimeError("ONNX conversion is not available in this coremltools build. Use --dummy.")

    try:
        print("  Using coremltools ONNX converter...")
        model = ct.converters.onnx.convert(
            str(onnx_path),
            minimum_deployment_target=ct.target.iOS17,
            compute_units=getattr(ct.ComputeUnit, compute_units),
            convert_to="mlprogram",
        )
        print("  ✓ ONNX conversion successful")
        return model, output_path

    except Exception as e:
        print(f"  ✗ ONNX conversion failed: {e}")
        raise


def convert_dummy(kind: str, compute_units: str) -> ct.models.MLModel:
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

    if kind == "talker":
        model = DummyTalker()
        inputs = [
            ct.TensorType(name="input_ids", shape=(1, ct.RangeDim(1, 128)), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, ct.RangeDim(1, 128)), dtype=np.int32),
        ]
        outputs = [
            ct.TensorType(name="logits"),
            ct.TensorType(name="audio_codes"),
        ]
        example_inputs = (
            torch.randint(0, 256, (1, 8), dtype=torch.int32),
            torch.ones(1, 8, dtype=torch.int32),
        )
    elif kind == "decoder":
        model = DummyDecoder()
        inputs = [
            ct.TensorType(name="audio_codes", shape=(1, 16, ct.RangeDim(1, 24)), dtype=np.int32),
        ]
        outputs = [
            ct.TensorType(name="waveform"),
        ]
        example_inputs = (
            torch.zeros((1, 16, 12), dtype=torch.int32),
        )
    else:
        raise ValueError("dummy kind must be 'talker' or 'decoder'")

    scripted = torch.jit.trace(model, example_inputs)

    mlmodel = ct.convert(
        scripted,
        inputs=inputs,
        outputs=outputs,
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram",
        source="pytorch",
        compute_units=getattr(ct.ComputeUnit, compute_units),
    )
    mlmodel.short_description = "VoiceClone dummy model"
    mlmodel.user_defined_metadata["voiceclone_dummy"] = "true"
    return mlmodel


def convert_simple_talker(model_name: str, compute_units: str, attn_impl: str | None) -> ct.models.MLModel:
    """Convert simplified talker model with error handling."""
    try:
        # Apply masking workaround
        if HAS_MASKING_UTILS:
            masking_utils._is_torch_greater_or_equal_than_2_5 = True

        print(f"  Loading model: {model_name}")
        if HAS_QWEN_TTS:
            model = Qwen3TTSModel.from_pretrained(
                model_name,
                torch_dtype=torch.float32,
                device_map="cpu"
            )
        else:
            model = AutoModel.from_pretrained(
                model_name,
                torch_dtype=torch.float32,
                device_map="cpu",
                trust_remote_code=True
            )
        print("  ✓ Model loaded")
    except Exception as e:
        print(f"  ✗ Failed to load model: {e}")
        raise
    core_model = resolve_core_model(model)
    talker = resolve_transformer(core_model)
    if attn_impl:
        if hasattr(talker, "config"):
            talker.config._attn_implementation = attn_impl
        if hasattr(talker, "model") and hasattr(talker.model, "config"):
            talker.model.config._attn_implementation = attn_impl
    num_code_groups = getattr(talker.config, "num_code_groups", 16)
    text_vocab_size = getattr(talker.config, "text_vocab_size", 151936)

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

    wrapper = SimpleTalkerWrapper(talker, num_code_groups)
    wrapper.eval()

    example_input_ids = torch.randint(0, text_vocab_size, (1, 64), dtype=torch.int32)

    try:
        print("  Tracing model with torch.jit...")
        traced = torch.jit.trace(wrapper, example_input_ids)
        print("  ✓ Tracing successful")
    except Exception as e:
        print(f"  ✗ Tracing failed: {e}")
        raise

    try:
        print("  Converting to CoreML...")
        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(name="input_ids", shape=(1, ct.RangeDim(1, 256)), dtype=np.int32),
            ],
            outputs=[ct.TensorType(name="audio_codes")],
            minimum_deployment_target=ct.target.iOS17,
            convert_to="mlprogram",
            source="pytorch",
            compute_precision=ct.precision.FLOAT16,
            compute_units=getattr(ct.ComputeUnit, compute_units),
        )
        print("  ✓ CoreML conversion successful")
    except Exception as e:
        print(f"  ✗ CoreML conversion failed: {e}")
        print("  Try using --attn-impl eager to force eager attention")
        raise

    mlmodel.short_description = "VoiceClone simplified talker (text -> audio codes)"
    mlmodel.user_defined_metadata["voiceclone_simple"] = "true"
    return mlmodel


def convert_speech_decoder(model_name: str, compute_units: str) -> ct.models.MLModel:
    """Convert speech decoder model with error handling."""
    try:
        print(f"  Loading model: {model_name}")
        if HAS_QWEN_TTS:
            model = Qwen3TTSModel.from_pretrained(
                model_name,
                torch_dtype=torch.float16,
                device_map="cpu"
            )
        else:
            model = AutoModel.from_pretrained(
                model_name,
                torch_dtype=torch.float16,
                device_map="cpu",
                trust_remote_code=True
            )
        print("  ✓ Model loaded")

        core_model = resolve_core_model(model)
        decoder = resolve_speech_decoder(core_model)
    except Exception as e:
        print(f"  ✗ Failed to load model or decoder: {e}")
        raise

    num_quantizers = 16
    if hasattr(decoder, "config") and hasattr(decoder.config, "num_quantizers"):
        num_quantizers = decoder.config.num_quantizers

    class DecoderWrapper(torch.nn.Module):
        def __init__(self, decoder):
            super().__init__()
            self.decoder = decoder

        def forward(self, audio_codes):
            return self.decoder(audio_codes.to(torch.long))

    wrapper = DecoderWrapper(decoder)
    wrapper.eval()

    example_codes = torch.zeros((1, num_quantizers, 12), dtype=torch.int32)

    try:
        print("  Tracing decoder with torch.jit...")
        traced = torch.jit.trace(wrapper, example_codes)
        print("  ✓ Tracing successful")
    except Exception as e:
        print(f"  ✗ Tracing failed: {e}")
        raise

    try:
        print("  Converting to CoreML...")
        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(name="audio_codes", shape=(1, num_quantizers, ct.RangeDim(1, 256)), dtype=np.int32),
            ],
            outputs=[ct.TensorType(name="waveform")],
            minimum_deployment_target=ct.target.iOS17,
            convert_to="mlprogram",
            source="pytorch",
            compute_precision=ct.precision.FLOAT16,
            compute_units=getattr(ct.ComputeUnit, compute_units),
        )
        print("  ✓ CoreML conversion successful")
    except Exception as e:
        print(f"  ✗ CoreML conversion failed: {e}")
        raise

    mlmodel.short_description = "VoiceClone speech decoder"
    return mlmodel


def optimize_for_ane(model_path: Path, output_path: Path):
    """Apply ANE-specific optimizations."""

    model = ct.models.MLModel(str(model_path))

    from coremltools.optimize.coreml import (
        OpThresholdPrunerConfig,
        OptimizationConfig,
        prune_weights
    )

    config = OptimizationConfig(
        global_config=OpThresholdPrunerConfig(
            threshold=1e-7,
            minimum_sparsity_percentile=0.0
        )
    )

    optimized = prune_weights(model, config)
    optimized.save(str(output_path))

    return optimized


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
    parser = argparse.ArgumentParser(
        description="Convert models to CoreML format with error handling and validation"
    )
    parser.add_argument("--onnx", type=Path, help="Path to ONNX model file")
    parser.add_argument("--output", type=Path, required=True, help="Output path for .mlpackage")
    parser.add_argument("--compute-units", default="ALL", choices=["ALL", "CPU_AND_NE", "CPU_ONLY"],
                        help="CoreML compute units to use")
    parser.add_argument("--dummy", choices=["talker", "decoder"],
                        help="Generate dummy model instead of converting")
    parser.add_argument("--model", help="HuggingFace model id for --simple/--decoder")
    parser.add_argument("--simple", action="store_true",
                        help="Convert simplified talker directly from PyTorch")
    parser.add_argument("--decoder", action="store_true",
                        help="Convert speech decoder directly from PyTorch")
    parser.add_argument("--attn-impl", help="Override attention implementation (e.g. eager)")
    parser.add_argument("--no-validate", action="store_true",
                        help="Skip model validation after conversion")
    args = parser.parse_args()

    try:
        convert_to_coreml(
            args.onnx,
            args.output,
            args.compute_units,
            args.dummy,
            model_name=args.model,
            simple=args.simple,
            decoder=args.decoder,
            attn_impl=args.attn_impl,
            validate=not args.no_validate,
        )
        print("\n✓ Conversion completed successfully!")
        sys.exit(0)
    except Exception as e:
        print(f"\n✗ Conversion failed: {e}")
        sys.exit(1)
