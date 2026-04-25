//
//  DIContainer.swift
//  VoiceClone
//

import Combine
import SwiftUI

@MainActor
final class DIContainer: ObservableObject {
    let ttsService: MLXTTSService
    let audioEngine: AudioEngine
    let voiceStorage: VoiceStorage

    init() {
        let audioEngine = AudioEngine()
        self.audioEngine = audioEngine
        self.voiceStorage = VoiceStorage()
        self.ttsService = MLXTTSService(audioEngine: audioEngine)
    }
}

private struct DIContainerKey: EnvironmentKey {
    static let defaultValue: DIContainer = MainActor.assumeIsolated { DIContainer() }
}

extension EnvironmentValues {
    @MainActor
    var container: DIContainer {
        get { self[DIContainerKey.self] }
        set { self[DIContainerKey.self] = newValue }
    }
}
