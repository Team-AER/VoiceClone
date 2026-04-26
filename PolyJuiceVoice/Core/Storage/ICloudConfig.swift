//
//  ICloudConfig.swift
//  PolyJuiceVoice
//

import Foundation

enum ICloudConfig {
    // MARK: - Project-specific constants — update if the bundle ID changes

    /// iCloud container identifier.
    ///
    /// Must match the container configured in:
    ///   • Apple Developer Portal → Identifiers → App IDs → iCloud Containers
    ///   • Xcode → Signing & Capabilities → iCloud → Containers (both targets)
    static let containerIdentifier = "iCloud.app.aer.PolyJuiceVoice"

    // MARK: - Internal

    static let syncEnabledKey = "icloudSyncEnabled"
}
