//
//  RootView.swift
//  VoiceClone
//

import SwiftUI

struct RootView: View {

    @EnvironmentObject private var downloadManager: ModelDownloadManager

    var body: some View {
        if downloadManager.state.isReady {
            ContentView()
        } else {
            ModelDownloadView()
        }
    }
}
