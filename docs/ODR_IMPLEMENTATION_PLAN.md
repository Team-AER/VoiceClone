# On-Demand Resources (ODR) Implementation Plan

## Overview

This document outlines the plan for implementing Apple's On-Demand Resources (ODR) to deliver the large MLX model files (~2.6GB total) after initial app installation while still keeping them within the App Store distribution system.

### Why ODR?

| Approach | App Store Hosted | Initial Size | Offline After Download | Auto-Updates |
|----------|------------------|--------------|------------------------|--------------|
| Bundle Everything | ✅ | ~2.6GB+ | ✅ | ✅ |
| **ODR (This Plan)** | ✅ | ~50MB | ✅ | ✅ |
| Self-Hosted Download | ❌ | ~50MB | ✅ | ❌ |

ODR keeps the benefits of App Store distribution (CDN, code signing, app review) while dramatically reducing initial download size.

---

## Model Inventory

### Current Model Files

| Model | File | Size | ODR Tag |
|-------|------|------|---------|
| Qwen3 TTS Talker | `weights.npz` | ~1.0GB | `tts_model_talker` |
| Qwen3 TTS Talker | `weights.pkl` | ~1.2GB | `tts_model_talker` |
| Qwen3 TTS Talker | `config.json` | ~2KB | `tts_model_talker` |
| Speech Decoder | `weights.npz` | ~436MB | `tts_model_decoder` |
| Speech Decoder | `config.json` | ~1KB | `tts_model_decoder` |

**Total ODR Size**: ~2.6GB

---

## Implementation Phases

### Phase 1: Xcode Project Configuration

#### 1.1 Create ODR Directory Structure

```
VoiceClone/
├── Resources/
│   └── ODRModels/              # NEW: ODR-tagged resources
│       ├── Qwen3TTS_INT4/
│       │   ├── weights.npz
│       │   ├── weights.pkl
│       │   └── config.json
│       └── Qwen3TTS_Decoder/
│           ├── weights.npz
│           └── config.json
```

#### 1.2 Configure Resource Tags in Xcode

1. Select the `Qwen3TTS_INT4` folder in Xcode
2. In File Inspector → On Demand Resource Tags, add: `tts_model_talker`
3. Select the `Qwen3TTS_Decoder` folder
4. Add tag: `tts_model_decoder`

#### 1.3 Configure Build Settings

In `VoiceClone.xcodeproj`:
- Enable: **Build Settings → Enable On Demand Resources** = `YES`
- Set: **Build Settings → On Demand Resources Initial Install Tags** = (empty for deferred download)
- Set: **Build Settings → On Demand Resources Prefetch Order** = `tts_model_talker, tts_model_decoder`

---

### Phase 2: ODR Manager Implementation

#### 2.1 Create ODRManager Actor

Create `VoiceClone/Core/ML/ODR/ODRManager.swift`:

