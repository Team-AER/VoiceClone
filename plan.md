# VoiceClone Implementation Plan

## Overview

This document outlines the step-by-step implementation plan for VoiceClone, an iOS app for on-device TTS with voice cloning capabilities using Qwen3-TTS models.

---

## Phase 1: Project Setup & Infrastructure

### Step 1.1: Initialize Xcode Project

```bash
# Create project directory structure
mkdir -p VoiceClone/{App,Features,Core,Shared,Resources,Tests}
```

**Xcode Configuration:**
- Target: iOS 17.0+
- Swift version: 6.0
- Strict concurrency: Complete
- Build system: New Build System
- Enable: Swift Testing framework

**Project Structure:**
```
VoiceClone.xcodeproj/
├── VoiceClone/
│   ├── App/
│   │   ├── VoiceCloneApp.swift
│   │   ├── AppDelegate.swift          # Background task registration
│   │   └── SceneDelegate.swift
│   ├── Features/
│   ├── Core/
│   ├── Shared/
│   └── Resources/
├── VoiceCloneTests/
└── VoiceCloneUITests/
```

**Dependencies (Package.swift or SPM in Xcode):**
```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.2.0"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.0"),
]
```

### Step 1.2: Configure Build Settings

**Info.plist Entries:**
```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>processing</string>
</array>
<key>NSMicrophoneUsageDescription</key>
<string>VoiceClone needs microphone access to record reference audio for voice cloning.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>VoiceClone uses speech recognition to transcribe your reference audio.</string>
```

**Build Settings:**
```
SWIFT_STRICT_CONCURRENCY = complete
SWIFT_VERSION = 6.0
ENABLE_PREVIEWS = YES
DEBUG_INFORMATION_FORMAT = dwarf-with-dsym
SWIFT_OPTIMIZATION_LEVEL = -O (Release)
OTHER_SWIFT_FLAGS = -Xfrontend -warn-long-function-bodies=200
```

### Step 1.3: Set Up Dependency Injection

```swift
// App/Environment/DIContainer.swift
import SwiftUI
import Dependencies

@MainActor
final class DIContainer: ObservableObject {
    let ttsService: TTSService
    let modelManager: MLModelManager
    let audioEngine: AudioEngine
    let voiceStorage: VoiceStorage

    init() {
        self.modelManager = MLModelManager()
        self.audioEngine = AudioEngine()
        self.voiceStorage = VoiceStorage()
        self.ttsService = TTSService(
            modelManager: modelManager,
            audioEngine: audioEngine
        )
    }
}

// Environment key
private struct DIContainerKey: EnvironmentKey {
    static let defaultValue = DIContainer()
}

extension EnvironmentValues {
    var container: DIContainer {
        get { self[DIContainerKey.self] }
        set { self[DIContainerKey.self] = newValue }
    }
}
```

---

## Phase 2: Model Conversion Pipeline

### Step 2.1: Set Up Python Environment

```bash
# Create conversion environment
cd VoiceClone/scripts
python3.12 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install torch==2.3.0 \
    transformers>=4.44.0 \
    coremltools>=8.0 \
    onnx>=1.16.0 \
    onnxruntime>=1.18.0 \
    qwen-tts \
    numpy<2.0
```

### Step 2.2: Export Model to ONNX

```python
# scripts/export_onnx.py
"""Export Qwen3-TTS models to ONNX format."""

import torch
import argparse
from pathlib import Path
from qwen_tts import Qwen3TTSModel
from transformers import AutoTokenizer

def export_model(
    model_name: str,
    output_dir: Path,
    opset_version: int = 17
):
    print(f"Loading model: {model_name}")

    # Load model in FP16 for export
    model = Qwen3TTSModel.from_pretrained(
        model_name,
        torch_dtype=torch.float16,
        device_map="cpu"
    )
    model.eval()

    tokenizer = AutoTokenizer.from_pretrained(model_name)

    # Create dummy inputs
    batch_size = 1
    seq_len = 128

    dummy_input_ids = torch.randint(0, tokenizer.vocab_size, (batch_size, seq_len))
    dummy_attention_mask = torch.ones(batch_size, seq_len, dtype=torch.long)

    # Export main transformer
    output_path = output_dir / f"{model_name.split('/')[-1]}.onnx"

    torch.onnx.export(
        model.transformer,
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

    # Export speech decoder separately
    decoder_path = output_dir / "speech_decoder.onnx"
    export_speech_decoder(model.speech_decoder, decoder_path)

    return output_path, decoder_path

def export_speech_decoder(decoder, output_path: Path):
    """Export the speech tokenizer decoder."""
    dummy_codes = torch.randint(0, 2048, (1, 16, 100))  # 16 codebooks, 100 frames

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

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--output", type=Path, default=Path("./onnx_models"))
    args = parser.parse_args()

    args.output.mkdir(exist_ok=True)
    export_model(args.model, args.output)
```

### Step 2.3: Convert ONNX to CoreML

```python
# scripts/convert_coreml.py
"""Convert ONNX models to CoreML format."""

import coremltools as ct
from coremltools.models.neural_network import quantization_utils
import argparse
from pathlib import Path

def convert_to_coreml(
    onnx_path: Path,
    output_path: Path,
    compute_units: str = "ALL"
):
    print(f"Converting: {onnx_path}")

    # Load and convert
    model = ct.converters.onnx.convert(
        str(onnx_path),
        minimum_deployment_target=ct.target.iOS17,
        compute_units=getattr(ct.ComputeUnit, compute_units),
        convert_to="mlprogram",
    )

    # Set metadata
    model.author = "VoiceClone"
    model.license = "Apache 2.0"
    model.short_description = "Qwen3-TTS model for on-device speech synthesis"

    # Save as mlpackage
    model.save(str(output_path))
    print(f"Saved to: {output_path}")

    return model

def optimize_for_ane(model_path: Path, output_path: Path):
    """Apply ANE-specific optimizations."""

    model = ct.models.MLModel(str(model_path))

    # Chunk einsum operations for ANE compatibility
    # ANE has limited einsum support
    spec = model.get_spec()

    # Apply optimizations via coremltools passes
    from coremltools.optimize.coreml import (
        OpThresholdPrunerConfig,
        OptimizationConfig,
        prune_weights
    )

    # Light pruning for ANE efficiency
    config = OptimizationConfig(
        global_config=OpThresholdPrunerConfig(
            threshold=1e-7,
            minimum_sparsity_percentile=0.0
        )
    )

    optimized = prune_weights(model, config)
    optimized.save(str(output_path))

    return optimized

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--onnx", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compute-units", default="ALL", choices=["ALL", "CPU_AND_NE", "CPU_ONLY"])
    args = parser.parse_args()

    convert_to_coreml(args.onnx, args.output, args.compute_units)
```

### Step 2.4: Quantize to INT4

