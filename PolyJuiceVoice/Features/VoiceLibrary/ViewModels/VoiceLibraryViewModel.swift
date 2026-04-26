//
//  VoiceLibraryViewModel.swift
//  PolyJuiceVoice
//

import Foundation
import Combine

@MainActor
final class VoiceLibraryViewModel: ObservableObject {

    @Published private(set) var voices: [Voice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    // Search and filter
    @Published var searchText: String = ""
    @Published var filterType: Voice.VoiceType? = nil
    @Published var filterLanguage: Language? = nil
    @Published var sortOption: SortOption = .dateDescending

    enum SortOption: String, CaseIterable {
        case dateDescending = "Newest First"
        case dateAscending = "Oldest First"
        case nameAscending = "Name (A-Z)"
        case nameDescending = "Name (Z-A)"
    }

    var filteredVoices: [Voice] {
        var result = voices

        // Apply search filter
        if !searchText.isEmpty {
            result = result.filter { voice in
                voice.name.localizedCaseInsensitiveContains(searchText) ||
                voice.language.rawValue.localizedCaseInsensitiveContains(searchText) ||
                (voice.instruction?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        // Apply type filter
        if let filterType {
            result = result.filter { $0.type == filterType }
        }

        // Apply language filter
        if let filterLanguage {
            result = result.filter { $0.language == filterLanguage }
        }

        // Apply sorting
        switch sortOption {
        case .dateDescending:
            result.sort { $0.createdAt > $1.createdAt }
        case .dateAscending:
            result.sort { $0.createdAt < $1.createdAt }
        case .nameAscending:
            result.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .nameDescending:
            result.sort { $0.name.localizedCompare($1.name) == .orderedDescending }
        }

        return result
    }

    private var storage: VoiceStorage?
    private var remoteChangeCancellable: AnyCancellable?

    func setup(storage: VoiceStorage) async {
        self.storage = storage
        await loadVoices()

        // When iCloud sync is active, reload the library whenever CloudKit
        // delivers a change from another device.
        if ICloudSyncSettings.shared.activeAtStartup {
            remoteChangeCancellable = NotificationCenter.default
                .publisher(for: CoreDataStack.didReceiveRemoteChange)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { await self?.loadVoices() }
                }
        }
    }

    func loadVoices() async {
        guard let storage else { return }
        isLoading = true

        do {
            voices = try await storage.fetchVoices()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func deleteVoice(at offsets: IndexSet) {
        guard let storage else { return }
        let ids = offsets.compactMap { voices[$0].id }

        Task {
            for id in ids {
                try? await storage.deleteVoice(id)
            }
            await loadVoices()
        }
    }

    func clearError() {
        error = nil
    }

    func clearFilters() {
        searchText = ""
        filterType = nil
        filterLanguage = nil
    }

    func setTypeFilter(_ type: Voice.VoiceType?) {
        filterType = type
    }

    func setLanguageFilter(_ language: Language?) {
        filterLanguage = language
    }

    func setSortOption(_ option: SortOption) {
        sortOption = option
    }

    var hasActiveFilters: Bool {
        !searchText.isEmpty || filterType != nil || filterLanguage != nil
    }
}
