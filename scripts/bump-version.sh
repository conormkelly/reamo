#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/bump-version.sh <version>
# Examples:
#   ./scripts/bump-version.sh 0.8.0
#   ./scripts/bump-version.sh 0.8.0-rc1
#
# Updates all version strings across the project.
# Does NOT create a git commit or tag — that's up to you.

VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>"
  echo "  e.g. $0 0.8.0"
  echo "  e.g. $0 0.8.0-rc1"
  exit 1
fi

# Validate version format: major.minor.patch with optional -prerelease suffix
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
  echo "Error: Invalid version format '$VERSION'"
  echo "Expected: X.Y.Z or X.Y.Z-suffix (e.g. 1.2.3, 1.2.3-rc1)"
  exit 1
fi

# Resolve project root (parent of scripts/)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Bumping version to $VERSION"
echo ""

# --- extension/build.zig.zon ---
FILE="$ROOT/extension/build.zig.zon"
if [[ -f "$FILE" ]]; then
  sed -i '' -E 's/\.version = "[^"]+"/\.version = "'"$VERSION"'"/' "$FILE"
  echo "  Updated extension/build.zig.zon"
else
  echo "  WARNING: extension/build.zig.zon not found"
fi

# --- extension/src/core/protocol.zig ---
FILE="$ROOT/extension/src/core/protocol.zig"
if [[ -f "$FILE" ]]; then
  sed -i '' -E 's/EXTENSION_VERSION = "[^"]+"/EXTENSION_VERSION = "'"$VERSION"'"/' "$FILE"
  echo "  Updated extension/src/core/protocol.zig"
else
  echo "  WARNING: extension/src/core/protocol.zig not found"
fi

# --- extension/API.md ---
FILE="$ROOT/extension/API.md"
if [[ -f "$FILE" ]]; then
  sed -i '' -E 's/"extensionVersion": "[^"]+"/"extensionVersion": "'"$VERSION"'"/' "$FILE"
  echo "  Updated extension/API.md"
else
  echo "  WARNING: extension/API.md not found"
fi

# --- frontend/package.json ---
FILE="$ROOT/frontend/package.json"
if [[ -f "$FILE" ]]; then
  # Use node to update only the top-level "version" field
  node -e "
    const fs = require('fs');
    const pkg = JSON.parse(fs.readFileSync('$FILE', 'utf8'));
    pkg.version = '$VERSION';
    fs.writeFileSync('$FILE', JSON.stringify(pkg, null, 2) + '\n');
  "
  echo "  Updated frontend/package.json"
else
  echo "  WARNING: frontend/package.json not found"
fi

# --- frontend/package-lock.json ---
FILE="$ROOT/frontend/package-lock.json"
if [[ -f "$FILE" ]]; then
  # Update both the root "version" and packages[""].version
  node -e "
    const fs = require('fs');
    const lock = JSON.parse(fs.readFileSync('$FILE', 'utf8'));
    lock.version = '$VERSION';
    if (lock.packages && lock.packages['']) {
      lock.packages[''].version = '$VERSION';
    }
    fs.writeFileSync('$FILE', JSON.stringify(lock, null, 2) + '\n');
  "
  echo "  Updated frontend/package-lock.json"
else
  echo "  WARNING: frontend/package-lock.json not found"
fi

# --- installer/README.txt ---
FILE="$ROOT/installer/README.txt"
if [[ -f "$FILE" ]]; then
  sed -i '' -E 's/^REAmo v[^ ]+/REAmo v'"$VERSION"'/' "$FILE"
  echo "  Updated installer/README.txt"
else
  echo "  WARNING: installer/README.txt not found"
fi

echo ""
echo "Done. Version is now $VERSION across all files."
echo ""
echo "Next steps:"
echo "  git add -A && git commit -m 'chore: bump version to $VERSION'"
echo "  git tag v$VERSION"
echo "  git push origin main --tags"
