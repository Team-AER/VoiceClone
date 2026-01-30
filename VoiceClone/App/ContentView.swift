//
//  ContentView.swift
//  VoiceClone
//
//  Created by Prakhar Shukla on 28-01-2026.
//

import SwiftUI

struct ContentView: View {

    @EnvironmentObject var container: DIContainer
    @State private var selectedTab: Tab = .speak

    enum Tab: String, CaseIterable {
        case speak = "Speak"
        case design = "Design"
        case clone = "Clone"
        case library = "Library"

        var icon: String {
            switch self {
            case .speak: return "waveform"
            case .design: return "sparkles"
            case .clone: return "mic.fill"
            case .library: return "books.vertical"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(Tab.allCases, id: \.self) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.rawValue, systemImage: tab.icon)
                    }
                    .tag(tab)
            }
        }
    }

    @ViewBuilder
    private func tabContent(for tab: Tab) -> some View {
        switch tab {
        case .speak:
            SynthesisView()
        case .design:
            VoiceDesignView()
        case .clone:
            VoiceCloneView()
        case .library:
            VoiceLibraryView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DIContainer())
        .environment(\.container, DIContainer())
}
