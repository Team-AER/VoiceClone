# Xcode Project Configuration

**Last Updated**: 2026-01-30  
**Project**: VoiceClone iOS App

---

## Project Settings

### Basic Information
- **Bundle Identifier**: `app.aer.VoiceClone`
- **Product Name**: VoiceClone
- **Version**: 0.1.0 (Build 1)
- **Team**: (Configure in Xcode)

### Platform & Deployment
- **Platforms**: iOS (iPhone/iPad)
- **Deployment Target**: iOS 17.0+
- **Swift Version**: 6.0
- **Supported Devices**: iPhone, iPad
- **Supported Orientations**: Portrait, Landscape

### Build Settings

#### Swift Compiler
```
SWIFT_VERSION = 6.0
SWIFT_STRICT_CONCURRENCY = complete
SWIFT_APPROACHABLE_CONCURRENCY = YES
SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES
ENABLE_STRICT_OBJC_MSGSEND = YES
```

#### Metal Compiler
```
MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE (Debug)
MTL_ENABLE_DEBUG_INFO = NO (Release)
MTL_FAST_MATH = YES
```

#### Optimization
```
SWIFT_OPTIMIZATION_LEVEL = -Onone (Debug)
SWIFT_OPTIMIZATION_LEVEL = -O (Release)
SWIFT_COMPILATION_MODE = wholemodule (Release)
```

---

## Swift Package Dependencies

### mlx-swift
- **Repository**: https://github.com/ml-explore/mlx-swift
- **Version**: Latest (0.20.0+)
- **Products**:
  - MLX
  - MLXNN
  - MLXOptimizers
  - MLXFast

**Installation**:
1. Already added to project
2. Xcode should auto-resolve on open
3. If not: File → Add Package Dependencies → Enter URL

---

## Project Structure

### Main Target (VoiceClone)

**Source Files**:
```
VoiceClone/
├── App/
│   ├── VoiceCloneApp.swift
│   ├── ContentView.swift
│   └── Environment/
│       └── DIContainer.swift
├── Core/
│   ├── TTS/
│   │   └── TTSTypes.swift
│   ├── ML/
│   │   ├── MLX/
│   │   │   ├── MLXTTSService.swift
│   │   │   └── MLXQwen3TTSModel.swift
│   │   └── Tokenizer/
│   │       └── Qwen3Tokenizer.swift
│   ├── Audio/
│   │   ├── AudioEngine.swift
│   │   ├── AudioRecorder.swift
│   │   └── AudioExporter.swift
│   ├── Storage/
│   │   ├── VoiceStorage.swift
│   │   └── CoreDataStack.swift
│   └── Models/
│       ├── Language.swift
│       ├── PresetVoice.swift
│       ├── AudioChunk.swift
│       └── Voice.swift
├── Features/
│   ├── Synthesis/
│   ├── VoiceDesign/
│   ├── VoiceClone/
│   └── VoiceLibrary/
└── Shared/
    └── WaveformView.swift
```

**Resources**:
```
Resources/
├── MLXModels/              # ⚠️ NOT in Git (large files)
│   ├── Qwen3TTS_INT4/
│   │   ├── config.json
│   │   └── weights.npz
├── Tokenizer/
│   ├── vocab.json
│   ├── merges.txt
│   └── special_tokens.json
└── PresetVoices/
    └── voices.json
```

**Decoder model (not bundled)**:
```
models/MLXModels/Qwen3TTS_Decoder/
├── config.json
└── weights.npz
```

### Test Targets

**VoiceCloneTests**:
- `MLXTTSServiceTests.swift`
- `AudioEngineTests.swift`
- Unit tests for core functionality

**VoiceCloneUITests**:
- UI automation tests

---

## Build Configurations

### Debug Configuration
- **Optimization**: `-Onone`
- **Assertions**: Enabled
- **Debug Symbols**: Full
- **Metal Debug**: Enabled
- **Use Case**: Development, debugging

### Release Configuration
- **Optimization**: `-O`
- **Assertions**: Disabled
- **Debug Symbols**: dSYM only
- **Metal Debug**: Disabled
- **Dead Code Stripping**: Yes
- **Use Case**: Production builds

---

## Required Capabilities

### Entitlements
- None currently required
- May need audio recording permission in Info.plist

### Info.plist Keys

**Required**:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>VoiceClone needs microphone access to record voice samples for cloning.</string>

<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>

<key>UIRequiredDeviceCapabilities</key>
<array>
    <string>armv7</string>
    <string>metal</string>
