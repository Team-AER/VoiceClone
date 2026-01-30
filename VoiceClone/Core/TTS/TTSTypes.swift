//
//  TTSTypes.swift
//  VoiceClone
//
//  Common types for TTS services
//

import Foundation

/// TTS service state
enum TTSServiceState: Equatable {
    case idle
    case loading
    case ready
    case synthesizing(progress: Double)
    case error(String)
}

/// TTS capabilities
enum TTSCapability: Hashable {
    case voiceDesign
    case customVoice
    case voiceClone
}

/// TTS errors
enum TTSError: LocalizedError {
    case modelNotFound(TTSCapability)
    case modelLoadFailed(String)
    case capabilityNotLoaded(TTSCapability)
    case modelNotLoaded
    case tokenizationFailed
    case synthesisError(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotFound(let capability):
            return "Model not found for capability: \(capability)"
        case .modelLoadFailed(let message):
            return "Failed to load model: \(message)"
        case .capabilityNotLoaded(let capability):
            return "Capability not loaded: \(capability)"
        case .modelNotLoaded:
            return "Model not loaded"
        case .tokenizationFailed:
            return "Tokenization failed"
        case .synthesisError(let message):
            return "Synthesis error: \(message)"
        }
    }
}
