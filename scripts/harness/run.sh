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
#   HARNESS_JOBS    scenarios to run at once (default: 4); output is still
#                   printed one scenario at a time, in order
#   TOUR_ONLY       tour scenarios run only the ops whose name contains one of
#                   these space-separated words
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

# Cached after the first build; rebuilt only when the Dockerfile changes.
docker build -q -t "$IMAGE" "$HERE" >/dev/null

# Screenshots and other per-scenario artifacts (gitignored).
ARTIFACTS="$HERE/out"
mkdir -p "$ARTIFACTS"

case "$(docker info --format '{{.Architecture}}')" in
    aarch64 | arm64) arch=aarch64 ;;
    x86_64 | amd64) arch=x86_64 ;;
    *) echo "error: unsupported Docker architecture" >&2; exit 1 ;;
esac

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# Containers read a snapshot of this directory taken now: Docker Desktop's
# bind mounts can briefly serve a stale or truncated copy of a file that was
# just edited, and a run should see one consistent version of the harness.
mkdir -p "$OUT/harness"
(cd "$HERE" && tar --exclude ./out --exclude ./reaper-license.rk -cf - .) | (cd "$OUT/harness" && tar -xf -)

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
    # A full run is a release check: every protocol command must be toured.
    python3 "$HERE/check_tour_coverage.py" || { echo "error: tour coverage incomplete (see above)" >&2; exit 1; }
fi

JOBS="${HARNESS_JOBS:-4}"
for s in "${scenarios[@]}"; do
    [ -f "$HERE/scenarios/$s/test.py" ] || { echo "error: no scenario '$s'" >&2; exit 1; }
done

# Runs are keyed by position, so a scenario named twice (to chase a flake)
# runs twice rather than sharing one container name and status file.
run_one() {
    local i="$1" s="$2" out="$2"
    [ "$(printf '%s\n' "${scenarios[@]}" | grep -cxF "$s")" -eq 1 ] || out="$s.$i"
    docker run --rm --name "reamo-v1-harness-$s-$$-$i" --network none --label reamo.harness=v1 \
        -v "$OUT/harness:/harness:ro" -v "$OUT:/ext:ro" -v "$ROOT/web:/web:ro" \
        -v "$ROOT/extension/effects:/effects:ro" -v "$ROOT/test-fixtures:/fixtures:ro" \
        -v "$ARTIFACTS:/out" \
        ${lic_mount[@]+"${lic_mount[@]}"} -e HARNESS_GDB="${HARNESS_GDB:-0}" -e HARNESS_OUT_DIR="$out" -e TOUR_ONLY="${TOUR_ONLY:-}" \
        "$IMAGE" bash /harness/boot.sh "$s" >"$OUT/run-$i.log" 2>&1 && rc=0 || rc=$?
    echo "$rc" >"$OUT/run-$i.status"
}

# Each scenario writes its own log; they are printed in order as each one
# (and every one before it) finishes, so output reads the same as a serial run.
printed=0
print_ready() {
    while [ "$printed" -lt "${#scenarios[@]}" ] && [ -f "$OUT/run-$printed.status" ]; do
        echo "=== ${scenarios[$printed]}"
        cat "$OUT/run-$printed.log"
        printed=$((printed + 1))
    done
}

for i in "${!scenarios[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do
        sleep 0.5
        print_ready
    done
    run_one "$i" "${scenarios[$i]}" &
done
wait
print_ready

pass=0
failed=()
for i in "${!scenarios[@]}"; do
    if [ "$(cat "$OUT/run-$i.status")" = 0 ]; then
        pass=$((pass + 1))
    else
        failed+=("${scenarios[$i]}")
    fi
done

echo
[ ${#failed[@]} -eq 0 ] || echo "screenshots of failed scenarios: $ARTIFACTS/<scenario>/ (<scenario>.<run> when repeated)"
echo "harness: $pass passed, ${#failed[@]} failed${failed[*]:+ (${failed[*]})}"
[ ${#failed[@]} -eq 0 ]
