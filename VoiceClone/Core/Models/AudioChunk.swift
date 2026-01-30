//
//  AudioChunk.swift
//  VoiceClone
//

import Foundation

struct AudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let timestamp: TimeInterval
}
