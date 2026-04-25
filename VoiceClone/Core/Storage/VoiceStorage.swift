//
//  VoiceStorage.swift
//  VoiceClone
//

import Foundation
import CoreData

/// Manages voice persistence
actor VoiceStorage {

    private let fileManager = FileManager.default
    private let voicesDirectory: URL

    init() {
        let fm = FileManager.default
        voicesDirectory = fm
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voices", isDirectory: true)

        try? fm.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)
    }

    func saveVoice(_ voice: Voice) async throws {
        try await CoreDataStack.shared.performBackgroundTask { context in
            let entity = VoiceEntity(context: context)
            entity.id = voice.id
            entity.name = voice.name
            entity.type = voice.type.rawValue
            entity.language = voice.language.rawValue
            entity.createdAt = voice.createdAt
            entity.instruction = voice.instruction

            try context.save()
        }

        if let audioURL = voice.referenceAudioURL {
            let destURL = voicesDirectory.appendingPathComponent("\(voice.id).wav")
            if fileManager.fileExists(atPath: destURL.path) {
                try? fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: audioURL, to: destURL)
        }

        if let embedding = voice.embeddingData {
            let embeddingURL = voicesDirectory.appendingPathComponent("\(voice.id).embedding")
            try embedding.write(to: embeddingURL)
        }
    }

    func fetchVoices() async throws -> [Voice] {
        let dir = voicesDirectory
        return try await CoreDataStack.shared.performBackgroundTask { context in
            let request = NSFetchRequest<VoiceEntity>(entityName: "VoiceEntity")
            request.sortDescriptors = [NSSortDescriptor(keyPath: \VoiceEntity.createdAt, ascending: false)]

            let entities = try context.fetch(request)
            // FileManager.default is fine off-actor; we don't capture self.
            let fm = FileManager.default

            return entities.compactMap { entity -> Voice? in
                guard let id = entity.id,
                      let name = entity.name,
                      let typeRaw = entity.type,
                      let type = Voice.VoiceType(rawValue: typeRaw),
                      let langRaw = entity.language,
                      let language = Language(rawValue: langRaw),
                      let createdAt = entity.createdAt else {
                    return nil
                }

                // Hydrate reference audio + embedding from disk.
                let audioURL = dir.appendingPathComponent("\(id).wav")
                let referenceAudioURL = fm.fileExists(atPath: audioURL.path) ? audioURL : nil
                let embeddingURL = dir.appendingPathComponent("\(id).embedding")
                let embeddingData = fm.fileExists(atPath: embeddingURL.path)
                    ? try? Data(contentsOf: embeddingURL)
                    : nil

                return Voice(
                    id: id,
                    name: name,
                    type: type,
                    language: language,
                    createdAt: createdAt,
                    instruction: entity.instruction,
                    referenceAudioURL: referenceAudioURL,
                    embeddingData: embeddingData
                )
            }
        }
    }

    /// Load the on-disk reference audio bytes for a saved voice.
    /// Returns nil when the voice has no reference recording (e.g. an
    /// instruction-only "designed" voice).
    func referenceAudioData(for voiceID: UUID) async throws -> Data? {
        let url = voicesDirectory.appendingPathComponent("\(voiceID).wav")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Delete Core Data entities whose backing files no longer exist on
    /// disk. Called at app launch so the Library tab never shows a voice
    /// that would silently fail to play. Returns the number of entities
    /// removed (for logging).
    @discardableResult
    func pruneOrphans() async throws -> Int {
        let dir = voicesDirectory
        return try await CoreDataStack.shared.performBackgroundTask { context in
            let request = NSFetchRequest<VoiceEntity>(entityName: "VoiceEntity")
            let entities = try context.fetch(request)
            let fm = FileManager.default
            var removed = 0
            for entity in entities {
                guard let id = entity.id, let typeRaw = entity.type,
                      let type = Voice.VoiceType(rawValue: typeRaw) else {
                    // Unrecognised entity — drop it, it can never be rendered.
                    context.delete(entity)
                    removed += 1
                    continue
                }
                // Cloned voices need an on-disk reference recording. Designed
                // and preset voices don't.
                if type == .cloned {
                    let audioURL = dir.appendingPathComponent("\(id).wav")
                    if !fm.fileExists(atPath: audioURL.path) {
                        context.delete(entity)
                        removed += 1
                    }
                }
            }
            if removed > 0 {
                try context.save()
            }
            return removed
        }
    }

    func deleteVoice(_ id: UUID) async throws {
        try await CoreDataStack.shared.performBackgroundTask { context in
            let request = NSFetchRequest<VoiceEntity>(entityName: "VoiceEntity")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

            if let entity = try context.fetch(request).first {
                context.delete(entity)
                try context.save()
            }
        }

        let audioURL = voicesDirectory.appendingPathComponent("\(id).wav")
        let embeddingURL = voicesDirectory.appendingPathComponent("\(id).embedding")

        try? fileManager.removeItem(at: audioURL)
        try? fileManager.removeItem(at: embeddingURL)
    }
}
