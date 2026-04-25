//
//  VoiceDesignView.swift
//  PolyJuiceVoice
//

import SwiftUI

struct VoiceDesignView: View {

    @StateObject private var viewModel = VoiceDesignViewModel()
    @EnvironmentObject var container: DIContainer
    @EnvironmentObject var downloadManager: ModelDownloadManager
    @EnvironmentObject var selectionStore: ModelSelectionStore

    @State private var showingModelManager = false
    @State private var showingSaveSheet = false
    @State private var saveVoiceName = ""

    var body: some View {
        NavigationStack {
            Group {
                if let needs = viewModel.unconfiguredCapability {
                    centeredMissing(needs)
                } else {
                    ScrollView {
                        GlassEffectContainer(spacing: 18) {
                            VStack(alignment: .leading, spacing: 18) {
                                textEditor
                                instructionEditor
                                languageSelector
                                playbackCard
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 12)
                            .padding(.bottom, 110)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .safeAreaInset(edge: .bottom) {
                        synthesizeButton
                            .padding(.horizontal, 18)
                            .padding(.bottom, 14)
                    }
                }
            }
            .navigationTitle("Design")
            .toolbar { toolbarContent }
            .task {
                await viewModel.setup(
                    ttsService: container.ttsService,
                    audioEngine: container.audioEngine,
                    voiceStorage: container.voiceStorage,
                    downloadManager: downloadManager,
                    selectionStore: selectionStore
                )
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK") { viewModel.clearError() }
            } message: {
                Text(viewModel.error ?? "")
            }
            .sheet(isPresented: $showingModelManager, onDismiss: { Task { @MainActor in viewModel.retrySetup() } }) {
                ModelManagerView(focusCapability: .voiceDesign)
                    .environmentObject(downloadManager)
                    .environmentObject(selectionStore)
            }
            .sheet(isPresented: $showingSaveSheet) {
                SaveVoiceSheet(
                    title: "Save designed voice",
                    placeholder: "e.g. Calm narrator",
                    name: $saveVoiceName
                ) {
                    let n = saveVoiceName
                    showingSaveSheet = false
                    saveVoiceName = ""
                    Task { await viewModel.saveVoice(name: n) }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            DebugLogToolbarButton()
            Button {
                showingModelManager = true
            } label: {
                Image(systemName: "internaldrive")
            }
            .accessibilityLabel("Models")
            .help("Manage downloaded models")
        }
    }

    private func centeredMissing(_ capability: TTSCapability) -> some View {
        ScrollView {
            MissingCapabilityPrompt(capability: capability) {
                showingModelManager = true
            }
            .frame(maxWidth: 460)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(title: "Text to speak")
            GlassTextEditor(text: $viewModel.text,
                            minHeight: 130,
                            prompt: "Type or paste what this voice should say…")
        }
    }

    private var instructionEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(title: "Voice description")
            GlassTextEditor(text: $viewModel.instruction,
                            minHeight: 90,
                            prompt: "e.g. A warm female voice with a friendly tone")
            Text("Describe the voice you want — tone, age, mood, accent.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var languageSelector: some View {
        HStack {
            FieldLabel(title: "Language")
            Picker("Language", selection: $viewModel.language) {
                ForEach(Language.allCases, id: \.self) { language in
                    Text(language.rawValue).tag(language)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Spacer()
        }
    }

    private var playbackCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                WaveformView(samples: viewModel.waveformSamples,
                             progress: viewModel.playbackProgress)
                    .frame(height: 64)

                HStack(spacing: 18) {
                    Button {
                        viewModel.togglePlayback()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
                    .disabled(!viewModel.hasAudio)
                    .keyboardShortcut(.space, modifiers: [])

                    Button {
                        showingSaveSheet = true
                    } label: {
                        Label("Save Voice", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.glass)
                    .disabled(!viewModel.canSaveVoice)
                    .keyboardShortcut("s", modifiers: [.command])

                    Spacer()

                    if let url = viewModel.exportURL {
                        ShareLink(item: url) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.glass)
                        .keyboardShortcut("e", modifiers: [.command])
                    } else {
                        Button {
                            viewModel.export()
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.glass)
                        .disabled(!viewModel.hasAudio)
                        .keyboardShortcut("e", modifiers: [.command])
                    }
                }
            }
        }
    }

    private var synthesizeButton: some View {
        PrimaryActionButton(
            title: "Generate",
            isWorking: viewModel.isSynthesizing,
            isEnabled: viewModel.canSynthesize
        ) {
            Task { await viewModel.synthesize() }
        }
        .keyboardShortcut(.return, modifiers: [.command])
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.error != nil },
            set: { newValue in if !newValue { viewModel.clearError() } }
        )
    }
}

#Preview {
    VoiceDesignView()
        .environmentObject(DIContainer())
        .environmentObject(ModelDownloadManager())
        .environmentObject(ModelSelectionStore())
}
