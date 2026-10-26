#!/usr/bin/env bash
# Run harness scenarios on a Windows PC over SSH: what ../run.sh --os windows
# runs, with REAPER_VERSION already resolved (see the README's "Windows
# runner" for setting the PC up).
#
# The PC runs one scenario at a time, on its desktop: one screen, one
# REAPER, one port. Each run gets a fresh copy of REAPER and this harness;
# its log and screenshots come back to out/<scenario>/ as on Linux.
#
# Env (as ../run.sh, TOUR_ONLY included, plus):
#   HARNESS_WINDOWS_HOST  ssh host for the PC (default: reamo-win)
#   HARNESS_WINDOWS_TIMEOUT  seconds a scenario may take there (default 900)
#   HARNESS_CACHE         where REAPER for Windows is kept, unpacked
#                         (default: ~/.cache/reamo-harness)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
: "${REAPER_VERSION:?set by ../run.sh}"
HOST="${HARNESS_WINDOWS_HOST:-reamo-win}"
ZIG="${ZIG:-zig}"
LICENSE="${REAPER_LICENSE:-$HERE/reaper-license.rk}"
CACHE="${HARNESS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/reamo-harness}/reaper-windows"
REMOTE=reamo-harness  # under the PC user's home

zig_version="$("$ZIG" version 2>/dev/null || true)"
case "$zig_version" in
    0.15.*) ;;
    *) echo "error: need Zig 0.15.x (got '${zig_version:-none}'); set ZIG=/path/to/zig-0.15" >&2; exit 1 ;;
esac
[ -f "$ROOT/web/index.html" ] || { echo "error: no built frontend in web/; run: make frontend" >&2; exit 1; }
ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" "exit 0" \
    || { echo "error: can't reach the Windows PC as '$HOST' over ssh (see README, Windows runner)" >&2; exit 1; }

