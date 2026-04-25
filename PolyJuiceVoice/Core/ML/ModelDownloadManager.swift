//
//  ModelDownloadManager.swift
//  PolyJuiceVoice
//
//  Downloads pre-converted MLX weights from HuggingFace on demand. The user
//  picks which (family, capability, precision) snapshots to install in
//  `ModelManagerView`; this manager handles the actual fetching, throughput
//  / ETA tracking, atomic per-snapshot cleanup, and disk-space prechecks.
//
//  The launch gate is no longer tied to a single hardcoded snapshot — we
//  surface the matrix in the Model Manager and the user picks. See
//  `ModelSelectionStore` for the per-capability persistence.
//

import Foundation

// MARK: - Per-snapshot state

enum SnapshotInstallState: Equatable {
    case absent
    case checking
    case downloading(progress: Double, currentFile: String, bytesPerSecond: Double, etaSeconds: Double?)
    case installed
    case failed(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

// MARK: - Manager

@MainActor
final class ModelDownloadManager: NSObject, ObservableObject {

    /// Per-snapshot install state. Drives every UI surface that cares about
    /// download progress (Model Manager rows, missing-model prompts).
    @Published private(set) var snapshotStates: [ModelSnapshot: SnapshotInstallState] = [:]

    /// Per-snapshot disk footprint of installed files. Refreshed on
    /// `rescan()` and after each download / delete.
    @Published private(set) var snapshotDiskUsage: [ModelSnapshot: Int64] = [:]

    /// Selection store for keeping the user's per-capability picks consistent
    /// when snapshots are deleted. Optional so callers that don't care
    /// (e.g. the test harness) can omit it.
    private weak var selectionStore: ModelSelectionStore?

    private var urlSession: URLSession?
    /// Maps a URLSessionDownloadTask back to the (snapshot, file) it was
    /// fetching. Tasks dispatch off the main actor; this is keyed by
    /// `taskIdentifier`, which is stable for the task's lifetime.
    private var taskRegistry: [Int: (snapshot: ModelSnapshot, file: ModelFile)] = [:]
    /// Per-snapshot pending file count + completed count, for progress UI.
    private var pendingBySnapshot: [ModelSnapshot: PendingDownload] = [:]

    private struct PendingDownload {
        let pending: [ModelFile]
        var completed: Int
        let startedAt: Date
        var bytesWrittenWindow: [(at: Date, bytes: Int64)] = []
        var totalBytesWritten: Int64 = 0
        var totalBytesExpected: Int64
        /// Last wall-clock time we pushed a `.downloading(...)` value to
        /// `snapshotStates`. Used to throttle UI publishes — see
        /// `Self.uiPublishInterval`.
        var lastUIPublish: Date = .distantPast
    }

    /// Cap on how often we surface mid-download progress to the
    /// `@Published snapshotStates` map. URLSession's `didWriteData` callback
    /// fires hundreds of times per second; pushing every one through the
    /// ObservableObject pipeline forces the manager UI to re-render the
    /// glass cards at that rate, killing scroll responsiveness.
    private static let uiPublishInterval: TimeInterval = 0.15

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        // One-shot migration from the pre-matrix on-disk layout. Existing
        // installs had three fixed directories; rename them in place so users
        // don't re-download.
        Self.migrateLegacyDirectoriesIfNeeded()

        // Initial scan: see what's already on disk.
        for snap in ModelSnapshot.allCases {
            snapshotStates[snap] = Self.isInstalled(snap) ? .installed : .absent
            snapshotDiskUsage[snap] = Self.diskUsage(of: snap)
        }
    }

    /// Wire up the selection store so we can drop stale selections when the
    /// user deletes a snapshot they had picked. Also catches up any snapshot
    /// already on disk at launch — the auto-select-on-install hook only
    /// fires when we *complete* a download, so existing installs (or the
    /// legacy-directory migration) would otherwise leave the user staring
    /// at "needs a model" prompts despite having one.
    func attach(selectionStore: ModelSelectionStore) {
        self.selectionStore = selectionStore
        for (snap, state) in snapshotStates where state.isInstalled {
            selectionStore.autoSelectIfUnconfigured(snap)
        }
    }

    // MARK: - Public — any snapshot

    /// Begin downloading the given snapshot if not already installed.
    func startDownload(of snapshot: ModelSnapshot) {
        if Self.isInstalled(snapshot) {
            snapshotStates[snapshot] = .installed
            return
        }

        // Atomic reset: if a previous attempt left half-downloaded files,
        // wipe the directory so we never end up with mixed-version weights.
        clearSnapshotFiles(for: snapshot)

        let missing = snapshot.manifest.filter { !fileIsValid($0, in: snapshot) }
        guard !missing.isEmpty else {
            snapshotStates[snapshot] = .installed
            return
        }

        // Disk-space precheck.
        let needed = missing.reduce(Int64(0)) { $0 + $1.expectedBytes }
        let dir = Self.directory(for: snapshot)
        if !DiskSpace.hasRoomFor(needed, at: dir) {
            let free = DiskSpace.availableBytes(at: dir).map(DiskSpace.format) ?? "unknown"
            let needStr = DiskSpace.format(needed)
            let msg = "Not enough disk space — \(snapshot.displayName) needs \(needStr) but only \(free) is free. " +
                      "Free up some space and try again."
            AppLog.warning(msg, "download")
            snapshotStates[snapshot] = .failed(msg)
            return
        }

        pendingBySnapshot[snapshot] = PendingDownload(
            pending: missing,
            completed: 0,
            startedAt: Date(),
            totalBytesExpected: needed
        )
        snapshotStates[snapshot] = .downloading(
            progress: 0,
            currentFile: missing.first?.relativePath ?? "",
            bytesPerSecond: 0,
            etaSeconds: nil
        )

        guard let session = urlSession else { return }
        for file in missing {
            guard let url = URL(string: file.downloadURL) else { continue }
            let task = session.downloadTask(with: url)
            taskRegistry[task.taskIdentifier] = (snapshot, file)
            task.resume()
        }
        AppLog.info("Downloading \(snapshot.displayName) — \(missing.count) files, \(DiskSpace.format(needed))", "download")
    }

    /// Retry a failed snapshot — same as `startDownload(of:)` but with the
    /// distinct API for the UI's "Try again" button.
    func retry(_ snapshot: ModelSnapshot) {
        clearSnapshotFiles(for: snapshot)
        startDownload(of: snapshot)
    }

    /// Delete every file for a snapshot. Cancels any in-flight download for
    /// that snapshot first, and drops any user selection that pointed at it.
    func delete(_ snapshot: ModelSnapshot) {
        // Cancel in-flight tasks targeting this snapshot.
        for (id, mapping) in taskRegistry where mapping.snapshot == snapshot {
            urlSession?.getAllTasks { tasks in
                for t in tasks where t.taskIdentifier == id { t.cancel() }
            }
        }
        taskRegistry = taskRegistry.filter { $0.value.snapshot != snapshot }
        pendingBySnapshot.removeValue(forKey: snapshot)

        clearSnapshotFiles(for: snapshot)
        snapshotStates[snapshot] = .absent
        snapshotDiskUsage[snapshot] = 0

        // If the user had selected this snapshot for any capability, drop
        // that selection so the UI re-prompts instead of silently failing.
        selectionStore?.dropSelectionsReferencing(snapshot)

        AppLog.info("Deleted snapshot: \(snapshot.displayName)", "download")
    }

    /// Best-effort: re-scan disk and update snapshot states. Cheap.
    func rescan() {
        for snap in ModelSnapshot.allCases {
            // Don't clobber a download in progress.
            if case .downloading = snapshotStates[snap] { continue }
            snapshotStates[snap] = Self.isInstalled(snap) ? .installed : .absent
            snapshotDiskUsage[snap] = Self.diskUsage(of: snap)
        }
    }

    // MARK: - Static query

    /// Root directory holding all snapshot subdirectories.
    nonisolated static var modelsDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PolyJuiceVoice/MLXModels", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MLXModels", isDirectory: true)
        #endif
    }

    /// Absolute path to a specific snapshot's directory.
    nonisolated static func directory(for snapshot: ModelSnapshot) -> URL {
        modelsDirectory.appendingPathComponent(snapshot.directoryName, isDirectory: true)
    }

    /// `true` when every file required to run the given snapshot is on disk
    /// AND passes the basic content sniff.
    nonisolated static func isInstalled(_ snapshot: ModelSnapshot) -> Bool {
        let fm = FileManager.default
        let dir = directory(for: snapshot)
        for file in snapshot.manifest {
            let url = dir.appendingPathComponent(file.relativePath)
            guard fm.fileExists(atPath: url.path) else { return false }
            guard contentIsValid(at: url) else { return false }
        }
        return true
    }

    /// All currently-installed snapshots. Convenience for UIs that just want
    /// to enumerate "what's on disk?" without iterating `allCases`.
    nonisolated static func installedSnapshots() -> [ModelSnapshot] {
        ModelSnapshot.allCases.filter { isInstalled($0) }
    }

    /// Total bytes occupied on disk by a snapshot's files. 0 if absent.
    nonisolated static func diskUsage(of snapshot: ModelSnapshot) -> Int64 {
        let fm = FileManager.default
        let dir = directory(for: snapshot)
        var total: Int64 = 0
        for file in snapshot.manifest {
            let url = dir.appendingPathComponent(file.relativePath)
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    /// Backward-compat: any snapshot installed at all. Used by the E2E test
    /// to bail when the dev hasn't downloaded anything.
    nonisolated static func areModelsAvailable() -> Bool {
        !installedSnapshots().isEmpty
    }

    // MARK: - Legacy on-disk migration

    /// One-shot rename of pre-matrix directory names so existing installs
    /// don't re-download. Safe to call repeatedly — no-ops once migrated.
    nonisolated private static func migrateLegacyDirectoriesIfNeeded() {
        let fm = FileManager.default
        let root = modelsDirectory
        let migrations: [(legacy: String, target: ModelSnapshot)] = [
            ("Qwen3TTS-CustomVoice-bf16",
             ModelSnapshot(family: .b06, capability: .customVoice, precision: .bf16)),
            ("Qwen3TTS-Base-bf16",
             ModelSnapshot(family: .b06, capability: .base, precision: .bf16)),
            ("Qwen3TTS-VoiceDesign-bf16",
             ModelSnapshot(family: .b17, capability: .voiceDesign, precision: .bf16)),
        ]
        for (legacy, target) in migrations {
            let from = root.appendingPathComponent(legacy, isDirectory: true)
            let to = root.appendingPathComponent(target.directoryName, isDirectory: true)
            guard fm.fileExists(atPath: from.path),
                  !fm.fileExists(atPath: to.path) else { continue }
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                AppLog.info("Migrated legacy snapshot directory \(legacy) → \(target.directoryName)", "download")
            } catch {
                AppLog.warning("Failed to migrate \(legacy): \(error.localizedDescription)", "download")
            }
        }
    }

    // MARK: - File validity

    private func fileIsValid(_ file: ModelFile, in snapshot: ModelSnapshot) -> Bool {
        let url = Self.directory(for: snapshot).appendingPathComponent(file.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return Self.contentIsValid(at: url)
    }

    nonisolated private static func contentIsValid(at url: URL) -> Bool {
        switch url.pathExtension {
        case "json":
            guard let data = try? Data(contentsOf: url),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return false
            }
            return true
        case "safetensors":
            return safetensorsHeaderIsValid(at: url)
        default:
            return true
        }
    }

    nonisolated private static func safetensorsHeaderIsValid(at url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let prefix = fh.readData(ofLength: 8)
        guard prefix.count == 8 else { return false }
        let headerLen = prefix.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        return headerLen > 0 && headerLen < 100_000_000
    }

    /// Atomic per-snapshot wipe — used both for failure recovery and for the
    /// user-initiated "Delete" action. Removes every manifested file (and
    /// the speech_tokenizer subdirectory if empty afterwards).
    private func clearSnapshotFiles(for snapshot: ModelSnapshot) {
        let fm = FileManager.default
        let dir = Self.directory(for: snapshot)
        for file in snapshot.manifest {
            let url = dir.appendingPathComponent(file.relativePath)
            try? fm.removeItem(at: url)
        }
        // Try to remove now-empty subdirectories (e.g. speech_tokenizer/).
        if let contents = try? fm.contentsOfDirectory(atPath: dir.path) {
            for sub in contents {
                let subURL = dir.appendingPathComponent(sub)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: subURL.path, isDirectory: &isDir),
                   isDir.boolValue,
                   (try? fm.contentsOfDirectory(atPath: subURL.path))?.isEmpty == true {
                    try? fm.removeItem(at: subURL)
                }
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId = downloadTask.taskIdentifier
        // The temp file at `location` will be deleted as soon as this delegate
        // returns, so move it synchronously here.
        let mappingResult: (snapshot: ModelSnapshot, file: ModelFile)? = MainActor.assumeIsolated {
            self.taskRegistry[taskId]
        }
        guard let mapping = mappingResult else { return }

        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            let code = httpResponse.statusCode
            let path = mapping.file.relativePath
            Task { @MainActor in
                self.failSnapshot(mapping.snapshot,
                                  reason: "Server returned HTTP \(code) for \(path)")
            }
            return
        }

        let dir = ModelDownloadManager.directory(for: mapping.snapshot)
        let destination = dir.appendingPathComponent(mapping.file.relativePath)

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in
                self.failSnapshot(mapping.snapshot,
                                  reason: "Failed to save \(mapping.file.relativePath): \(message)")
            }
            return
        }

        // Reject HTML error pages masquerading as JSON.
        if destination.pathExtension == "json" {
            let isValid = (try? Data(contentsOf: destination))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
            if !isValid {
                try? FileManager.default.removeItem(at: destination)
                Task { @MainActor in
                    self.failSnapshot(mapping.snapshot,
                                      reason: "Downloaded \(mapping.file.relativePath) is not valid JSON — server may have returned an error page.")
                }
                return
            }
        }

        Task { @MainActor in
            self.taskRegistry.removeValue(forKey: taskId)
            self.markFileComplete(snapshot: mapping.snapshot)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskId = downloadTask.taskIdentifier
        let fileProgress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { @MainActor in
            guard let mapping = self.taskRegistry[taskId] else { return }
            self.publishProgress(snapshot: mapping.snapshot,
                                 currentFile: mapping.file.relativePath,
                                 currentFileProgress: fileProgress,
                                 bytesWritten: bytesWritten)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        let taskId = task.taskIdentifier
        let message = error.localizedDescription
        Task { @MainActor in
            guard let mapping = self.taskRegistry[taskId] else { return }
            self.failSnapshot(mapping.snapshot, reason: message)
        }
    }

    // MARK: - State transitions (main-actor)

    private func failSnapshot(_ snapshot: ModelSnapshot, reason: String) {
        AppLog.error("Snapshot \(snapshot.displayName) failed: \(reason)", "download")
        snapshotStates[snapshot] = .failed(reason)
        pendingBySnapshot.removeValue(forKey: snapshot)
        for (id, mapping) in taskRegistry where mapping.snapshot == snapshot {
            urlSession?.getAllTasks { tasks in
                for t in tasks where t.taskIdentifier == id {
                    t.cancel()
                }
            }
        }
        taskRegistry = taskRegistry.filter { $0.value.snapshot != snapshot }
        clearSnapshotFiles(for: snapshot)
        snapshotDiskUsage[snapshot] = 0
    }

    private func markFileComplete(snapshot: ModelSnapshot) {
        guard var entry = pendingBySnapshot[snapshot] else { return }
        entry.completed += 1
        pendingBySnapshot[snapshot] = entry

        let total = entry.pending.count
        if entry.completed >= total {
            pendingBySnapshot.removeValue(forKey: snapshot)
            if Self.isInstalled(snapshot) {
                snapshotStates[snapshot] = .installed
                snapshotDiskUsage[snapshot] = Self.diskUsage(of: snapshot)
                AppLog.notice("Snapshot \(snapshot.displayName) installed.", "download")
                // First snapshot to cover a capability becomes its default.
                // Power users can reassign in the manager.
                selectionStore?.autoSelectIfUnconfigured(snapshot)
            } else {
                snapshotStates[snapshot] = .failed("Some files failed verification after download.")
                clearSnapshotFiles(for: snapshot)
                snapshotDiskUsage[snapshot] = 0
            }
        } else {
            let progress = Double(entry.completed) / Double(max(total, 1))
            let currentFile = entry.pending[min(entry.completed, total - 1)].relativePath
            let bps = throughput(for: entry)
            let eta = etaSeconds(for: entry, bps: bps)
            snapshotStates[snapshot] = .downloading(
                progress: progress,
                currentFile: currentFile,
                bytesPerSecond: bps,
                etaSeconds: eta
            )
        }
    }

    private func publishProgress(snapshot: ModelSnapshot,
                                 currentFile: String,
                                 currentFileProgress: Double,
                                 bytesWritten: Int64) {
        guard var entry = pendingBySnapshot[snapshot] else { return }
        let now = Date()
        entry.bytesWrittenWindow.append((now, bytesWritten))
        let cutoff = now.addingTimeInterval(-10)
        entry.bytesWrittenWindow.removeAll { $0.at < cutoff }
        entry.totalBytesWritten += bytesWritten

        // Only push to the @Published map at most ~7Hz — anything faster
        // overwhelms downstream views (the manager re-renders every glass
        // card on each emit). Internal accounting (`pendingBySnapshot`)
        // still updates on every byte so throughput / ETA stays accurate.
        if now.timeIntervalSince(entry.lastUIPublish) < Self.uiPublishInterval {
            pendingBySnapshot[snapshot] = entry
            return
        }
        entry.lastUIPublish = now
        pendingBySnapshot[snapshot] = entry

        let total = entry.pending.count
        let overall = (Double(entry.completed) + currentFileProgress) / Double(max(total, 1))
        let bps = throughput(for: entry)
        let eta = etaSeconds(for: entry, bps: bps)
        snapshotStates[snapshot] = .downloading(
            progress: overall,
            currentFile: currentFile,
            bytesPerSecond: bps,
            etaSeconds: eta
        )
    }

    private func throughput(for entry: PendingDownload) -> Double {
        guard let first = entry.bytesWrittenWindow.first,
              let last = entry.bytesWrittenWindow.last,
              last.at > first.at else {
            return 0
        }
        let bytes = entry.bytesWrittenWindow.reduce(Int64(0)) { $0 + $1.bytes }
        let elapsed = last.at.timeIntervalSince(first.at)
        return Double(bytes) / max(elapsed, 0.001)
    }

    private func etaSeconds(for entry: PendingDownload, bps: Double) -> Double? {
        guard bps > 0 else { return nil }
        let remaining = max(entry.totalBytesExpected - entry.totalBytesWritten, 0)
        return Double(remaining) / bps
    }
}
