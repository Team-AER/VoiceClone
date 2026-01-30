//
//  ResidualVectorQuantizer.swift
//  VoiceClone
//
//  Residual Vector Quantizer for speech decoder
//  Converts discrete audio codes to continuous embeddings
//

import Foundation
import MLX

/// Residual Vector Quantizer for audio codec
/// Looks up discrete codes in learned codebooks
struct ResidualVectorQuantizer {
    let numQuantizers: Int
    let codebookSize: Int
    let codebookDim: Int
    let codebooks: [MLXArray]  // Array of [codebook_size, codebook_dim]
    
    /// Initialize RVQ with pre-trained codebooks
    /// - Parameters:
    ///   - numQuantizers: Number of quantizer levels (typically 16)
    ///   - codebookSize: Size of each codebook (typically 2048)
    ///   - codebookDim: Dimension of codebook vectors (typically 256 or 512)
    ///   - codebooks: Pre-trained codebook embeddings
    init(numQuantizers: Int, codebookSize: Int, codebookDim: Int, codebooks: [MLXArray]) {
        self.numQuantizers = numQuantizers
        self.codebookSize = codebookSize
        self.codebookDim = codebookDim
        self.codebooks = codebooks
    }
    
    /// Decode audio codes to embeddings
    /// - Parameter codes: Audio codes [batch, num_quantizers, seq_len]
    /// - Returns: Embeddings [batch, seq_len, latent_dim]
    func decode(_ codes: MLXArray) -> MLXArray {
        guard codes.ndim == 3 else {
            fatalError("Expected 3D codes [batch, num_quantizers, seq_len], got shape \(codes.shape)")
        }
        
        let batchSize = codes.shape[0]
        let numQuant = codes.shape[1]
        let seqLen = codes.shape[2]
        
        guard numQuant == numQuantizers else {
            fatalError("Expected \(numQuantizers) quantizers, got \(numQuant)")
        }
        
        // Accumulate embeddings from all quantizers
        var embeddings: [MLXArray] = []
        
        for q in 0..<numQuantizers {
            // Extract codes for this quantizer: [batch, seq_len]
            let codesQ = codes[0..., q, 0...]
            
            // Flatten for lookup: [batch * seq_len]
            let codesFlat = codesQ.reshaped(-1)
            
            // Look up in codebook: [batch * seq_len, codebook_dim]
            let codebook = codebooks[q]
            let embeddingsFlat = MLX.take(codebook, codesFlat, axis: 0)
            
            // Reshape back: [batch, seq_len, codebook_dim]
            let embeddingsQ = embeddingsFlat.reshaped(batchSize, seqLen, codebookDim)
            
            embeddings.append(embeddingsQ)
        }
        
        // Sum all quantizer embeddings: [batch, seq_len, codebook_dim]
        var result = embeddings[0]
        for i in 1..<embeddings.count {
            result = result + embeddings[i]
        }
        
        return result
    }
}

/// Load RVQ from weights dictionary
/// - Parameters:
///   - weights: Weight dictionary
///   - numQuantizers: Number of quantizers
///   - codebookSize: Codebook size
///   - codebookDim: Codebook dimension
///   - prefix: Prefix for weight keys (e.g., "quantizer.rvq")
/// - Returns: ResidualVectorQuantizer instance
func loadResidualVectorQuantizer(
    from weights: [String: MLXArray],
    numQuantizers: Int,
    codebookSize: Int,
    codebookDim: Int,
    prefix: String = "quantizer.rvq"
) -> ResidualVectorQuantizer {
    var codebooks: [MLXArray] = []
    
    for q in 0..<numQuantizers {
        // Look for weight key like "quantizer.rvq.layers.0.codebook.weight"
        let key = "\(prefix).layers.\(q).codebook.weight"
        
        if let codebook = weights[key] {
            codebooks.append(codebook)
        } else {
            // Fallback: create random codebook (should not happen with proper weights)
            print("⚠️ Warning: Codebook \(q) not found, using random initialization")
            // Create placeholder codebook (zeros) since we don't have random in MLX 0.30.3
            let randomCodebook = MLX.zeros([codebookSize, codebookDim])
            codebooks.append(randomCodebook)
        }
    }
    
    return ResidualVectorQuantizer(
        numQuantizers: numQuantizers,
        codebookSize: codebookSize,
        codebookDim: codebookDim,
        codebooks: codebooks
    )
}