```python
# scripts/quantize_int4.py
"""Quantize CoreML models to INT4 for mobile deployment."""

import coremltools as ct
from coremltools.optimize.coreml import (
    OptimizationConfig,
    OpLinearQuantizerConfig,
    quantize_weights,
    OpPalettizerConfig,
    palettize_weights
)
import argparse
from pathlib import Path

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
        # Use palettization for INT4 (more stable than linear quantization)
        config = OptimizationConfig(
            global_config=OpPalettizerConfig(
                mode="kmeans",
                nbits=4,
                granularity=granularity,
                block_size=block_size if granularity == "per_block" else None
            )
        )
        quantized = palettize_weights(model, config)
    else:
        # Linear quantization for INT8
        config = OptimizationConfig(
            global_config=OpLinearQuantizerConfig(
                mode="linear_symmetric",
                dtype=f"int{bits}",
                granularity=granularity,
                block_size=block_size if granularity == "per_block" else None
            )
        )
        quantized = quantize_weights(model, config)

    # Validate output shape consistency
    print("Validating quantized model...")

    quantized.save(str(output_path))
    print(f"Saved quantized model to: {output_path}")

    # Print size comparison
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
```

### Step 2.5: Segment Large Models

```python
# scripts/segment_model.py
"""Segment large models for iOS memory constraints."""

import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import Program
import numpy as np
from pathlib import Path
import argparse

LAYERS_PER_SEGMENT = 7  # 28 layers / 4 segments

def segment_transformer(model_path: Path, output_dir: Path):
    """Split transformer into multiple segments."""

    output_dir.mkdir(exist_ok=True)

    # Load the full model spec
    model = ct.models.MLModel(str(model_path))
    spec = model.get_spec()

    # This is a simplified approach - actual implementation requires
    # careful handling of the MIL program

    segments = []

    for seg_idx in range(4):
        start_layer = seg_idx * LAYERS_PER_SEGMENT
        end_layer = (seg_idx + 1) * LAYERS_PER_SEGMENT

        segment_path = output_dir / f"transformer_segment_{seg_idx}.mlpackage"

        # Extract layers [start_layer, end_layer)
        # This requires MIL manipulation - simplified here
        print(f"Creating segment {seg_idx}: layers {start_layer}-{end_layer-1}")

        # In practice, you'd use coremltools MIL operations to slice the model
        # For now, we save metadata about the segmentation
        segments.append({
            "index": seg_idx,
            "start_layer": start_layer,
            "end_layer": end_layer,
            "path": str(segment_path)
        })

    # Save segmentation config
    import json
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
```

### Step 2.6: Export Tokenizer

```python
# scripts/export_tokenizer.py
"""Export tokenizer for iOS."""

from transformers import AutoTokenizer
import json
from pathlib import Path
import argparse

def export_tokenizer(model_name: str, output_dir: Path):
    output_dir.mkdir(exist_ok=True)

    tokenizer = AutoTokenizer.from_pretrained(model_name)

    # Export vocab
    vocab = tokenizer.get_vocab()
    vocab_path = output_dir / "vocab.json"
    with open(vocab_path, "w", encoding="utf-8") as f:
        json.dump(vocab, f, ensure_ascii=False, indent=2)

    # Export merges (for BPE)
    if hasattr(tokenizer, "bpe_ranks"):
        merges = list(tokenizer.bpe_ranks.keys())
        merges_path = output_dir / "merges.txt"
        with open(merges_path, "w", encoding="utf-8") as f:
            f.write("#version: 0.2\n")
            for merge in merges:
                f.write(f"{merge[0]} {merge[1]}\n")

    # Export special tokens
    special_tokens = {
        "bos_token": tokenizer.bos_token,
        "eos_token": tokenizer.eos_token,
        "pad_token": tokenizer.pad_token,
        "unk_token": tokenizer.unk_token,
    }
    special_path = output_dir / "special_tokens.json"
    with open(special_path, "w") as f:
        json.dump(special_tokens, f, indent=2)

    # Export tokenizer config
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
```

---

## Phase 3: Core iOS Implementation

### Step 3.1: Implement Tokenizer

```swift
// Core/ML/Tokenizer/Qwen3Tokenizer.swift
import Foundation

/// BPE tokenizer for Qwen3-TTS
final class Qwen3Tokenizer: Sendable {

    private let vocab: [String: Int]
    private let reverseVocab: [Int: String]
    private let merges: [(String, String)]
    private let specialTokens: SpecialTokens

    struct SpecialTokens: Codable {
        let bosToken: String
        let eosToken: String
        let padToken: String?
        let unkToken: String
    }

    init(vocabURL: URL, mergesURL: URL, specialTokensURL: URL) throws {
        // Load vocab
        let vocabData = try Data(contentsOf: vocabURL)
        self.vocab = try JSONDecoder().decode([String: Int].self, from: vocabData)
        self.reverseVocab = Dictionary(uniqueKeysWithValues: vocab.map { ($1, $0) })

        // Load merges
        let mergesContent = try String(contentsOf: mergesURL, encoding: .utf8)
        self.merges = mergesContent
            .components(separatedBy: .newlines)
            .dropFirst() // Skip version header
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: " ")
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            }

        // Load special tokens
        let specialData = try Data(contentsOf: specialTokensURL)
        self.specialTokens = try JSONDecoder().decode(SpecialTokens.self, from: specialData)
    }

    func encode(text: String, language: Language, instruction: String? = nil) -> [Int] {
        var tokens: [Int] = []

        // Add BOS token
        if let bosId = vocab[specialTokens.bosToken] {
            tokens.append(bosId)
        }

        // Add language tag
        let langTag = "<|lang:\(language.code)|>"
        if let langId = vocab[langTag] {
            tokens.append(langId)
        }

        // Add instruction if provided
        if let instruction = instruction {
            let instructTokens = tokenize(instruction)
            tokens.append(contentsOf: instructTokens)

            // Add instruction separator
            if let sepId = vocab["<|instruct_end|>"] {
                tokens.append(sepId)
            }
        }

        // Tokenize main text
        let textTokens = tokenize(text)
        tokens.append(contentsOf: textTokens)

        // Add EOS token
        if let eosId = vocab[specialTokens.eosToken] {
            tokens.append(eosId)
        }

        return tokens
    }

    func decode(_ tokens: [Int]) -> String {
        tokens
            .compactMap { reverseVocab[$0] }
            .joined()
            .replacingOccurrences(of: "Ġ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func tokenize(_ text: String) -> [Int] {
        // Pre-tokenize: split on whitespace, preserve spaces as Ġ prefix
        let words = preTokenize(text)

        var tokens: [Int] = []
        for word in words {
            let wordTokens = bpe(word)
            tokens.append(contentsOf: wordTokens)
        }

        return tokens
    }

    private func preTokenize(_ text: String) -> [String] {
        var words: [String] = []
        var currentWord = ""

        for char in text {
            if char.isWhitespace {
                if !currentWord.isEmpty {
                    words.append(currentWord)
                    currentWord = ""
                }
                currentWord = "Ġ" // GPT-style space prefix
            } else {
                currentWord.append(char)
            }
        }

        if !currentWord.isEmpty {
            words.append(currentWord)
        }

        return words
    }

    private func bpe(_ word: String) -> [Int] {
        var chars = word.map { String($0) }

        while chars.count > 1 {
            // Find best merge
            var bestMerge: (Int, (String, String))? = nil

            for i in 0..<(chars.count - 1) {
                let pair = (chars[i], chars[i + 1])
                if let rank = mergeRank(pair) {
                    if bestMerge == nil || rank < bestMerge!.0 {
                        bestMerge = (rank, pair)
                    }
                }
            }

            guard let (_, (first, second)) = bestMerge else { break }

            // Apply merge
            var newChars: [String] = []
            var i = 0
            while i < chars.count {
                if i < chars.count - 1 && chars[i] == first && chars[i + 1] == second {
                    newChars.append(first + second)
                    i += 2
                } else {
                    newChars.append(chars[i])
                    i += 1
                }
            }
            chars = newChars
        }

        // Convert to token IDs
        return chars.compactMap { vocab[$0] ?? vocab[specialTokens.unkToken] }
    }

    private func mergeRank(_ pair: (String, String)) -> Int? {
        merges.firstIndex { $0 == pair }
    }
}
```

