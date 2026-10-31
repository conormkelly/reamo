#!/usr/bin/env bash
# Run tests/ws-integration against a real, headless REAPER in Docker, with
# test-fixtures/test-project-1.RPP open: no desktop REAPER needed.
#
#   scripts/harness/ws-integration.sh                  # pinned REAPER
#   scripts/harness/ws-integration.sh --reaper oldest  # as run.sh's --reaper
#
# REAPER runs in a harness container (no network, no published ports) under
# ws-integration/test.py, which opens the fixture and waits. The suite runs
# in the check image (scripts/container/Dockerfile) sharing that container's
# network namespace, so it reaches the extension on localhost:9224 exactly
# as it would on a desktop, and nothing on the host's ports is involved.
#
# Passes only if the suite passes and REAPER is still running afterwards.
# Needs what run.sh needs (Docker, Zig 0.15.x, `make frontend-build`, the licence);
# Env: ZIG, REAPER_LICENSE, REAPER_VERSION, HARNESS_IMAGE as for run.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEV_IMAGE="${DEV_IMAGE:-reamo-v1-dev}"
ZIG="${ZIG:-zig}"
LICENSE="${REAPER_LICENSE:-$HERE/reaper-license.rk}"
reaper_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --reaper) reaper_args=(--reaper "${2:?--reaper needs a version}"); shift 2 ;;
        *) echo "error: unknown argument $1" >&2; exit 1 ;;
    esac
done

zig_version="$("$ZIG" version 2>/dev/null || true)"
case "$zig_version" in
    0.15.*) ;;
    *) echo "error: need Zig 0.15.x (got '${zig_version:-none}'); set ZIG=/path/to/zig-0.15" >&2; exit 1 ;;
esac
[ -f "$ROOT/reamo/index.html" ] || { echo "error: no built frontend in reamo/; run: make frontend-build" >&2; exit 1; }

# run.sh resolves the REAPER version and builds its image.
image="$("$HERE/run.sh" ${reaper_args[@]+"${reaper_args[@]}"} --image-only | sed -n 's/^built //p')"
[ -n "$image" ] || { echo "error: couldn't build the harness image" >&2; exit 1; }
echo "Building $DEV_IMAGE (the suite's Node)..."
docker build -q -f "$ROOT/scripts/container/Dockerfile" -t "$DEV_IMAGE" "$ROOT" >/dev/null

case "$(docker info --format '{{.Architecture}}')" in
    aarch64 | arm64) arch=aarch64 ;;
    x86_64 | amd64) arch=x86_64 ;;
    *) echo "error: unsupported Docker architecture" >&2; exit 1 ;;
esac

OUT="$(mktemp -d)"
name="reamo-v1-ws-integration-$$"
cleanup() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    rm -rf "$OUT"
}
trap cleanup EXIT

mkdir -p "$OUT/harness" "$HERE/out"
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

docker run -d --name "$name" --network none --label reamo.harness=v1 \
    -v "$OUT/harness:/harness:ro" -v "$OUT:/ext:ro" -v "$ROOT/reamo:/reamo:ro" \
    -v "$ROOT/extension/effects:/effects:ro" -v "$ROOT/test-fixtures:/fixtures:ro" \
    -v "$HERE/out:/out" ${lic_mount[@]+"${lic_mount[@]}"} \
    -e HARNESS_SCENARIO_DIR=/harness/ws-integration -e HARNESS_OUT_DIR=ws-integration \
    "$image" bash /harness/boot.sh ws-integration >/dev/null

echo "Starting REAPER ($image) with test-project-1.RPP..."
ready=0
for _ in $(seq 1 360); do  # 90 s: boot.sh waits up to 30 s for REAPER, then 30 s for the project
    if grep -qx 'WS-INTEGRATION READY' <<<"$(docker logs "$name" 2>&1)"; then ready=1; break; fi
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || break
    sleep 0.25
done
if [ "$ready" != 1 ]; then
    docker logs "$name" 2>&1
    echo "error: REAPER didn't come up with the fixture project" >&2
    exit 1
fi

docker run --rm --init --network "container:$name" -w /src/tests/ws-integration "$DEV_IMAGE" npm test \
    && suite=0 || suite=$?

# REAPER may already have exited (boot.sh's own timeout): still show its log.
docker exec "$name" sh -c "echo $suite >/tmp/ws-integration-status.tmp && mv /tmp/ws-integration-status.tmp /tmp/ws-integration-status" || true
reaper_status="$(docker wait "$name")"
echo "=== REAPER side"
docker logs "$name" 2>&1
[ "$reaper_status" = 0 ]
