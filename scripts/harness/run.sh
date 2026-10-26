#!/usr/bin/env bash
# Run harness scenarios against a real, headless REAPER in Docker.
#
#   scripts/harness/run.sh                         # every scenario, pinned REAPER
#   scripts/harness/run.sh item-notes ...          # just these
#   scripts/harness/run.sh --reaper 6.0 smoke      # on a given REAPER release
#   scripts/harness/run.sh --reaper oldest         # the oldest REAPER we support
#   scripts/harness/run.sh --reaper latest         # reaper.fm's current release
#   scripts/harness/run.sh --reaper 6.0 --image-only   # just build that image
#
# --reaper takes a release as reaper.fm numbers it, or one of: pinned (the
# default, the newest release we have checked), oldest, latest (looked up on
# reaper.fm, so it needs the network and can change under you). Each version
# gets its own image, built on first use.
#
# Env:
#   ZIG             Zig 0.15.x binary (default: zig on PATH)
#   REAPER_LICENSE  licence file (default: scripts/harness/reaper-license.rk)
#   REAPER_VERSION  as --reaper, which overrides it
#   HARNESS_GDB=1   run REAPER under gdb; a crash prints all thread backtraces
#   HARNESS_IMAGE   image name (default: reamo-v1-harness), tagged reaper-<version>
#   HARNESS_JOBS    scenarios to run at once (default: 4); output is still
#                   printed one scenario at a time, in order
#   TOUR_ONLY       tour scenarios run only the ops whose name contains one of
#                   these space-separated words
#
# Each scenario gets a fresh REAPER in its own --rm container with no network
# and no published ports, so it can run beside a desktop REAPER (or another
# project's harness) without contention.
set -euo pipefail

PINNED_REAPER=7.83
OLDEST_REAPER=6.0

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REAPER_VERSION="${REAPER_VERSION:-pinned}"
image_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --reaper) REAPER_VERSION="${2:?--reaper needs a version}"; shift 2 ;;
        --image-only) image_only=1; shift ;;
        --) shift; break ;;
        -*) echo "error: unknown option $1" >&2; exit 1 ;;
        *) break ;;
    esac
done
case "$REAPER_VERSION" in
    pinned) REAPER_VERSION="$PINNED_REAPER" ;;
    oldest) REAPER_VERSION="$OLDEST_REAPER" ;;
    latest)
        # reaper.fm links its current Linux tarballs as files/<major>.x/reaper<major><minor>_linux_*.
        latest="$(curl -fsSL https://www.reaper.fm/download.php \
            | grep -oE 'files/[0-9]+\.x/reaper[0-9]+_linux_x86_64\.tar\.xz' | head -1)" \
            || { echo "error: couldn't look up the latest REAPER on reaper.fm" >&2; exit 1; }
        major="$(printf '%s' "$latest" | sed -E 's|files/([0-9]+)\.x/.*|\1|')"
        digits="$(printf '%s' "$latest" | sed -E 's|.*/reaper([0-9]+)_linux.*|\1|')"
        REAPER_VERSION="$major.${digits#"$major"}"
        echo "latest REAPER on reaper.fm: $REAPER_VERSION"
        ;;
esac
printf '%s' "$REAPER_VERSION" | grep -qE '^[0-9]+\.[0-9]+$' \
    || { echo "error: REAPER version '$REAPER_VERSION' isn't like 7.83" >&2; exit 1; }
IMAGE="${HARNESS_IMAGE:-reamo-v1-harness}:reaper-$REAPER_VERSION"
ZIG="${ZIG:-zig}"
LICENSE="${REAPER_LICENSE:-$HERE/reaper-license.rk}"

# Cached after the first build; rebuilt only when the Dockerfile changes.
docker build -q --build-arg REAPER_VERSION="$REAPER_VERSION" -t "$IMAGE" "$HERE" >/dev/null
[ "$image_only" = 0 ] || { echo "built $IMAGE"; exit 0; }

zig_version="$("$ZIG" version 2>/dev/null || true)"
case "$zig_version" in
    0.15.*) ;;
    *) echo "error: need Zig 0.15.x (got '${zig_version:-none}'); set ZIG=/path/to/zig-0.15" >&2; exit 1 ;;
esac

[ -f "$ROOT/web/index.html" ] || { echo "error: no built frontend in web/; run: make frontend" >&2; exit 1; }

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

echo "Building extension for $arch-linux (REAPER $REAPER_VERSION)..."
(cd "$ROOT/extension" && "$ZIG" build -Doptimize=ReleaseSafe -Dtarget="$arch-linux-gnu.2.28" --prefix "$OUT/build")
cp "$OUT/build/lib/libreaper_reamo.so" "$OUT/reaper_reamo.so"
# The release installer scripts, for scenarios that install over a running REAmo.
cp -R "$ROOT/installer" "$OUT/installer"

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
    # Linux capabilities the scenario needs, one per line in its `capabilities`.
    local caps=()
    if [ -f "$HERE/scenarios/$s/capabilities" ]; then
        while read -r cap; do [ -z "$cap" ] || caps+=(--cap-add "$cap"); done <"$HERE/scenarios/$s/capabilities"
    fi
    docker run --rm --name "reamo-v1-harness-$s-$$-$i" --network none --label reamo.harness=v1 \
        -v "$OUT/harness:/harness:ro" -v "$OUT:/ext:ro" -v "$ROOT/web:/web:ro" \
        -v "$ROOT/extension/effects:/effects:ro" -v "$ROOT/test-fixtures:/fixtures:ro" \
        -v "$ARTIFACTS:/out" \
        ${lic_mount[@]+"${lic_mount[@]}"} ${caps[@]+"${caps[@]}"} -e HARNESS_GDB="${HARNESS_GDB:-0}" -e HARNESS_OUT_DIR="$out" -e TOUR_ONLY="${TOUR_ONLY:-}" \
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
skipped=()
for i in "${!scenarios[@]}"; do
    case "$(cat "$OUT/run-$i.status")" in
        0) pass=$((pass + 1)) ;;
        77) skipped+=("${scenarios[$i]}") ;;
        *) failed+=("${scenarios[$i]}") ;;
    esac
done

echo
[ ${#failed[@]} -eq 0 ] || echo "screenshots of failed scenarios: $ARTIFACTS/<scenario>/ (<scenario>.<run> when repeated)"
echo "harness on REAPER $REAPER_VERSION: $pass passed, ${#skipped[@]} skipped${skipped[*]:+ (${skipped[*]})}, ${#failed[@]} failed${failed[*]:+ (${failed[*]})}"
[ ${#failed[@]} -eq 0 ]
