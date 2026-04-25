//
//  CoreDataStack.swift
//  VoiceClone
//

import CoreData
import os

/// Thread-safe Core Data stack.
///
/// Initialization is **crash-free**: if the on-disk SQLite store cannot be
/// loaded (corruption, low disk, permissions), we fall back to an in-memory
/// store and surface `loadError` so the UI can warn the user that saved
/// voices won't persist this session — instead of taking the whole app down
/// with a `fatalError` the way the original implementation did.
final class CoreDataStack: @unchecked Sendable {

    static let shared = CoreDataStack()

    let container: NSPersistentContainer

    /// Non-nil when the persistent (SQLite) store failed to load and we
    /// fell back to an in-memory store. UI surfaces this as a warning
    /// banner; saves still succeed but only for the current process.
    private(set) var loadError: Error?

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    private static let logger = Logger(subsystem: "com.aer.polyjuicevoice", category: "coredata")

    private init() {
        let model = Self.loadModel()
        container = NSPersistentContainer(name: "VoiceClone", managedObjectModel: model)

        // Attempt the persistent (SQLite) load.
        var capturedError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        container.loadPersistentStores { _, error in
            capturedError = error
            semaphore.signal()
        }
        // `loadPersistentStores` is synchronous in practice but signals via
        // a callback. Wait briefly so we can react inline.
        _ = semaphore.wait(timeout: .now() + 5)

        if let error = capturedError {
            Self.logger.error("Persistent store load failed: \(error.localizedDescription, privacy: .public). Falling back to in-memory store.")
            self.loadError = error
            // Tear down any partially initialized stores.
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
            // Add an in-memory store so the app still functions for this session.
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            do {
                try container.persistentStoreCoordinator.addPersistentStore(
                    ofType: NSInMemoryStoreType,
                    configurationName: nil,
                    at: nil,
                    options: nil
                )
            } catch {
                // Even the in-memory store failed — extremely unusual. Log and
                // continue with an empty container; subsequent save() calls
                // will throw, which the UI can surface as an error alert.
                Self.logger.fault("In-memory fallback also failed: \(error.localizedDescription, privacy: .public)")
            }
            _ = description // silence unused warning when guard fails
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
    }

    func save() throws {
        guard viewContext.hasChanges else { return }
        try viewContext.save()
    }

    nonisolated func performBackgroundTask<T: Sendable>(_ block: @escaping @Sendable (NSManagedObjectContext) throws -> T) async throws -> T {
        try await container.performBackgroundTask { context in
            try block(context)
        }
    }

    private static func loadModel() -> NSManagedObjectModel {
        if let modelURL = Bundle.main.url(forResource: "VoiceClone", withExtension: "momd"),
           let model = NSManagedObjectModel(contentsOf: modelURL) {
            return model
        }

        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "VoiceEntity"
        entity.managedObjectClassName = NSStringFromClass(VoiceEntity.self)

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false

        let name = NSAttributeDescription()
        name.name = "name"
        name.attributeType = .stringAttributeType
        name.isOptional = false

        let type = NSAttributeDescription()
        type.name = "type"
        type.attributeType = .stringAttributeType
        type.isOptional = false

        let language = NSAttributeDescription()
        language.name = "language"
        language.attributeType = .stringAttributeType
        language.isOptional = false

        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false

        let instruction = NSAttributeDescription()
        instruction.name = "instruction"
        instruction.attributeType = .stringAttributeType
        instruction.isOptional = true

        entity.properties = [id, name, type, language, createdAt, instruction]
        model.entities = [entity]

        return model
    }
}
