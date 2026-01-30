#!/bin/bash
# Verify that model files are NOT being bundled into the app

echo "🔍 Checking VoiceClone app bundle size..."
echo ""

# Find the most recent build
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "VoiceClone.app" -path "*Debug-iphoneos*" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "⚠️  No app bundle found. Please build the project first:"
    echo "   xcodebuild build -project VoiceClone.xcodeproj -scheme VoiceClone -destination 'generic/platform=iOS'"
    exit 1
fi

echo "📦 App bundle location:"
echo "   $APP_PATH"
echo ""

# Check bundle size
BUNDLE_SIZE=$(du -sh "$APP_PATH" | awk '{print $1}')
echo "📊 Total bundle size: $BUNDLE_SIZE"
echo ""

# Check for large model files
echo "🔎 Checking for large model files (.npz, .pkl):"
LARGE_FILES=$(find "$APP_PATH" -type f \( -name "*.npz" -o -name "*.pkl" \) -exec ls -lh {} \; 2>/dev/null)

if [ -z "$LARGE_FILES" ]; then
    echo "   ✅ No large model files found in bundle (GOOD!)"
    echo ""
    echo "✅ Build is optimized - model files are NOT being bundled"
    exit 0
else
    echo "   ❌ Found large model files:"
    echo "$LARGE_FILES" | awk '{print "      " $9 " (" $5 ")"}'
    echo ""
    echo "❌ Model files are still being bundled!"
    echo ""
    echo "💡 To fix, try one of these solutions:"
    echo ""
    echo "   1. Clean DerivedData and rebuild:"
    echo "      rm -rf ~/Library/Developer/Xcode/DerivedData/VoiceClone-*"
    echo "      xcodebuild build -project VoiceClone.xcodeproj -scheme VoiceClone -destination 'generic/platform=iOS'"
    echo ""
    echo "   2. Move model files outside project (recommended):"
    echo "      mkdir -p ~/Developer/MLXModels"
    echo "      mv VoiceClone/Resources/MLXModels/* ~/Developer/MLXModels/"
    echo "      # Then update dev paths in MLXTTSService.swift"
    exit 1
fi
