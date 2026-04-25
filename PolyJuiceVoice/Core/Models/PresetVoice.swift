//
//  PresetVoice.swift
//  PolyJuiceVoice
//

import Foundation

/// Built-in preset speakers shipped with the model.
/// rawValue must match a key in talkerConfig.spkId (case-insensitive).
/// Available model speakers: vivian, ono_anna, aiden, serena, sohee, uncle_fu, eric, ryan, dylan
enum PresetVoice: String, CaseIterable, Codable, Sendable {
    case ryan = "Ryan"
    case vivian = "Vivian"
    case aiden = "Aiden"
    case serena = "Serena"
}