```swift
import Foundation

/// Manages On-Demand Resources for MLX models
@MainActor
final class ODRManager: ObservableObject {

    // MARK: - Types

    enum ODRTag: String, CaseIterable {
        case talkerModel = "tts_model_talker"
        case decoderModel = "tts_model_decoder"

        var displayName: String {
            switch self {
            case .talkerModel: return "Voice Model"
            case .decoderModel: return "Audio Decoder"
            }
        }

        var estimatedSizeMB: Int {
            switch self {
            case .talkerModel: return 2200  // ~2.2GB
            case .decoderModel: return 440  // ~440MB
            }
        }
    }

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case error(String)
    }

    // MARK: - Published State

    @Published private(set) var talkerState: DownloadState = .notDownloaded
    @Published private(set) var decoderState: DownloadState = .notDownloaded
    @Published private(set) var overallProgress: Double = 0.0

    // MARK: - Private Properties

    private var activeRequests: [ODRTag: NSBundleResourceRequest] = [:]
    private var progressObservers: [ODRTag: NSKeyValueObservation] = [:]

    // MARK: - Initialization

    init() {
        checkInitialAvailability()
    }

    // MARK: - Public API

    /// Check if all required models are available
    var allModelsAvailable: Bool {
        talkerState == .downloaded && decoderState == .downloaded
    }

    /// Total estimated download size in MB
    var totalDownloadSizeMB: Int {
        var size = 0
        if talkerState != .downloaded { size += ODRTag.talkerModel.estimatedSizeMB }
        if decoderState != .downloaded { size += ODRTag.decoderModel.estimatedSizeMB }
        return size
    }

    /// Download all required models
    func downloadAllModels() async throws {
        // Download in parallel
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.downloadModel(tag: .talkerModel) }
            group.addTask { try await self.downloadModel(tag: .decoderModel) }
            try await group.waitForAll()
        }
    }

    /// Download a specific model
    func downloadModel(tag: ODRTag) async throws {
        updateState(for: tag, state: .downloading(progress: 0))

        let request = NSBundleResourceRequest(tags: [tag.rawValue])
        request.loadingPriority = NSBundleResourceRequestLoadingPriorityUrgent
        activeRequests[tag] = request

        // Observe progress
        let observation = request.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor in
                self?.updateState(for: tag, state: .downloading(progress: progress.fractionCompleted))
                self?.updateOverallProgress()
            }
        }
        progressObservers[tag] = observation

        // Conditionally check availability first
        let isAvailable = await request.conditionallyBeginAccessingResources()

        if isAvailable {
            updateState(for: tag, state: .downloaded)
            return
        }

        // Need to download
        do {
            try await request.beginAccessingResources()
            updateState(for: tag, state: .downloaded)
        } catch {
            updateState(for: tag, state: .error(error.localizedDescription))
            throw error
        }
    }

    /// Get the URL for a downloaded model directory
    func modelURL(for tag: ODRTag) -> URL? {
        guard stateFor(tag: tag) == .downloaded else { return nil }

        let subdirectory: String
        switch tag {
        case .talkerModel:
            subdirectory = "ODRModels/Qwen3TTS_INT4"
        case .decoderModel:
            subdirectory = "ODRModels/Qwen3TTS_Decoder"
        }

        return Bundle.main.url(forResource: nil, withExtension: nil, subdirectory: subdirectory)
    }

    /// Release resources (allows iOS to purge if needed)
    func releaseResources(for tag: ODRTag) {
        activeRequests[tag]?.endAccessingResources()
        activeRequests[tag] = nil
        progressObservers[tag] = nil
    }

    /// Cancel an in-progress download
    func cancelDownload(for tag: ODRTag) {
        activeRequests[tag]?.progress.cancel()
        activeRequests[tag] = nil
        progressObservers[tag] = nil
        updateState(for: tag, state: .notDownloaded)
    }

    // MARK: - Private Helpers

    private func checkInitialAvailability() {
        Task {
            for tag in ODRTag.allCases {
                let request = NSBundleResourceRequest(tags: [tag.rawValue])
                let available = await request.conditionallyBeginAccessingResources()
                if available {
                    updateState(for: tag, state: .downloaded)
                    activeRequests[tag] = request
                }
            }
        }
    }

    private func updateState(for tag: ODRTag, state: DownloadState) {
        switch tag {
        case .talkerModel:
            talkerState = state
        case .decoderModel:
            decoderState = state
        }
    }

    private func stateFor(tag: ODRTag) -> DownloadState {
        switch tag {
        case .talkerModel: return talkerState
        case .decoderModel: return decoderState
        }
    }

    private func updateOverallProgress() {
        var totalProgress = 0.0
        var count = 0

        for tag in ODRTag.allCases {
            if case .downloading(let progress) = stateFor(tag: tag) {
                totalProgress += progress
                count += 1
            } else if stateFor(tag: tag) == .downloaded {
                totalProgress += 1.0
                count += 1
            }
        }

        overallProgress = count > 0 ? totalProgress / Double(ODRTag.allCases.count) : 0
    }
}
```

#### 2.2 Create Download UI View

Create `VoiceClone/Features/Onboarding/ModelDownloadView.swift`:

