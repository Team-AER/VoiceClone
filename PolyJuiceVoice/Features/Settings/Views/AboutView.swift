//
//  AboutView.swift
//  PolyJuiceVoice
//
//  About / Licenses screen. Reachable from Settings. Surfaces app version,
//  attribution for the Qwen3-TTS model + dependencies, and license text.
//

import SwiftUI

struct AboutView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                description
                creditsSection
                licensesSection
                Spacer(minLength: 24)
            }
            .padding(24)
            .frame(maxWidth: 720)
        }
        .frame(maxWidth: .infinity)
        .scrollContentBackground(.hidden)
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("PolyJuiceVoice")
                .font(.largeTitle.bold())
            Text(versionAndBuild)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var versionAndBuild: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "Version \(version) (\(build))"
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On-device text to speech")
                .font(.headline)
            Text("PolyJuiceVoice synthesizes speech entirely on this device using Apple's MLX framework. Your text and voice recordings never leave your hardware.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var creditsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Built with")
                .font(.headline)
            VStack(spacing: 0) {
                creditRow(
                    title: "Qwen3-TTS",
                    subtitle: "Alibaba Cloud · Apache 2.0",
                    url: URL(string: "https://huggingface.co/Qwen/Qwen3-TTS-0.6B")
                )
                Divider()
                creditRow(
                    title: "MLX & mlx-swift",
                    subtitle: "Apple Inc. · MIT License",
                    url: URL(string: "https://github.com/ml-explore/mlx-swift")
                )
                Divider()
                creditRow(
                    title: "swift-transformers",
                    subtitle: "Hugging Face · Apache 2.0",
                    url: URL(string: "https://github.com/huggingface/swift-transformers")
                )
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }

    private func creditRow(title: String, subtitle: String, url: URL?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url {
                Link(destination: url) {
                    Image(systemName: "arrow.up.forward.app")
                        .foregroundStyle(.tint)
                }
                .accessibilityLabel("Open \(title) homepage")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var licensesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Privacy")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                privacyRow(symbol: "checkmark.shield",  text: "All synthesis runs on this device.")
                privacyRow(symbol: "wifi.slash",        text: "No audio is uploaded or shared.")
                privacyRow(symbol: "icloud.slash",      text: "No analytics, telemetry, or accounts.")
                privacyRow(symbol: "internaldrive",     text: "Models are downloaded once from Hugging Face.")
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }

    private func privacyRow(symbol: String, text: String) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}

#Preview {
    NavigationStack { AboutView() }
}
