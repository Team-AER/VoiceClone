//
//  CoreDataStack.swift
//  PolyJuiceVoice
//

import CoreData
import os

/// Thread-safe Core Data stack with optional iCloud / CloudKit sync.
///
/// Initialization is crash-free: if the on-disk SQLite store fails to load,
/// we fall back to an in-memory store and surface `loadError` so the UI can
/// warn the user that saved voices won't persist this session.
///
/// iCloud sync is opt-in (default: off).  The container type is fixed at
/// class-load time — changes only take effect after a process restart, and
/// the Settings UI shows a "Restart required" notice when the preference
/// differs from the active startup value.
final class CoreDataStack: @unchecked Sendable {

    static let shared = CoreDataStack()

    /// Posted on the main queue whenever CloudKit delivers a remote change.
    /// `VoiceLibraryViewModel` observes this to refresh the library list.
    static let didReceiveRemoteChange = Notification.Name(
        "app.aer.PolyJuiceVoice.CoreDataStack.remoteChange"
    )

    let container: NSPersistentContainer

    /// Long-lived private-queue context for all off-main reads/writes.
    ///
    /// We deliberately avoid `container.performBackgroundTask { … }`:
    /// that API spins up a fresh context whose queue is fixed at background
    /// QoS, so @MainActor callers waiting on it trigger priority inversions.
    /// `NSManagedObjectContext.perform(_:)` propagates the awaiting task's
    /// QoS and serialises writes for free.
    let backgroundContext: NSManagedObjectContext

    /// Non-nil when the persistent store failed to load and we fell back to
    /// an in-memory store.  Saves still succeed for the current process.
    private(set) var loadError: Error?

    var viewContext: NSManagedObjectContext { container.viewContext }

    // Captured once at class-load time so the container type is stable for
    // the entire process lifetime.  Toggling iCloud sync in Settings only
    // takes effect after a process restart.
    private static let cloudKitEnabled: Bool = UserDefaults.standard
        .bool(forKey: ICloudConfig.syncEnabledKey)

    private static let logger = Logger(
        subsystem: "app.aer.PolyJuiceVoice", category: "coredata"
    )

    private init() {
        let model = Self.loadModel()

        // Choose the container type based on the startup preference.
        if Self.cloudKitEnabled {
            container = NSPersistentCloudKitContainer(
                name: "PolyJuiceVoice", managedObjectModel: model
            )
        } else {
            container = NSPersistentContainer(
                name: "PolyJuiceVoice", managedObjectModel: model
            )
        }

        // Configure the store description *before* loadPersistentStores.
        // History tracking and remote-change notifications are required for
        // CloudKit sync; they are harmless on the plain container.
        if let description = container.persistentStoreDescriptions.first {
            if Self.cloudKitEnabled {
                description.setOption(
                    true as NSNumber, forKey: NSPersistentHistoryTrackingKey
                )
                description.setOption(
                    true as NSNumber,
                    forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey
                )
                description.cloudKitContainerOptions =
                    NSPersistentCloudKitContainerOptions(
                        containerIdentifier: ICloudConfig.containerIdentifier
                    )
            }
        }

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
            Self.logger.error(
                "Persistent store load failed: \(error.localizedDescription, privacy: .public). Falling back to in-memory store."
            )
            self.loadError = error
            // Tear down any partially initialized stores.
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
            // Add an in-memory store so the app still functions this session.
            let desc = NSPersistentStoreDescription()
            desc.type = NSInMemoryStoreType
            do {
                try container.persistentStoreCoordinator.addPersistentStore(
                    ofType: NSInMemoryStoreType,
                    configurationName: nil,
                    at: nil,
                    options: nil
                )
            } catch {
                Self.logger.fault(
                    "In-memory fallback also failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump

        backgroundContext = container.newBackgroundContext()
        backgroundContext.automaticallyMergesChangesFromParent = true
        backgroundContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump

        // Forward CloudKit remote-change notifications so view models can
        // reload without polling.
        if Self.cloudKitEnabled {
            NotificationCenter.default.addObserver(
                forName: .NSPersistentStoreRemoteChange,
                object: container.persistentStoreCoordinator,
                queue: .main
            ) { _ in
                NotificationCenter.default.post(
                    name: CoreDataStack.didReceiveRemoteChange, object: nil
                )
            }
        }
    }

    func save() throws {
        guard viewContext.hasChanges else { return }
        try viewContext.save()
    }

    nonisolated func performBackgroundTask<T: Sendable>(
        _ block: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) async throws -> T {
        let context = backgroundContext
        return try await context.perform { try block(context) }
    }

    // MARK: - Model

    private static func loadModel() -> NSManagedObjectModel {
        if let modelURL = Bundle.main.url(forResource: "PolyJuiceVoice", withExtension: "momd"),
           let model = NSManagedObjectModel(contentsOf: modelURL) {
            return model
        }

        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "VoiceEntity"
        entity.managedObjectClassName = NSStringFromClass(VoiceEntity.self)

        func makeAttr(
            _ name: String,
            type: NSAttributeType,
            optional: Bool = false
        ) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            return a
        }

        entity.properties = [
            makeAttr("id",          type: .UUIDAttributeType),
            makeAttr("name",        type: .stringAttributeType),
            makeAttr("type",        type: .stringAttributeType),
            makeAttr("language",    type: .stringAttributeType),
            makeAttr("createdAt",   type: .dateAttributeType),
            makeAttr("instruction", type: .stringAttributeType, optional: true),
            // TODO: Delete modelVersion after all users have been on
            // iCloud-enabled builds for 3+ months.
            makeAttr("modelVersion", type: .stringAttributeType, optional: true),
        ]
        model.entities = [entity]
        return model
    }
}
