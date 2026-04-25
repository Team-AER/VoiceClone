//
//  SynthesisView.swift
//  PolyJuiceVoice
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
    @EnvironmentObject var selectionStore: ModelSelectionStore

    @State private var showingModelManager = false

    var body: some View {
        NavigationStack {
            Group {
                if let needs = viewModel.unconfiguredCapability {
                    centeredMissingPrompt(needs)
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
                    .scrollDismissesKeyboard(.immediately)
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
                    downloadManager: downloadManager,
                    selectionStore: selectionStore
                )
            }
            .onAppear { Task { await viewModel.reloadVoiceOptions() } }
            .alert("Error", isPresented: errorBinding) {
                Button("OK") { viewModel.clearError() }
            } message: {
                Text(viewModel.error ?? "")
            }
            .sheet(isPresented: $showingModelManager, onDismiss: { Task { @MainActor in viewModel.retrySetup() } }) {
                ModelManagerView(focusCapability: viewModel.unconfiguredCapability)
                    .environmentObject(downloadManager)
                    .environmentObject(selectionStore)
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

    private func centeredMissingPrompt(_ capability: TTSCapability) -> some View {
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

    private var voiceSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            FieldLabel(title: "Voice")

            VoicePillSection(
                title: "Presets",
                tint: .accentColor,
                options: presetOptions,
                selected: viewModel.selectedOption,
                onSelect: { viewModel.selectedOption = $0 }
            )

            if !savedOptions.isEmpty {
                VoicePillSection(
                    title: "Your Voices",
                    tint: .purple,
                    options: savedOptions,
                    selected: viewModel.selectedOption,
                    onSelect: { viewModel.selectedOption = $0 }
                )
            }
        }
    }

    /// Stock preset speakers — shipped with the app.
    private var presetOptions: [VoiceOption] {
        viewModel.voiceOptions.filter { if case .preset = $0 { return true } else { return false } }
    }

    /// User-saved cloned / designed voices.
    private var savedOptions: [VoiceOption] {
        viewModel.voiceOptions.filter { if case .saved = $0 { return true } else { return false } }
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

// MARK: - Voice pill section

/// One labelled, color-coded row of voice pills. Presets and saved voices
/// each get their own section so the user can tell them apart at a glance.
private struct VoicePillSection: View {
    let title: LocalizedStringKey
    let tint: Color
    let options: [VoiceOption]
    let selected: VoiceOption
    let onSelect: (VoiceOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(options) { option in
                        VoicePill(
                            label: option.name,
                            tint: tint,
                            isSelected: option == selected,
                            onTap: { onSelect(option) }
                        )
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 1)   // breathing room for the focus ring
            }
        }
    }
}

/// Single voice pill — accent-tinted capsule when selected, thin material
/// otherwise. Cheap to render (no per-pill `.glassEffect`).
private struct VoicePill: View {
    let label: String
    let tint: Color
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(tint.opacity(0.18))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(tint.opacity(0.55), lineWidth: 1)
                            )
                    } else {
                        Capsule(style: .continuous)
                            .fill(.thinMaterial)
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
                            )
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}

#Preview {
    SynthesisView()
        .environmentObject(DIContainer())
        .environmentObject(ModelDownloadManager())
        .environmentObject(ModelSelectionStore())
}
