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
struct ResidualVectorQuantizer: @unchecked Sendable {
    nonisolated(unsafe) let numQuantizers: Int
    nonisolated(unsafe) let codebookSize: Int
    nonisolated(unsafe) let codebookDim: Int
    nonisolated(unsafe) let codebooks: [MLXArray]  // Array of [codebook_size, codebook_dim]
    
    /// Initialize RVQ with pre-trained codebooks
    /// - Parameters:
    ///   - numQuantizers: Number of quantizer levels (typically 16)
    ///   - codebookSize: Size of each codebook (typically 2048)
    ///   - codebookDim: Dimension of codebook vectors (typically 256 or 512)
    ///   - codebooks: Pre-trained codebook embeddings
    nonisolated init(numQuantizers: Int, codebookSize: Int, codebookDim: Int, codebooks: [MLXArray]) {
        self.numQuantizers = numQuantizers
        self.codebookSize = codebookSize
        self.codebookDim = codebookDim
        self.codebooks = codebooks
    }
    
    /// Decode audio codes to embeddings
    /// - Parameter codes: Audio codes [batch, num_quantizers, seq_len]
    /// - Returns: Embeddings [batch, seq_len, latent_dim]
    nonisolated func decode(_ codes: MLXArray) -> MLXArray {
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
            // Ensure indices are int32 for take operation
            let indices = codesFlat.asType(.int32)
            let embeddingsFlat = MLX.take(codebook, indices, axis: 0)
            // Ensure embeddings are float32
            let embeddingsFlatFloat = embeddingsFlat.asType(.float32)
            
            // Reshape back: [batch, seq_len, codebook_dim]
            let embeddingsQ = embeddingsFlatFloat.reshaped(batchSize, seqLen, codebookDim)
            
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
nonisolated func loadResidualVectorQuantizer(
    from weights: [String: MLXArray],
    numQuantizers: Int,
    codebookSize: Int,
    codebookDim: Int,
    prefix: String = "quantizer.rvq"
) -> ResidualVectorQuantizer {
    var codebooks: [MLXArray] = []
    var actualCodebookDim = codebookDim
    
    for q in 0..<numQuantizers {
        var codebook: MLXArray? = nil
        
        // Try multiple key formats:
        // 1. Original format: "quantizer.rvq.layers.X.codebook.weight"
        let originalKey = "\(prefix).layers.\(q).codebook.weight"
        codebook = weights[originalKey]
        
        // 2. Qwen3-TTS format with split RVQ:
        // - First quantizer: "quantizer.rvq_first.vq.layers.0._codebook.embedding_sum"
        // - Rest quantizers: "quantizer.rvq_rest.vq.layers.X._codebook.embedding_sum"
        if codebook == nil {
            if q == 0 {
                // Try first quantizer
                let firstKey = "quantizer.rvq_first.vq.layers.0._codebook.embedding_sum"
                codebook = weights[firstKey]
            } else {
                // Try rest quantizers (indexed from 0)
                let restKey = "quantizer.rvq_rest.vq.layers.\(q - 1)._codebook.embedding_sum"
                codebook = weights[restKey]
            }
        }
        
        if let codebook = codebook {
            // Check actual shape on first codebook
            if q == 0 {
                actualCodebookDim = codebook.shape[1]
                if actualCodebookDim != codebookDim {
                    print("⚠️ Warning: Codebook dimension mismatch!")
                    print("   Config expects: \(codebookDim)")
                    print("   Actual weights: \(actualCodebookDim)")
                    print("   Codebook shape: \(codebook.shape)")
                    print("   Using actual dimension: \(actualCodebookDim)")
                }
            }
            codebooks.append(codebook)
        } else {
            // Fallback: create zero codebook (should not happen with proper weights)
            print("⚠️ Warning: Codebook \(q) not found, using zero initialization")
            let zeroCodebook = MLX.zeros([codebookSize, actualCodebookDim])
            codebooks.append(zeroCodebook)
        }
    }
    
    print("✓ Loaded \(codebooks.count) codebooks with dimension \(actualCodebookDim)")
    
    return ResidualVectorQuantizer(
        numQuantizers: numQuantizers,
        codebookSize: codebookSize,
        codebookDim: actualCodebookDim,  // Use actual dimension from weights
        codebooks: codebooks
    )
}
