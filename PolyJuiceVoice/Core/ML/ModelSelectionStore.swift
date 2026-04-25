//
//  ModelSelectionStore.swift
//  PolyJuiceVoice
//
//  Per-capability snapshot selection. The user picks "for voice cloning,
//  use 1.7B Base bf16" in the Model Manager and the choice persists across
//  launches in `UserDefaults`. Feature view models query
//  `selectedSnapshot(for:)` to know which on-disk variant to load.
//
//  No defaults: an unset capability resolves to `nil`, and the UI directs
//  the user back to the Model Manager.
//

import Combine
import Foundation

@MainActor
final class ModelSelectionStore: ObservableObject {

    /// Per-capability chosen snapshot, keyed by capability rawValue,
    /// valued by snapshot directoryName. Mirrored to UserDefaults.
    @Published private(set) var selections: [TTSCapability: ModelSnapshot] = [:]

    private let defaults: UserDefaults
    private let storageKey = "ModelSelectionStore.selections.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Public API

    /// The snapshot the user has chosen to back this capability, or `nil` if
    /// nothing is configured. Caller should prompt the user to open the
    /// Model Manager when this returns `nil`.
    func selected(for capability: TTSCapability) -> ModelSnapshot? {
        selections[capability]
    }

    /// Pick a snapshot for a capability. Validates that the snapshot is
    /// actually compatible — guards against a stale UI handing us an
    /// invalid pair.
    func select(_ snapshot: ModelSnapshot, for capability: TTSCapability) {
        guard capability.acceptedSnapshotCapabilities.contains(snapshot.capability) else {
            AppLog.warning(
                "Refusing to select \(snapshot.displayName) for \(capability.displayName) — not compatible.",
                "selection"
            )
            return
        }
        selections[capability] = snapshot
        persist()
    }

    /// Clear the user's selection for a capability — used when the user
    /// deletes the snapshot they had picked.
    func clear(_ capability: TTSCapability) {
        selections.removeValue(forKey: capability)
        persist()
    }

    /// If the user picked a snapshot that has since been deleted, drop the
    /// selection so the UI re-prompts. Called by `ModelDownloadManager`
    /// after a delete.
    func dropSelectionsReferencing(_ snapshot: ModelSnapshot) {
        var changed = false
        for (cap, snap) in selections where snap == snapshot {
            selections.removeValue(forKey: cap)
            changed = true
        }
        if changed { persist() }
    }

    /// When a snapshot finishes installing, claim it as the active variant
    /// for any compatible capability that doesn't already have one. Avoids
    /// the footgun of "user downloaded a model but the tab still says
    /// 'needs setup'" — they can always reassign explicitly via the
    /// manager's "Use this" button.
    func autoSelectIfUnconfigured(_ snapshot: ModelSnapshot) {
        var changed = false
        for capability in TTSCapability.allCases
        where capability.acceptedSnapshotCapabilities.contains(snapshot.capability) {
            if selections[capability] == nil {
                selections[capability] = snapshot
                changed = true
            }
        }
        if changed {
            AppLog.info("Auto-selected \(snapshot.displayName) for newly-uncovered capabilities.", "selection")
            persist()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let raw = defaults.dictionary(forKey: storageKey) as? [String: String] else {
            return
        }
        var loaded: [TTSCapability: ModelSnapshot] = [:]
        for (capKey, snapKey) in raw {
            guard let cap = TTSCapability(rawValue: capKey),
                  let snap = ModelSnapshot.find(directoryName: snapKey) else {
                continue
            }
            loaded[cap] = snap
        }
        selections = loaded
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: selections.map {
            ($0.key.rawValue, $0.value.directoryName)
        })
        defaults.set(raw, forKey: storageKey)
    }
}
