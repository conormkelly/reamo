#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔨 Building Reamo extension..."
zig build

# Get the output path (Zig prefixes with 'lib')
DYLIB="zig-out/lib/libreaper_reamo.dylib"

if [ ! -f "$DYLIB" ]; then
    echo "❌ Build failed - dylib not found"
    exit 1
fi

# Copy to REAPER UserPlugins (without 'lib' prefix - REAPER expects reaper_*.dylib)
DEST="$HOME/Library/Application Support/REAPER/UserPlugins/reaper_reamo.dylib"

echo "📦 Installing to REAPER UserPlugins..."
cp "$DYLIB" "$DEST"

echo ""
echo "✅ Done!"
echo ""
echo "📍 Installed: $DEST"
echo ""
echo "Next steps:"
echo "  1. Restart REAPER"
echo "  2. Open REAPER's console: View → Show Console"
echo "  3. Look for 'Reamo: Extension loaded successfully!' message"
echo "  4. Test client: Open your web interface and navigate to /extension/test-client.html"
