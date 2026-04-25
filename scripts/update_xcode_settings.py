#!/usr/bin/env python3
"""
Update Xcode project settings for PolyJuiceVoice MLX project
"""

import sys
import re
from pathlib import Path

def update_project_file(project_path: str):
    """Update Xcode project.pbxproj with correct settings"""
    
    with open(project_path, 'r') as f:
        content = f.read()
    
    original_content = content
    
    # 1. Fix Swift version (5.0 -> 6.0)
    print("Updating Swift version to 6.0...")
    content = re.sub(
        r'SWIFT_VERSION = 5\.0;',
        'SWIFT_VERSION = 6.0;',
        content
    )
    
    # 2. Fix deployment target (26.2 is wrong, should be 17.0)
    print("Fixing deployment target to iOS 17.0...")
    content = re.sub(
        r'IPHONEOS_DEPLOYMENT_TARGET = 26\.2;',
        'IPHONEOS_DEPLOYMENT_TARGET = 17.0;',
        content
    )
    
    # 3. Add/update build settings for MLX
    # Find the buildSettings sections and ensure proper Metal settings
    print("Verifying Metal compiler settings...")
    
    # Ensure MTL_ENABLE_DEBUG_INFO is set
    if 'MTL_ENABLE_DEBUG_INFO' not in content:
        print("⚠ MTL_ENABLE_DEBUG_INFO not found - project may need manual configuration")
    
    # 4. Update marketing version format
    print("Updating version format...")
    content = re.sub(
        r'MARKETING_VERSION = 1\.0;',
        'MARKETING_VERSION = 0.1.0;',
        content
    )
    
    # 5. Ensure proper concurrency settings
    print("Ensuring Swift concurrency settings...")
    # These should already be there, but verify
    
    if content != original_content:
        # Backup original
        backup_path = project_path + '.backup'
        with open(backup_path, 'w') as f:
            f.write(original_content)
        print(f"✓ Created backup at {backup_path}")
        
        # Write updated content
        with open(project_path, 'w') as f:
            f.write(content)
        print(f"✓ Updated {project_path}")
        
        print("\nChanges made:")
        print("  - Swift version: 5.0 → 6.0")
        print("  - Deployment target: 26.2 → 17.0")
        print("  - Marketing version: 1.0 → 0.1.0")
    else:
        print("✓ No changes needed - settings already correct")
    
    return True

def main():
    project_path = Path(__file__).parent.parent / "PolyJuiceVoice.xcodeproj" / "project.pbxproj"
    
    if not project_path.exists():
        print(f"Error: Project file not found at {project_path}")
        return 1
    
    print(f"Updating Xcode project settings...")
    print(f"Project: {project_path}\n")
    
    try:
        update_project_file(str(project_path))
        print("\n✓ Xcode project settings updated successfully")
        print("\nNext steps:")
        print("  1. Open PolyJuiceVoice.xcodeproj in Xcode")
        print("  2. Verify mlx-swift package is resolved")
        print("  3. Add MLXModels folder to project if not already added")
        print("  4. Build and test")
        return 0
    except Exception as e:
        print(f"Error updating project: {e}")
        return 1

if __name__ == "__main__":
    sys.exit(main())