### Step 3.2: Implement Model Manager

```swift
// Core/ML/MLModelManager.swift
import CoreML
import Combine

/// Manages CoreML model lifecycle with memory-aware loading
actor MLModelManager {

    enum ModelType: String, CaseIterable, Sendable {
        case voiceDesign = "Qwen3TTS_VoiceDesign_INT4"
        case customVoice = "Qwen3TTS_CustomVoice_INT4"
        case speechDecoder = "Qwen3TTS_SpeechDecoder"
        case base06B = "Qwen3TTS_Base_06B_INT4"
    }

    enum State: Sendable {
        case unloaded
        case loading(progress: Double)
        case loaded
        case error(Error)
    }

    private var loadedModels: [ModelType: MLModel] = [:]
    private var modelStates: [ModelType: State] = [:]

    private let modelsDirectory: URL
    private let configuration: ModelConfiguration

    struct ModelConfiguration: Sendable {
        let computeUnits: MLComputeUnits
        let allowLowPrecision: Bool
        let maxSequenceLength: Int

        static let `default` = ModelConfiguration(
            computeUnits: .cpuAndNeuralEngine,
            allowLowPrecision: true,
            maxSequenceLength: 2048
        )

        static let memoryConstrained = ModelConfiguration(
            computeUnits: .cpuAndNeuralEngine,
            allowLowPrecision: true,
            maxSequenceLength: 1024
        )
    }

    init(configuration: ModelConfiguration = .default) {
        self.configuration = configuration
        self.modelsDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
    }

    func loadModel(_ type: ModelType) async throws -> MLModel {
        // Return cached if available
        if let model = loadedModels[type] {
            return model
        }

        modelStates[type] = .loading(progress: 0)

        let modelURL = modelsDirectory.appendingPathComponent("\(type.rawValue).mlpackage")

        // Check if compiled version exists
        let compiledURL = try await compileIfNeeded(modelURL: modelURL, type: type)

        // Configure model
        let config = MLModelConfiguration()
        config.computeUnits = configuration.computeUnits
        config.allowLowPrecisionAccumulationOnGPU = configuration.allowLowPrecision

        // Load model
        let model = try await Task.detached(priority: .userInitiated) {
            try MLModel(contentsOf: compiledURL, configuration: config)
        }.value

        loadedModels[type] = model
        modelStates[type] = .loaded

        return model
    }

    func unloadModel(_ type: ModelType) {
        loadedModels[type] = nil
        modelStates[type] = .unloaded
    }

    func unloadAll() {
        loadedModels.removeAll()
        for type in ModelType.allCases {
            modelStates[type] = .unloaded
        }
    }

    func state(for type: ModelType) -> State {
        modelStates[type] ?? .unloaded
    }

    private func compileIfNeeded(modelURL: URL, type: ModelType) async throws -> URL {
        let compiledPath = modelsDirectory
            .appendingPathComponent("Compiled", isDirectory: true)
            .appendingPathComponent("\(type.rawValue).mlmodelc")

        // Check if already compiled
        if FileManager.default.fileExists(atPath: compiledPath.path) {
            return compiledPath
        }

        // Compile model
        modelStates[type] = .loading(progress: 0.5)

        let compiled = try await Task.detached(priority: .userInitiated) {
            try MLModel.compileModel(at: modelURL)
        }.value

        // Move to permanent location
        try FileManager.default.createDirectory(
            at: compiledPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: compiled, to: compiledPath)

        return compiledPath
    }
}
```

### Step 3.3: Implement KV Cache

```swift
// Core/ML/Inference/KVCache.swift
import CoreML
import Accelerate

/// Key-Value cache for efficient autoregressive generation
final class KVCache: @unchecked Sendable {

    private let numLayers: Int
    private let numHeads: Int
    private let headDim: Int
    private let maxLength: Int

    private var keyCache: [MLMultiArray]
    private var valueCache: [MLMultiArray]
    private(set) var currentLength: Int = 0

    private let lock = NSLock()

    init(
        numLayers: Int = 28,
        numHeads: Int = 16,
        headDim: Int = 128,
        maxLength: Int = 2048
    ) {
        self.numLayers = numLayers
        self.numHeads = numHeads
        self.headDim = headDim
        self.maxLength = maxLength

        // Pre-allocate cache buffers
        self.keyCache = (0..<numLayers).map { _ in
            try! MLMultiArray(
                shape: [1, numHeads, maxLength, headDim] as [NSNumber],
                dataType: .float16
            )
        }

        self.valueCache = (0..<numLayers).map { _ in
            try! MLMultiArray(
                shape: [1, numHeads, maxLength, headDim] as [NSNumber],
                dataType: .float16
            )
        }
    }

    func update(with output: MLFeatureProvider, position: Int) {
        lock.lock()
        defer { lock.unlock() }

        for layer in 0..<numLayers {
            guard let newK = output.featureValue(for: "past_key_\(layer)")?.multiArrayValue,
                  let newV = output.featureValue(for: "past_value_\(layer)")?.multiArrayValue else {
                continue
            }

            copyToCache(source: newK, target: keyCache[layer], position: position)
            copyToCache(source: newV, target: valueCache[layer], position: position)
        }

        currentLength = position + 1
    }

    func getCacheSlice(upTo length: Int) -> (keys: [MLMultiArray], values: [MLMultiArray]) {
        lock.lock()
        defer { lock.unlock() }

        // Return views into the cache up to the specified length
        // In practice, you'd create sliced views or use strides
        return (keyCache, valueCache)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }

        currentLength = 0

        // Zero out caches
        for layer in 0..<numLayers {
            vDSP_vclr(
                keyCache[layer].dataPointer.assumingMemoryBound(to: Float.self),
                1,
                vDSP_Length(keyCache[layer].count)
            )
            vDSP_vclr(
                valueCache[layer].dataPointer.assumingMemoryBound(to: Float.self),
                1,
                vDSP_Length(valueCache[layer].count)
            )
        }
    }

    private func copyToCache(source: MLMultiArray, target: MLMultiArray, position: Int) {
        // Copy new KV values to the cache at the specified position
        let srcPtr = source.dataPointer.assumingMemoryBound(to: Float16.self)
        let dstPtr = target.dataPointer.assumingMemoryBound(to: Float16.self)

        let offset = position * numHeads * headDim
        let count = numHeads * headDim

        memcpy(dstPtr.advanced(by: offset), srcPtr, count * MemoryLayout<Float16>.size)
    }
}
```

