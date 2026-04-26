//
//  ICloudSyncSettings.swift
//  PolyJuiceVoice
//

import Foundation

/// Manages the user's opt-in iCloud sync preference.
///
/// `activeAtStartup` is a snapshot captured at process launch — CoreDataStack
/// and VoiceStorage key off this value and do not change behaviour mid-run.
/// `isEnabled` is the live toggle state shown in Settings. When they differ,
/// `pendingRestart` is true and the UI shows a "Restart required" notice.
@MainActor
final class ICloudSyncSettings: ObservableObject {

    static let shared = MainActor.assumeIsolated { ICloudSyncSettings() }

    /// Captured once at launch. Drives CoreDataStack + VoiceStorage init.
    let activeAtStartup: Bool

    /// Live value reflected by the Settings toggle.
    @Published private(set) var isEnabled: Bool

    /// True when the user toggled the switch since launch; restart is needed.
    var pendingRestart: Bool { isEnabled != activeAtStartup }

    private init() {
        let stored = UserDefaults.standard.bool(forKey: ICloudConfig.syncEnabledKey)
        self.activeAtStartup = stored
        self.isEnabled = stored
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: ICloudConfig.syncEnabledKey)
    }
}
