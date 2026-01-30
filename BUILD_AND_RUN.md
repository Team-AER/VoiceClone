# Build and Run Guide

Quick guide to build and run VoiceClone after recent updates.

---

## Prerequisites

### Required
- macOS 14.0+ (Sonoma or newer)
- Xcode 16.0+
- iOS 17.0+ device or simulator
- 4GB free disk space (for models)

### Optional
- Physical iPhone/iPad with A14+ chip (for on-device testing)
- Git LFS (if models are stored in LFS)

---

## First Time Setup

### 1. Clone and Prepare
```bash
# Clone repository
cd /Users/prakhar/Developer/AER/VoiceClone

# Check git status
git status

# The following files should be modified:
# - .gitignore (enhanced)
# - VoiceClone.xcodeproj/project.pbxproj (settings updated)
# - CLAUDE.md (MLX documentation)
# - Various Swift files (CoreML removal)
```

### 2. Download Models

**Option A: Manual Download**
```bash
# Create models directory
mkdir -p VoiceClone/Resources/MLXModels

# Download from Hugging Face or your storage
# Models needed for the app bundle:
# - Qwen3TTS_INT4 (1.0GB)
#
# Optional (not bundled to avoid duplicate resource names):
# - Qwen3TTS_Decoder (436MB) → models/MLXModels/Qwen3TTS_Decoder

# Expected structure:
# VoiceClone/Resources/MLXModels/
#   ├── Qwen3TTS_INT4/
#   │   ├── config.json
#   │   └── weights.npz
#
# Optional decoder (kept outside the app bundle):
# models/MLXModels/Qwen3TTS_Decoder/
#   ├── config.json
#   └── weights.npz
```

**Option B: Use Pre-converted Models**
```bash
# If models already converted in scripts/
cp -r scripts/mlx_models/Qwen3TTS_INT4 VoiceClone/Resources/MLXModels/
cp -r scripts/mlx_models/Qwen3TTS_Decoder models/MLXModels/
```

### 3. Open Project
```bash
# Open in Xcode
open VoiceClone.xcodeproj

# Or use Xcode menu:
# File → Open → Select VoiceClone.xcodeproj
```

### 4. Resolve Packages
1. Xcode should automatically start resolving packages
2. If not: **File → Packages → Resolve Package Versions**
3. Wait for mlx-swift to download (~30 seconds)

### 5. Select Target Device
- Top toolbar: Select "VoiceClone" scheme
- Select device: **iPhone 15 Pro** (simulator) or your physical device

---

## Build Instructions

### Quick Build (Cmd+B)
```bash
# From command line:
xcodebuild build \
    -project VoiceClone.xcodeproj \
    -scheme VoiceClone \
    -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

### Clean Build
```bash
# In Xcode: Product → Clean Build Folder (Cmd+Shift+K)

# From command line:
xcodebuild clean \
    -project VoiceClone.xcodeproj \
    -scheme VoiceClone
```

### Expected Build Time
- **First build**: 2-3 minutes (includes package resolution)
- **Incremental builds**: 10-30 seconds
- **Clean rebuild**: 1-2 minutes

---

## Run Instructions

### In Xcode
1. Select device/simulator
2. Press **Cmd+R** or click ▶️ Run button
3. App should launch in ~5 seconds

### From Command Line
```bash
# Build and run in simulator
xcodebuild test \
    -project VoiceClone.xcodeproj \
    -scheme VoiceClone \
    -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

---

## First Launch

### What to Expect
1. App launches with tab navigation
2. 3 tabs: Synthesis, Voice Design, Voice Clone
3. Initially: Model loading ~3-5 seconds
4. Once loaded: Ready to synthesize

### Test Synthesis
1. Go to **Synthesis** tab
2. Enter text: "Hello, this is a test."
3. Select voice: Ryan or Vivian
4. Tap **Synthesize**
5. Audio should play (currently placeholder sine waves)

### Expected Behavior
- ✓ App launches without crash
- ✓ Models load successfully
- ✓ Tokenization works
- ✓ Audio chunks generate
- ✓ Playback works
- ⚠️ Audio quality is placeholder (decoder not implemented)

---

## Running Tests

### All Tests
```bash
# In Xcode: Product → Test (Cmd+U)

# From command line:
xcodebuild test \
    -project VoiceClone.xcodeproj \
    -scheme VoiceClone \
    -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

### Specific Test
```bash
# Run only MLXTTSServiceTests
xcodebuild test \
    -project VoiceClone.xcodeproj \
    -scheme VoiceClone \
    -only-testing:VoiceCloneTests/MLXTTSServiceTests \
    -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

