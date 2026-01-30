//
//  VoiceEntity.swift
//  VoiceClone
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
}

extension VoiceEntity {
    @nonobjc class func fetchRequest() -> NSFetchRequest<VoiceEntity> {
        NSFetchRequest<VoiceEntity>(entityName: "VoiceEntity")
    }
}
