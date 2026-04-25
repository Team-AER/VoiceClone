//
//  AppLog.swift
//  PolyJuiceVoice
//
//  Centralised `os.Logger` wrappers + an in-memory ring buffer that powers
//  the in-app Debug Log viewer (Settings → Debug Log).
//

import Foundation
import os
import Combine

enum LogLevel: String, Sendable, Codable, CaseIterable {
    case debug, info, notice, warning, error, fault

    var emoji: String {
        switch self {
        case .debug:   return "·"
        case .info:    return "ℹ"
        case .notice:  return "→"
        case .warning: return "⚠"
        case .error:   return "✗"
        case .fault:   return "☠"
        }
    }

    var sortOrder: Int {
        switch self {
        case .debug:   return 0
        case .info:    return 1
        case .notice:  return 2
        case .warning: return 3
        case .error:   return 4
        case .fault:   return 5
        }
    }
}

struct LogEntry: Identifiable, Sendable, Hashable {
    let id: UUID
    let timestamp: Date
    let category: String
    let level: LogLevel
    let message: String
}

/// Project-wide logger registry. Use one of the `AppLog.*` shortcuts so log
/// entries are also captured into the in-memory `LogStore` for the in-app
/// viewer.
enum AppLog {
    private static let subsystem = "com.aer.polyjuicevoice"

    static let app        = Logger(subsystem: subsystem, category: "app")
    static let mlx        = Logger(subsystem: subsystem, category: "mlx")
    static let runtime    = Logger(subsystem: subsystem, category: "runtime")
    static let download   = Logger(subsystem: subsystem, category: "download")
    static let audio      = Logger(subsystem: subsystem, category: "audio")
    static let storage    = Logger(subsystem: subsystem, category: "storage")
    static let synthesis  = Logger(subsystem: subsystem, category: "synthesis")
    static let profiling  = Logger(subsystem: subsystem, category: "profiling")

    /// Mirror to OSLog **and** the in-app ring buffer.
    static func log(_ message: String,
                    level: LogLevel = .info,
                    category: String = "app",
                    logger: Logger? = nil) {
        let lg = logger ?? Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug:   lg.debug("\(message, privacy: .public)")
        case .info:    lg.info("\(message, privacy: .public)")
        case .notice:  lg.notice("\(message, privacy: .public)")
        case .warning: lg.warning("\(message, privacy: .public)")
        case .error:   lg.error("\(message, privacy: .public)")
        case .fault:   lg.fault("\(message, privacy: .public)")
        }
        LogStore.append(LogEntry(
            id: UUID(),
            timestamp: Date(),
            category: category,
            level: level,
            message: message
        ))
    }

    static func debug(_ msg: String,   _ category: String = "app") { log(msg, level: .debug,   category: category) }
    static func info(_ msg: String,    _ category: String = "app") { log(msg, level: .info,    category: category) }
    static func notice(_ msg: String,  _ category: String = "app") { log(msg, level: .notice,  category: category) }
    static func warning(_ msg: String, _ category: String = "app") { log(msg, level: .warning, category: category) }
    static func error(_ msg: String,   _ category: String = "app") { log(msg, level: .error,   category: category) }
    static func fault(_ msg: String,   _ category: String = "app") { log(msg, level: .fault,   category: category) }
}

/// In-memory ring buffer of the most recent log entries — surfaced by the
/// in-app Debug Log viewer (Settings → Debug Log). Keeps the last `capacity`
/// entries and notifies SwiftUI subscribers on append.
///
/// Append is callable from any isolation domain via the `nonisolated`
/// `LogStore.append(_:)` static helper, which hops onto the MainActor before
/// touching `@Published` state.
@MainActor
final class LogStore: ObservableObject {

    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []
    private let capacity: Int = 500

    /// Cross-actor append: hop to MainActor before mutating `entries`.
    nonisolated static func append(_ entry: LogEntry) {
        Task { @MainActor in
            shared.appendOnMain(entry)
        }
    }

    private func appendOnMain(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// Render the buffer as a single shareable plain-text dump.
    func plainText() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries.map { e in
            "[\(formatter.string(from: e.timestamp))] \(e.level.emoji) \(e.category.padding(toLength: 10, withPad: " ", startingAt: 0)) \(e.message)"
        }.joined(separator: "\n")
    }
}
