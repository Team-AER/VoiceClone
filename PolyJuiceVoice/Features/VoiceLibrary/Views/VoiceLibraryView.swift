//
//  VoiceLibraryView.swift
//  PolyJuiceVoice
//

import SwiftUI

struct VoiceLibraryView: View {

    @StateObject private var viewModel = VoiceLibraryViewModel()
    @StateObject private var syncMonitor = ICloudSyncStatusMonitor()
    @EnvironmentObject var container: DIContainer

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView("Loading voices...")
                } else if viewModel.voices.isEmpty {
                    ContentUnavailableView(
                        "No voices",
                        systemImage: "person.wave.2",
                        description: Text("Record or design a voice to see it here.")
                    )
                } else if viewModel.filteredVoices.isEmpty {
                    ContentUnavailableView(
                        "No matching voices",
                        systemImage: "magnifyingglass",
                        description: Text("Try adjusting your search or filters.")
                    )
                } else {
                    List {
                        ForEach(viewModel.filteredVoices) { voice in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(voice.name)
                                    .fontWeight(.medium)
                                Text("\(voice.type.rawValue.capitalized) • \(voice.language.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let instruction = voice.instruction, !instruction.isEmpty {
                                    Text(instruction)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .onDelete(perform: viewModel.deleteVoice)
                    }
                    .searchable(text: $viewModel.searchText, prompt: "Search voices")
                }
            }
            .navigationTitle("Library")
            .toolbar {
                // iCloud sync status — only shown when sync is active.
                if ICloudSyncSettings.shared.activeAtStartup {
                    ToolbarItem(placement: .automatic) {
                        syncStatusIndicator
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        sortMenu
                        Divider()
                        typeFilterMenu
                        Divider()
                        languageFilterMenu
                        Divider()
                        if viewModel.hasActiveFilters {
                            Button("Clear Filters", systemImage: "xmark.circle") {
                                viewModel.clearFilters()
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: viewModel.hasActiveFilters
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .task {
                await viewModel.setup(storage: container.voiceStorage)
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK") { viewModel.clearError() }
            } message: {
                Text(viewModel.error ?? "")
            }
        }
    }

    // MARK: - Sync indicator

    @ViewBuilder
    private var syncStatusIndicator: some View {
        switch syncMonitor.status {
        case .notEnabled:
            EmptyView()
        case .notAvailable:
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(.secondary)
                .help("iCloud is unavailable. Sign in to iCloud to sync your library.")
        case .synced:
            Image(systemName: "checkmark.icloud")
                .foregroundStyle(.secondary)
                .help("Library is synced via iCloud.")
        case .syncing:
            Image(systemName: "icloud.and.arrow.up")
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse)
                .help("Syncing with iCloud…")
        }
    }

    // MARK: - Filter menus

    private var sortMenu: some View {
        Menu("Sort By") {
            ForEach(VoiceLibraryViewModel.SortOption.allCases, id: \.self) { option in
                Button {
                    viewModel.setSortOption(option)
                } label: {
                    Label {
                        Text(option.rawValue)
                    } icon: {
                        if viewModel.sortOption == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    private var typeFilterMenu: some View {
        Menu("Voice Type") {
            Button("All Types") {
                viewModel.setTypeFilter(nil)
            }
            .disabled(viewModel.filterType == nil)

            ForEach([Voice.VoiceType.preset, .custom, .cloned], id: \.self) { type in
                Button {
                    viewModel.setTypeFilter(type)
                } label: {
                    Label {
                        Text(type.rawValue.capitalized)
                    } icon: {
                        if viewModel.filterType == type {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    private var languageFilterMenu: some View {
        Menu("Language") {
            Button("All Languages") {
                viewModel.setLanguageFilter(nil)
            }
            .disabled(viewModel.filterLanguage == nil)

            ForEach(Language.allCases, id: \.self) { language in
                Button {
                    viewModel.setLanguageFilter(language)
                } label: {
                    Label {
                        Text(language.rawValue)
                    } icon: {
                        if viewModel.filterLanguage == language {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.error != nil },
            set: { newValue in if !newValue { viewModel.clearError() } }
        )
    }
}

#Preview {
    VoiceLibraryView()
        .environmentObject(DIContainer())
}
