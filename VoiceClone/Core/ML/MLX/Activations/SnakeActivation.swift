//
//  SnakeActivation.swift
//  VoiceClone
//
//  Snake activation function for speech decoder
//  Formula: y = x + (1/β) * sin²(α * x)
//

import Foundation
import MLX

/// Snake activation with learnable alpha and beta parameters
/// Used in the Qwen3-TTS speech decoder for better audio quality
struct SnakeActivation {
    let alpha: MLXArray
    let beta: MLXArray
    
    /// Initialize Snake activation
    /// - Parameters:
    ///   - channels: Number of input channels
    ///   - alphaInit: Initial value for alpha (default: 1.0)
    ///   - betaInit: Initial value for beta (default: 1.0)
    init(channels: Int, alphaInit: Float = 1.0, betaInit: Float = 1.0) {
        self.alpha = MLX.full([channels], values: alphaInit)
        self.beta = MLX.full([channels], values: betaInit)
    }
    
    /// Initialize with pre-trained parameters
    init(alpha: MLXArray, beta: MLXArray) {
        self.alpha = alpha
        self.beta = beta
    }
    
    /// Apply Snake activation
    /// - Parameter x: Input tensor [batch, channels, time] or [batch, channels]
    /// - Returns: Activated tensor with same shape
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // Reshape alpha and beta to broadcast correctly
        // Input: [batch, channels, time] or [batch, channels]
        let ndim = x.ndim
        
        var alphaReshaped = alpha
        var betaReshaped = beta
        
        if ndim == 3 {
            // [channels] -> [1, channels, 1]
            alphaReshaped = alpha.reshaped(1, -1, 1)
            betaReshaped = beta.reshaped(1, -1, 1)
        } else if ndim == 2 {
            // [channels] -> [1, channels]
            alphaReshaped = alpha.reshaped(1, -1)
            betaReshaped = beta.reshaped(1, -1)
        }
        
        // Snake: y = x + (1/β) * sin²(α * x)
        let alphaX = alphaReshaped * x
        let sinAlphaX = MLX.sin(alphaX)
        let sin2AlphaX = sinAlphaX * sinAlphaX
        
        return x + (sin2AlphaX / betaReshaped)
    }
}

/// Load Snake activation parameters from weights dictionary
/// - Parameters:
///   - weights: Weight dictionary
///   - prefix: Prefix for parameter names (e.g., "decoder.1.snake1")
/// - Returns: SnakeActivation instance
func loadSnakeActivation(from weights: [String: MLXArray], prefix: String) -> SnakeActivation {
    let alpha = weights["\(prefix).alpha"] ?? MLX.ones([1])
    let beta = weights["\(prefix).beta"] ?? MLX.ones([1])
    return SnakeActivation(alpha: alpha, beta: beta)
}
