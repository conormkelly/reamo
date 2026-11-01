#!/usr/bin/env bash
# Remove the Docker leftovers REAmo's harness piles up:
#
#   - stopped harness containers: ws-integration.sh's REAPER container
#     (started with -d, so no --rm) when the script was killed past its
#     EXIT trap, or any harness container after a Docker crash;
#   - harness images for REAPER releases other than the pinned and oldest
#     ones, once Docker built them a day ago or more (a cached rebuild
#     keeps the old time; a `--reaper latest` or `--reaper 7.80` run builds
#     one each, about 0.9 GB);
#   - dangling harness image builds. Only Docker's classic image store
#     leaves these on a rebuild; the containerd store (Docker Desktop's
#     default) keeps the old layers in the build cache instead.
#
# It refuses to run while a harness container or a check-image container
# (ws-integration.sh's npm test, whose REAPER container may already have
# stopped) is running, so it can't take a container from a run in
# progress. Images are removed only once a day old, and docker rmi keeps
# any image a container still uses. That leaves one gap: a run of a
# release other than the pinned and oldest ones, starting while this
# runs, can lose its image between building it and starting its first
# container (it builds the extension in between); run it again. Deleting
# a release that another checkout pins only costs a rebuild there.
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
#   DEV_IMAGE       check image name (default: reamo-v1-dev), as the Makefile
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN_SH="$HERE/harness/run.sh"
HARNESS_IMAGE="${HARNESS_IMAGE:-reamo-v1-harness}"
DEV_IMAGE="${DEV_IMAGE:-reamo-v1-dev}"
MIN_AGE_SECS=$((24 * 3600))

pinned="$(sed -n 's/^PINNED_REAPER=\([0-9.]*\).*/\1/p' "$RUN_SH")"
oldest="$(sed -n 's/^OLDEST_REAPER=\([0-9.]*\).*/\1/p' "$RUN_SH")"
[ -n "$pinned" ] && [ -n "$oldest" ] \
    || { echo "error: couldn't read PINNED_REAPER and OLDEST_REAPER from $RUN_SH" >&2; exit 1; }

busy="$(docker ps -q --filter label=reamo.harness=v1)$(docker ps -q --filter "ancestor=$DEV_IMAGE" 2>/dev/null || true)"
if [ -n "$busy" ]; then
    echo "error: a harness or check container is running; run this after it ends" >&2
    exit 1
fi

echo "Stopped harness containers:"
docker container prune -f --filter label=reamo.harness=v1

echo "Harness images other than REAPER $pinned and $oldest, a day old or more:"
now="$(date +%s)"
removed=0
# Tag and creation time; only images with the harness label, whatever
# HARNESS_IMAGE names.
while read -r tag id; do
    case "$tag" in
        "<none>" | "reaper-$pinned" | "reaper-$oldest") continue ;;
    esac
    created="$(docker image inspect -f '{{.Created}}' "$id")"
    age=$((now - $(python3 -c 'import sys, datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1][:19]).replace(tzinfo=datetime.timezone.utc).timestamp()))' "$created")))
    if [ "$age" -lt "$MIN_AGE_SECS" ]; then
        echo "  kept $HARNESS_IMAGE:$tag: built under a day ago"
        continue
    fi
    docker rmi "$HARNESS_IMAGE:$tag" && removed=$((removed + 1))
done < <(docker images "$HARNESS_IMAGE" --filter label=reamo.reaper-version --format '{{.Tag}} {{.ID}}')
[ "$removed" -gt 0 ] || echo "  none removed"

echo "Dangling harness image builds:"
docker image prune -f --filter label=reamo.reaper-version