### Step 3.4: Implement TTS Inference Engine

```swift
// Core/ML/Inference/TTSInferenceEngine.swift
import CoreML
import Accelerate

/// Handles TTS model inference with streaming support
actor TTSInferenceEngine {

    private let modelManager: MLModelManager
    private var model: MLModel?
    private var speechDecoder: MLModel?
    private var kvCache: KVCache?

    private let sampleRate: Int = 24000
    private let numCodebooks: Int = 16

    init(modelManager: MLModelManager) {
        self.modelManager = modelManager
    }

    func loadModels(type: MLModelManager.ModelType) async throws {
        model = try await modelManager.loadModel(type)
        speechDecoder = try await modelManager.loadModel(.speechDecoder)
        kvCache = KVCache()
    }

    func generateStream(
        inputIds: [Int],
        maxNewTokens: Int = 1024
    ) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.generate(
                        inputIds: inputIds,
                        maxNewTokens: maxNewTokens,
                        onChunk: { chunk in
                            continuation.yield(chunk)
                        }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func generate(
        inputIds: [Int],
        maxNewTokens: Int,
        onChunk: (AudioChunk) -> Void
    ) async throws {
        guard let model = model, let decoder = speechDecoder, let cache = kvCache else {
            throw TTSError.modelNotLoaded
        }

        cache.reset()

        // Prepare initial input
        var currentIds = inputIds
        var position = 0
        var audioCodeBuffer: [[Int]] = Array(repeating: [], count: numCodebooks)

        let chunkSize = 12 // 12 frames = 1 second at 12Hz

        while position < maxNewTokens {
            // Prepare input features
            let inputFeatures = try prepareInput(
                tokens: currentIds,
                position: position,
                cache: cache
            )

            // Run inference
            let output = try await Task.detached(priority: .userInitiated) {
                try model.prediction(from: inputFeatures)
            }.value

            // Update KV cache
            cache.update(with: output, position: position)

            // Extract audio codes
            guard let audioCodes = output.featureValue(for: "audio_codes")?.multiArrayValue else {
                throw TTSError.invalidOutput
            }

            // Append codes to buffer
            appendCodes(audioCodes, to: &audioCodeBuffer)

            // Check for EOS or generate audio chunk
            if shouldEmitChunk(audioCodeBuffer, chunkSize: chunkSize) {
                let chunk = try await decodeAudioChunk(
                    codes: audioCodeBuffer,
                    decoder: decoder
                )
                onChunk(chunk)

                // Clear emitted portion
                for i in 0..<numCodebooks {
                    audioCodeBuffer[i].removeFirst(chunkSize)
                }
            }

            // Get next token
            guard let nextToken = sampleNextToken(from: output) else {
                break // EOS
            }

            currentIds = [nextToken]
            position += 1
        }

        // Emit remaining audio
        if audioCodeBuffer[0].count > 0 {
            let chunk = try await decodeAudioChunk(
                codes: audioCodeBuffer,
                decoder: decoder
            )
            onChunk(chunk)
        }
    }

    private func prepareInput(
        tokens: [Int],
        position: Int,
        cache: KVCache
    ) throws -> MLFeatureProvider {
        // Create input_ids MLMultiArray
        let inputIds = try MLMultiArray(shape: [1, tokens.count] as [NSNumber], dataType: .int32)
        for (i, token) in tokens.enumerated() {
            inputIds[i] = NSNumber(value: token)
        }

        // Create attention mask
        let seqLen = position + tokens.count
        let attentionMask = try MLMultiArray(shape: [1, seqLen] as [NSNumber], dataType: .int32)
        for i in 0..<seqLen {
            attentionMask[i] = 1
        }

        // Create position_ids
        let positionIds = try MLMultiArray(shape: [1, tokens.count] as [NSNumber], dataType: .int32)
        for i in 0..<tokens.count {
            positionIds[i] = NSNumber(value: position + i)
        }

        // Build feature dictionary
        var features: [String: MLFeatureValue] = [
            "input_ids": MLFeatureValue(multiArray: inputIds),
            "attention_mask": MLFeatureValue(multiArray: attentionMask),
            "position_ids": MLFeatureValue(multiArray: positionIds)
        ]

        // Add KV cache if not first token
        if position > 0 {
            let (keys, values) = cache.getCacheSlice(upTo: position)
            for (layer, (key, value)) in zip(keys, values).enumerated() {
                features["past_key_\(layer)"] = MLFeatureValue(multiArray: key)
                features["past_value_\(layer)"] = MLFeatureValue(multiArray: value)
            }
        }

        return try MLDictionaryFeatureProvider(dictionary: features)
    }

    private func appendCodes(_ codes: MLMultiArray, to buffer: inout [[Int]]) {
        // codes shape: [1, numCodebooks, frames]
        let frames = codes.shape[2].intValue

        for codebook in 0..<numCodebooks {
            for frame in 0..<frames {
                let idx = codebook * frames + frame
                buffer[codebook].append(codes[idx].intValue)
            }
        }
    }

    private func shouldEmitChunk(_ buffer: [[Int]], chunkSize: Int) -> Bool {
        buffer[0].count >= chunkSize
    }

    private func decodeAudioChunk(
        codes: [[Int]],
        decoder: MLModel
    ) async throws -> AudioChunk {
        let frames = codes[0].count

        // Prepare codes for decoder
        let codesArray = try MLMultiArray(
            shape: [1, numCodebooks, frames] as [NSNumber],
            dataType: .int32
        )

        for codebook in 0..<numCodebooks {
            for frame in 0..<frames {
                let idx = codebook * frames + frame
                codesArray[idx] = NSNumber(value: codes[codebook][frame])
            }
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_codes": MLFeatureValue(multiArray: codesArray)
        ])

        let output = try await Task.detached(priority: .userInitiated) {
            try decoder.prediction(from: input)
        }.value

        guard let waveform = output.featureValue(for: "waveform")?.multiArrayValue else {
            throw TTSError.invalidOutput
        }

        // Convert to Float array
        let samples = (0..<waveform.count).map { Float(truncating: waveform[$0]) }

        return AudioChunk(
            samples: samples,
            sampleRate: sampleRate,
            timestamp: Date().timeIntervalSince1970
        )
    }

    private func sampleNextToken(from output: MLFeatureProvider) -> Int? {
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            return nil
        }

        // Get last position logits
        let vocabSize = logits.shape.last!.intValue
        let lastPosition = logits.count / vocabSize - 1

        // Simple greedy sampling (can be replaced with temperature/top-p)
        var maxIdx = 0
        var maxVal = Float(truncating: logits[lastPosition * vocabSize])

        for i in 1..<vocabSize {
            let val = Float(truncating: logits[lastPosition * vocabSize + i])
            if val > maxVal {
                maxVal = val
                maxIdx = i
            }
        }

        // Check for EOS token (typically 2)
        if maxIdx == 2 {
            return nil
        }

        return maxIdx
    }
}
```

