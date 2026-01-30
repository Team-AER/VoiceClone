//
//  VoiceCloneView.swift
//  VoiceClone
//

import SwiftUI

struct VoiceCloneView: View {

    @StateObject private var viewModel = VoiceCloneViewModel()
    @EnvironmentObject var container: DIContainer

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                recordingSection
                referenceTextField
                targetTextField
                languageSelector
                waveformDisplay
                controlButtons
                synthesizeButton
            }
            .padding()
            .navigationTitle("Clone")
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

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference recording")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button {
                    viewModel.toggleRecording()
                } label: {
                    Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 44))
                        .foregroundStyle(viewModel.isRecording ? .red : .primary)
                }

                VStack(alignment: .leading) {
                    Text(viewModel.isRecording ? "Recording..." : (viewModel.hasReferenceAudio ? "Reference captured" : "Tap to record"))
                        .fontWeight(.medium)
                    Text("\(viewModel.recordingTime, format: .number.precision(.fractionLength(1)))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Circle()
                    .fill(Color.red.opacity(Double(min(1, viewModel.audioLevel + 0.05))))
                    .frame(width: 12, height: 12)
            }
        }
    }

    private var referenceTextField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference transcript")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("What did you say?", text: $viewModel.referenceText)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var targetTextField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text to speak")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $viewModel.targetText)
                .frame(minHeight: 120)
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
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
            .disabled(viewModel.waveformSamples.isEmpty)

            Spacer()

            if let url = viewModel.exportURL {
                ShareLink(item: url) {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(viewModel.waveformSamples.isEmpty)
            } else {
                Button {
                    viewModel.export()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(viewModel.waveformSamples.isEmpty)
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
                    Text("Clone")
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
    VoiceCloneView()
        .environmentObject(DIContainer())
}
