//
//  VoiceCloningView.swift
//  PolyJuiceVoice
//

import SwiftUI

struct VoiceCloningView: View {

    @StateObject private var viewModel = VoiceCloningViewModel()
    @EnvironmentObject var container: DIContainer
    @EnvironmentObject var downloadManager: ModelDownloadManager
    @EnvironmentObject var selectionStore: ModelSelectionStore

    @State private var showingModelManager = false
    @State private var showingSaveSheet = false
    @State private var saveVoiceName = ""
    @State private var showingPermissionPrompt = false

    var body: some View {
        NavigationStack {
            Group {
                if let needs = viewModel.unconfiguredCapability {
                    centeredMissing(needs)
                } else {
                    ScrollView {
                        GlassEffectContainer(spacing: 18) {
                            VStack(alignment: .leading, spacing: 18) {
                                recordingCard
                                referenceTextField
                                targetTextField
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
            .navigationTitle("Clone")
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
                if (viewModel.error ?? "").localizedCaseInsensitiveContains("microphone") {
                    Button("Open Settings") {
                        SystemSettings.openMicrophoneSettings()
                        viewModel.clearError()
                    }
                }
                Button("OK") { viewModel.clearError() }
            } message: {
                Text(viewModel.error ?? "")
            }
            .sheet(isPresented: $showingModelManager, onDismiss: { Task { @MainActor in viewModel.retrySetup() } }) {
                ModelManagerView(focusCapability: .voiceClone)
                    .environmentObject(downloadManager)
                    .environmentObject(selectionStore)
            }
            .sheet(isPresented: $showingSaveSheet) {
                SaveVoiceSheet(
                    title: "Save cloned voice",
                    placeholder: "e.g. My voice",
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

    private var recordingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                FieldLabel(title: "Reference recording")
                HStack(spacing: 16) {
                    Button {
                        viewModel.toggleRecording()
                    } label: {
                        Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 44))
                            .foregroundStyle(viewModel.isRecording ? .red : .accentColor)
                            .symbolEffect(.pulse, isActive: viewModel.isRecording)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Start recording")
                    .keyboardShortcut("r", modifiers: [.command])

                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusText)
                            .fontWeight(.medium)
                        Text("\(viewModel.recordingTime, format: .number.precision(.fractionLength(1)))s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    levelMeter
                }
            }
        }
    }

    private var statusText: String {
        if viewModel.isRecording { return "Recording…" }
        if viewModel.hasReferenceAudio { return "Reference captured" }
        return "Tap to record"
    }

    private var levelMeter: some View {
        HStack(spacing: 3) {
            ForEach(0..<6, id: \.self) { i in
                Capsule()
                    .fill(barColor(at: i))
                    .frame(width: 4, height: barHeight(at: i))
                    .animation(.easeOut(duration: 0.08), value: viewModel.audioLevel)
            }
        }
        .frame(width: 50, height: 28)
        .accessibilityHidden(true)
    }

    private func barHeight(at i: Int) -> CGFloat {
        let level = max(0, min(1, CGFloat(viewModel.audioLevel)))
        let threshold = CGFloat(i) / 6
        return level > threshold ? 8 + CGFloat(i) * 4 : 6
    }

    private func barColor(at i: Int) -> Color {
        let level = max(0, min(1, CGFloat(viewModel.audioLevel)))
        let threshold = CGFloat(i) / 6
        return level > threshold ? .red : Color.secondary.opacity(0.3)
    }

    private var referenceTextField: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(title: "Reference transcript")
            GlassTextEditor(text: $viewModel.referenceText,
                            minHeight: 80,
                            prompt: "What did you say in the recording?")
        }
    }

    private var targetTextField: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(title: "Text to speak")
            GlassTextEditor(text: $viewModel.targetText,
                            minHeight: 120,
                            prompt: "Type or paste what the cloned voice should say…")
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
                    .disabled(viewModel.waveformSamples.isEmpty)
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
                        .disabled(viewModel.waveformSamples.isEmpty)
                        .keyboardShortcut("e", modifiers: [.command])
                    }
                }
            }
        }
    }

    private var synthesizeButton: some View {
        PrimaryActionButton(
            title: "Clone",
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
    VoiceCloningView()
        .environmentObject(DIContainer())
        .environmentObject(ModelDownloadManager())
        .environmentObject(ModelSelectionStore())
}
