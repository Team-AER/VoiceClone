//
//  VoiceStorage.swift
//  PolyJuiceVoice
//

import Foundation
import CoreData

/// Manages voice persistence — metadata via Core Data, binary assets on disk.
///
/// When iCloud sync is active the binary assets live in the iCloud ubiquity
/// container (`<container>/Documents/Voices/`); otherwise they live in the
/// local Documents directory.  The directory is resolved lazily on the first
/// actor call so that `url(forUbiquityContainerIdentifier:)` — which may
/// block — runs on the actor's background executor rather than the main thread.
actor VoiceStorage {

    private let fileManager = FileManager.default
    private let useICloud: Bool

    // Resolved lazily on first actor method call; nil until then.
    private var _voicesDirectory: URL?

    init() {
        self.useICloud = UserDefaults.standard.bool(forKey: ICloudConfig.syncEnabledKey)
    }

    // MARK: - Directory resolution

    /// Returns the resolved voices directory, creating it if needed.
    ///
    /// Falls back to the local Documents directory when iCloud is unavailable
    /// (user not signed in, container not configured, etc.).
    private func voicesDirectory() -> URL {
        if let cached = _voicesDirectory { return cached }

        let url: URL
        if useICloud,
           let base = fileManager.url(
               forUbiquityContainerIdentifier: ICloudConfig.containerIdentifier
           ) {
            url = base.appendingPathComponent("Documents/Voices", isDirectory: true)
        } else {
            url = fileManager
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Voices", isDirectory: true)
        }

        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        _voicesDirectory = url
        return url
    }

    // MARK: - Write

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

        let dir = voicesDirectory()

        if let audioURL = voice.referenceAudioURL {
            let dest = dir.appendingPathComponent("\(voice.id).wav")
            if fileManager.fileExists(atPath: dest.path) {
                try? fileManager.removeItem(at: dest)
            }
            try fileManager.copyItem(at: audioURL, to: dest)
        }

        if let embedding = voice.embeddingData {
            let embeddingURL = dir.appendingPathComponent("\(voice.id).embedding")
            try embedding.write(to: embeddingURL)
        }
    }

    // MARK: - Read

    func fetchVoices() async throws -> [Voice] {
        // Capture actor state before entering the non-isolated closure.
        let dir = voicesDirectory()
        let iCloud = useICloud

        return try await CoreDataStack.shared.performBackgroundTask { context in
            let request = NSFetchRequest<VoiceEntity>(entityName: "VoiceEntity")
            request.sortDescriptors = [NSSortDescriptor(
                keyPath: \VoiceEntity.createdAt, ascending: false
            )]

            let entities = try context.fetch(request)
            let fm = FileManager.default

            return entities.compactMap { entity -> Voice? in
                guard let id = entity.id,
                      let name = entity.name,
                      let typeRaw = entity.type,
                      let type = Voice.VoiceType(rawValue: typeRaw),
                      let langRaw = entity.language,
                      let language = Language(rawValue: langRaw),
                      let createdAt = entity.createdAt else { return nil }

                // Binary assets return nil when the iCloud file hasn't synced
                // yet. Downloads are triggered lazily; the next library refresh
                // (after the remote-change notification fires) will pick them up.
                let audioURL = dir.appendingPathComponent("\(id).wav")
                let referenceAudioURL: URL? =
                    ubiquitousFileIsReady(audioURL, fm: fm, iCloud: iCloud)
                    ? audioURL : nil

                let embeddingURL = dir.appendingPathComponent("\(id).embedding")
                let embeddingData: Data?
                if ubiquitousFileIsReady(embeddingURL, fm: fm, iCloud: iCloud) {
                    embeddingData = try? Data(contentsOf: embeddingURL)
                } else {
                    // Kick off background download; available on next refresh.
                    try? fm.startDownloadingUbiquitousItem(at: embeddingURL)
                    embeddingData = nil
                }

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

    /// Load the on-disk reference audio for a saved voice, triggering an
    /// iCloud download if the file hasn't synced to this device yet.
    /// Returns nil when the voice has no reference recording.
    func referenceAudioData(for voiceID: UUID) async throws -> Data? {
        let url = voicesDirectory().appendingPathComponent("\(voiceID).wav")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        if useICloud {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
        }
        return try? Data(contentsOf: url)
    }

    // MARK: - Update

    /// Persist the serialized embedding blob for a voice that was previously
    /// saved without one. Called after the first synthesis to skip the encoder
    /// step on future calls.
    func updateEmbedding(_ data: Data, for voiceID: UUID) throws {
        let url = voicesDirectory().appendingPathComponent("\(voiceID).embedding")
        try data.write(to: url)
    }

    // MARK: - Delete

    func deleteVoice(_ id: UUID) async throws {
        try await CoreDataStack.shared.performBackgroundTask { context in
            let request = NSFetchRequest<VoiceEntity>(entityName: "VoiceEntity")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            if let entity = try context.fetch(request).first {
                context.delete(entity)
                try context.save()
            }
        }

        let dir = voicesDirectory()
        try? fileManager.removeItem(at: dir.appendingPathComponent("\(id).wav"))
        try? fileManager.removeItem(at: dir.appendingPathComponent("\(id).embedding"))
    }

    // MARK: - Maintenance

    /// Delete Core Data entities whose backing files no longer exist locally.
    ///
    /// Skipped when iCloud sync is active because file absence may mean
    /// "not yet downloaded" rather than "deleted" — CloudKit is the source
    /// of truth in that case.
    @discardableResult
    func pruneOrphans() async throws -> Int {
        guard !useICloud else { return 0 }

        let dir = voicesDirectory()
        return try await CoreDataStack.shared.performBackgroundTask { context in
            let request = NSFetchRequest<VoiceEntity>(entityName: "VoiceEntity")
            let entities = try context.fetch(request)
            let fm = FileManager.default
            var removed = 0
            for entity in entities {
                guard let id = entity.id,
                      let typeRaw = entity.type,
                      let type = Voice.VoiceType(rawValue: typeRaw) else {
                    context.delete(entity)
                    removed += 1
                    continue
                }
                // Cloned voices need an on-disk reference recording; designed
                // and preset voices don't.
                if type == .cloned {
                    let audioURL = dir.appendingPathComponent("\(id).wav")
                    if !fm.fileExists(atPath: audioURL.path) {
                        context.delete(entity)
                        removed += 1
                    }
                }
            }
            if removed > 0 { try context.save() }
            return removed
        }
    }

    // MARK: - iCloud migration (Phase 6)

    /// Move voice asset files from the local Documents directory into the
    /// iCloud container when the user first enables iCloud sync.
    ///
    /// Files already present at the destination are left untouched.
    /// Only runs when `useICloud` is true and the iCloud container resolved
    /// to a different path than the local directory.
    ///
    /// TODO: Delete this migration after all users have been on
    /// iCloud-enabled builds for 3+ months.
    func migrateLocalFilesToICloud() throws {
        guard useICloud else { return }

        let iCloudDir = voicesDirectory()
        let localDir = fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voices", isDirectory: true)

        // Guard against re-running when both paths resolve to the same place
        // (happens when iCloud container fell back to local storage).
        guard localDir.standardizedFileURL != iCloudDir.standardizedFileURL,
              fileManager.fileExists(atPath: localDir.path) else { return }

        let contents = (try? fileManager.contentsOfDirectory(
            at: localDir, includingPropertiesForKeys: nil
        )) ?? []

        for file in contents {
            let dest = iCloudDir.appendingPathComponent(file.lastPathComponent)
            guard !fileManager.fileExists(atPath: dest.path) else { continue }
            try? fileManager.moveItem(at: file, to: dest)
        }
    }
}

// MARK: - Free helpers (non-isolated; safe inside performBackgroundTask closures)

/// Returns true when the file exists locally and is fully downloaded.
///
/// For non-iCloud files the ubiquitous download-status attribute is absent;
/// the `guard` falls through and we return true (treat as ready).
private func ubiquitousFileIsReady(_ url: URL, fm: FileManager, iCloud: Bool) -> Bool {
    guard fm.fileExists(atPath: url.path) else { return false }
    guard iCloud else { return true }
    let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
    guard let status = values?.ubiquitousItemDownloadingStatus else { return true }
    return status == .current
}
