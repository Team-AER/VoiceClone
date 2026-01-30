"""Test CoreML model outputs."""
import coremltools as ct
import numpy as np
import sys
from pathlib import Path


def test_talker_model(model_path):
    """Test that the talker model generates independent codebooks."""
    print(f"\nTesting talker model: {model_path}")
    print("=" * 60)

    try:
        model = ct.models.MLModel(str(model_path))
        print("✓ Model loaded successfully")
    except Exception as e:
        print(f"✗ Failed to load model: {e}")
        return False

    # Test inference
    test_input = {"input_ids": np.array([[1, 2, 3, 4, 5]], dtype=np.int32)}

    # Check if model requires attention_mask
    spec = model.get_spec()
    input_names = [inp.name for inp in spec.description.input]
    if "attention_mask" in input_names:
        test_input["attention_mask"] = np.ones((1, 5), dtype=np.int32)

    try:
        result = model.predict(test_input)
        print("✓ Inference completed")
    except Exception as e:
        print(f"✗ Inference failed: {e}")
        return False

    codes = result["audio_codes"]

    print(f"  Output shape: {codes.shape}")

    # Validate shape
    if len(codes.shape) != 3:
        print(f"✗ Expected 3D output, got {len(codes.shape)}D")
        return False

    if codes.shape[1] != 16:
        print(f"✗ Expected 16 codebooks, got {codes.shape[1]}")
        return False

    print(f"✓ Shape is correct: [batch={codes.shape[0]}, codebooks={codes.shape[1]}, frames={codes.shape[2]}]")

    # Verify codebooks are DIFFERENT (not repeated)
    codebook_0 = codes[0, 0, :]
    codebook_1 = codes[0, 1, :]

    if np.array_equal(codebook_0, codebook_1):
        print("✗ ERROR: Codebooks 0 and 1 are IDENTICAL")
        print(f"  Codebook 0: {codebook_0[:10]}...")
        print(f"  Codebook 1: {codebook_1[:10]}...")
        print("  This means the multi-codebook bug is NOT fixed!")
        return False
    else:
        print("✓ Codebooks 0 and 1 are different (correct)")
        print(f"  Codebook 0: {codebook_0[:10]}...")
        print(f"  Codebook 1: {codebook_1[:10]}...")

    # Check value ranges
    min_val = codes.min()
    max_val = codes.max()
    print(f"  Code value range: [{min_val}, {max_val}]")

    if min_val < 0 or max_val > 2047:
        print(f"⚠ Warning: Codes outside expected range [0, 2047]")

    # Check for diversity across all codebooks
    unique_patterns = set()
    for i in range(min(16, codes.shape[1])):
        pattern = tuple(codes[0, i, :].tolist())
        unique_patterns.add(pattern)

    print(f"  Found {len(unique_patterns)} unique codebook patterns out of {codes.shape[1]} codebooks")

    if len(unique_patterns) == 1:
        print("✗ ERROR: All codebooks have the same pattern!")
        return False
    elif len(unique_patterns) < codes.shape[1] // 2:
        print(f"⚠ Warning: Low diversity - only {len(unique_patterns)}/{codes.shape[1]} unique patterns")
    else:
        print(f"✓ Good diversity - {len(unique_patterns)}/{codes.shape[1]} unique patterns")

    print("\n" + "=" * 60)
    print("✓ Talker model PASSED all tests")
    return True


def test_decoder_model(model_path):
    """Test that the decoder model works correctly."""
    print(f"\nTesting decoder model: {model_path}")
    print("=" * 60)

    try:
        model = ct.models.MLModel(str(model_path))
        print("✓ Model loaded successfully")
    except Exception as e:
        print(f"✗ Failed to load model: {e}")
        return False

    # Test with dummy codes
    test_codes = np.random.randint(0, 2048, size=(1, 16, 12), dtype=np.int32)
    test_input = {"audio_codes": test_codes}

    try:
        result = model.predict(test_input)
        print("✓ Inference completed")
    except Exception as e:
        print(f"✗ Inference failed: {e}")
        return False

    waveform = result["waveform"]
    print(f"  Output shape: {waveform.shape}")

    if len(waveform.shape) < 1:
        print("✗ Invalid waveform shape")
        return False

    print(f"✓ Waveform generated with {waveform.shape[-1]} samples")

    print("\n" + "=" * 60)
    print("✓ Decoder model PASSED")
    return True


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Test CoreML model outputs")
    parser.add_argument("--talker", type=Path, help="Path to talker .mlpackage")
    parser.add_argument("--decoder", type=Path, help="Path to decoder .mlpackage")
    args = parser.parse_args()

    passed = True

    if args.talker:
        if not test_talker_model(args.talker):
            passed = False
    else:
        print("⚠ No talker model specified, skipping talker test")

    if args.decoder:
        if not test_decoder_model(args.decoder):
            passed = False
    else:
        print("⚠ No decoder model specified, skipping decoder test")

    if not args.talker and not args.decoder:
        print("\nUsage:")
        print("  python test_model_outputs.py --talker path/to/talker.mlpackage")
        print("  python test_model_outputs.py --decoder path/to/decoder.mlpackage")
        print("  python test_model_outputs.py --talker path/to/talker.mlpackage --decoder path/to/decoder.mlpackage")
        sys.exit(1)

    if passed:
        print("\n" + "=" * 60)
        print("✓ ALL TESTS PASSED")
        print("=" * 60)
        sys.exit(0)
    else:
        print("\n" + "=" * 60)
        print("✗ SOME TESTS FAILED")
        print("=" * 60)
        sys.exit(1)
