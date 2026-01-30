// MLXQwen3TTSModel.swift
// MLX-based Qwen3-TTS model for iOS
//
// Uses mlx-swift for on-device inference with Apple Silicon

import Foundation
import MLX
import MLXNN

// Helper function for SiLU activation (not in MLX by default)
fileprivate func silu(_ x: MLXArray) -> MLXArray {
    // SiLU(x) = x * sigmoid(x) = x / (1 + exp(-x))
    return x * sigmoid(x)
}


/// Configuration for Qwen3-TTS MLX model
struct MLXQwen3TTSConfig: Codable {
    let hiddenSize: Int
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let numKeyValueHeads: Int
    let intermediateSize: Int
    let vocabSize: Int
    let rmsNormEps: Float
    let numCodeGroups: Int
    let codebookSize: Int

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case intermediateSize = "intermediate_size"
        case vocabSize = "vocab_size"
        case rmsNormEps = "rms_norm_eps"
        case numCodeGroups = "num_code_groups"
        case codebookSize = "codebook_size"
    }
}

/// MLX implementation of Qwen3-TTS model
@available(iOS 16.0, *)
public actor MLXQwen3TTSModel {

    private let config: MLXQwen3TTSConfig
    private var weights: [String: MLXArray]

    public init(modelPath: URL) async throws {
        // Load config
        let configURL = modelPath.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        self.config = try JSONDecoder().decode(MLXQwen3TTSConfig.self, from: configData)

        // Load weights
        let weightsURL = modelPath.appendingPathComponent("weights.npz")
        self.weights = try MLX.loadArrays(url: weightsURL)

        print("✓ Loaded MLX model from \(modelPath.lastPathComponent)")
        print("  Layers: \(config.numHiddenLayers)")
        print("  Hidden size: \(config.hiddenSize)")
        print("  Parameters: \(weights.count)")
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
        var hidden = embedTokens(inputIds)

        // Text projection
        hidden = textProjection(hidden)

        // Transformer layers
        for layer in 0..<config.numHiddenLayers {
            hidden = try transformerLayer(hidden, layerIdx: layer)
        }

        // Final norm
        hidden = rmsNorm(hidden, weight: weights["norm.weight"]!, eps: config.rmsNormEps)

        // Codec head
        let codecLogits = linear(hidden, weight: weights["codec_head.weight"]!)

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

    private func embedTokens(_ inputIds: MLXArray) -> MLXArray {
        let embedWeight = weights["embed_tokens.weight"]!
        return MLX.take(embedWeight, inputIds, axis: 0)
    }

    private func textProjection(_ hidden: MLXArray) -> MLXArray {
        return linear(hidden, weight: weights["text_projection.weight"]!)
    }

    private func transformerLayer(_ hidden: MLXArray, layerIdx: Int) throws -> MLXArray {
        let prefix = "layers.\(layerIdx)"

        // Self-attention
        let normHidden = rmsNorm(
            hidden,
            weight: weights["\(prefix).input_layernorm.weight"]!,
            eps: config.rmsNormEps
        )

        let attnOutput = try attention(
            normHidden,
            qWeight: weights["\(prefix).self_attn.q_proj.weight"]!,
            kWeight: weights["\(prefix).self_attn.k_proj.weight"]!,
            vWeight: weights["\(prefix).self_attn.v_proj.weight"]!,
            oWeight: weights["\(prefix).self_attn.o_proj.weight"]!
        )

        var residual = hidden + attnOutput

        // MLP
        let mlpNormHidden = rmsNorm(
            residual,
            weight: weights["\(prefix).post_attention_layernorm.weight"]!,
            eps: config.rmsNormEps
        )

        let mlpOutput = mlp(
            mlpNormHidden,
            gateWeight: weights["\(prefix).mlp.gate_proj.weight"]!,
            upWeight: weights["\(prefix).mlp.up_proj.weight"]!,
            downWeight: weights["\(prefix).mlp.down_proj.weight"]!
        )

        residual = residual + mlpOutput

        return residual
    }

    private func attention(
        _ hidden: MLXArray,
        qWeight: MLXArray,
        kWeight: MLXArray,
        vWeight: MLXArray,
        oWeight: MLXArray
    ) throws -> MLXArray {
        let batchSize = hidden.shape[0]
        let seqLen = hidden.shape[1]
        let headDim = config.hiddenSize / config.numAttentionHeads

        // Project Q, K, V
        let q = linear(hidden, weight: qWeight)
        let k = linear(hidden, weight: kWeight)
        let v = linear(hidden, weight: vWeight)

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
            kHeadsExpanded = kHeads.repeated(nRep, axis: 1)
            vHeadsExpanded = vHeads.repeated(nRep, axis: 1)
        } else {
            kHeadsExpanded = kHeads
            vHeadsExpanded = vHeads
        }

        // Scaled dot-product attention
        let scale = 1.0 / sqrt(Float(headDim))
        let scores = MLX.matmul(qHeads, kHeadsExpanded.transposed(axes: [0, 1, 3, 2])) * scale

        // Causal mask
        let mask = MLX.triu(MLX.full(seqLen, seqLen, values: Float.infinity), k: 1)
        let maskedScores = scores - mask

        let weights = MLX.softmax(maskedScores, axis: -1)
        let attnOutput = MLX.matmul(weights, vHeadsExpanded)

        // Reshape back
        let output = attnOutput.transposed(axes: [0, 2, 1, 3])
            .reshaped(batchSize, seqLen, config.hiddenSize)

        // Output projection
        return linear(output, weight: oWeight)
    }

    private func mlp(
        _ hidden: MLXArray,
        gateWeight: MLXArray,
        upWeight: MLXArray,
        downWeight: MLXArray
    ) -> MLXArray {
        let gate = linear(hidden, weight: gateWeight)
        let up = linear(hidden, weight: upWeight)
        let activated = silu(gate) * up
        return linear(activated, weight: downWeight)
    }

    // MARK: - Helper Functions

    private func linear(_ input: MLXArray, weight: MLXArray, bias: MLXArray? = nil) -> MLXArray {
        var output = MLX.matmul(input, weight.T)
        if let bias = bias {
            output = output + bias
        }
        return output
    }

    private func rmsNorm(_ input: MLXArray, weight: MLXArray, eps: Float) -> MLXArray {
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
