//
//  DIContainer.swift
//  PolyJuiceVoice
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
        let storage = VoiceStorage()
        self.voiceStorage = storage
        self.ttsService = MLXTTSService(audioEngine: audioEngine)

        // Clean up orphaned voice rows (Core Data entities whose backing
        // .wav was deleted out from under us) so the Library never shows
        // a voice that would silently fail.
        Task.detached(priority: .background) {
            do {
                let removed = try await storage.pruneOrphans()
                if removed > 0 {
                    AppLog.info("Pruned \(removed) orphaned voice(s) from the library.", "storage")
                }
            } catch {
                AppLog.warning("Voice library prune failed: \(error.localizedDescription)", "storage")
            }
        }
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
