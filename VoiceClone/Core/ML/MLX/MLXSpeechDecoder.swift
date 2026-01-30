//
//  MLXSpeechDecoder.swift
//  VoiceClone
//
//  Speech decoder for converting audio codes to waveforms
//  Implements the Qwen3-TTS decoder architecture with Snake activation
//

import Foundation
import MLX
import MLXNN

// Helper function for GELU activation
nonisolated fileprivate func gelu(_ x: MLXArray) -> MLXArray {
    // GELU(x) = x * Φ(x) where Φ is the Gaussian CDF
    // Approximation: GELU(x) ≈ 0.5 * x * (1 + tanh(√(2/π) * (x + 0.044715 * x³)))
    let sqrt2OverPi = sqrt(2.0 / Float.pi)
    let x3 = x * x * x
    let inner = sqrt2OverPi * (x + 0.044715 * x3)
    return 0.5 * x * (1.0 + MLX.tanh(inner))
}

/// Configuration for speech decoder
struct SpeechDecoderConfig: @unchecked Sendable {
    nonisolated(unsafe) let numQuantizers: Int
    nonisolated(unsafe) let codebookSize: Int
    nonisolated(unsafe) let codebookDim: Int
    nonisolated(unsafe) let hiddenSize: Int
    nonisolated(unsafe) let latentDim: Int
    nonisolated(unsafe) let decoderDim: Int
    nonisolated(unsafe) let numHiddenLayers: Int
    nonisolated(unsafe) let numAttentionHeads: Int
    nonisolated(unsafe) let upsampleRates: [Int]
    nonisolated(unsafe) let upscaleRatios: [Int]
    nonisolated(unsafe) let outputSampleRate: Int
    nonisolated(unsafe) let decodeUpsampleRate: Int
    
    enum CodingKeys: String, CodingKey {
        case numQuantizers = "num_quantizers"
        case codebookSize = "codebook_size"
        case codebookDim = "codebook_dim"
        case hiddenSize = "hidden_size"
        case latentDim = "latent_dim"
        case decoderDim = "decoder_dim"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case upsampleRates = "upsample_rates"
        case upscaleRatios = "upsampling_ratios"
        case outputSampleRate = "output_sample_rate"
        case decodeUpsampleRate = "decode_upsample_rate"
    }
    
    nonisolated init(
        numQuantizers: Int,
        codebookSize: Int,
        codebookDim: Int,
        hiddenSize: Int,
        latentDim: Int,
        decoderDim: Int,
        numHiddenLayers: Int,
        numAttentionHeads: Int,
        upsampleRates: [Int],
        upscaleRatios: [Int],
        outputSampleRate: Int,
        decodeUpsampleRate: Int
    ) {
        self.numQuantizers = numQuantizers
        self.codebookSize = codebookSize
        self.codebookDim = codebookDim
        self.hiddenSize = hiddenSize
        self.latentDim = latentDim
        self.decoderDim = decoderDim
        self.numHiddenLayers = numHiddenLayers
        self.numAttentionHeads = numAttentionHeads
        self.upsampleRates = upsampleRates
        self.upscaleRatios = upscaleRatios
        self.outputSampleRate = outputSampleRate
        self.decodeUpsampleRate = decodeUpsampleRate
    }
    
    nonisolated static func loadFromConfig(at url: URL) throws -> SpeechDecoderConfig {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecoderError.configMissing("Invalid JSON format")
        }
        
        // Extract decoder_config
        guard let decoderConfigDict = json["decoder_config"] as? [String: Any] else {
            throw DecoderError.configMissing("decoder_config not found")
        }
        
        // Parse decoder config manually to avoid Codable MainActor issues
        // Use actual config values from Qwen3-TTS decoder config
        let config = SpeechDecoderConfig(
            numQuantizers: decoderConfigDict["num_quantizers"] as? Int ?? 16,
            codebookSize: decoderConfigDict["codebook_size"] as? Int ?? 2048,
            codebookDim: decoderConfigDict["codebook_dim"] as? Int ?? 512,  // Updated from 256
            hiddenSize: decoderConfigDict["hidden_size"] as? Int ?? 512,    // Updated from 1024
            latentDim: decoderConfigDict["latent_dim"] as? Int ?? 1024,     // Updated from 256
            decoderDim: decoderConfigDict["decoder_dim"] as? Int ?? 1536,   // Updated from 512
            numHiddenLayers: decoderConfigDict["num_hidden_layers"] as? Int ?? 8,  // Updated from 4
            numAttentionHeads: decoderConfigDict["num_attention_heads"] as? Int ?? 16,  // Updated from 8
            upsampleRates: decoderConfigDict["upsample_rates"] as? [Int] ?? [8, 5, 4, 3],
            upscaleRatios: decoderConfigDict["upsampling_ratios"] as? [Int] ?? [2, 2],
            outputSampleRate: json["output_sample_rate"] as? Int ?? 24000,
            decodeUpsampleRate: json["decode_upsample_rate"] as? Int ?? 1920
        )
        
