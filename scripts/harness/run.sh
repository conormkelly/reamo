#!/usr/bin/env bash
# Run harness scenarios against a real, headless REAPER in Docker.
#
#   scripts/harness/run.sh                 # every scenario
#   scripts/harness/run.sh item-notes ...  # just these
#
# Env:
#   ZIG             Zig 0.15.x binary (default: zig on PATH)
#   REAPER_LICENSE  licence file (default: scripts/harness/reaper-license.rk)
#   HARNESS_GDB=1   run REAPER under gdb; a crash prints all thread backtraces
#   HARNESS_IMAGE   image tag (default: reamo-v1-harness)
#
# Each scenario gets a fresh REAPER in its own --rm container with no network
# and no published ports, so it can run beside a desktop REAPER (or another
# project's harness) without contention.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
IMAGE="${HARNESS_IMAGE:-reamo-v1-harness}"
ZIG="${ZIG:-zig}"
LICENSE="${REAPER_LICENSE:-$HERE/reaper-license.rk}"

zig_version="$("$ZIG" version 2>/dev/null || true)"
case "$zig_version" in
    0.15.*) ;;
    *) echo "error: need Zig 0.15.x (got '${zig_version:-none}'); set ZIG=/path/to/zig-0.15" >&2; exit 1 ;;
esac

[ -f "$ROOT/web/index.html" ] || { echo "error: no built frontend in web/; run: make frontend" >&2; exit 1; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Building $IMAGE (one-time)..."
    docker build -q -t "$IMAGE" "$HERE" >/dev/null
fi

case "$(docker info --format '{{.Architecture}}')" in
    aarch64 | arm64) arch=aarch64 ;;
    x86_64 | amd64) arch=x86_64 ;;
    *) echo "error: unsupported Docker architecture" >&2; exit 1 ;;
esac

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
echo "Building extension for $arch-linux..."
(cd "$ROOT/extension" && "$ZIG" build -Doptimize=ReleaseSafe -Dtarget="$arch-linux-gnu.2.28" --prefix "$OUT/build")
cp "$OUT/build/lib/libreaper_reamo.so" "$OUT/reaper_reamo.so"

lic_mount=()
if [ -f "$LICENSE" ]; then
    lic_mount=(-v "$LICENSE:/lic/reaper-license.rk:ro")
else
    echo "warning: no REAPER licence at $LICENSE; the evaluation nag may block REAPER (see README)" >&2
fi

if [ $# -gt 0 ]; then
    scenarios=("$@")
else
    scenarios=()
    for d in "$HERE"/scenarios/*/; do scenarios+=("$(basename "$d")"); done
fi

pass=0
failed=()
for s in "${scenarios[@]}"; do
    [ -f "$HERE/scenarios/$s/test.py" ] || { echo "error: no scenario '$s'" >&2; exit 1; }
    echo "=== $s"
    if docker run --rm --name "reamo-v1-harness-$s-$$" --network none --label reamo.harness=v1 \
        -v "$HERE:/harness:ro" -v "$OUT:/ext:ro" -v "$ROOT/web:/web:ro" \
        -v "$ROOT/extension/effects:/effects:ro" -v "$ROOT/test-fixtures:/fixtures:ro" \
        ${lic_mount[@]+"${lic_mount[@]}"} -e HARNESS_GDB="${HARNESS_GDB:-0}" \
        "$IMAGE" bash /harness/boot.sh "$s"; then
        pass=$((pass + 1))
    else
        failed+=("$s")
    fi
done

echo
echo "harness: $pass passed, ${#failed[@]} failed${failed[*]:+ (${failed[*]})}"
[ ${#failed[@]} -eq 0 ]
