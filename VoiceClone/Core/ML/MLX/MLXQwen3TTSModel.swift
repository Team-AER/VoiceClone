// MLXQwen3TTSModel.swift
// MLX-based Qwen3-TTS model for iOS
//
// Uses mlx-swift for on-device inference with Apple Silicon

import Foundation
import MLX
import MLXNN

// Helper function for SiLU activation (not in MLX by default)
nonisolated fileprivate func silu(_ x: MLXArray) -> MLXArray {
    // SiLU(x) = x * sigmoid(x) = x / (1 + exp(-x))
    return x * sigmoid(x)
}


/// Configuration for Qwen3-TTS MLX model
struct MLXQwen3TTSConfig: @unchecked Sendable {
    let hiddenSize: Int
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let numKeyValueHeads: Int
    let intermediateSize: Int
    let vocabSize: Int
    let rmsNormEps: Float
    let numCodeGroups: Int
    let codebookSize: Int
    
    nonisolated init(json: [String: Any]) {
        self.hiddenSize = json["hidden_size"] as? Int ?? 1024
        self.numHiddenLayers = json["num_hidden_layers"] as? Int ?? 12
        self.numAttentionHeads = json["num_attention_heads"] as? Int ?? 16
        self.numKeyValueHeads = json["num_key_value_heads"] as? Int ?? 16
        self.intermediateSize = json["intermediate_size"] as? Int ?? 4096
        self.vocabSize = json["vocab_size"] as? Int ?? 32000
        self.rmsNormEps = (json["rms_norm_eps"] as? NSNumber)?.floatValue ?? 1e-6
        self.numCodeGroups = json["num_code_groups"] as? Int ?? 16
        self.codebookSize = json["codebook_size"] as? Int ?? 192
    }
}