if [ $# -gt 0 ]; then
    scenarios=("$@")
else
    scenarios=()
    for d in "$HERE"/scenarios/*/; do scenarios+=("$(basename "$d")"); done
    python3 "$HERE/check_tour_coverage.py" || { echo "error: tour coverage incomplete (see above)" >&2; exit 1; }
fi
for s in "${scenarios[@]}"; do
    [ -f "$HERE/scenarios/$s/test.py" ] || { echo "error: no scenario '$s'" >&2; exit 1; }
done

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# macOS tar would add AppleDouble (._*) files for extended attributes.
export COPYFILE_DISABLE=1

# REAPER for Windows, as its installer's portable install lays it out: the
# program at the top, and the resource folder's contents (Effects, Data,
# Scripts...) beside it. Unpacked here rather than run on the PC, where the
# installer would want a desktop and possibly elevation.
reaper_dir="$CACHE/$REAPER_VERSION"
if [ ! -f "$reaper_dir/reaper.exe" ]; then
    command -v 7zz >/dev/null || { echo "error: need 7zz to unpack REAPER's installer (brew install sevenzip)" >&2; exit 1; }
    major="${REAPER_VERSION%%.*}"
    url="https://www.reaper.fm/files/$major.x/reaper$(printf '%s' "$REAPER_VERSION" | tr -d .)_x64-install.exe"
    echo "Fetching REAPER $REAPER_VERSION for Windows ($url)..."
    curl -fsSL "$url" -o "$OUT/installer.exe"
    7zz x -y -o"$OUT/unpacked" "$OUT/installer.exe" >/dev/null
    rm -rf "$reaper_dir.tmp" && mkdir -p "$reaper_dir.tmp"
    (cd "$OUT/unpacked" && for f in * .[!.]*; do
        case "$f" in '$PLUGINSDIR' | '$COMMONFILES'* | '$INSTDIR'* | Uninstall.exe.nsis | '.[!.]*') ;; *) cp -R "$f" "$reaper_dir.tmp/" ;; esac
    done)
    for d in "$OUT"/unpacked/\$INSTDIR*; do cp -R "$d"/. "$reaper_dir.tmp/"; done
    [ -f "$reaper_dir.tmp/reaper.exe" ] || { echo "error: no reaper.exe in REAPER $REAPER_VERSION's installer" >&2; exit 1; }
    rm -rf "$reaper_dir" && mv "$reaper_dir.tmp" "$reaper_dir"
fi
# Windows ends the line with \r\n.
if [ "$(ssh -o BatchMode=yes "$HOST" "Test-Path $REMOTE\\reaper\\$REAPER_VERSION\\reaper.exe" | tr -d '\r')" != True ]; then
    echo "Copying REAPER $REAPER_VERSION to $HOST..."
    tar -czf "$OUT/reaper.tgz" -C "$reaper_dir" .
    ssh -o BatchMode=yes "$HOST" "New-Item -ItemType Directory -Force $REMOTE\\reaper\\$REAPER_VERSION | Out-Null"
    scp -q -o BatchMode=yes "$OUT/reaper.tgz" "$HOST:$REMOTE/reaper.tgz"
    ssh -o BatchMode=yes "$HOST" "tar -xf $REMOTE\\reaper.tgz -C $REMOTE\\reaper\\$REAPER_VERSION; Remove-Item $REMOTE\\reaper.tgz"
fi

echo "Building extension for x86_64-windows (REAPER $REAPER_VERSION)..."
(cd "$ROOT/extension" && "$ZIG" build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows -Dcpu=baseline --prefix "$OUT/build")

# One snapshot of everything a run reads, so every scenario sees the same
# version of the harness however long the run takes.
stage="$OUT/stage"
mkdir -p "$stage/harness"
(cd "$HERE" && tar --exclude ./out --exclude ./reaper-license.rk --exclude __pycache__ -cf - .) | (cd "$stage/harness" && tar -xf -)
cp -R "$ROOT/web" "$stage/web"
cp -R "$ROOT/extension/effects" "$stage/effects"
cp -R "$ROOT/test-fixtures" "$stage/fixtures"
cp "$OUT/build/bin/reaper_reamo.dll" "$stage/reaper_reamo.dll"
# The release installer scripts, for scenarios that install over a running REAmo.
cp -R "$ROOT/installer" "$stage/installer"
if [ -f "$LICENSE" ]; then
    cp "$LICENSE" "$stage/reaper-license.rk"
else
    echo "warning: no REAPER licence at $LICENSE; the evaluation nag may block REAPER (see README)" >&2
fi
tar -czf "$OUT/stage.tgz" -C "$stage" .
scp -q -o BatchMode=yes "$OUT/stage.tgz" "$HOST:$REMOTE/stage.tgz"
ssh -o BatchMode=yes "$HOST" "if (Test-Path $REMOTE\\stage) { Remove-Item -Recurse -Force $REMOTE\\stage }; \
New-Item -ItemType Directory $REMOTE\\stage | Out-Null; tar -xf $REMOTE\\stage.tgz -C $REMOTE\\stage; Remove-Item $REMOTE\\stage.tgz"

ARTIFACTS="$HERE/out"
mkdir -p "$ARTIFACTS"
pass=0
failed=()
skipped=()
for i in "${!scenarios[@]}"; do
    s="${scenarios[$i]}"
    out="$s"
    [ "$(printf '%s\n' "${scenarios[@]}" | grep -cxF "$s")" -eq 1 ] || out="$s.$i"
    rc=0
    # An empty argument doesn't survive the trip into powershell.exe, so
    # -TourOnly goes only with words to pass.
    tour_only=""
    [ -z "${TOUR_ONLY:-}" ] || tour_only=" -TourOnly '$TOUR_ONLY'"
    [ -z "${HARNESS_WINDOWS_TIMEOUT:-}" ] || tour_only="$tour_only -TimeoutSeconds $HARNESS_WINDOWS_TIMEOUT"
    # A run that fails to start mustn't leave the last run's log to be read as its own.
    ssh -o BatchMode=yes "$HOST" "Remove-Item $REMOTE\\boot.log -ErrorAction SilentlyContinue" || true
    ssh -o BatchMode=yes "$HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File $REMOTE\\stage\\harness\\windows\\run-scenario.ps1 $s $REAPER_VERSION $out$tour_only; exit \$LASTEXITCODE" || rc=$?
    echo "=== $s"
    scp -q -o BatchMode=yes "$HOST:$REMOTE/boot.log" "$OUT/boot.log" 2>/dev/null && cat "$OUT/boot.log" \
        || echo "(no log from the PC)"
    rm -rf "${ARTIFACTS:?}/$out"
    scp -q -r -o BatchMode=yes "$HOST:$REMOTE/out/$out" "$ARTIFACTS/$out" 2>/dev/null || true
    case "$rc" in
        0) pass=$((pass + 1)) ;;
        77) skipped+=("$s") ;;
        *) failed+=("$s") ;;
    esac
done

echo
[ ${#failed[@]} -eq 0 ] || echo "screenshots of failed scenarios: $ARTIFACTS/<scenario>/ (<scenario>.<run> when repeated)"
echo "harness on REAPER $REAPER_VERSION (windows): $pass passed, ${#skipped[@]} skipped${skipped[*]:+ (${skipped[*]})}, ${#failed[@]} failed${failed[*]:+ (${failed[*]})}"
[ ${#failed[@]} -eq 0 ]