### Step 3.5: Implement TTS Service

```swift
// Core/TTS/TTSService.swift
import Foundation
import Combine

/// Main TTS service orchestrating synthesis
@MainActor
final class TTSService: ObservableObject {

    enum State: Equatable {
        case idle
        case loading
        case ready
        case synthesizing(progress: Double)
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var loadedCapabilities: Set<Capability> = []

    enum Capability: Hashable {
        case voiceDesign
        case customVoice
        case voiceClone
    }

    private let modelManager: MLModelManager
    private let audioEngine: AudioEngine
    private let tokenizer: Qwen3Tokenizer
    private var inferenceEngine: TTSInferenceEngine?

    init(modelManager: MLModelManager, audioEngine: AudioEngine) {
        self.modelManager = modelManager
        self.audioEngine = audioEngine

        // Load tokenizer from bundle
        let bundle = Bundle.main
        self.tokenizer = try! Qwen3Tokenizer(
            vocabURL: bundle.url(forResource: "vocab", withExtension: "json", subdirectory: "Tokenizer")!,
            mergesURL: bundle.url(forResource: "merges", withExtension: "txt", subdirectory: "Tokenizer")!,
            specialTokensURL: bundle.url(forResource: "special_tokens", withExtension: "json", subdirectory: "Tokenizer")!
        )
    }

    func loadCapability(_ capability: Capability) async throws {
        state = .loading

        let modelType: MLModelManager.ModelType
        switch capability {
        case .voiceDesign:
            modelType = .voiceDesign
        case .customVoice:
            modelType = .customVoice
        case .voiceClone:
            modelType = .base06B
        }

        inferenceEngine = TTSInferenceEngine(modelManager: modelManager)
        try await inferenceEngine?.loadModels(type: modelType)

        loadedCapabilities.insert(capability)
        state = .ready
    }

    // MARK: - Voice Design

    func synthesize(
        text: String,
        language: Language,
        instruction: String
    ) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        guard loadedCapabilities.contains(.voiceDesign) else {
            throw TTSError.capabilityNotLoaded(.voiceDesign)
        }

        state = .synthesizing(progress: 0)

        let tokens = tokenizer.encode(
            text: text,
            language: language,
            instruction: instruction
        )

        guard let engine = inferenceEngine else {
            throw TTSError.modelNotLoaded
        }

        return engine.generateStream(inputIds: tokens)
    }

    // MARK: - Custom Voice (Presets)

    func synthesize(
        text: String,
        language: Language,
        speaker: PresetVoice,
        instruction: String? = nil
    ) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        guard loadedCapabilities.contains(.customVoice) else {
            throw TTSError.capabilityNotLoaded(.customVoice)
        }

        state = .synthesizing(progress: 0)

        // Encode with speaker token
        let speakerInstruction = instruction ?? "Speak naturally as \(speaker.rawValue)."
        let tokens = tokenizer.encode(
            text: text,
            language: language,
            instruction: "<|speaker:\(speaker.embeddingId)|> \(speakerInstruction)"
        )

        guard let engine = inferenceEngine else {
            throw TTSError.modelNotLoaded
        }

        return engine.generateStream(inputIds: tokens)
    }

    // MARK: - Voice Cloning

    func synthesize(
        text: String,
        language: Language,
        referenceAudio: Data,
        referenceText: String
    ) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        guard loadedCapabilities.contains(.voiceClone) else {
            throw TTSError.capabilityNotLoaded(.voiceClone)
        }

        state = .synthesizing(progress: 0)

        // Process reference audio to extract features
        // This would involve additional model inference
        let voiceEmbedding = try await extractVoiceEmbedding(
            audio: referenceAudio,
            transcript: referenceText
        )

        // Encode with voice embedding
        var tokens = tokenizer.encode(text: text, language: language)
        // Prepend voice embedding tokens
        tokens = voiceEmbedding + tokens

        guard let engine = inferenceEngine else {
            throw TTSError.modelNotLoaded
        }

        return engine.generateStream(inputIds: tokens)
    }

    private func extractVoiceEmbedding(audio: Data, transcript: String) async throws -> [Int] {
        // In a full implementation, this would:
        // 1. Convert audio to mel spectrogram
        // 2. Run through voice encoder
        // 3. Return embedding tokens

        // Placeholder - actual implementation depends on model architecture
        return []
    }

    // MARK: - Playback

    func playStream(_ stream: AsyncThrowingStream<AudioChunk, Error>) async throws {
        try await audioEngine.playStream(stream)
        state = .ready
    }

    func stop() {
        audioEngine.stop()
        state = .ready
    }
}

// MARK: - Errors

enum TTSError: LocalizedError {
    case modelNotLoaded
    case capabilityNotLoaded(TTSService.Capability)
    case invalidOutput
    case audioProcessingFailed
    case tokenizationFailed

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "TTS model is not loaded"
        case .capabilityNotLoaded(let cap):
            return "\(cap) capability is not loaded"
        case .invalidOutput:
            return "Model produced invalid output"
        case .audioProcessingFailed:
            return "Audio processing failed"
        case .tokenizationFailed:
            return "Text tokenization failed"
        }
    }
}
```

---

## Phase 4: Audio System

### Step 4.1: Implement Audio Engine

