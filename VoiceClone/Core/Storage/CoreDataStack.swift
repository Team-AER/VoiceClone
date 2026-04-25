//
//  CoreDataStack.swift
//  VoiceClone
//

import CoreData

final class CoreDataStack: @unchecked Sendable {

    static let shared = CoreDataStack()

    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    private init() {
        let model = Self.loadModel()
        container = NSPersistentContainer(name: "VoiceClone", managedObjectModel: model)

        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Core Data failed to load: \(error)")
            }
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
