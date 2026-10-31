#!/usr/bin/env bash
# Installs Zig 0.15.2 for Linux into /opt/zig, for the check container.
#
# Every download is checked against the SHA-256 pinned below, so whichever
# mirror serves it, the compiler is exactly ziglang.org's official build. The
# hashes were checked against the minisign signatures from
# https://ziglang.org/download (key
# RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U); the x86_64 one
# is the same as .github/scripts/install-zig.sh pins for release builds.
# Moving to another Zig version means adding its hashes, checked the same way.
#
# Usage: install-zig.sh <docker TARGETARCH: amd64 or arm64>
set -euo pipefail

version=0.15.2
case "${1:?usage: install-zig.sh <amd64|arm64>}" in
    amd64) arch=x86_64;  sha256=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239 ;;
    arm64) arch=aarch64; sha256=958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f ;;
    *) echo "error: no Zig build pinned for TARGETARCH '$1'" >&2; exit 1 ;;
esac

name="zig-$arch-linux-$version"
file="$name.tar.xz"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ziglang.org asks automated downloads to use the community mirrors first;
# the hash decides what's accepted, so any source will do and ziglang.org
# itself is the last resort.
mirrors="$(curl -fsSL --max-time 20 https://ziglang.org/download/community-mirrors.txt || true)"
sources="$(printf '%s\n' "$mirrors" | tr -d '\r' | grep -E '^https://' | shuf || true)"
sources="$(printf '%s\nhttps://ziglang.org/download/%s\n' "$sources" "$version" | grep -v '^$')"

while IFS= read -r base; do
    echo "Fetching $base/$file"
    curl -fsSL --retry 2 --max-time 300 -o "$work/$file" "$base/$file?source=github-conormkelly-reamo" || continue
    if [ "$(sha256sum "$work/$file" | cut -d' ' -f1)" = "$sha256" ]; then
        # The image has no xz; Python's tarfile reads it.
        python3 -I -c 'import sys, tarfile; tarfile.open(sys.argv[1]).extractall(sys.argv[2], filter="data")' \
            "$work/$file" /opt
        mv "/opt/$name" /opt/zig
        /opt/zig/zig version
        exit 0
    fi
    echo "warning: $base served $file with the wrong SHA-256; trying the next source" >&2
done <<<"$sources"

echo "error: no source served $file with the pinned SHA-256 $sha256" >&2
exit 1