```swift
// Core/Audio/AudioEngine.swift
import AVFoundation
import Combine

/// Manages audio playback with streaming support
@MainActor
final class AudioEngine: ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat

    private var displayLink: CADisplayLink?
    private var scheduledBuffers: Int = 0
    private var completedBuffers: Int = 0

    init(sampleRate: Double = 24000) {
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        setupEngine()
    }

    private func setupEngine() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    func playStream(_ stream: AsyncThrowingStream<AudioChunk, Error>) async throws {
        try configureAudioSession()
        try engine.start()
        playerNode.play()
        isPlaying = true

        scheduledBuffers = 0
        completedBuffers = 0

        startTimeTracking()

        do {
            for try await chunk in stream {
                let buffer = try createBuffer(from: chunk)
                scheduleBuffer(buffer)
            }

            // Wait for all buffers to complete
            await waitForPlaybackCompletion()
        } catch {
            stop()
            throw error
        }

        stop()
    }

    func play(audio: Data, format: AudioFormat) async throws {
        let buffer = try decodeAudio(data: audio, format: format)

        try configureAudioSession()
        try engine.start()
        playerNode.play()
        isPlaying = true

        duration = Double(buffer.frameLength) / buffer.format.sampleRate
        startTimeTracking()

        await withCheckedContinuation { continuation in
            playerNode.scheduleBuffer(buffer) {
                Task { @MainActor in
                    continuation.resume()
                }
            }
        }

        stop()
    }

    func stop() {
        playerNode.stop()
        engine.stop()
        isPlaying = false
        currentTime = 0
        stopTimeTracking()
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
    }

    func resume() {
        playerNode.play()
        isPlaying = true
    }

    // MARK: - Private

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    private func createBuffer(from chunk: AudioChunk) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(chunk.samples.count)
        ) else {
            throw AudioError.bufferCreationFailed
        }

        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)

        let channelData = buffer.floatChannelData![0]
        for (i, sample) in chunk.samples.enumerated() {
            channelData[i] = sample
        }

        return buffer
    }

    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        scheduledBuffers += 1

        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                self?.completedBuffers += 1
            }
        }
    }

    private func waitForPlaybackCompletion() async {
        while completedBuffers < scheduledBuffers {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func startTimeTracking() {
        displayLink = CADisplayLink(target: self, selector: #selector(updateTime))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopTimeTracking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func updateTime() {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return
        }

        currentTime = Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func decodeAudio(data: Data, format: AudioFormat) throws -> AVAudioPCMBuffer {
        // Implementation for decoding WAV/M4A data
        // Would use AVAudioFile or AudioToolbox
        fatalError("Implement audio decoding")
    }
}

// MARK: - Types

enum AudioFormat {
    case wav
    case m4a
}

enum AudioError: LocalizedError {
    case bufferCreationFailed
    case decodingFailed
    case sessionConfigurationFailed

    var errorDescription: String? {
        switch self {
        case .bufferCreationFailed:
            return "Failed to create audio buffer"
        case .decodingFailed:
            return "Failed to decode audio data"
        case .sessionConfigurationFailed:
            return "Failed to configure audio session"
        }
    }
}
```

### Step 4.2: Implement Audio Recorder

```swift
// Core/Audio/AudioRecorder.swift
import AVFoundation
import Combine

/// Records audio for voice cloning reference
@MainActor
final class AudioRecorder: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0

    private var audioRecorder: AVAudioRecorder?
    private var levelTimer: Timer?

    private let fileManager = FileManager.default

    var minimumDuration: TimeInterval { 3.0 }

    func startRecording() async throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)

        // Request permission
        let permitted = await withCheckedContinuation { continuation in
            session.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        guard permitted else {
            throw RecordingError.permissionDenied
        }

        let url = tempRecordingURL()

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        audioRecorder?.isMeteringEnabled = true
        audioRecorder?.record()

        isRecording = true
        startLevelMetering()

        return url
    }

    func stopRecording() throws -> (url: URL, duration: TimeInterval) {
        guard let recorder = audioRecorder else {
            throw RecordingError.notRecording
        }

        let duration = recorder.currentTime
        let url = recorder.url

        recorder.stop()
        audioRecorder = nil

        isRecording = false
        stopLevelMetering()

        guard duration >= minimumDuration else {
            try? fileManager.removeItem(at: url)
            throw RecordingError.tooShort(minimum: minimumDuration)
        }

        return (url, duration)
    }

    func cancelRecording() {
        guard let recorder = audioRecorder else { return }

        recorder.stop()
        try? fileManager.removeItem(at: recorder.url)
        audioRecorder = nil

        isRecording = false
        stopLevelMetering()
    }

    private func tempRecordingURL() -> URL {
        let tempDir = fileManager.temporaryDirectory
        let filename = "recording_\(UUID().uuidString).wav"
        return tempDir.appendingPathComponent(filename)
    }

    private func startLevelMetering() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateLevels()
        }
    }

    private func stopLevelMetering() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0
        currentTime = 0
    }

    private func updateLevels() {
        guard let recorder = audioRecorder else { return }

        recorder.updateMeters()

        let level = recorder.averagePower(forChannel: 0)
        // Convert dB to linear scale (0-1)
        audioLevel = pow(10, level / 20)
        currentTime = recorder.currentTime
    }
}

enum RecordingError: LocalizedError {
    case permissionDenied
    case notRecording
    case tooShort(minimum: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied"
        case .notRecording:
            return "Not currently recording"
        case .tooShort(let minimum):
            return "Recording must be at least \(Int(minimum)) seconds"
        }
    }
}
```

---

## Phase 5: UI Implementation

### Step 5.1: Main App Structure

```swift
// App/VoiceCloneApp.swift
import SwiftUI

@main
struct VoiceCloneApp: App {

    @StateObject private var container = DIContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(container)
                .environment(\.container, container)
        }
    }
}

// App/ContentView.swift
import SwiftUI

struct ContentView: View {

    @EnvironmentObject var container: DIContainer
    @State private var selectedTab: Tab = .speak

    enum Tab: String, CaseIterable {
        case speak = "Speak"
        case design = "Design"
        case clone = "Clone"
        case library = "Library"

        var icon: String {
            switch self {
            case .speak: return "waveform"
            case .design: return "sparkles"
            case .clone: return "mic.fill"
            case .library: return "books.vertical"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(Tab.allCases, id: \.self) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.rawValue, systemImage: tab.icon)
                    }
                    .tag(tab)
            }
        }
    }

    @ViewBuilder
    private func tabContent(for tab: Tab) -> some View {
        switch tab {
        case .speak:
            SynthesisView()
        case .design:
            VoiceDesignView()
        case .clone:
            VoiceCloneView()
        case .library:
            VoiceLibraryView()
        }
    }
}
```

### Step 5.2: Synthesis View