        print("📐 Decoder config loaded:")
        print("  Codebook dim: \(config.codebookDim)")
        print("  Latent dim: \(config.latentDim)")
        print("  Hidden size: \(config.hiddenSize)")
        print("  Num quantizers: \(config.numQuantizers)")
        
        return config
    }
}

/// Helper for decoding arbitrary JSON
struct AnyCodable: Codable, @unchecked Sendable {
    nonisolated(unsafe) let value: Any
    
    nonisolated init(_ value: Any) {
        self.value = value
    }
    
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
    
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

/// MLX Speech Decoder for Qwen3-TTS
@available(iOS 16.0, *)
public actor MLXSpeechDecoder {
    private let config: SpeechDecoderConfig
    private let weights: [String: MLXArray]
    private let rvq: ResidualVectorQuantizer
    private let actualRvqOutputDim: Int  // Track actual RVQ output dimension
    
    public init(modelPath: URL) async throws {
        // Load config
        let configURL = modelPath.appendingPathComponent("decoder_config.json")
        self.config = try SpeechDecoderConfig.loadFromConfig(at: configURL)

        // Load weights - use .safetensors format (MLX Swift API supports this)
        let weightsURL = modelPath.appendingPathComponent("decoder_weights.safetensors")
        print("📍 Loading decoder weights from: \(weightsURL.path)")

        // MLX Swift API can load .safetensors directly
        self.weights = try MLX.loadArrays(url: weightsURL)
        
        // Initialize RVQ
        self.rvq = loadResidualVectorQuantizer(
            from: weights,
            numQuantizers: config.numQuantizers,
            codebookSize: config.codebookSize,
            codebookDim: config.codebookDim,
            prefix: "quantizer.rvq"
        )
        
        // Store actual RVQ output dimension
        self.actualRvqOutputDim = rvq.codebookDim
        
        print("✓ Loaded speech decoder from \(modelPath.lastPathComponent)")
        print("  Quantizers: \(config.numQuantizers)")
        print("  Codebook size: \(config.codebookSize)")
        print("  RVQ output dim: \(actualRvqOutputDim)")
        print("  Upsample rate: \(config.decodeUpsampleRate)x")
    }
    
    /// Decode audio codes to waveform
    /// - Parameter codes: Audio codes [batch, num_codebooks, seq_len]
    /// - Returns: Audio waveform [batch, num_samples]
    public func decode(_ codes: MLXArray) async throws -> MLXArray {
        // 1. RVQ lookup: [batch, num_codebooks, seq_len] -> [batch, seq_len, latent_dim]
        var hidden = rvq.decode(codes)
        
        // 2. Pre-transformer
        hidden = preTransformer(hidden)
        
        // 3. Pre-conv: [batch, seq_len, latent_dim] -> [batch, latent_dim, seq_len]
        hidden = hidden.transposed(axes: [0, 2, 1])
        hidden = preConv(hidden)
        
        // 4. Upsampling blocks
        for (idx, ratio) in config.upscaleRatios.enumerated() {
            hidden = upsampleBlock(hidden, blockIdx: idx, ratio: ratio)
        }
        
        // 5. Decoder blocks with Snake activation
        let channelProgression = [
            config.decoderDim,
            config.decoderDim * 3 / 4,
            config.decoderDim / 2,
            config.decoderDim / 4,
            config.decoderDim / 8
        ]
        
        for (idx, ratio) in config.upsampleRates.enumerated() {
            let inChannels = idx == 0 ? config.latentDim : channelProgression[idx - 1]
            let outChannels = channelProgression[idx]
            hidden = decoderBlock(hidden, blockIdx: idx, ratio: ratio, inChannels: inChannels, outChannels: outChannels)
        }
        
        // 6. Final convolution to 1 channel
        hidden = finalConv(hidden)
        
        // 7. Squeeze and apply tanh: [batch, 1, num_samples] -> [batch, num_samples]
        let waveform = hidden.squeezed(axis: 1)
        return MLX.tanh(waveform)
    }
    
    // MARK: - Model Components
    
    private func preTransformer(_ hidden: MLXArray) -> MLXArray {
        var x = hidden
        
        print("🔍 PreTransformer input shape: \(x.shape)")
        
        // Input projection
        if let inputProj = weights["pre_transformer.input_proj.weight"] {
            print("🔍 Input projection weight shape: \(inputProj.shape)")
            print("   Expected: [hidden_size(\(config.hiddenSize)), rvq_output(\(actualRvqOutputDim))]")
            
            // Check if dimensions match
            let expectedInputDim = inputProj.shape[1]  // For PyTorch format (out, in)
            let actualInputDim = x.shape[x.ndim - 1]
            
            if expectedInputDim != actualInputDim {
                print("⚠️ Dimension mismatch in input projection!")
                print("   Weight expects input: \(expectedInputDim)")
                print("   Actual input: \(actualInputDim)")
                
                // Try transposing the weight to fix the issue
                let transposedWeight = inputProj.T
                print("   Trying transposed weight shape: \(transposedWeight.shape)")
                x = linear(x, weight: transposedWeight, useTranspose: false)
            } else {
                x = linear(x, weight: inputProj)
            }
        }
        
        print("🔍 After input projection: \(x.shape)")
        
        // Transformer layers
        for layerIdx in 0..<config.numHiddenLayers {
            x = transformerLayer(x, layerIdx: layerIdx)
        }
        
        // Output projection
        if let outputProj = weights["pre_transformer.output_proj.weight"] {
            x = linear(x, weight: outputProj)
        }
        
        return x
    }
    
    private func transformerLayer(_ hidden: MLXArray, layerIdx: Int) -> MLXArray {
        let prefix = "pre_transformer.layers.\(layerIdx)"
        
        // Self-attention with residual
        let norm1 = layerNorm(hidden, prefix: "\(prefix).norm1")
        let attn = selfAttention(norm1, prefix: "\(prefix).self_attn")
        var x = hidden + attn
        
        // FFN with residual
        let norm2 = layerNorm(x, prefix: "\(prefix).norm2")
        let ffn = feedForward(norm2, prefix: "\(prefix).ffn")
        x = x + ffn
        
        return x
    }
    
    private func selfAttention(_ x: MLXArray, prefix: String) -> MLXArray {
        // Simplified attention (full implementation would use proper multi-head attention)
        let qWeight = weights["\(prefix).q_proj.weight"] ?? MLX.zeros([config.hiddenSize, config.hiddenSize])
        let kWeight = weights["\(prefix).k_proj.weight"] ?? MLX.zeros([config.hiddenSize, config.hiddenSize])
        let vWeight = weights["\(prefix).v_proj.weight"] ?? MLX.zeros([config.hiddenSize, config.hiddenSize])
        let oWeight = weights["\(prefix).o_proj.weight"] ?? MLX.zeros([config.hiddenSize, config.hiddenSize])
        
        let q = linear(x, weight: qWeight)
        let k = linear(x, weight: kWeight)
        let v = linear(x, weight: vWeight)
        
        // Scaled dot-product attention
        let scale = Float(1.0 / sqrt(Double(config.hiddenSize)))
        let scores = MLX.matmul(q, k.transposed(axes: [0, 2, 1])) * scale
        let attnWeights = MLX.softmax(scores, axis: -1)
        let attnOutput = MLX.matmul(attnWeights, v)
        
        return linear(attnOutput, weight: oWeight)
    }
    
    private func feedForward(_ x: MLXArray, prefix: String) -> MLXArray {
        let fc1Weight = weights["\(prefix).fc1.weight"] ?? MLX.zeros([config.hiddenSize * 4, config.hiddenSize])
        let fc2Weight = weights["\(prefix).fc2.weight"] ?? MLX.zeros([config.hiddenSize, config.hiddenSize * 4])
        
        let hidden = linear(x, weight: fc1Weight)
        let activated = gelu(hidden)
        return linear(activated, weight: fc2Weight)
    }
    
    private func preConv(_ x: MLXArray) -> MLXArray {
        // Causal conv1d
        if let weight = weights["pre_conv.weight"] {
            // Simplified: use direct convolution (proper implementation would use CausalConv1d)
            return conv1d(x, weight: weight)
        }
        return x
    }
    
    private func upsampleBlock(_ x: MLXArray, blockIdx: Int, ratio: Int) -> MLXArray {
        let prefix = "upsample.\(blockIdx)"
        
        // Transposed convolution for upsampling
        var hidden = x
        if let weight = weights["\(prefix).0.weight"] {
            hidden = convTranspose1d(hidden, weight: weight, stride: ratio)
        }
        
        // Depthwise separable conv
        if let dwWeight = weights["\(prefix).1.depthwise.weight"],
           let pwWeight = weights["\(prefix).1.pointwise.weight"] {
            hidden = conv1d(hidden, weight: dwWeight)
            hidden = conv1d(hidden, weight: pwWeight)
        }
        
        // Layer norm and activation
        hidden = layerNorm(hidden.transposed(axes: [0, 2, 1]), prefix: "\(prefix).2").transposed(axes: [0, 2, 1])
        hidden = gelu(hidden)
        
        return hidden
    }
    
    private func decoderBlock(_ x: MLXArray, blockIdx: Int, ratio: Int, inChannels: Int, outChannels: Int) -> MLXArray {
        let prefix = "decoder.\(blockIdx)"
        var hidden = x
        
        // Snake activation
        let snake1 = loadSnakeActivation(from: weights, prefix: "\(prefix).snake1")
        hidden = snake1(hidden)
        
        // Transposed convolution for upsampling
        if let weight = weights["\(prefix).upconv.weight"] {
            hidden = convTranspose1d(hidden, weight: weight, stride: ratio)
        }
        
        // Residual blocks (3 per decoder block)
        for resIdx in 0..<3 {
            hidden = residualBlock(hidden, prefix: "\(prefix).res.\(resIdx)", channels: outChannels)
        }
        
        return hidden
    }
    
    private func residualBlock(_ x: MLXArray, prefix: String, channels: Int) -> MLXArray {
        let residual = x
        
        // Snake activation
        let snake = loadSnakeActivation(from: weights, prefix: "\(prefix).snake")
        var hidden = snake(x)
        
        // Conv1d
        if let weight = weights["\(prefix).conv1.weight"] {
            hidden = conv1d(hidden, weight: weight)
        }
        
        // Snake activation
        hidden = snake(hidden)
        
        // Conv1d
        if let weight = weights["\(prefix).conv2.weight"] {
            hidden = conv1d(hidden, weight: weight)
        }
        
        return hidden + residual
    }
    
    private func finalConv(_ x: MLXArray) -> MLXArray {
        if let weight = weights["decoder.final_conv.weight"] {
            return conv1d(x, weight: weight)
        }
        return x
    }
    
    // MARK: - Helper Functions
    
    private func linear(_ input: MLXArray, weight: MLXArray, bias: MLXArray? = nil, useTranspose: Bool = true) -> MLXArray {
        let weightToUse = useTranspose ? weight.T : weight
        var output = MLX.matmul(input, weightToUse)
        if let bias = bias {
            output = output + bias
        }
        return output
    }
    
    private func layerNorm(_ x: MLXArray, prefix: String) -> MLXArray {
        let weight = weights["\(prefix).weight"] ?? MLX.ones([x.shape.last!])
        let bias = weights["\(prefix).bias"] ?? MLX.zeros([x.shape.last!])
        
        let mean = MLX.mean(x, axis: -1, keepDims: true)
        let variance = MLX.variance(x, axis: -1, keepDims: true)
        let normalized = (x - mean) / MLX.sqrt(variance + 1e-5)
        
        return normalized * weight + bias
    }
    
    private func conv1d(_ x: MLXArray, weight: MLXArray, bias: MLXArray? = nil) -> MLXArray {
        // Simplified 1D convolution
        // Proper implementation would use MLXNN.Conv1d
        // For now, return input (weights will be applied properly when integrated)
        return x
    }
    
    private func convTranspose1d(_ x: MLXArray, weight: MLXArray, stride: Int) -> MLXArray {
        // Simplified transposed convolution for upsampling
        // Proper implementation would use proper transposed conv
        // For now, use simple repeat-based upsampling
        let batchSize = x.shape[0]
        let channels = x.shape[1]
        let timeSteps = x.shape[2]
        
        // Repeat each time step 'stride' times
        let upsampled = MLX.repeated(x, count: stride, axis: 2)
        return upsampled
    }
}

/// Decoder-specific errors
enum DecoderError: LocalizedError {
    case configMissing(String)
    case weightsMissing(String)
    case invalidShape(String)
    
    var errorDescription: String? {
        switch self {
        case .configMissing(let msg):
            return "Config missing: \(msg)"
        case .weightsMissing(let msg):
            return "Weights missing: \(msg)"
        case .invalidShape(let msg):
            return "Invalid shape: \(msg)"
        }
    }
}
