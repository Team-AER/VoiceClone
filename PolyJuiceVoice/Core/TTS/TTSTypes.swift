//
//  TTSTypes.swift
//  PolyJuiceVoice
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

/// What the user wants to do. Each capability is satisfied by one of
/// potentially several `ModelSnapshot`s — the user picks which variant
/// (size × precision) to download in the Model Manager, and that selection
/// is resolved at runtime by `ModelSelectionStore`.
enum TTSCapability: String, Hashable, CaseIterable, Codable, Sendable {
    /// Synthesize with one of the built-in preset speakers, optionally
    /// modulated by a free-form `instruct` style description.
    /// Backed by either a `customVoice` or a `base` snapshot.
    case customVoice
    /// Generate a brand-new voice from a free-form description, no preset
    /// speaker required. Backed by a `voiceDesign` snapshot — only
    /// published at 1.7B.
    case voiceDesign
    /// Clone a voice from a user-supplied reference audio + transcript.
    /// Backed by a `base` snapshot.
    case voiceClone

    /// User-facing label for prompts and settings rows.
    var displayName: String {
        switch self {
        case .customVoice: return "Preset Voices"
        case .voiceDesign: return "Voice Design"
        case .voiceClone:  return "Voice Cloning"
        }
    }

    /// Which on-disk snapshot capabilities can satisfy this user-intent.
    /// `customVoice` accepts either a `customVoice` or a `base` snapshot,
    /// because the Base model can also run the preset path.
    var acceptedSnapshotCapabilities: Set<SnapshotCapability> {
        switch self {
        case .customVoice: return [.customVoice, .base]
        case .voiceClone:  return [.base]
        case .voiceDesign: return [.voiceDesign]
        }
    }

    /// All snapshots that can satisfy this capability — the candidate set
    /// the user picks from in the Model Manager.
    var compatibleSnapshots: [ModelSnapshot] {
        ModelSnapshot.allCases.filter {
            acceptedSnapshotCapabilities.contains($0.capability)
        }
    }
}

/// TTS errors
enum TTSError: LocalizedError {
    case modelNotFound(TTSCapability)
    /// The user's selected snapshot was deleted out from under us, or no
    /// snapshot has ever been selected for this capability.
    case capabilityNotConfigured(TTSCapability)
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
            return "Model not found for capability: \(capability.displayName)"
        case .capabilityNotConfigured(let capability):
            return "\(capability.displayName) needs a model. Open Model Manager to download one."
        case .snapshotNotInstalled(let snapshot):
            return "\(snapshot.displayName) is not installed. Download it from the Model Manager."
        case .modelLoadFailed(let message):
            return "Failed to load model: \(message)"
        case .capabilityNotLoaded(let capability):
            return "Capability not loaded: \(capability.displayName)"
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
