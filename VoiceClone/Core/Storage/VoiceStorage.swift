//
//  VoiceStorage.swift
//  VoiceClone
//

import Foundation
import CoreData

/// Manages voice persistence
actor VoiceStorage {

    private let coreData = CoreDataStack.shared
    private let fileManager = FileManager.default
    private let voicesDirectory: URL

    init() {
        voicesDirectory = fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voices", isDirectory: true)

        try? fileManager.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)
    }

    func saveVoice(_ voice: Voice) async throws {
        try await coreData.performBackgroundTask { context in
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
        try await coreData.performBackgroundTask { context in
            let request = VoiceEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \VoiceEntity.createdAt, ascending: false)]

            let entities = try context.fetch(request)

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

                return Voice(
                    id: id,
                    name: name,
                    type: type,
                    language: language,
                    createdAt: createdAt,
                    instruction: entity.instruction,
                    referenceAudioURL: nil,
                    embeddingData: nil
                )
            }
        }
    }

    func deleteVoice(_ id: UUID) async throws {
        try await coreData.performBackgroundTask { context in
            let request = VoiceEntity.fetchRequest()
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
