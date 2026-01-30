//
//  VoiceLibraryView.swift
//  VoiceClone
//

import SwiftUI

struct VoiceLibraryView: View {

    @StateObject private var viewModel = VoiceLibraryViewModel()
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
                ToolbarItem(placement: .topBarTrailing) {
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
                        Label("Filter", systemImage: viewModel.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
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

    private var sortMenu: some View {
        Menu("Sort By") {
            ForEach(VoiceLibraryViewModel.SortOption.allCases, id: \.self) { option in
                Button {
                    viewModel.setSortOption(option)
                } label: {
                    Label(option.rawValue, systemImage: viewModel.sortOption == option ? "checkmark" : "")
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
                    Label(type.rawValue.capitalized, systemImage: viewModel.filterType == type ? "checkmark" : "")
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
                    Label(language.rawValue, systemImage: viewModel.filterLanguage == language ? "checkmark" : "")
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.error != nil },
            set: { newValue in
                if !newValue { viewModel.clearError() }
            }
        )
    }
}

#Preview {
    VoiceLibraryView()
        .environmentObject(DIContainer())
}
