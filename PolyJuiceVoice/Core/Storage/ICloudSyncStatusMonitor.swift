//
//  ICloudSyncStatusMonitor.swift
//  PolyJuiceVoice
//

import Foundation
import Combine

/// Watches the iCloud Voices directory via NSMetadataQuery and exposes a
/// coarse sync status used by the Library toolbar indicator.
///
/// Only starts the query when iCloud sync is active at startup.
@MainActor
final class ICloudSyncStatusMonitor: ObservableObject {

    enum Status {
        case notEnabled     // iCloud sync is toggled off
        case notAvailable   // iCloud is on but container is unreachable (not signed in, etc.)
        case synced
        case syncing
    }

    @Published private(set) var status: Status = .notEnabled

    // nonisolated(unsafe) because deinit is nonisolated in Swift 6 and
    // NSMetadataQuery is not Sendable.  Safe in practice: this object is
    // always a @StateObject whose lifetime is managed on the main actor.
    nonisolated(unsafe) private var query: NSMetadataQuery?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        guard ICloudSyncSettings.shared.activeAtStartup else { return }
        startQuery()
    }

    deinit { query?.stop() }

    // MARK: - Private

    private func startQuery() {
        guard FileManager.default.url(
            forUbiquityContainerIdentifier: ICloudConfig.containerIdentifier
        ) != nil else {
            status = .notAvailable
            return
        }

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // Only watch voice asset files, not the whole container.
        q.predicate = NSPredicate(
            format: "%K ENDSWITH '.wav' OR %K ENDSWITH '.embedding'",
            NSMetadataItemFSNameKey,
            NSMetadataItemFSNameKey
        )
        self.query = q

        NotificationCenter.default
            .publisher(for: .NSMetadataQueryDidUpdate, object: q)
            .merge(with: NotificationCenter.default
                .publisher(for: .NSMetadataQueryDidFinishGathering, object: q))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        q.start()
        status = .synced
    }

    private func refresh() {
        guard let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }

        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem else { continue }

            let downloadStatus = item.value(
                forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey
            ) as? String
            let isUploading = item.value(
                forAttribute: NSMetadataUbiquitousItemIsUploadingKey
            ) as? Bool ?? false

            if downloadStatus != NSMetadataUbiquitousItemDownloadingStatusCurrent || isUploading {
                status = .syncing
                return
            }
        }

        status = .synced
    }
}