/// MLX implementation of Qwen3-TTS model
@available(iOS 16.0, *)
public actor MLXQwen3TTSModel {

    private let config: MLXQwen3TTSConfig
    private var weights: [String: MLXArray]

    nonisolated public init(modelPath: URL) async throws {
        // Load config manually to avoid actor isolation issues
        let configURL = modelPath.appendingPathComponent("talker_config.json")
        print("📍 Loading talker config from: \(configURL.path)")
        let configData = try Data(contentsOf: configURL)
        let json = try JSONSerialization.jsonObject(with: configData) as? [String: Any] ?? [:]
        let loadedConfig = MLXQwen3TTSConfig(json: json)

        // Load FP16 weights - use .safetensors format (MLX Swift API supports this)
        let weightsURL = modelPath.appendingPathComponent("talker_weights.safetensors")
        print("📍 Loading talker FP16 weights from: \(weightsURL.path)")

        // MLX Swift API can load .safetensors directly (no dequantization needed for FP16)
        let loadedWeights = try MLX.loadArrays(url: weightsURL)

        self.config = loadedConfig
        self.weights = loadedWeights

        print("✓ Loaded MLX FP16 model from \(modelPath.lastPathComponent)")
        print("  Layers: \(loadedConfig.numHiddenLayers)")
        print("  Hidden size: \(loadedConfig.hiddenSize)")
        print("  Parameters: \(loadedWeights.count)")
        
        // Print weight key structure for debugging
        let allKeys = loadedWeights.keys.sorted()
        print("\n🔍 WEIGHT KEY STRUCTURE:")
        print("  First 20 keys:")
        for (idx, key) in allKeys.prefix(20).enumerated() {
            let shape = loadedWeights[key]?.shape ?? []
            print("    [\(idx)]: \(key) -> \(shape)")
        }
        
        // Detect unique top-level prefixes
        let prefixes = Set(allKeys.compactMap { $0.split(separator: ".").first.map(String.init) })
        print("\n  Unique top-level prefixes: \(prefixes.sorted().joined(separator: ", "))")
        
        // Check for embedding-related keys
        let embedKeys = allKeys.filter { $0.lowercased().contains("embed") }.prefix(10)
        print("  Embedding-related keys: \(embedKeys.joined(separator: ", "))")
        print("")
    }

    /// Generate audio codes from text tokens
    /// - Parameter inputIds: Text token IDs [batch, seq_len]
    /// - Returns: Audio codes [batch, num_codebooks, seq_len]
    public func generate(inputIds: MLXArray) async throws -> MLXArray {
        // Validate input
        guard inputIds.ndim == 2 else {
            throw MLXError.invalidShape("Expected 2D input, got \(inputIds.ndim)D")
        }

        let batchSize = inputIds.shape[0]
        let seqLen = inputIds.shape[1]

        // Text embeddings
        var hidden = try embedTokens(inputIds)

        // Text projection
        hidden = try textProjection(hidden)

        // Transformer layers
        for layer in 0..<config.numHiddenLayers {
            hidden = try transformerLayer(hidden, layerIdx: layer)
        }

        // Final norm
        hidden = try rmsNorm(hidden, weightKey: "norm.weight", eps: config.rmsNormEps)

        // Codec head
        let codecLogits = try linear(hidden, weightKey: "codec_head.weight")

        // Reshape for multi-codebook: [batch, seq, num_groups * codebook_size] -> [batch, seq, num_groups, codebook_size]
        let reshaped = codecLogits.reshaped(
            batchSize,
            seqLen,
            config.numCodeGroups,
            config.codebookSize
        )

        // Argmax over codebook dimension
        let codes = reshaped.argMax(axis: -1, keepDims: false)

        // Transpose to [batch, num_groups, seq]
        let output = codes.transposed(axes: [0, 2, 1])

        return output
    }

    // MARK: - Model Components
    
    /// Safely retrieve a weight tensor by key
    private func getWeight(_ key: String) throws -> MLXArray {
        guard let weight = weights[key] else {
            print("❌ ERROR: Weight '\(key)' not found")
            print("Available keys containing '\(key.split(separator: ".").first ?? "")':")
            let relatedKeys = weights.keys.filter { $0.contains(key.split(separator: ".").first ?? "") }
            relatedKeys.sorted().prefix(10).forEach { print("  - \($0)") }
            throw MLXError.loadFailed("Weight '\(key)' not found in model")
        }
        return weight
    }

    private func embedTokens(_ inputIds: MLXArray) throws -> MLXArray {
        // First, try to find any key containing "embed" in the weights
        let allEmbedKeys = weights.keys.filter { $0.lowercased().contains("embed") && $0.contains("weight") }
        
        // Try different possible key names for embedding weights
        let possibleKeys = [
            "embed_tokens.weight",
            "model.embed_tokens.weight",
            "transformer.wte.weight",
            "talker.embed_tokens.weight"
        ] + allEmbedKeys.sorted() // Add any found embed keys
        
        guard let embedKey = possibleKeys.first(where: { weights[$0] != nil }) else {
            print("❌ Could not find embedding weights. Tried:")
            possibleKeys.forEach { print("  - \($0)") }
            print("\nAvailable keys with 'embed':")
            allEmbedKeys.sorted().forEach { print("  - \($0)") }
            throw MLXError.loadFailed("No embedding weights found in model")
        }
        
        print("✓ Using embedding key: \(embedKey)")
        let embedWeight = try getWeight(embedKey)
        
        // Ensure indices are int32 for take operation
        let indices = inputIds.asType(.int32)
        // Take operation returns the dtype of embedWeight, but ensure it's float32
        let embedded = MLX.take(embedWeight, indices, axis: 0)
        return embedded.asType(.float32)
    }

    private func textProjection(_ hidden: MLXArray) throws -> MLXArray {
        return try linear(hidden, weightKey: "text_projection.weight")
    }

    private func transformerLayer(_ hidden: MLXArray, layerIdx: Int) throws -> MLXArray {
        let prefix = "layers.\(layerIdx)"

        // Self-attention
        let normHidden = try rmsNorm(
            hidden,
            weightKey: "\(prefix).input_layernorm.weight",
            eps: config.rmsNormEps
        )

        let attnOutput = try attention(
            normHidden,
            qWeightKey: "\(prefix).self_attn.q_proj.weight",
            kWeightKey: "\(prefix).self_attn.k_proj.weight",
            vWeightKey: "\(prefix).self_attn.v_proj.weight",
            oWeightKey: "\(prefix).self_attn.o_proj.weight"
        )

        var residual = hidden + attnOutput

        // MLP
        let mlpNormHidden = try rmsNorm(
            residual,
            weightKey: "\(prefix).post_attention_layernorm.weight",
            eps: config.rmsNormEps
        )

        let mlpOutput = try mlp(
            mlpNormHidden,
            gateWeightKey: "\(prefix).mlp.gate_proj.weight",
            upWeightKey: "\(prefix).mlp.up_proj.weight",
            downWeightKey: "\(prefix).mlp.down_proj.weight"
        )

        residual = residual + mlpOutput

        return residual
    }

    private func attention(
        _ hidden: MLXArray,
        qWeightKey: String,
        kWeightKey: String,
        vWeightKey: String,
        oWeightKey: String
    ) throws -> MLXArray {
        let batchSize = hidden.shape[0]
        let seqLen = hidden.shape[1]
        let headDim = config.hiddenSize / config.numAttentionHeads

        // Project Q, K, V
        let q = try linear(hidden, weightKey: qWeightKey)
        let k = try linear(hidden, weightKey: kWeightKey)
        let v = try linear(hidden, weightKey: vWeightKey)

        // Reshape for multi-head
        let qHeads = q.reshaped(batchSize, seqLen, config.numAttentionHeads, headDim)
            .transposed(axes: [0, 2, 1, 3])
        let kHeads = k.reshaped(batchSize, seqLen, config.numKeyValueHeads, headDim)
            .transposed(axes: [0, 2, 1, 3])
        let vHeads = v.reshaped(batchSize, seqLen, config.numKeyValueHeads, headDim)
            .transposed(axes: [0, 2, 1, 3])

        // Repeat K/V for GQA if needed
        let kHeadsExpanded: MLXArray
        let vHeadsExpanded: MLXArray

        if config.numKeyValueHeads < config.numAttentionHeads {
            let nRep = config.numAttentionHeads / config.numKeyValueHeads
            kHeadsExpanded = MLX.repeated(kHeads, count: nRep, axis: 1)
            vHeadsExpanded = MLX.repeated(vHeads, count: nRep, axis: 1)
        } else {
            kHeadsExpanded = kHeads
            vHeadsExpanded = vHeads
        }

        // Scaled dot-product attention
        let scale = 1.0 / sqrt(Float(headDim))
        let scores = MLX.matmul(qHeads, kHeadsExpanded.transposed(axes: [0, 1, 3, 2])) * scale

        // Causal mask
        let mask = MLX.triu(MLX.full([seqLen, seqLen], values: Float.infinity), k: 1)
        let maskedScores = scores - mask

        let weights = MLX.softmax(maskedScores, axis: -1)
        let attnOutput = MLX.matmul(weights, vHeadsExpanded)

        // Reshape back
        let output = attnOutput.transposed(axes: [0, 2, 1, 3])
            .reshaped(batchSize, seqLen, config.hiddenSize)

        // Output projection
        return try linear(output, weightKey: oWeightKey)
    }

    private func mlp(
        _ hidden: MLXArray,
        gateWeightKey: String,
        upWeightKey: String,
        downWeightKey: String
    ) throws -> MLXArray {
        let gate = try linear(hidden, weightKey: gateWeightKey)
        let up = try linear(hidden, weightKey: upWeightKey)
        let activated = silu(gate) * up
        return try linear(activated, weightKey: downWeightKey)
    }

    // MARK: - Helper Functions

    private func linear(_ input: MLXArray, weightKey: String, biasKey: String? = nil, useTranspose: Bool = true) throws -> MLXArray {
        let weight = try getWeight(weightKey)
        let weightToUse = useTranspose ? weight.T : weight
        var output = MLX.matmul(input, weightToUse)
        if let biasKey = biasKey, let bias = weights[biasKey] {
            output = output + bias
        }
        return output
    }

    private func rmsNorm(_ input: MLXArray, weightKey: String, eps: Float) throws -> MLXArray {
        let weight = try getWeight(weightKey)
        let variance = MLX.mean(input * input, axis: -1, keepDims: true)
        let normalized = input * MLX.rsqrt(variance + eps)
        return normalized * weight
    }
}

/// MLX-specific errors
enum MLXError: LocalizedError {
    case invalidShape(String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidShape(let msg):
            return "Invalid shape: \(msg)"
        case .loadFailed(let msg):
            return "Load failed: \(msg)"
        }
    }
}