</array>
```

**Optional (for future features)**:
```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>To export generated audio files to your photo library.</string>
```

---

## Frameworks & Libraries

### System Frameworks
- **Foundation** - Core utilities
- **SwiftUI** - UI framework
- **Combine** - Reactive programming
- **AVFoundation** - Audio playback/recording
- **CoreData** - Persistence
- **Metal** - GPU acceleration (via MLX)
- **Accelerate** - Vector operations

### Third-Party
- **mlx-swift** - ML inference (SPM)

---

## Build Scripts

### Pre-Build Scripts
None currently

### Post-Build Scripts
None currently

### Future Considerations
- Script to download MLX models if not present
- Script to verify tokenizer files
- Script to compress assets

---

## Asset Catalog Configuration

### App Icons
- **iOS App Icon**: 1024x1024 required
- Location: `Assets.xcassets/AppIcon.appiconset/`

### Launch Screen
- Using SwiftUI LaunchScreen.storyboard
- Can customize with app branding

### Colors
- Accent Color: System default (customize in Assets.xcassets)
- Dark/Light mode support: Automatic

---

## Code Signing

### Development
- **Team**: (Set in Xcode)
- **Signing Certificate**: Apple Development
- **Provisioning Profile**: Automatic

### Distribution
- **Team**: (Set in Xcode)
- **Signing Certificate**: Apple Distribution
- **Provisioning Profile**: Manual (App Store)

---

## Build Warnings & Errors

### Expected Warnings
None - project should build cleanly

### Common Issues

**Issue**: `Cannot find type 'MLXArray'`
- **Fix**: Ensure mlx-swift package is resolved (File → Packages → Resolve)

**Issue**: `Module 'MLX' not found`
- **Fix**: Clean build folder (Cmd+Shift+K), rebuild

**Issue**: Model files not found at runtime
- **Fix**: Add MLXModels folder to project (drag into Xcode, select "Create folder references")

**Issue**: Tokenizer files not found
- **Fix**: Ensure Tokenizer folder is in Copy Bundle Resources build phase

---

## Performance Optimization

### Build Time
- **Whole Module Optimization**: Enabled in Release
- **Parallel Building**: Enabled
- **Index While Building**: Enabled

### Runtime
- **Metal Shader Caching**: Automatic
- **MLX JIT Compilation**: Automatic
- **Audio Buffer Size**: 1024 samples (adjustable)

---

## Testing Configuration

### Unit Tests
- **Target**: VoiceCloneTests
- **Code Coverage**: Enabled
- **Parallel Testing**: Enabled
- **Test Plans**: Default

### UI Tests
- **Target**: VoiceCloneUITests
- **Test Devices**: iPhone 15 Pro (simulator)
- **Locale**: en_US

---

## Continuous Integration

### GitHub Actions (Suggested)
```yaml
name: iOS Build

on: [push, pull_request]

jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.0.app
      
      - name: Build
        run: |
          xcodebuild build \
            -project VoiceClone.xcodeproj \
            -scheme VoiceClone \
            -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
      
      - name: Test
        run: |
          xcodebuild test \
            -project VoiceClone.xcodeproj \
            -scheme VoiceClone \
            -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

---

## Archive & Distribution

### Creating Archive
```bash
xcodebuild archive \
    -project VoiceClone.xcodeproj \
    -scheme VoiceClone \
    -archivePath ./build/VoiceClone.xcarchive \
    -configuration Release \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO
```

### Exporting IPA
```bash
xcodebuild -exportArchive \
    -archivePath ./build/VoiceClone.xcarchive \
    -exportPath ./build \
    -exportOptionsPlist ExportOptions.plist
```

---

## Known Limitations

1. **Large Model Files**: MLX models (~1GB) not included in Git
   - Must be downloaded separately or via Git LFS
   
2. **iOS 17+ Required**: Uses latest SwiftUI/Combine features
   
3. **Metal Required**: Device must support Metal (A12+ chip)

4. **Memory Usage**: Requires ~2GB RAM for model inference

---

## Troubleshooting

### Build Fails with "Undefined symbol: MLX..."
1. Clean build folder (Cmd+Shift+K)
2. Delete DerivedData: `rm -rf ~/Library/Developer/Xcode/DerivedData`
3. Resolve packages: File → Packages → Resolve Package Versions
4. Rebuild

### Tests Fail: "Model not found"
1. Check MLXModels folder is in project
2. Verify build phase "Copy Bundle Resources"
3. Run from repo root, not Xcode workspace

### Runtime: "Metal device not available"
1. Requires physical device or Metal-capable simulator
2. Check Metal is available: `MTLCreateSystemDefaultDevice()`

---

## Resources

- **Xcode**: Version 16.0+
- **Swift**: Version 6.0
- **iOS SDK**: Version 17.0+
- **MLX Documentation**: https://ml-explore.github.io/mlx/

---

## Maintenance

### Regular Tasks
- [ ] Update Swift package versions quarterly
- [ ] Review and update deployment target yearly
- [ ] Update model files when new versions available
- [ ] Profile memory and performance regularly

### Before Release
- [ ] Update marketing version
- [ ] Increment build number
- [ ] Test on physical devices
- [ ] Profile with Instruments
- [ ] Verify all resources are included
- [ ] Check code signing configuration
