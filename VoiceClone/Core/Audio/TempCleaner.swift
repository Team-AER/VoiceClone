//
//  TempCleaner.swift
//  VoiceClone
//
//  Sweeps the OS temp directory for stale recording / export / reference
//  audio files left behind by previous sessions (e.g. if the app crashed
//  before the user got a chance to share or save). Run once at app launch
//  from `MLXRuntime.bootstrap` (or wherever boot work lives).
//

import Foundation

enum TempCleaner {

    /// File-name prefixes the app writes into `temporaryDirectory`.
    /// Anything matching is fair game to evict if older than `maxAge`.
    private static let knownPrefixes = [
        "recording_",      // AudioRecorder
        "voiceclone_",     // AudioExporter, AudioEngine.decodeAudio
        "vc_ref_",         // MLXTTSService.loadReferenceAudio
    ]

    static let maxAge: TimeInterval = 24 * 60 * 60   // 24 h

    /// Sweep stale files. Best-effort — any IO error is logged and ignored.
    @discardableResult
    static func sweep() -> Int {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        var removed = 0

        guard let entries = try? fm.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        let cutoff = Date().addingTimeInterval(-maxAge)
        for url in entries {
            let name = url.lastPathComponent
            guard knownPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modDate, modDate >= cutoff { continue }
            do {
                try fm.removeItem(at: url)
                removed += 1
            } catch {
                AppLog.warning("TempCleaner: could not remove \(name): \(error.localizedDescription)", "app")
            }
        }
        if removed > 0 {
            AppLog.info("TempCleaner swept \(removed) stale file(s).", "app")
        }
        return removed
    }
}
