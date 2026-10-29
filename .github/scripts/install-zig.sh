#!/usr/bin/env bash
# Installs the Zig compiler for a release build and puts it on the job's
# PATH. Every download is checked against the SHA-256 pinned below, so the
# compiler that builds a release is exactly the one pinned here, whichever
# mirror served it, and nothing comes from the Actions cache.
#
# The hashes are of ziglang.org's official builds, checked against their
# minisign signatures (key RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U,
# from https://ziglang.org/download). Moving to another Zig version means
# adding its hashes, checked the same way.
#
# Usage: install-zig.sh <version>   (runs on the Linux, macOS and Windows runners)
set -euo pipefail

version="${1:?usage: install-zig.sh <version>}"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)                 target=x86_64-linux;   ext=tar.xz ;;
  Darwin-arm64)                 target=aarch64-macos;  ext=tar.xz ;;
  MINGW*-x86_64|MSYS*-x86_64)   target=x86_64-windows; ext=zip ;;
  *) echo "::error::no Zig build pinned for $(uname -s)-$(uname -m)"; exit 1 ;;
esac

case "$version/$target" in
  0.15.2/x86_64-linux)   sha256=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239 ;;
  0.15.2/aarch64-macos)  sha256=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b ;;
  0.15.2/x86_64-windows) sha256=3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c ;;
  *) echo "::error::no SHA-256 pinned for Zig $version on $target"; exit 1 ;;
esac

name="zig-$target-$version"
file="$name.$ext"
work="${RUNNER_TEMP:?}/zig-install"
mkdir -p "$work"

# Hashes stdin: given a file name, sha256sum escapes one containing a
# backslash (every Windows RUNNER_TEMP path) by prefixing the hash with '\'.
sha256_of() {
  if command -v sha256sum > /dev/null; then sha256sum; else shasum -a 256; fi < "$1" | cut -d' ' -f1
}

# ziglang.org asks automated downloads to use the community mirrors first.
# Any source will do, since the hash decides what's accepted; ziglang.org
# itself is the last resort.
mirrors=$(curl -fsSL --max-time 20 https://ziglang.org/download/community-mirrors.txt || true)
sources=$(printf '%s\n' "$mirrors" | tr -d '\r' | grep -E '^https://' | awk 'BEGIN{srand()} {print rand() "\t" $0}' | sort | cut -f2- || true)
sources=$(printf '%s\nhttps://ziglang.org/download/%s\n' "$sources" "$version" | grep -v '^$')

installed=false
while IFS= read -r base; do
  # Mirrors serve releases at the top level; ziglang.org under /download/<version>.
  url="$base/$file?source=github-conormkelly-reamo"
  echo "Fetching $url"
  if ! curl -fsSL --retry 2 --max-time 300 -o "$work/$file" "$url"; then
    echo "::warning::download failed from $base"
    continue
  fi
  actual=$(sha256_of "$work/$file")
  if [ "$actual" != "$sha256" ]; then
    echo "::warning::$base served $file with SHA-256 $actual, not the pinned $sha256; trying the next source"
    continue
  fi
  installed=true
  break
done <<< "$sources"

if [ "$installed" != true ]; then
  echo "::error::no source served $file with the pinned SHA-256"
  exit 1
fi
echo "$file matches the pinned SHA-256 $sha256"

if [ "$ext" = zip ]; then
  7z x -y -bd -o"$work" "$work/$file" > /dev/null
else
  tar -xJf "$work/$file" -C "$work"
fi

zig_dir="$work/$name"
"$zig_dir/zig" version
if command -v cygpath > /dev/null; then zig_dir=$(cygpath -w "$zig_dir"); fi
echo "$zig_dir" >> "${GITHUB_PATH:?}"
