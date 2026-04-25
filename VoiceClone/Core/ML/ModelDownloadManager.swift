//
//  ModelDownloadManager.swift
//  VoiceClone
//
//  Downloads pre-converted MLX weights from HuggingFace at first launch and
//  on demand thereafter. The required snapshot (CustomVoice) gates the launch
//  screen; Base and VoiceDesign are opt-in downloads from the Model Manager.
//

import Foundation

// MARK: - Per-snapshot state

enum SnapshotInstallState: Equatable {
    case absent
    case checking
    case downloading(progress: Double, currentFile: String)
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

/// Gate state for the launch screen. Mirrors the required snapshot state but
/// keeps the existing API names stable for `RootView` / `ModelDownloadView`.
enum ModelDownloadState: Equatable {
    case checking
    case awaitingPermission
    case ready
    case downloading(file: String, progress: Double, overallProgress: Double)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - Manager

@MainActor
final class ModelDownloadManager: NSObject, ObservableObject {

    /// Gate state — only reflects the required (CustomVoice) snapshot.
    @Published private(set) var state: ModelDownloadState = .checking

    /// Per-snapshot install state — used by the Model Manager UI for
    /// optional downloads (Base, VoiceDesign).
    @Published private(set) var snapshotStates: [ModelSnapshot: SnapshotInstallState] = [:]

    private var urlSession: URLSession?
    /// Maps a URLSessionDownloadTask back to the (snapshot, file) it was
    /// fetching. Tasks are dispatched from background queues so we keep this
    /// keyed by `taskIdentifier`, which is stable for the lifetime of the task.
    private var taskRegistry: [Int: (snapshot: ModelSnapshot, file: ModelFile)] = [:]
    /// Per-snapshot pending file count + completed count, for progress UI.
    private var pendingBySnapshot: [ModelSnapshot: (pending: [ModelFile], completed: Int)] = [:]

    override init() {
        super.init()
        // Lazy URLSession with a background-tolerant timeout.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        // Initial scan: see what's already on disk.
        for snap in ModelSnapshot.allCases {
            snapshotStates[snap] = Self.isInstalled(snap) ? .installed : .absent
        }
        refreshGateState()
    }

    // MARK: - Public — gate snapshot

    /// Trigger a download of the required snapshot (called from the launch UI).
    func startDownload() {
        startDownload(of: .customVoice)
    }

    func retry() {
        clearCorruptFiles(for: .customVoice)
        startDownload()
    }

    // MARK: - Public — any snapshot

    /// Begin downloading the given snapshot if not already installed.
    func startDownload(of snapshot: ModelSnapshot) {
        if Self.isInstalled(snapshot) {
            snapshotStates[snapshot] = .installed
            refreshGateState()
            return
        }
        clearCorruptFiles(for: snapshot)
        let missing = snapshot.manifest.filter { !fileIsValid($0, in: snapshot) }
        guard !missing.isEmpty else {
            snapshotStates[snapshot] = .installed
            refreshGateState()
            return
        }
        pendingBySnapshot[snapshot] = (missing, 0)
        snapshotStates[snapshot] = .downloading(progress: 0, currentFile: missing.first?.relativePath ?? "")
        refreshGateState()

        guard let session = urlSession else { return }
        for file in missing {
            guard let url = URL(string: file.downloadURL) else { continue }
            let task = session.downloadTask(with: url)
            taskRegistry[task.taskIdentifier] = (snapshot, file)
            task.resume()
        }
    }

    /// Best-effort: re-scan disk and update snapshot states. Cheap.
    func rescan() {
        for snap in ModelSnapshot.allCases {
            // Don't clobber a download in progress.
            if case .downloading = snapshotStates[snap] { continue }
            snapshotStates[snap] = Self.isInstalled(snap) ? .installed : .absent
        }
        refreshGateState()
    }

    // MARK: - Static query

    /// Root directory holding all snapshot subdirectories.
    nonisolated static var modelsDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VoiceClone/MLXModels", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MLXModels", isDirectory: true)
        #endif
    }

    /// Absolute path to a specific snapshot's directory.
    nonisolated static func directory(for snapshot: ModelSnapshot) -> URL {
        modelsDirectory.appendingPathComponent(snapshot.rawValue, isDirectory: true)
    }