### Test Results
- Tests should complete in ~30 seconds
- Expected: All pass (some may fail if models not present)

---

## Common Issues

### Issue: "Cannot find module 'MLX'"
**Solution**:
1. File → Packages → Resolve Package Versions
2. Clean build folder (Cmd+Shift+K)
3. Rebuild

### Issue: "Model file not found"
**Solution**:
1. Check `VoiceClone/Resources/MLXModels/` exists
2. Verify `config.json` and `weights.npz` are present
3. In Xcode, verify folder is in project navigator
4. Check Build Phases → Copy Bundle Resources

### Issue: Build fails with Swift 6 errors
**Solution**:
1. Verify Xcode 16.0+
2. Check project settings: Build Settings → Swift Language Version = 6.0
3. Update packages to latest versions

### Issue: "Metal device not available"
**Solution**:
1. Requires Metal-capable device/simulator
2. Simulators: Use iPhone 12+ models
3. Physical devices: A12 chip or newer

### Issue: App crashes on launch
**Solution**:
1. Check Console for error messages
2. Verify all resources are bundled
3. Check tokenizer files exist
4. Ensure deployment target matches device

---

## Build Configurations

### Debug (Default)
- Full debug symbols
- No optimization
- Assertions enabled
- Use for: Development

**Build time**: Faster  
**App size**: Larger  
**Performance**: Slower

### Release
- Optimized code
- dSYM symbols only
- Assertions disabled
- Use for: Testing performance, distribution

**Build time**: Slower  
**App size**: Smaller  
**Performance**: Faster

**To use Release**:
1. Product → Scheme → Edit Scheme
2. Run → Build Configuration → Release
3. Build and run

---

## Performance Profiling

### Memory Usage
```bash
# In Xcode:
# 1. Product → Profile (Cmd+I)
# 2. Select "Allocations" instrument
# 3. Run and synthesize some audio
# 4. Check peak memory (should be < 2GB)
```

### Time Profiling
```bash
# 1. Product → Profile (Cmd+I)
# 2. Select "Time Profiler"
# 3. Run and synthesize
# 4. Check for hot spots
```

### Metal Performance
```bash
# 1. Product → Profile (Cmd+I)
# 2. Select "Metal System Trace"
# 3. Run and synthesize
# 4. Verify GPU utilization
```

---

## Device Testing

### iOS Device Setup
1. Connect iPhone/iPad via USB
2. Trust computer on device
3. In Xcode: Window → Devices and Simulators
4. Verify device appears
5. Select device in target dropdown
6. Build and run (Cmd+R)

### First Device Run
- May need to enable Developer Mode on device:
  - Settings → Privacy & Security → Developer Mode → ON
  - Restart device
  
- May need to trust developer certificate:
  - Settings → General → VPN & Device Management
  - Trust your developer certificate

---

## Distribution Build

### Archive
```bash
# In Xcode:
# 1. Product → Archive
# 2. Wait for archive to complete (~2 minutes)
# 3. Organizer window opens automatically
```

### Export
```bash
# In Organizer:
# 1. Select archive
# 2. Click "Distribute App"
# 3. Choose distribution method:
#    - App Store Connect
#    - Ad Hoc
#    - Enterprise
#    - Development
# 4. Follow wizard
```

---

## Next Steps After Successful Build

1. **Test All Features**
   - [ ] Synthesis with preset voices
   - [ ] Voice design with instructions
   - [ ] Voice cloning (currently placeholder)
   - [ ] Recording
   - [ ] Playback controls
   - [ ] Export audio

2. **Implement Speech Decoder**
   - See `DECODER_STATUS.md`
   - Estimated: 2-3 days
   - Enables real speech output

3. **Optimize Performance**
   - Profile with Instruments
   - Reduce memory usage
   - Optimize model loading

4. **Add Features**
   - Voice library
   - Saved voices
   - Custom voice presets
   - Batch synthesis

---

## Support

### Documentation
- `CLAUDE.md` - Developer guide
- `XCODE_PROJECT_SETUP.md` - Project configuration
- `PROJECT_STATUS.md` - Current status
- `DECODER_STATUS.md` - Decoder implementation

### Troubleshooting
- Check build logs: View → Navigators → Reports
- Check console: Debug → Activate Console
- View diagnostics: Product → Perform Action → Generate Build Reports

### Getting Help
- Check GitHub issues
- Review MLX documentation
- Apple Developer Forums
- Swift Forums

---

**Ready to build?** Open `VoiceClone.xcodeproj` and press **Cmd+R**! 🚀
