//
//  SynthesisView.swift
//  VoiceClone
//

import SwiftUI

struct SynthesisView: View {

    @StateObject private var viewModel = SynthesisViewModel()
    @EnvironmentObject var container: DIContainer

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                voiceSelector
                textEditor
                instructionField
                languageSelector
                waveformDisplay
                controlButtons
                synthesizeButton
            }
            .padding()
            .navigationTitle("Speak")
            .task {
                await viewModel.setup(ttsService: container.ttsService, audioEngine: container.audioEngine)
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK") { viewModel.clearError() }
            } message: {
                Text(viewModel.error ?? "")
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

    private var voiceSelector: some View {
        HStack {
            Text("Voice:")
                .foregroundStyle(.secondary)

            Menu {
                ForEach(PresetVoice.allCases, id: \.self) { voice in
                    Button(voice.rawValue) {
                        viewModel.selectedVoice = voice
                    }
                }

                Divider()

                NavigationLink("Custom Voices...") {
                    VoiceLibraryView()
                }
            } label: {
                HStack {
                    Text(viewModel.selectedVoice.rawValue)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary)
                .clipShape(Capsule())
            }

            Spacer()
        }
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
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.quaternary, lineWidth: 1)
                )
        }
    }

    private var instructionField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Style instruction (optional)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("e.g. Calm and warm", text: $viewModel.instruction)
                .textFieldStyle(.roundedBorder)
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
        WaveformView(
            samples: viewModel.waveformSamples,
            progress: viewModel.playbackProgress
        )
        .frame(height: 60)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var controlButtons: some View {
        HStack(spacing: 24) {
            Button {
                viewModel.seekBackward()
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.title2)
            }
            .disabled(!viewModel.hasAudio)

            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
            }
            .disabled(!viewModel.hasAudio)

            Button {
                viewModel.seekForward()
            } label: {
                Image(systemName: "goforward.10")
                    .font(.title2)
            }
            .disabled(!viewModel.hasAudio)

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
                    Text("Speak")
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
    SynthesisView()
        .environmentObject(DIContainer())
}
