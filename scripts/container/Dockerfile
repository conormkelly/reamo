# Everything REAmo's checks need, at pinned versions, so they run the same on
# any machine with Docker: Node and npm for frontend/ and tests/ws-integration/,
# Chromium for the Playwright E2E tests, and Zig for the extension.
#
#   make container-check        # builds this image, runs `make check` in it
#   make test-ws-harness        # also uses it, to run tests/ws-integration
#
# Built from the repo root; Dockerfile.dockerignore beside this file decides
# what is copied: an allow-list of what the checks need, never local notes,
# licence files or secrets. The
# working tree is copied in rather than mounted, so a run never writes into
# the checkout and the host's macOS node_modules never meet Linux ones.

# Playwright 1.64.1 on Ubuntu 24.04, with Node 24.22.1 and the Chromium that
# @playwright/test 1.64.1 drives. Move it with @playwright/test in
# frontend/package-lock.json, or the E2E tests look for a browser it lacks.
FROM mcr.microsoft.com/playwright:v1.64.1-noble@sha256:47b510dd9230bf0b9bfc9b20102241e577ea7a99334ab4c3ca19f19770e9b8ea AS tools
# Later stages inherit it; make docker-clean finds superseded builds by it.
LABEL reamo.image=v1-check

# make 4.3-4.1build2 is Ubuntu 24.04's release-pocket build, which never changes.
RUN apt-get update && apt-get install -y --no-install-recommends make=4.3-4.1build2 \
    && rm -rf /var/lib/apt/lists/*

# The npm CI uses: frontend/.npmrc's supply-chain settings need npm 11.16+.
RUN npm install -g npm@11.21.1 && npm --version

ARG TARGETARCH
COPY scripts/container/install-zig.sh /tmp/install-zig.sh
RUN bash /tmp/install-zig.sh "$TARGETARCH" && rm /tmp/install-zig.sh
ENV PATH=/opt/zig:$PATH

# Dependencies, in layers of their own so editing source doesn't refetch them.
# npm ci runs under each package's .npmrc (no install scripts, registry only).
FROM tools AS deps
WORKDIR /src
COPY frontend/package.json frontend/package-lock.json frontend/.npmrc frontend/
RUN cd frontend && npm ci
COPY tests/ws-integration/package.json tests/ws-integration/package-lock.json tests/ws-integration/.npmrc tests/ws-integration/
RUN cd tests/ws-integration && npm ci
COPY extension/build.zig extension/build.zig.zon extension/
RUN cd extension && zig build --fetch

FROM deps
COPY . .
# Playwright's HTML reporter would otherwise serve a failed run's report and
# wait for someone to open it.
ENV PLAYWRIGHT_HTML_OPEN=never
CMD ["make", "check"]
