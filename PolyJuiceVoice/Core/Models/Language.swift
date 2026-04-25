//
//  Language.swift
//  PolyJuiceVoice
//

import Foundation

enum Language: String, CaseIterable, Codable, Sendable, Hashable {
    case english = "English"
    case chinese = "Chinese"
    case japanese = "Japanese"
    case korean = "Korean"
    case spanish = "Spanish"
    case french = "French"
    case german = "German"

    var code: String {
        switch self {
        case .english: return "en"
        case .chinese: return "zh"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .spanish: return "es"
        case .french: return "fr"
        case .german: return "de"
        }
    }
}
