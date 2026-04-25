//
//  DebugLogView.swift
//  PolyJuiceVoice
//
//  In-app log viewer backed by `LogStore`. Reachable from Settings → Debug
//  Log and from the toolbar bug-report button on every feature tab.
//

import SwiftUI

struct DebugLogView: View {

    @StateObject private var store = LogStore.shared
    @State private var levelFilter: LogLevel? = nil
    @State private var categoryFilter: String? = nil
    @State private var followTail = true

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredEntries) { entry in
                            LogRow(entry: entry)
                                .id(entry.id)
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: store.entries.last?.id) { _, newID in
                    guard followTail, let newID else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Debug Log")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $followTail) {
                    Label("Follow", systemImage: "arrow.down.to.line.compact")
                }
                .toggleStyle(.button)
                .help("Auto-scroll as new entries arrive")

                ShareLink(item: store.plainText(), preview: SharePreview("PolyJuiceVoice log")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    store.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear in-memory log")
            }
        }
    }

    private var filteredEntries: [LogEntry] {
        store.entries.filter { entry in
            (levelFilter == nil || entry.level == levelFilter) &&
            (categoryFilter == nil || entry.category == categoryFilter)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("All levels") { levelFilter = nil }
                Divider()
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Button("\(level.emoji) \(level.rawValue.capitalized)") { levelFilter = level }
                }
            } label: {
                Label(levelFilter.map { "\($0.emoji) \($0.rawValue.capitalized)" } ?? "All levels",
                      systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.glass)
            .controlSize(.small)

            Menu {
                Button("All categories") { categoryFilter = nil }
                Divider()
                ForEach(allCategories, id: \.self) { cat in
                    Button(cat) { categoryFilter = cat }
                }
            } label: {
                Label(categoryFilter ?? "All categories", systemImage: "tag")
            }
            .buttonStyle(.glass)
            .controlSize(.small)

            Spacer()

            Text("\(filteredEntries.count) entries")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var allCategories: [String] {
        Array(Set(store.entries.map(\.category))).sorted()
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timeStr)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 88, alignment: .leading)
            Text(entry.level.emoji)
                .font(.caption)
                .foregroundStyle(color(for: entry.level))
                .frame(width: 14)
            Text(entry.category)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(entry.message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timeStr: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: entry.timestamp)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug:   return .secondary
        case .info:    return .secondary
        case .notice:  return .accentColor
        case .warning: return .orange
        case .error:   return .red
        case .fault:   return .pink
        }
    }
}

#Preview {
    NavigationStack { DebugLogView() }
}
