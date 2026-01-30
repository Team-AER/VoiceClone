//
//  Voice.swift
//  VoiceClone
//

import Foundation

struct Voice: Identifiable, Codable, Sendable {

    enum VoiceType: String, Codable, Sendable {
        case preset
        case custom
        case cloned
    }

    let id: UUID
    var name: String
    var type: VoiceType
    var language: Language
    var createdAt: Date
    var instruction: String?
    var referenceAudioURL: URL?
    var embeddingData: Data?
}
