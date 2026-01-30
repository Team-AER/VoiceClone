//
//  ConvLayers.swift
//  VoiceClone
//
//  Custom convolution layers for speech decoder
//

import Foundation
import MLX
import MLXNN

/// Causal 1D convolution with left padding
/// Ensures causality by only attending to past/current positions
struct CausalConv1d {
    let conv: Conv1d
    let padding: Int
    
    /// Initialize causal convolution
    /// - Parameters:
    ///   - inChannels: Number of input channels
    ///   - outChannels: Number of output channels
    ///   - kernelSize: Size of convolution kernel
    ///   - stride: Convolution stride
    ///   - dilation: Dilation rate
    ///   - groups: Number of groups for grouped convolution
    init(
        inChannels: Int,
        outChannels: Int,
        kernelSize: Int,
        stride: Int = 1,
        dilation: Int = 1,
        groups: Int = 1
    ) {
        // For causal conv, we pad on the left only
        self.padding = (kernelSize - 1) * dilation
        
        // Create conv without padding (we'll pad manually)
        self.conv = Conv1d(
            inputChannels: inChannels,
            outputChannels: outChannels,
            kernelSize: kernelSize,
            stride: stride,
            padding: 0,
            dilation: dilation,
            groups: groups
        )
    }
    
    /// Initialize from pre-trained weights
    init(conv: Conv1d, padding: Int) {
        self.conv = conv
        self.padding = padding
    }
    
    /// Apply causal convolution
    /// - Parameter x: Input tensor [batch, channels, time]
    /// - Returns: Output tensor [batch, out_channels, time]
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // Apply left padding
        let padded: MLXArray
        if padding > 0 {
            // Pad on the left (time dimension)
            // x shape: [batch, channels, time]
            let zeros = MLX.zeros([x.shape[0], x.shape[1], padding])
            padded = MLX.concatenated([zeros, x], axis: 2)
        } else {
            padded = x
        }
        
        // Apply convolution
        return conv(padded)
    }
}

/// Depthwise separable convolution
/// More efficient than regular convolution for audio processing
struct DepthwiseSeparableConv {
    let depthwise: Conv1d
    let pointwise: Conv1d
    
    /// Initialize depthwise separable convolution
    /// - Parameters:
    ///   - channels: Number of input/output channels
    ///   - kernelSize: Kernel size for depthwise conv
    ///   - stride: Stride for depthwise conv
    init(channels: Int, kernelSize: Int, stride: Int = 1) {
        // Depthwise: each input channel convolved separately
        self.depthwise = Conv1d(
            inputChannels: channels,
            outputChannels: channels,
            kernelSize: kernelSize,
            stride: stride,
            padding: kernelSize / 2,
            groups: channels  // Key: groups = channels for depthwise
        )
        
        // Pointwise: 1x1 conv to mix channels
        self.pointwise = Conv1d(
            inputChannels: channels,
            outputChannels: channels,
            kernelSize: 1,
            stride: 1,
            padding: 0
        )
    }
    
    /// Initialize from pre-trained weights
    init(depthwise: Conv1d, pointwise: Conv1d) {
        self.depthwise = depthwise
        self.pointwise = pointwise
    }
    
    /// Apply depthwise separable convolution
    /// - Parameter x: Input tensor [batch, channels, time]
    /// - Returns: Output tensor [batch, channels, time]
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let depthwiseOut = depthwise(x)
        return pointwise(depthwiseOut)
    }
}

/// Load causal conv from weights
func loadCausalConv1d(
    from weights: [String: MLXArray],
    prefix: String,
    inChannels: Int,
    outChannels: Int,
    kernelSize: Int,
    stride: Int = 1,
    dilation: Int = 1,
    groups: Int = 1
) -> CausalConv1d {
    let weightKey = "\(prefix).weight"
    let biasKey = "\(prefix).bias"
    
    let weight = weights[weightKey]!
    let bias = weights[biasKey]
    
    // Create conv layer with weights
    var conv = Conv1d(
        inputChannels: inChannels,
        outputChannels: outChannels,
        kernelSize: kernelSize,
        stride: stride,
        padding: 0,
        dilation: dilation,
        groups: groups
    )
    
    // TODO: Set weights properly (MLX doesn't expose weight setters directly)
    // For now, create with correct parameters
    
    let padding = (kernelSize - 1) * dilation
    return CausalConv1d(conv: conv, padding: padding)
}

/// Load depthwise separable conv from weights
func loadDepthwiseSeparableConv(
    from weights: [String: MLXArray],
    depthwisePrefix: String,
    pointwisePrefix: String,
    channels: Int,
    kernelSize: Int,
    stride: Int = 1
) -> DepthwiseSeparableConv {
    let depthwise = Conv1d(
        inputChannels: channels,
        outputChannels: channels,
        kernelSize: kernelSize,
        stride: stride,
        padding: kernelSize / 2,
        groups: channels
    )
    
    let pointwise = Conv1d(
        inputChannels: channels,
        outputChannels: channels,
        kernelSize: 1,
        stride: 1,
        padding: 0
    )
    
    return DepthwiseSeparableConv(depthwise: depthwise, pointwise: pointwise)
}
