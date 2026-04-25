//
//  PresetVoice.swift
//  PolyJuiceVoice
//

import Foundation

enum PresetVoice: String, CaseIterable, Codable, Sendable {
    case ryan = "Ryan"
    case sara = "Sara"
    case kai = "Kai"
    case emma = "Emma"

    var embeddingId: Int {
        switch self {
        case .ryan: return 1001
        case .sara: return 1002
        case .kai: return 1003
        case .emma: return 1004
        }
    }
}
