//
//  TTSTypes.swift
//  VoiceClone
//
//  Common types for TTS services.
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

/// What the user wants to do — each capability maps to a backing model snapshot.
enum TTSCapability: Hashable, CaseIterable {
    /// Synthesize with one of the built-in preset speakers, optionally
    /// modulated by a free-form `instruct` style description (CustomVoice).
    case customVoice
    /// Generate a brand-new voice from a free-form description, no preset
    /// speaker required (VoiceDesign).
    case voiceDesign
    /// Clone a voice from a user-supplied reference audio + transcript (Base).
    case voiceClone

    /// The model snapshot that backs this capability.
    var requiredSnapshot: ModelSnapshot {
        switch self {
        case .customVoice: return .customVoice
        case .voiceDesign: return .voiceDesign
        case .voiceClone:  return .base
        }
    }
}

/// TTS errors
enum TTSError: LocalizedError {
    case modelNotFound(TTSCapability)
    case snapshotNotInstalled(ModelSnapshot)
    case modelLoadFailed(String)
    case capabilityNotLoaded(TTSCapability)
    case modelNotLoaded
    case tokenizationFailed
    case synthesisError(String)
    case invalidReferenceAudio(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let capability):
            return "Model not found for capability: \(capability)"
        case .snapshotNotInstalled(let snapshot):
            return "\(snapshot.displayName) is not installed. Download it from the Model Manager."
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
        case .invalidReferenceAudio(let message):
            return "Invalid reference audio: \(message)"
        }
    }
}
