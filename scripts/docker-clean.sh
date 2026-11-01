#!/usr/bin/env bash
# Remove the Docker leftovers REAmo's harness piles up:
#
#   - stopped harness containers: ws-integration.sh's REAPER container
#     (started with -d, so no --rm) when the script was killed past its
#     EXIT trap, or any harness container after a Docker crash;
#   - harness images for REAPER releases other than the pinned and oldest
#     ones (a `--reaper latest` or `--reaper 7.80` run builds one each,
#     about 0.9 GB);
#   - dangling harness image builds. Only Docker's classic image store
#     leaves these on a rebuild; the containerd store (Docker Desktop's
#     default) keeps the old layers in the build cache instead.
#
# It refuses to run while any run.sh or ws-integration.sh is running, from
# any checkout: a run has stretches with no container (it builds the
# extension between building its image and starting one), and
# ws-integration.sh's REAPER container can stop while its npm test still
# needs it. It finds them by a command line containing
# scripts/harness/run.sh or ws-integration.sh, as make and the README start
# them; a run started as ./run.sh from inside scripts/harness isn't seen.
# Removing a release that another checkout pins only costs a rebuild there.
#
# Everything removed is rebuilt on next use. It never touches volumes,
# running containers, or images without the harness label. The build
# cache is shared by every project, so it's left alone; `docker builder
# prune` clears it.
#
#   make docker-clean
#
# Env:
#   HARNESS_IMAGE   harness image name (default: reamo-v1-harness), as run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN_SH="$HERE/harness/run.sh"
HARNESS_IMAGE="${HARNESS_IMAGE:-reamo-v1-harness}"

pinned="$(sed -n 's/^PINNED_REAPER=\([0-9.]*\).*/\1/p' "$RUN_SH")"
oldest="$(sed -n 's/^OLDEST_REAPER=\([0-9.]*\).*/\1/p' "$RUN_SH")"
[ -n "$pinned" ] && [ -n "$oldest" ] \
    || { echo "error: couldn't read PINNED_REAPER and OLDEST_REAPER from $RUN_SH" >&2; exit 1; }

if pgrep -f 'scripts/harness/(run|ws-integration)\.sh' >/dev/null; then
    echo "error: a harness run is in progress; run this after it ends" >&2
    exit 1
fi

echo "Stopped harness containers:"
docker container prune -f --filter label=reamo.harness=v1

echo "Harness images other than REAPER $pinned and $oldest:"
removed=0
# Only images with the harness label, whatever HARNESS_IMAGE names.
while read -r tag; do
    case "$tag" in
        "<none>" | "reaper-$pinned" | "reaper-$oldest") continue ;;
    esac
    # An image a container still uses is kept: docker rmi refuses it.
    docker rmi "$HARNESS_IMAGE:$tag" && removed=$((removed + 1))
done < <(docker images "$HARNESS_IMAGE" --filter label=reamo.reaper-version --format '{{.Tag}}')
[ "$removed" -gt 0 ] || echo "  none removed"

echo "Dangling harness image builds:"
docker image prune -f --filter label=reamo.reaper-version
