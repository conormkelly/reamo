# REAmo build, test and install commands. `make` (or `make help`) lists them.
#
# Every target is listed by `make help`: put a `## description` after its
# name (and a `##@ Heading` above a group), or it won't show up.

.DEFAULT_GOAL := help

.PHONY: help install all frontend frontend-build extension dev-extension tracy \
        frontend-dev dev dev-notests dev-cycle stop-reaper start-reaper \
        check lint typecheck test test-frontend test-e2e test-extension tuner-bench tuner-targets tuner-wav tuner-mdb zig-version \
        test-ws test-ws-harness harness harness-image release-check \
        container-image container-check clean

# Zig 0.15.x. Point ZIG at it when the `zig` on PATH is another version:
#   make test-extension ZIG=/path/to/zig-0.15/zig
ZIG ?= zig
export ZIG

# The check image (scripts/container/Dockerfile).
DEV_IMAGE ?= reamo-v1-dev
export DEV_IMAGE

# Platform: library name, REAPER's resource folders, and the optimize modes
# (ZIG_TEST_OPTIMIZE matches release.yml's test step).
# Linux: ReleaseSafe works around Zig 0.15 Debug codegen bug (MIR InvalidInstruction)
# Windows: ReleaseSafe needed — Debug builds have 650KB+ stack frames that overflow the 1MB default thread stack
ifeq ($(OS),Windows_NT)
    EXT_LIB = reaper_reamo.dll
    EXT_DEST = reaper_reamo.dll
    EXT_OUT_DIR = bin
    REAPER_PLUGINS = $(APPDATA)/REAPER/UserPlugins
    REAPER_WWW = $(APPDATA)/REAPER/reaper_www_root/reamo
    ZIG_OPTIMIZE = -Doptimize=ReleaseSafe
    ZIG_TEST_OPTIMIZE =
else ifeq ($(shell uname),Darwin)
    EXT_LIB = libreaper_reamo.dylib
    EXT_DEST = reaper_reamo.dylib
    EXT_OUT_DIR = lib
    REAPER_PLUGINS = $(HOME)/Library/Application Support/REAPER/UserPlugins
    REAPER_WWW = $(HOME)/Library/Application Support/REAPER/reaper_www_root/reamo
    ZIG_OPTIMIZE =
    ZIG_TEST_OPTIMIZE =
else
    EXT_LIB = libreaper_reamo.so
    EXT_DEST = reaper_reamo.so
    EXT_OUT_DIR = lib
    REAPER_PLUGINS = $(HOME)/.config/REAPER/UserPlugins
    REAPER_WWW = $(HOME)/.config/REAPER/reaper_www_root/reamo
    ZIG_OPTIMIZE = -Doptimize=ReleaseSafe
    ZIG_TEST_OPTIMIZE = -Doptimize=ReleaseSafe
endif

# Copies the extension just built into REAPER's UserPlugins.
define install_extension
	@mkdir -p "$(REAPER_PLUGINS)"
	cp "extension/zig-out/$(EXT_OUT_DIR)/$(EXT_LIB)" "$(REAPER_PLUGINS)/$(EXT_DEST)"
endef

##@ Getting started

help: ## List every target (the default)
	@awk 'BEGIN { FS = ":.*## " } \
		/^##@ / { printf "\n%s\n", substr($$0, 5); next } \
		/^[a-zA-Z0-9_-]+:.*## / { printf "  %-17s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "Targets marked (REAPER) write to your REAPER's resource folder or start/stop REAPER."

install: ## Install npm dependencies from the lockfiles, the git hooks, and Playwright's Chromium
	cd frontend && npm ci && npm run prepare
	cd frontend && npx playwright install chromium
	cd tests/ws-integration && npm ci

##@ Build and install into your REAPER

all: test frontend extension ## Run every test, then build and install both halves (REAPER)

frontend-build: ## Build the web UI into reamo/
	cd frontend && npm run build

