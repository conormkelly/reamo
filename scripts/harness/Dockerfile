# syntax=docker/dockerfile:1
#
# Headless REAPER for driving the REAmo extension end to end.
#
# Bakes a pinned REAPER and its runtime dependencies only. The extension .so,
# web UI and scenarios are bind-mounted at `docker run` time by run.sh, so
# editing extension code never rebuilds this image.
#
#   docker build -t reamo-v1-harness scripts/harness
#
# BuildKit sets TARGETARCH for the host: arm64 natively on Apple Silicon,
# amd64 on an x86 Linux host or CI runner.

FROM debian:bookworm-slim

# RUNTIME (headless REAPER):
#   xvfb xauth   REAPER always creates a window, even with nothing to show
#   libgtk-3-0   GDK-backed SWELL, REAPER's UI toolkit on Linux
#   libasound2   REAPER dlopens ALSA even with the dummy audio device
# HARNESS:
#   python3      the scenario client (stdlib only)
#   procps       pgrep, to tell whether REAPER survived a scenario
#   gdb          backtraces when REAPER crashes (HARNESS_GDB=1)
# DOWNLOAD (image build only):
#   ca-certificates curl xz-utils
RUN apt-get update && apt-get install -y --no-install-recommends \
        xvfb xauth libgtk-3-0 libasound2 \
        python3 procps gdb \
        ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# The tarball unpacks to reaper_linux_<arch>/REAPER/. run.sh copies it to a
# writable dir and puts a reaper.ini beside the binary, which makes REAPER
# portable: the binary's dir becomes its resource dir.
ARG TARGETARCH
ARG REAPER_VERSION=7.83
RUN set -eux; \
    case "$TARGETARCH" in \
        arm64) rarch=aarch64 ;; \
        amd64) rarch=x86_64 ;; \
        *) echo "unsupported TARGETARCH='$TARGETARCH'" >&2; exit 1 ;; \
    esac; \
    nodot="$(printf '%s' "$REAPER_VERSION" | tr -d '.')"; \
    major="${REAPER_VERSION%%.*}"; \
    curl -fsSL "https://www.reaper.fm/files/${major}.x/reaper${nodot}_linux_${rarch}.tar.xz" -o /tmp/reaper.tar.xz; \
    tar -C /opt -xJf /tmp/reaper.tar.xz; \
    mv "/opt/reaper_linux_${rarch}/REAPER" /opt/reaper; \
    rm -rf /tmp/reaper.tar.xz "/opt/reaper_linux_${rarch}"; \
    test -x /opt/reaper/reaper

LABEL reamo.reaper-version="${REAPER_VERSION}"
ENV REAPER_DIR=/opt/reaper