```swift
import SwiftUI

struct ModelDownloadView: View {
    @StateObject private var odrManager = ODRManager()
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""

    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Download Voice Models")
                    .font(.title)
                    .fontWeight(.bold)

                Text("VoiceClone needs to download AI models to generate speech on your device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)

            Spacer()

            // Download Status
            VStack(spacing: 16) {
                ModelDownloadRow(
                    name: "Voice Model",
                    sizeMB: ODRManager.ODRTag.talkerModel.estimatedSizeMB,
                    state: odrManager.talkerState
                )

                ModelDownloadRow(
                    name: "Audio Decoder",
                    sizeMB: ODRManager.ODRTag.decoderModel.estimatedSizeMB,
                    state: odrManager.decoderState
                )
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            // Overall Progress
            if case .downloading = odrManager.talkerState {
                VStack(spacing: 8) {
                    ProgressView(value: odrManager.overallProgress)
                        .progressViewStyle(.linear)

                    Text("\(Int(odrManager.overallProgress * 100))% complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Action Button
            if odrManager.allModelsAvailable {
                Button("Continue") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    startDownload()
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download (\(formatSize(odrManager.totalDownloadSizeMB)))")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isDownloading)
            }

            // Wi-Fi Recommendation
            Text("We recommend using Wi-Fi for this download.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .alert("Download Error", isPresented: $showError) {
            Button("Retry") { startDownload() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    private var isDownloading: Bool {
        if case .downloading = odrManager.talkerState { return true }
        if case .downloading = odrManager.decoderState { return true }
        return false
    }

    private func startDownload() {
        Task {
            do {
                try await odrManager.downloadAllModels()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func formatSize(_ mb: Int) -> String {
        if mb >= 1000 {
            return String(format: "%.1f GB", Double(mb) / 1000)
        }
        return "\(mb) MB"
    }
}

struct ModelDownloadRow: View {
    let name: String
    let sizeMB: Int
    let state: ODRManager.DownloadState

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                    .font(.headline)
                Text(formatSize(sizeMB))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusView
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .notDownloaded:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .downloading(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .frame(width: 24, height: 24)
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func formatSize(_ mb: Int) -> String {
        if mb >= 1000 {
            return String(format: "%.1f GB", Double(mb) / 1000)
        }
        return "\(mb) MB"
    }
}
```

---

### Phase 3: Integration with MLXTTSService

#### 3.1 Update Model Path Resolution

Modify `MLXTTSService.swift` to support ODR paths:

```swift
// Add ODRManager dependency
@MainActor
final class MLXTTSService: ObservableObject {
    private let odrManager: ODRManager

    init(odrManager: ODRManager = ODRManager()) {
        self.odrManager = odrManager
    }

    // Update getModelPath to check ODR first
    private func getModelPath(for modelType: ModelType) throws -> URL {
        // 1. Check ODR resources first (production)
        if let odrURL = getODRModelPath(for: modelType) {
            return odrURL
        }

        // 2. Check Documents directory (fallback for manual download)
        if let docsURL = getDocumentsModelPath(for: modelType) {
            return docsURL
        }

        // 3. Development paths (for Xcode builds)
        if let devURL = getDevelopmentModelPath(for: modelType) {
            return devURL
        }

        throw MLXTTSError.modelNotFound(modelType.rawValue)
    }

    private func getODRModelPath(for modelType: ModelType) -> URL? {
        let tag: ODRManager.ODRTag = modelType == .talker ? .talkerModel : .decoderModel
        return odrManager.modelURL(for: tag)
    }

    enum ModelType: String {
        case talker = "Qwen3TTS_INT4"
        case decoder = "Qwen3TTS_Decoder"
    }
}
```

#### 3.2 Add Pre-flight Check

```swift
extension MLXTTSService {
    /// Check if models are ready, returns missing tags if not
    func checkModelAvailability() -> [ODRManager.ODRTag] {
        var missing: [ODRManager.ODRTag] = []

        if !odrManager.allModelsAvailable {
            if odrManager.talkerState != .downloaded {
                missing.append(.talkerModel)
            }
            if odrManager.decoderState != .downloaded {
                missing.append(.decoderModel)
            }
        }

        return missing
    }
}
```

---

### Phase 4: App Flow Integration

#### 4.1 Update App Entry Point

Modify `VoiceCloneApp.swift`:

```swift
@main
struct VoiceCloneApp: App {
    @StateObject private var odrManager = ODRManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding && odrManager.allModelsAvailable {
                ContentView()
                    .environmentObject(odrManager)
            } else {
                ModelDownloadView {
                    hasCompletedOnboarding = true
                }
                .environmentObject(odrManager)
            }
        }
    }
}
```

#### 4.2 Handle Model Purging

iOS may purge ODR assets when storage is low. Handle this gracefully:

```swift
// In ContentView or main navigation
struct ContentView: View {
    @EnvironmentObject var odrManager: ODRManager
    @State private var showDownloadPrompt = false

    var body: some View {
        NavigationStack {
            // Main content
        }
        .onAppear {
            // Check if models were purged
            if !odrManager.allModelsAvailable {
                showDownloadPrompt = true
            }
        }
        .sheet(isPresented: $showDownloadPrompt) {
            ModelDownloadView {
                showDownloadPrompt = false
            }
        }
    }
}
```