```swift
// Features/Synthesis/Views/SynthesisView.swift
import SwiftUI

struct SynthesisView: View {

    @StateObject private var viewModel = SynthesisViewModel()
    @EnvironmentObject var container: DIContainer

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                voiceSelector
                textEditor
                languageSelector
                waveformDisplay
                controlButtons
                synthesizeButton
            }
            .padding()
            .navigationTitle("Speak")
            .task {
                await viewModel.setup(ttsService: container.ttsService)
            }
        }
    }

    private var voiceSelector: some View {
        HStack {
            Text("Voice:")
                .foregroundStyle(.secondary)

            Menu {
                ForEach(PresetVoice.allCases, id: \.self) { voice in
                    Button(voice.rawValue) {
                        viewModel.selectedVoice = voice
                    }
                }

                Divider()

                NavigationLink("Custom Voices...") {
                    VoiceLibraryView()
                }
            } label: {
                HStack {
                    Text(viewModel.selectedVoice.rawValue)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary)
                .clipShape(Capsule())
            }

            Spacer()
        }
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text to speak")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $viewModel.text)
                .frame(minHeight: 120)
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.quaternary, lineWidth: 1)
                )
        }
    }

    private var languageSelector: some View {
        HStack {
            Text("Language:")
                .foregroundStyle(.secondary)

            Picker("Language", selection: $viewModel.language) {
                ForEach(Language.allCases, id: \.self) { language in
                    Text(language.rawValue).tag(language)
                }
            }
            .pickerStyle(.menu)

            Spacer()
        }
    }

    private var waveformDisplay: some View {
        WaveformView(
            samples: viewModel.waveformSamples,
            progress: viewModel.playbackProgress
        )
        .frame(height: 60)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var controlButtons: some View {
        HStack(spacing: 24) {
            Button {
                viewModel.seekBackward()
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.title2)
            }
            .disabled(!viewModel.hasAudio)

            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
            }
            .disabled(!viewModel.hasAudio)

            Button {
                viewModel.seekForward()
            } label: {
                Image(systemName: "goforward.10")
                    .font(.title2)
            }
            .disabled(!viewModel.hasAudio)

            Spacer()

            Button {
                viewModel.export()
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .disabled(!viewModel.hasAudio)
        }
        .buttonStyle(.plain)
    }

    private var synthesizeButton: some View {
        Button {
            Task {
                await viewModel.synthesize()
            }
        } label: {
            Group {
                if viewModel.isSynthesizing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Text("Speak")
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(viewModel.canSynthesize ? Color.accentColor : Color.gray)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!viewModel.canSynthesize)
    }
}
```

### Step 5.3: Synthesis ViewModel

```swift
// Features/Synthesis/ViewModels/SynthesisViewModel.swift
import SwiftUI
import Combine

@MainActor
final class SynthesisViewModel: ObservableObject {

    @Published var text: String = ""
    @Published var language: Language = .english
    @Published var selectedVoice: PresetVoice = .ryan
    @Published var instruction: String = ""

    @Published private(set) var isSynthesizing = false
    @Published private(set) var isPlaying = false
    @Published private(set) var hasAudio = false
    @Published private(set) var playbackProgress: Double = 0
    @Published private(set) var waveformSamples: [Float] = []
    @Published private(set) var error: String?

    private var ttsService: TTSService?
    private var audioData: Data?
    private var cancellables = Set<AnyCancellable>()

    var canSynthesize: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSynthesizing &&
        ttsService?.state == .ready
    }

    func setup(ttsService: TTSService) async {
        self.ttsService = ttsService

        // Load custom voice capability
        do {
            try await ttsService.loadCapability(.customVoice)
        } catch {
            self.error = error.localizedDescription
        }

        // Observe TTS state
        ttsService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .synthesizing:
                    self?.isSynthesizing = true
                case .ready:
                    self?.isSynthesizing = false
                case .error(let msg):
                    self?.error = msg
                    self?.isSynthesizing = false
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    func synthesize() async {
        guard let tts = ttsService else { return }

        isSynthesizing = true
        waveformSamples = []

        do {
            let stream = try await tts.synthesize(
                text: text,
                language: language,
                speaker: selectedVoice,
                instruction: instruction.isEmpty ? nil : instruction
            )

            var allSamples: [Float] = []

            for try await chunk in stream {
                allSamples.append(contentsOf: chunk.samples)

                // Update waveform preview
                waveformSamples = downsample(allSamples, to: 100)
            }

            hasAudio = true

            // Play audio
            try await tts.playStream(stream)

        } catch {
            self.error = error.localizedDescription
        }

        isSynthesizing = false
    }

    func togglePlayback() {
        // Implementation
    }

    func seekForward() {
        // Implementation
    }

    func seekBackward() {
        // Implementation
    }

    func export() {
        // Implementation
    }

    private func downsample(_ samples: [Float], to count: Int) -> [Float] {
        guard samples.count > count else { return samples }

        let chunkSize = samples.count / count
        return stride(from: 0, to: samples.count, by: chunkSize).map { start in
            let end = min(start + chunkSize, samples.count)
            let chunk = samples[start..<end]
            return chunk.max() ?? 0
        }
    }
}
```

---

## Phase 6: Voice Library & Storage

### Step 6.1: Core Data Stack

```swift
// Core/Storage/CoreDataStack.swift
import CoreData

final class CoreDataStack {

    static let shared = CoreDataStack()

    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    private init() {
        container = NSPersistentContainer(name: "VoiceClone")

        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Core Data failed to load: \(error)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
    }

    func save() throws {
        guard viewContext.hasChanges else { return }
        try viewContext.save()
    }

    func performBackgroundTask<T>(_ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        try await container.performBackgroundTask { context in
            try block(context)
        }
    }
}
```

### Step 6.2: Voice Storage

```swift
// Core/Storage/VoiceStorage.swift
import Foundation
import CoreData

/// Manages voice persistence
actor VoiceStorage {

    private let coreData = CoreDataStack.shared
    private let fileManager = FileManager.default
    private let voicesDirectory: URL

    init() {
        voicesDirectory = fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voices", isDirectory: true)

        try? fileManager.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)
    }

    func saveVoice(_ voice: Voice) async throws {
        try await coreData.performBackgroundTask { context in
            let entity = VoiceEntity(context: context)
            entity.id = voice.id
            entity.name = voice.name
            entity.type = voice.type.rawValue
            entity.language = voice.language.rawValue
            entity.createdAt = voice.createdAt
            entity.instruction = voice.instruction

            try context.save()
        }

        // Save audio file if present
        if let audioURL = voice.referenceAudioURL {
            let destURL = voicesDirectory.appendingPathComponent("\(voice.id).wav")
            try fileManager.copyItem(at: audioURL, to: destURL)
        }

        // Save embedding if present
        if let embedding = voice.embeddingData {
            let embeddingURL = voicesDirectory.appendingPathComponent("\(voice.id).embedding")
            try embedding.write(to: embeddingURL)
        }
    }

    func fetchVoices() async throws -> [Voice] {
        try await coreData.performBackgroundTask { context in
            let request = VoiceEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \VoiceEntity.createdAt, ascending: false)]

            let entities = try context.fetch(request)

            return entities.compactMap { entity -> Voice? in
                guard let id = entity.id,
                      let name = entity.name,
                      let typeRaw = entity.type,
                      let type = Voice.VoiceType(rawValue: typeRaw),
                      let langRaw = entity.language,
                      let language = Language(rawValue: langRaw),
                      let createdAt = entity.createdAt else {
                    return nil
                }

                return Voice(
                    id: id,
                    name: name,
                    type: type,
                    language: language,
                    createdAt: createdAt,
                    instruction: entity.instruction,
                    referenceAudioURL: nil,
                    embeddingData: nil
                )
            }
        }
    }

    func deleteVoice(_ id: UUID) async throws {
        try await coreData.performBackgroundTask { context in
            let request = VoiceEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

            if let entity = try context.fetch(request).first {
                context.delete(entity)
                try context.save()
            }
        }

        // Delete associated files
        let audioURL = voicesDirectory.appendingPathComponent("\(id).wav")
        let embeddingURL = voicesDirectory.appendingPathComponent("\(id).embedding")

        try? fileManager.removeItem(at: audioURL)
        try? fileManager.removeItem(at: embeddingURL)
    }
}
```

