//
//  ContentView.swift
//  VoiceClone
//
//  Top-level chrome. macOS uses NavigationSplitView (sidebar floats with
//  Liquid Glass automatically). iOS uses TabView with the new
//  `.tabBarMinimizeBehavior` so the bar tucks away on scroll.
//

import SwiftUI

struct ContentView: View {

    @EnvironmentObject var container: DIContainer
    @EnvironmentObject var downloadManager: ModelDownloadManager
    @State private var selectedTab: Tab = .speak

    enum Tab: String, CaseIterable, Identifiable {
        case speak    = "Speak"
        case design   = "Design"
        case clone    = "Clone"
        case library  = "Library"
        case settings = "Settings"

        var id: Self { self }

        var icon: String {
            switch self {
            case .speak:    return "waveform"
            case .design:   return "sparkles"
            case .clone:    return "mic.fill"
            case .library:  return "books.vertical"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(Tab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .navigationTitle("PolyjuiceVoice")
        } detail: {
            tabContent(for: selectedTab)
        }
        .navigationSplitViewStyle(.balanced)
        #else
        TabView(selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.rawValue, systemImage: tab.icon)
                    }
                    .tag(tab)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
    }

    @ViewBuilder
    private func tabContent(for tab: Tab) -> some View {
        switch tab {
        case .speak:    SynthesisView()
        case .design:   VoiceDesignView()
        case .clone:    VoiceCloneView()
        case .library:  VoiceLibraryView()
        case .settings: SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DIContainer())
        .environmentObject(ModelDownloadManager())
}