    /// Required-snapshot directory. Kept as a non-deprecated alias so call
    /// sites that don't care about variant selection (the launch gate, the
    /// E2E test) still work.
    nonisolated static var currentModelDirectory: URL {
        directory(for: .customVoice)
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

    /// Backward-compat for the E2E test — true when the required (CustomVoice)
    /// snapshot is installed.
    nonisolated static func areModelsAvailable() -> Bool {
        isInstalled(.customVoice)
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

    private func clearCorruptFiles(for snapshot: ModelSnapshot) {
        let fm = FileManager.default
        let dir = Self.directory(for: snapshot)
        for file in snapshot.manifest {
            let url = dir.appendingPathComponent(file.relativePath)
            guard fm.fileExists(atPath: url.path) else { continue }
            if !Self.contentIsValid(at: url) {
                try? fm.removeItem(at: url)
                print("⚠️ Removed corrupt cached file: \(snapshot.rawValue)/\(file.relativePath)")
            }
        }
    }

    // MARK: - Gate state plumbing

    /// Recompute the launch-screen `state` from the required snapshot's state.
    private func refreshGateState() {
        guard let required = snapshotStates[.customVoice] else {
            state = .checking
            return
        }
        switch required {
        case .absent:
            state = .awaitingPermission
        case .checking:
            state = .checking
        case .downloading(let progress, let currentFile):
            state = .downloading(file: currentFile, progress: progress, overallProgress: progress)
        case .installed:
            state = .ready
        case .failed(let msg):
            state = .failed(msg)
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
        // returns, so move it synchronously here. We also need to know which
        // (snapshot, file) this task corresponds to, which lives on @MainActor.
        // Read the registry off the main actor by hopping briefly.
        let mappingResult: (snapshot: ModelSnapshot, file: ModelFile)? = MainActor.assumeIsolated {
            self.taskRegistry[taskId]
        }
        guard let mapping = mappingResult else { return }

        // HTTP error → record failure.
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
                                 currentFileProgress: fileProgress)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let taskId = task.taskIdentifier
        let message = error.localizedDescription
        Task { @MainActor in
            guard let mapping = self.taskRegistry[taskId] else { return }
            self.failSnapshot(mapping.snapshot, reason: message)
        }
    }

    // MARK: - State transitions (main-actor)

    private func failSnapshot(_ snapshot: ModelSnapshot, reason: String) {
        snapshotStates[snapshot] = .failed(reason)
        pendingBySnapshot.removeValue(forKey: snapshot)
        // Cancel any sibling tasks for this snapshot.
        for (id, mapping) in taskRegistry where mapping.snapshot == snapshot {
            urlSession?.getAllTasks { tasks in
                for t in tasks where t.taskIdentifier == id {
                    t.cancel()
                }
            }
        }
        taskRegistry = taskRegistry.filter { $0.value.snapshot != snapshot }
        refreshGateState()
    }

    private func markFileComplete(snapshot: ModelSnapshot) {
        guard var entry = pendingBySnapshot[snapshot] else { return }
        entry.completed += 1
        pendingBySnapshot[snapshot] = entry

        let total = entry.pending.count
        if entry.completed >= total {
            pendingBySnapshot.removeValue(forKey: snapshot)
            // Final verification: a corrupt file would still mean "absent."
            if Self.isInstalled(snapshot) {
                snapshotStates[snapshot] = .installed
            } else {
                snapshotStates[snapshot] = .failed("Some files failed verification after download.")
            }
        } else {
            let progress = Double(entry.completed) / Double(max(total, 1))
            let currentFile = entry.pending[min(entry.completed, total - 1)].relativePath
            snapshotStates[snapshot] = .downloading(progress: progress, currentFile: currentFile)
        }
        refreshGateState()
    }

    private func publishProgress(snapshot: ModelSnapshot,
                                 currentFile: String,
                                 currentFileProgress: Double) {
        guard let entry = pendingBySnapshot[snapshot] else { return }
        let total = entry.pending.count
        let overall = (Double(entry.completed) + currentFileProgress) / Double(max(total, 1))
        snapshotStates[snapshot] = .downloading(progress: overall, currentFile: currentFile)
        refreshGateState()
    }
}
