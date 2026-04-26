//
//  VoiceEntity.swift
//  PolyJuiceVoice
//

import CoreData

@objc(VoiceEntity)
final class VoiceEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var name: String?
    @NSManaged var type: String?
    @NSManaged var language: String?
    @NSManaged var createdAt: Date?
    @NSManaged var instruction: String?
    // TODO: Delete modelVersion after all users have been on iCloud-enabled
    // builds for 3+ months.
    @NSManaged var modelVersion: String?
}

extension VoiceEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<VoiceEntity> {
        NSFetchRequest<VoiceEntity>(entityName: "VoiceEntity")
    }
}