---

### Phase 5: Testing Strategy

#### 5.1 Simulator Testing (Limited)

ODR works in Simulator but downloads from Xcode's hosted server:

```bash
# Host ODR assets for simulator testing
# In Xcode: Product → Scheme → Edit Scheme → Run → Options
# Set "On Demand Resources: Download from Development Server"
```

#### 5.2 TestFlight Testing

ODR assets are hosted by Apple during TestFlight:
1. Archive and upload to App Store Connect
2. Enable "Include On-Demand Resources" in TestFlight build
3. Test download flow on real devices

#### 5.3 Unit Tests

```swift
final class ODRManagerTests: XCTestCase {

    func testInitialStateIsNotDownloaded() {
        let manager = ODRManager()
        XCTAssertEqual(manager.talkerState, .notDownloaded)
        XCTAssertEqual(manager.decoderState, .notDownloaded)
    }

    func testAllModelsAvailableIsFalseInitially() {
        let manager = ODRManager()
        XCTAssertFalse(manager.allModelsAvailable)
    }

    func testTotalDownloadSizeCalculation() {
        let manager = ODRManager()
        let expectedSize = ODRManager.ODRTag.talkerModel.estimatedSizeMB
                        + ODRManager.ODRTag.decoderModel.estimatedSizeMB
        XCTAssertEqual(manager.totalDownloadSizeMB, expectedSize)
    }
}
```

---

## Configuration Checklist

### Xcode Project Settings

- [ ] Enable "Enable On Demand Resources" in Build Settings
- [ ] Create `ODRModels/` directory structure
- [ ] Add resource tags to model directories
- [ ] Configure prefetch order (optional)
- [ ] Leave "Initial Install Tags" empty for deferred download

### App Store Connect

- [ ] Enable "Host On-Demand Resources" (automatic with ODR-enabled builds)
- [ ] Verify ODR size limits (iOS: 20GB total, 2GB per tag)

### Code Changes

- [ ] Implement `ODRManager` actor
- [ ] Create `ModelDownloadView` UI
- [ ] Update `MLXTTSService` model path resolution
- [ ] Add onboarding flow for first-time download
- [ ] Handle model purging scenarios
- [ ] Add progress tracking and error handling

---

## Error Handling

### Common ODR Errors

| Error | Cause | Resolution |
|-------|-------|------------|
| `NSBundleOnDemandResourceOutOfSpaceError` | Device low on storage | Show user-friendly message, suggest freeing space |
| `NSBundleOnDemandResourceExceededMaximumSizeError` | Asset > 2GB per tag | Split into multiple tags |
| `NSBundleOnDemandResourceInvalidTagError` | Tag doesn't exist | Check Xcode configuration |
| Network errors | No connectivity | Retry with exponential backoff |

### Retry Logic

```swift
func downloadWithRetry(tag: ODRTag, maxAttempts: Int = 3) async throws {
    var lastError: Error?

    for attempt in 1...maxAttempts {
        do {
            try await downloadModel(tag: tag)
            return
        } catch {
            lastError = error
            if attempt < maxAttempts {
                let delay = pow(2.0, Double(attempt)) // Exponential backoff
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    throw lastError!
}
```

---

## Size Limits Reference

| Platform | Per-Tag Limit | Total ODR Limit |
|----------|---------------|-----------------|
| iOS | 2 GB | 20 GB |
| tvOS | 2 GB | 20 GB |
| watchOS | 256 MB | 256 MB |

**Note**: The talker model (~2.2GB combined) exceeds the 2GB per-tag limit. You may need to split it:
- `tts_model_talker_weights` for `weights.npz`
- `tts_model_talker_config` for `weights.pkl` + `config.json`

---

## Timeline Estimate

| Phase | Description | Complexity |
|-------|-------------|------------|
| Phase 1 | Xcode Configuration | Low |
| Phase 2 | ODRManager Implementation | Medium |
| Phase 3 | MLXTTSService Integration | Medium |
| Phase 4 | App Flow Integration | Low |
| Phase 5 | Testing | Medium |

---

## References

- [Apple: On-Demand Resources Guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/On_Demand_Resources_Guide/)
- [Apple: NSBundleResourceRequest](https://developer.apple.com/documentation/foundation/nsbundleresourcerequest)
- [WWDC 2015: App Thinning in Xcode](https://developer.apple.com/videos/play/wwdc2015/404/)