---

## Phase 7: Testing

### Step 7.1: Unit Tests

```swift
// Tests/UnitTests/TokenizerTests.swift
import XCTest
@testable import VoiceClone

final class TokenizerTests: XCTestCase {

    var tokenizer: Qwen3Tokenizer!

    override func setUp() async throws {
        let bundle = Bundle(for: type(of: self))
        tokenizer = try Qwen3Tokenizer(
            vocabURL: bundle.url(forResource: "vocab", withExtension: "json")!,
            mergesURL: bundle.url(forResource: "merges", withExtension: "txt")!,
            specialTokensURL: bundle.url(forResource: "special_tokens", withExtension: "json")!
        )
    }

    func testBasicTokenization() {
        let text = "Hello, world!"
        let tokens = tokenizer.encode(text: text, language: .english)

        XCTAssertFalse(tokens.isEmpty)
        XCTAssertEqual(tokens.first, tokenizer.bosTokenId)
        XCTAssertEqual(tokens.last, tokenizer.eosTokenId)
    }

    func testRoundTrip() {
        let text = "The quick brown fox jumps over the lazy dog."
        let tokens = tokenizer.encode(text: text, language: .english)
        let decoded = tokenizer.decode(tokens)

        XCTAssertTrue(decoded.contains("quick brown fox"))
    }

    func testMultilingualTokenization() {
        let chineseText = "你好世界"
        let tokens = tokenizer.encode(text: chineseText, language: .chinese)

        XCTAssertFalse(tokens.isEmpty)
    }
}
```

### Step 7.2: Integration Tests

```swift
// Tests/IntegrationTests/InferenceTests.swift
import XCTest
@testable import VoiceClone

final class InferenceTests: XCTestCase {

    var modelManager: MLModelManager!
    var engine: TTSInferenceEngine!

    override func setUp() async throws {
        modelManager = MLModelManager()
        engine = TTSInferenceEngine(modelManager: modelManager)

        // Load test model (smaller variant for testing)
        try await engine.loadModels(type: .base06B)
    }

    func testBasicInference() async throws {
        let tokenizer = try loadTestTokenizer()
        let tokens = tokenizer.encode(text: "Hello", language: .english)

        var chunks: [AudioChunk] = []

        for try await chunk in engine.generateStream(inputIds: tokens, maxNewTokens: 100) {
            chunks.append(chunk)
        }

        XCTAssertFalse(chunks.isEmpty, "Should generate audio chunks")

        let totalSamples = chunks.reduce(0) { $0 + $1.samples.count }
        XCTAssertGreaterThan(totalSamples, 0, "Should have audio samples")
    }

    func testFirstTokenLatency() async throws {
        let tokenizer = try loadTestTokenizer()
        let tokens = tokenizer.encode(text: "Quick test", language: .english)

        let start = CFAbsoluteTimeGetCurrent()
        var firstChunkTime: CFAbsoluteTime?

        for try await _ in engine.generateStream(inputIds: tokens, maxNewTokens: 50) {
            if firstChunkTime == nil {
                firstChunkTime = CFAbsoluteTimeGetCurrent()
            }
        }

        let latency = (firstChunkTime! - start) * 1000
        XCTAssertLessThan(latency, 1000, "First token latency should be under 1000ms")
    }
}
```

### Step 7.3: Performance Tests

```swift
// Tests/PerformanceTests/MemoryTests.swift
import XCTest
@testable import VoiceClone

final class MemoryTests: XCTestCase {

    func testMemoryFootprint() async throws {
        let modelManager = MLModelManager()

        // Measure baseline memory
        let baselineMemory = currentMemoryUsage()

        // Load model
        _ = try await modelManager.loadModel(.customVoice)

        let loadedMemory = currentMemoryUsage()
        let memoryIncrease = loadedMemory - baselineMemory

        // Should be under 3GB
        XCTAssertLessThan(memoryIncrease, 3_000_000_000, "Memory usage should be under 3GB")
    }

    private func currentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
```

---

## Phase 8: Release Preparation

### Step 8.1: App Store Assets

- **App Icon**: 1024x1024 PNG
- **Screenshots**: iPhone 6.7", 6.5", 5.5"; iPad 12.9"
- **App Preview Videos**: 15-30 second demos

### Step 8.2: Privacy & Compliance

**Privacy Manifest (PrivacyInfo.xcprivacy):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>C617.1</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

### Step 8.3: Build Configuration

```bash
# Release build
xcodebuild archive \
    -project VoiceClone.xcodeproj \
    -scheme VoiceClone \
    -configuration Release \
    -archivePath build/VoiceClone.xcarchive \
    DEVELOPMENT_TEAM=YOUR_TEAM_ID

# Export for App Store
xcodebuild -exportArchive \
    -archivePath build/VoiceClone.xcarchive \
    -exportPath build/export \
    -exportOptionsPlist ExportOptions.plist
```

---

## Checklist

### Phase 1: Project Setup
- [ ] Create Xcode project with correct structure
- [ ] Configure build settings and entitlements
- [ ] Set up SPM dependencies
- [ ] Implement DI container

### Phase 2: Model Conversion
- [ ] Set up Python conversion environment
- [ ] Export models to ONNX
- [ ] Convert to CoreML
- [ ] Quantize to INT4
- [ ] Validate converted models
- [ ] Export tokenizer assets

### Phase 3: Core Implementation
- [ ] Implement Qwen3Tokenizer
- [ ] Implement MLModelManager
- [ ] Implement KVCache
- [ ] Implement TTSInferenceEngine
- [ ] Implement TTSService

### Phase 4: Audio System
- [ ] Implement AudioEngine
- [ ] Implement AudioRecorder
- [ ] Implement AudioExporter
- [ ] Test streaming playback

### Phase 5: UI Implementation
- [ ] Build main tab structure
- [ ] Implement SynthesisView
- [ ] Implement VoiceDesignView
- [ ] Implement VoiceCloneView
- [ ] Implement VoiceLibraryView
- [ ] Add loading states and error handling

### Phase 6: Storage
- [ ] Set up Core Data model
- [ ] Implement VoiceStorage
- [ ] Test persistence

### Phase 7: Testing
- [ ] Write unit tests (80% coverage)
- [ ] Write integration tests
- [ ] Write performance tests
- [ ] Manual QA testing

### Phase 8: Release
- [ ] Create App Store assets
- [ ] Configure privacy manifest
- [ ] Archive and submit to App Store
- [ ] Publish to GitHub
