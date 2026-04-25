//
//  VoiceDesignView.swift
//  VoiceClone
//

import SwiftUI

struct VoiceDesignView: View {

    @StateObject private var viewModel = VoiceDesignViewModel()
    @EnvironmentObject var container: DIContainer
    @EnvironmentObject var downloadManager: ModelDownloadManager

    @State private var showingModelManager = false
    @State private var showingSaveSheet = false
    @State private var saveVoiceName = ""

    var body: some View {
        NavigationStack {
            Group {
                if let missing = viewModel.missingSnapshot {
                    VStack {
                        Spacer()
                        MissingSnapshotPrompt(snapshot: missing) {
                            showingModelManager = true
                        }
                        Spacer()
                    }
                    .padding()
                } else {
                    designForm
                }
            }
            .navigationTitle("Design")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingModelManager = true
                    } label: {
                        Image(systemName: "icloud.and.arrow.down")
                    }
                    .help("Manage models")
                }
            }
            .task {
                await viewModel.setup(
                    ttsService: container.ttsService,
                    audioEngine: container.audioEngine,
                    voiceStorage: container.voiceStorage,
                    downloadManager: downloadManager
                )
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK") { viewModel.clearError() }
            } message: {
                Text(viewModel.error ?? "")
            }
            .sheet(isPresented: $showingModelManager, onDismiss: viewModel.retrySetup) {
                ModelManagerView(highlight: .voiceDesign)
                    .environmentObject(downloadManager)
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

    private var designForm: some View {
        VStack(spacing: 20) {
            textEditor
            instructionEditor
            languageSelector
            waveformDisplay
            controlButtons
            synthesizeButton
        }
        .padding()
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.error != nil },
            set: { newValue in
                if !newValue { viewModel.clearError() }
            }
        )
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text to speak")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $viewModel.text)
                .frame(minHeight: 120)
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var instructionEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Voice description")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $viewModel.instruction)
                .frame(minHeight: 80)
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text("Example: \"A warm female voice with a friendly tone\"")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var languageSelector: some View {
        HStack {
            Text("Language:")
                .foregroundStyle(.secondary)

            Picker("Language", selection: $viewModel.language) {
                ForEach(Language.allCases, id: \.self) { language in
                    Text(language.rawValue).tag(language)
                }
            }
            .pickerStyle(.menu)

            Spacer()
        }
    }

    private var waveformDisplay: some View {
        WaveformView(samples: viewModel.waveformSamples, progress: viewModel.playbackProgress)
            .frame(height: 60)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var controlButtons: some View {
        HStack(spacing: 24) {
            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .disabled(!viewModel.hasAudio)

            Button {
                showingSaveSheet = true
            } label: {
                Label("Save Voice", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(!viewModel.canSaveVoice)

            Spacer()

            if let url = viewModel.exportURL {
                ShareLink(item: url) {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(!viewModel.hasAudio)
            } else {
                Button {
                    viewModel.export()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(!viewModel.hasAudio)
            }
        }
        .buttonStyle(.plain)
    }

    private var synthesizeButton: some View {
        Button {
            Task {
                await viewModel.synthesize()
            }
        } label: {
            Group {
                if viewModel.isSynthesizing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Text("Generate")
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(viewModel.canSynthesize ? Color.accentColor : Color.gray)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!viewModel.canSynthesize)
    }
}

#Preview {
    VoiceDesignView()
        .environmentObject(DIContainer())
        .environmentObject(ModelDownloadManager())
}