frontend: frontend-build ## Build the web UI and copy it to REAPER's reaper_www_root/reamo (REAPER)
	@mkdir -p "$(REAPER_WWW)"
	@if [ "$$(cd reamo && pwd)" != "$$(cd "$(REAPER_WWW)" && pwd)" ]; then \
		cp -r reamo/* "$(REAPER_WWW)/"; \
		echo "Frontend installed to $(REAPER_WWW)"; \
	else \
		echo "Build output already in place (repo is inside reaper_www_root)."; \
	fi

extension: zig-version ## Build the extension and copy it to REAPER's UserPlugins (REAPER)
	cd extension && "$(ZIG)" build $(ZIG_OPTIMIZE)
	$(install_extension)
	@echo "Extension installed. Restart REAPER to load."

dev-extension: zig-version ## As extension, in dev mode: the HTML is re-read on every request (REAPER)
	cd extension && "$(ZIG)" build -Ddev=true $(ZIG_OPTIMIZE)
	$(install_extension)
	@echo "Dev extension installed (fresh HTML reads per request)."

# ReleaseFast: Tracy builds need it on Zig 0.15.
tracy: zig-version ## As extension, with the Tracy profiler compiled in (REAPER)
	cd extension && "$(ZIG)" build -Dtracy=true -Doptimize=ReleaseFast
	$(install_extension)
	@echo "Tracy-enabled extension installed. Start the Tracy GUI, launch REAPER, connect to it."

##@ Develop

frontend-dev: ## Vite dev server with hot reload, on port 5173
	cd frontend && npm run dev

dev: test dev-cycle ## Every test, then dev-cycle (REAPER)

dev-notests: dev-cycle ## dev-cycle without the tests (REAPER)

dev-cycle: zig-version stop-reaper dev-extension start-reaper ## Quit REAPER, install dev-extension, relaunch REAPER in this terminal (REAPER)

stop-reaper: ## Quit REAPER (REAPER)
	@echo "Stopping REAPER..."
ifeq ($(OS),Windows_NT)
	-@MSYS_NO_PATHCONV=1 taskkill /IM reaper.exe /F 2>NUL || exit 0
else
	-@pkill -x REAPER 2>/dev/null || pkill -x reaper 2>/dev/null || true
endif
	@sleep 0.5

# Foreground, so a panic or log line shows up in this terminal at once.
start-reaper: ## Launch REAPER in this terminal, its output attached (REAPER)
	@echo "Launching REAPER in foreground (Ctrl+C to stop)..."
ifeq ($(OS),Windows_NT)
	@echo "On Windows, run REAPER manually from terminal for stdout visibility"
	start "" "C:\Program Files\REAPER (x64)\reaper.exe"
else ifeq ($(shell uname),Darwin)
	/Applications/REAPER.app/Contents/MacOS/REAPER
else
	reaper
endif

##@ Check (no REAPER needed)

check: lint typecheck test ## Everything below: lint, typecheck and every test

lint: ## ESLint, on frontend/ and tests/ws-integration/
	cd frontend && npm run lint
	cd tests/ws-integration && npm run lint

typecheck: ## TypeScript, on frontend/ and tests/ws-integration/ (no build output)
	cd frontend && npm exec -- tsc -b
	cd tests/ws-integration && npm run typecheck

test: test-frontend test-e2e test-extension ## Frontend unit and E2E tests, extension unit tests

test-frontend: ## Frontend unit tests (Vitest)
	cd frontend && npm test

test-e2e: ## Frontend E2E tests (Playwright; starts Vite on 5173, or reuses one already there)
	cd frontend && npm run test:e2e

test-extension: zig-version ## Extension unit tests (zig build test)
	cd extension && "$(ZIG)" build test $(ZIG_TEST_OPTIMIZE)

tuner-bench: zig-version ## Tuner pitch analyser on synthetic signals: accuracy and CPU, against the JSFX (ReleaseFast)
	cd extension && "$(ZIG)" build tuner-bench -Doptimize=ReleaseFast

tuner-targets: zig-version ## Tuner pitch analyser against its accuracy targets on strings with known first partials (ReleaseFast)
	cd extension && "$(ZIG)" build tuner-targets -Doptimize=ReleaseFast

tuner-wav: zig-version ## Tuner pitch analyser over a WAV file: make tuner-wav WAV=take.wav [ARGS="--out frames.csv --notes notes.csv"]
	cd extension && "$(ZIG)" build tuner-wav -Doptimize=ReleaseFast -- "$(WAV)" $(ARGS)

tuner-mdb: zig-version ## Tuner pitch analyser on MDB-bass-synth stems: make tuner-mdb MDB=<dataset dir> [ARGS="--tracks name --out dir"]
	cd extension && "$(ZIG)" build tuner-mdb -Doptimize=ReleaseFast -- "$(MDB)" $(ARGS)

zig-version: ## Fail unless ZIG (default: the zig on PATH) is Zig 0.15.x
	@v="$$("$(ZIG)" version 2>/dev/null)"; case "$$v" in 0.15.*) ;; \
		*) echo "error: REAmo builds with Zig 0.15.x; '$(ZIG)' is '$${v:-not found}'. Run with ZIG=/path/to/zig-0.15/zig" >&2; exit 1 ;; esac

##@ Against a real REAPER

test-ws: ## tests/ws-integration against your running REAPER (test-fixtures/test-project-1.RPP open)
	cd tests/ws-integration && npm test

test-ws-harness: ## tests/ws-integration against headless REAPER in Docker (needs frontend-build)
	scripts/harness/ws-integration.sh

harness: ## Harness scenarios on headless REAPER in Docker; SCENARIOS="smoke ..." for a subset
	scripts/harness/run.sh $(SCENARIOS)

harness-image: ## Build the harness image for REAPER_VERSION (pinned, oldest, latest or e.g. 6.0)
	scripts/harness/run.sh --image-only

release-check: ## Release gate: every scenario on the oldest supported REAPER, then the pinned newest
	scripts/harness/run.sh --reaper oldest
	scripts/harness/run.sh --reaper pinned

##@ In a container (needs only Docker)

container-image: ## Build the check image: pinned Node, npm, Playwright's Chromium and Zig
	docker build -f scripts/container/Dockerfile -t "$(DEV_IMAGE)" .

container-check: container-image ## Run `make check` in the check image, on a copy of this working tree
	docker run --rm --init --shm-size=1g "$(DEV_IMAGE)" make check

##@ Housekeeping

clean: ## Delete build output (reamo/, zig-out, caches) and node_modules
	rm -rf frontend/dist frontend/node_modules tests/ws-integration/node_modules reamo
	rm -rf extension/.zig-cache extension/zig-out
