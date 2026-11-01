#!/usr/bin/env bash
# Remove the Docker leftovers REAmo's own images and runs pile up:
#
#   - stopped harness containers (a run killed before --rm fired), once
#     they are 10 minutes old;
#   - harness images for REAPER releases other than the pinned and oldest
#     ones (a `--reaper latest` or `--reaper 7.80` run builds one each);
#   - superseded builds of the harness and check images. With Docker's
#     classic image store a rebuild leaves the old image untagged
#     (dangling). With the containerd store (Docker Desktop's default) it
#     doesn't, and the old layers stay in the build cache instead.
#
# Everything removed is rebuilt on next use. It never touches volumes,
# running containers, or images it didn't build: it matches only REAmo's
# labels and image names. The build cache is shared by every project, so
# it's left alone; `docker builder prune` clears it.
#
#   make docker-clean
#
# Env:
#   HARNESS_IMAGE   harness image name (default: reamo-v1-harness), as run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN_SH="$HERE/harness/run.sh"
HARNESS_IMAGE="${HARNESS_IMAGE:-reamo-v1-harness}"

pinned="$(sed -n 's/^PINNED_REAPER=//p' "$RUN_SH")"
oldest="$(sed -n 's/^OLDEST_REAPER=//p' "$RUN_SH")"
[ -n "$pinned" ] && [ -n "$oldest" ] \
    || { echo "error: couldn't read PINNED_REAPER and OLDEST_REAPER from $RUN_SH" >&2; exit 1; }

echo "Stopped harness containers:"
# Only ones created over 10 minutes ago: a run starting now
# creates its container a moment before starting it.
docker container prune -f --filter label=reamo.harness=v1 --filter until=10m

echo "Harness images other than REAPER $pinned and $oldest:"
removed=0
while read -r tag; do
    case "$tag" in
        "reaper-$pinned" | "reaper-$oldest") ;;
        *)
            # An image a container still uses is kept: docker rmi refuses it.
            docker rmi "$HARNESS_IMAGE:$tag" || true
            removed=1
            ;;
    esac
done < <(docker images "$HARNESS_IMAGE" --format '{{.Tag}}' | grep -vx '<none>' || true)
[ "$removed" = 1 ] || echo "  none"

echo "Superseded harness and check image builds:"
docker image prune -f --filter label=reamo.reaper-version
docker image prune -f --filter label=reamo.image=v1-check
