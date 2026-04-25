//
//  DiskSpace.swift
//  PolyJuiceVoice
//
//  Free-space query for the volume that hosts a given URL. Used by the
//  download manager to refuse a 4–5 GB snapshot pull when the user's disk
//  cannot fit it, instead of half-downloading and failing on disk-full.
//

import Foundation

enum DiskSpace {

    /// Bytes free on the volume that owns `url`. Returns `nil` if the
    /// query failed (very rare — usually only when the URL doesn't exist
    /// yet, which we treat as "unknown, allow").
    static func availableBytes(at url: URL) -> Int64? {
        // The URL may not exist yet (e.g. snapshot dir we're about to create).
        // Walk up to the first ancestor that does.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent == probe { return nil }
            probe = parent
        }
        do {
            let values = try probe.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return Int64(capacity)
            }
        } catch {
            return nil
        }
        return nil
    }

    /// Convenience: confirm `requiredBytes` will fit on the volume hosting
    /// `url`, with a 200 MB safety margin so we never wedge the OS.
    static func hasRoomFor(_ requiredBytes: Int64, at url: URL) -> Bool {
        guard let free = availableBytes(at: url) else {
            // Unknown — let the download attempt and surface a real OS error.
            return true
        }
        let safetyMargin: Int64 = 200 * 1024 * 1024
        return free >= requiredBytes + safetyMargin
    }

    /// Render a byte count for user messages: "4.2 GB".
    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
