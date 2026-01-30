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
