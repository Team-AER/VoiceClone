//
//  GlassControls.swift
//  PolyJuiceVoice
//
//  Shared SwiftUI building blocks that embrace Liquid Glass on iOS 26 /
//  macOS 26: glass-backed text editors, the primary action button, the
//  voice-picker capsule, and the waveform card. Keeping them in one place
//  means the three feature tabs share the exact same chrome.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Field labels

struct FieldLabel: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Glass-backed text editor

/// Multi-line input with a Liquid Glass background that morphs with the
/// rest of the form. Replaces ad-hoc `.background(.quaternary).clipShape`.
struct GlassTextEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 120
    var prompt: LocalizedStringKey?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty, let prompt {
                Text(prompt)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Glass-backed single-line field

struct GlassTextField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Primary CTA button

/// Project-wide primary action button. Uses `.glassProminent` so it
/// participates in the system's glass tinting.
struct PrimaryActionButton: View {
    let title: LocalizedStringKey
    let isWorking: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            #if os(iOS)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
            action()
        } label: {
            HStack(spacing: 10) {
                if isWorking {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .tint(.accentColor)
        .disabled(!isEnabled || isWorking)
    }
}

// MARK: - Section card wrapper

/// Wrap a logical group (waveform + transport controls) in a single glass
/// surface so multiple controls morph together inside `GlassEffectContainer`.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Toolbar bug-report (debug log) button

/// Drop into any `.toolbar { ... }` so every screen has a one-tap path
/// into the in-app debug log. Pairs with the icloud-download "Models"
/// button as the standard right-hand toolbar group.
struct DebugLogToolbarButton: View {
    @State private var presented = false

    var body: some View {
        Button {
            presented = true
        } label: {
            Image(systemName: "ladybug")
        }
        .accessibilityLabel("Debug log")
        .help("Show recent log events")
        .sheet(isPresented: $presented) {
            NavigationStack {
                DebugLogView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { presented = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 480)
            #endif
        }
    }
}
