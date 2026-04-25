//
//  SynthesisView.swift
//  VoiceClone
//
//  Speak tab. iOS 26 / macOS 26 Liquid Glass throughout: toolbar adopts
//  the system glass pill, primary CTA uses `.glassProminent`, the voice
//  picker and waveform sit on glass capsules / cards, and inputs use
//  `GlassTextEditor` / `GlassTextField` so the whole tab morphs together.
//

import SwiftUI

struct SynthesisView: View {

    @StateObject private var viewModel = SynthesisViewModel()
    @EnvironmentObject var container: DIContainer
    @EnvironmentObject var downloadManager: ModelDownloadManager

    @State private var showingModelManager = false

    var body: some View {
        NavigationStack {
            Group {
                if let missing = viewModel.missingSnapshot {
                    centeredMissingPrompt(missing)
                } else {
                    ScrollView {
                        GlassEffectContainer(spacing: 18) {
                            VStack(alignment: .leading, spacing: 18) {
                                voiceSelector
                                textEditor
                                instructionField
                                languageSelector
                                playbackCard
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 12)
                            .padding(.bottom, 110)   // leave room for the floating CTA
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
            .navigationTitle("Speak")
            .toolbar { toolbarContent }
            .task {
                await viewModel.setup(
                    ttsService: container.ttsService,
                    audioEngine: container.audioEngine,
                    voiceStorage: container.voiceStorage,
                    downloadManager: downloadManager
                )
            }
            .onAppear { Task { await viewModel.reloadVoiceOptions() } }
            .alert("Error", isPresented: errorBinding) {
                Button("OK") { viewModel.clearError() }
            } message: {
                Text(viewModel.error ?? "")
            }
            .sheet(isPresented: $showingModelManager, onDismiss: viewModel.retrySetup) {
                ModelManagerView(highlight: viewModel.missingSnapshot)
                    .environmentObject(downloadManager)
            }
        }
    }

    // MARK: - Toolbar

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

    // MARK: - Sections

    private func centeredMissingPrompt(_ missing: ModelSnapshot) -> some View {
        VStack {
            Spacer()
            MissingSnapshotPrompt(snapshot: missing) {
                showingModelManager = true
            }
            Spacer()
        }
        .padding()
    }

    private var voiceSelector: some View {
        HStack(spacing: 10) {
            FieldLabel(title: "Voice")
            Menu {
                Section("Presets") {
                    ForEach(viewModel.voiceOptions.filter { if case .preset = $0 { return true } else { return false } }) { option in
                        Button(option.name) { viewModel.selectedOption = option }
                    }
                }
                let savedOptions = viewModel.voiceOptions.filter {
                    if case .saved = $0 { return true } else { return false }
                }
                if !savedOptions.isEmpty {
                    Section("Your Voices") {
                        ForEach(savedOptions) { option in
                            Button(option.name) { viewModel.selectedOption = option }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(viewModel.selectedOption.name).fontWeight(.medium)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .menuStyle(.borderlessButton)
            .glassEffect(.regular, in: .capsule)
            Spacer()
        }
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(title: "Text to speak")
            GlassTextEditor(text: $viewModel.text,
                            minHeight: 140,
                            prompt: "Type or paste what this voice should say…")
        }
    }

    private var instructionField: some View {
        let isPreset: Bool = {
            if case .preset = viewModel.selectedOption { return true } else { return false }
        }()
        return Group {
            if isPreset {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(title: "Style instruction (optional)")
                    GlassTextField(text: $viewModel.instruction,
                                   prompt: "e.g. Calm and warm")
                }
            }
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
                WaveformView(
                    samples: viewModel.waveformSamples,
                    progress: viewModel.playbackProgress
                )
                .frame(height: 64)
                .accessibilityLabel("Waveform of synthesized audio")

                HStack(spacing: 18) {
                    Button {
                        viewModel.seekBackward()
                    } label: {
                        Image(systemName: "gobackward.10").font(.title2)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .accessibilityLabel("Skip back 10 seconds")
                    .disabled(!viewModel.hasAudio)
                    .keyboardShortcut(.leftArrow, modifiers: [.command])

                    Button {
                        viewModel.togglePlayback()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
                    .disabled(!viewModel.hasAudio)
                    .keyboardShortcut(.space, modifiers: [])

                    Button {
                        viewModel.seekForward()
                    } label: {
                        Image(systemName: "goforward.10").font(.title2)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .accessibilityLabel("Skip forward 10 seconds")
                    .disabled(!viewModel.hasAudio)
                    .keyboardShortcut(.rightArrow, modifiers: [.command])

                    Spacer()

                    if let url = viewModel.exportURL {
                        ShareLink(item: url) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                        .keyboardShortcut("e", modifiers: [.command])
                    } else {
                        Button {
                            viewModel.export()
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                        .accessibilityLabel("Export audio")
                        .disabled(!viewModel.hasAudio)
                        .keyboardShortcut("e", modifiers: [.command])
                    }
                }
            }
        }
    }

    private var synthesizeButton: some View {
        PrimaryActionButton(
            title: "Speak",
            isWorking: viewModel.isSynthesizing,
            isEnabled: viewModel.canSynthesize
        ) {
            Task { await viewModel.synthesize() }
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityLabel("Synthesize speech")
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.error != nil },
            set: { newValue in if !newValue { viewModel.clearError() } }
        )
    }
}

#Preview {
    SynthesisView()
        .environmentObject(DIContainer())
        .environmentObject(ModelDownloadManager())
}
