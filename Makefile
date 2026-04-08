.PHONY: all frontend extension dev-extension clean test test-frontend test-extension test-e2e \
        dev dev-notests dev-cycle stop-reaper start-reaper frontend-dev install typecheck tracy \
        release release-dir

# Platform detection: library name and REAPER plugin directory
ifeq ($(shell uname),Darwin)
    EXT_LIB = libreaper_reamo.dylib
    EXT_DEST = reaper_reamo.dylib
    EXT_OUT_DIR = lib
    REAPER_PLUGINS = $(HOME)/Library/Application Support/REAPER/UserPlugins
    REAPER_WWW = $(HOME)/Library/Application Support/REAPER/reaper_www_root/web
else ifeq ($(OS),Windows_NT)
    EXT_LIB = reaper_reamo.dll
    EXT_DEST = reaper_reamo.dll
    EXT_OUT_DIR = bin
    REAPER_PLUGINS = $(APPDATA)/REAPER/UserPlugins
    REAPER_WWW = $(APPDATA)/REAPER/reaper_www_root/web
else
    EXT_LIB = libreaper_reamo.so
    EXT_DEST = reaper_reamo.so
    EXT_OUT_DIR = lib
    REAPER_PLUGINS = $(HOME)/.config/REAPER/UserPlugins
    REAPER_WWW = $(HOME)/.config/REAPER/reaper_www_root/web
endif

# Default target: run tests first, then build
all: test frontend extension

# Build frontend, copy to www root, and install to REAPER's www root
frontend:
	@echo "Building frontend..."
	cd frontend && npm run build
	@mkdir -p "$(REAPER_WWW)"
	@if [ "$$(cd web && pwd)" != "$$(cd "$(REAPER_WWW)" && pwd)" ]; then \
		cp -r web/* "$(REAPER_WWW)/"; \
		echo "Frontend installed to $(REAPER_WWW)"; \
	else \
		echo "Build output already in place (repo is inside reaper_www_root)."; \
	fi
	@echo "Frontend built and installed."

# Build and install Zig extension
# Linux: ReleaseSafe works around Zig 0.15 Debug codegen bug (MIR InvalidInstruction)
# Windows: ReleaseSafe needed — Debug builds have 650KB+ stack frames that overflow the 1MB default thread stack
extension:
	@echo "Building extension..."
ifeq ($(shell uname),Linux)
	cd extension && zig build -Doptimize=ReleaseSafe
else ifeq ($(OS),Windows_NT)
	cd extension && zig build -Doptimize=ReleaseSafe
else
	cd extension && zig build
endif
	@echo "Installing to REAPER UserPlugins..."
	@mkdir -p "$(REAPER_PLUGINS)"
	cp "extension/zig-out/$(EXT_OUT_DIR)/$(EXT_LIB)" "$(REAPER_PLUGINS)/$(EXT_DEST)"
	@echo "Extension installed. Restart REAPER to load."

# Build and install Zig extension in dev mode (fresh HTML reads per request)
dev-extension:
	@echo "Building extension (dev mode)..."
ifeq ($(shell uname),Linux)
	cd extension && zig build -Ddev=true -Doptimize=ReleaseSafe
else ifeq ($(OS),Windows_NT)
	cd extension && zig build -Ddev=true -Doptimize=ReleaseSafe
else
	cd extension && zig build -Ddev=true
endif
	@echo "Installing dev build to REAPER UserPlugins..."
	@mkdir -p "$(REAPER_PLUGINS)"
	cp "extension/zig-out/$(EXT_OUT_DIR)/$(EXT_LIB)" "$(REAPER_PLUGINS)/$(EXT_DEST)"
	@echo "Dev extension installed (fresh HTML reads per request)."

# Build extension with Tracy profiler enabled (ReleaseFast required for Zig 0.15)
tracy:
	@echo "Building extension with Tracy profiler..."
	cd extension && zig build -Dtracy=true -Doptimize=ReleaseFast
	@echo "Installing Tracy-enabled build to REAPER UserPlugins..."
	@mkdir -p "$(REAPER_PLUGINS)"
	cp "extension/zig-out/$(EXT_OUT_DIR)/$(EXT_LIB)" "$(REAPER_PLUGINS)/$(EXT_DEST)"
	@echo ""
	@echo "Tracy-enabled extension installed. To profile:"
	@echo "  1. Start Tracy GUI: tracy (or open Tracy.app)"
	@echo "  2. Launch REAPER"
	@echo "  3. Connect Tracy to REAPER process"
	@echo "  4. Trigger actions to profile (e.g., open Actions panel)"

# Build extension with CSurf push-based callbacks enabled
csurf:
	@echo "Building extension with CSurf (push-based callbacks)..."
	cd extension && zig build -Dcsurf=true
	@echo "Installing CSurf-enabled build to REAPER UserPlugins..."
	@mkdir -p "$(REAPER_PLUGINS)"
	cp "extension/zig-out/$(EXT_OUT_DIR)/$(EXT_LIB)" "$(REAPER_PLUGINS)/$(EXT_DEST)"
	@echo ""
	@echo "CSurf-enabled extension installed. Restart REAPER to load."
	@echo "Check extension log for 'CSurf registered for push-based callbacks'"

# Clean build artifacts
clean:
	@echo "Cleaning frontend..."
	rm -rf frontend/dist frontend/node_modules
	rm -f index.html
	@echo "Cleaning extension..."
	rm -rf extension/.zig-cache extension/zig-out
	@echo "Clean complete."

# Install frontend dependencies
install:
	cd frontend && npm install

# Run frontend dev server (hot reload for UI development)
frontend-dev:
	cd frontend && npm run dev

# Rapid extension development: test, kill REAPER, build, install, relaunch
# Runs all tests first, then restarts REAPER with stdout attached for debugging
dev: test dev-cycle

# Quick dev cycle without tests (for rapid iteration after tests pass)
dev-notests: dev-cycle

# Internal: the actual kill/build/install/relaunch cycle
dev-cycle: stop-reaper dev-extension start-reaper

# Stop REAPER (cross-platform)
stop-reaper:
	@echo "Stopping REAPER..."
ifeq ($(OS),Windows_NT)
	-@taskkill /IM reaper.exe /F 2>NUL || exit 0
else
	-@pkill -x REAPER 2>/dev/null || pkill -x reaper 2>/dev/null || true
endif
	@sleep 0.5

# Start REAPER in foreground (cross-platform)
# Keeps stdout/stderr attached for immediate visibility of panics/logs
start-reaper:
	@echo "Launching REAPER in foreground (Ctrl+C to stop)..."
ifeq ($(OS),Windows_NT)
	@echo "On Windows, run REAPER manually from terminal for stdout visibility"
	start "" "C:\Program Files\REAPER (x64)\reaper.exe"
else
ifeq ($(shell uname),Darwin)
	/Applications/REAPER.app/Contents/MacOS/REAPER
else
	reaper
endif
endif

# Run all tests (frontend unit + E2E + extension)
test: test-frontend test-e2e test-extension

# Run frontend unit tests (vitest)
test-frontend:
	@echo "Running frontend unit tests..."
	cd frontend && npm test

# Run frontend E2E tests (playwright)
test-e2e:
	@echo "Running E2E tests..."
	cd frontend && npm run test:e2e

# Run extension unit tests (zig)
test-extension:
	@echo "Running extension tests..."
	cd extension && zig build test

# Type check frontend
typecheck:
	cd frontend && npm run build -- --mode development

# =============================================================================
# Release packaging
# =============================================================================

# Version from frontend/package.json
VERSION := $(shell node -p "require('./frontend/package.json').version")
RELEASE_DIR := release/REAmo-v$(VERSION)

# Build release ZIP with platform binaries + frontend + installer
# Builds: macOS universal (arm64+x86_64), Windows x86_64, Linux x86_64
release: frontend release-dir
	@echo "=== Building release v$(VERSION) ==="
	@# macOS universal binary (arm64 + x86_64 via lipo)
	@echo "Building macOS arm64..."
	cd extension && zig build -Doptimize=ReleaseSafe
	cp extension/zig-out/lib/libreaper_reamo.dylib "$(RELEASE_DIR)/reaper_reamo_arm64.dylib"
	@echo "Building macOS x86_64..."
	cd extension && zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos
	@echo "Creating macOS universal binary..."
	lipo -create \
		"$(RELEASE_DIR)/reaper_reamo_arm64.dylib" \
		extension/zig-out/lib/libreaper_reamo.dylib \
		-output "$(RELEASE_DIR)/reaper_reamo.dylib"
	@rm "$(RELEASE_DIR)/reaper_reamo_arm64.dylib"
	@# Windows x86_64 (cross-compile)
	@echo "Building Windows x86_64..."
	cd extension && zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows
	cp extension/zig-out/bin/reaper_reamo.dll "$(RELEASE_DIR)/reaper_reamo.dll"
	@# Linux x86_64 (cross-compile)
	@echo "Building Linux x86_64..."
	cd extension && zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux
	cp extension/zig-out/lib/libreaper_reamo.so "$(RELEASE_DIR)/reaper_reamo.so"
	@# Package
	@echo "Creating ZIP..."
	cd release && zip -r "REAmo-v$(VERSION).zip" "REAmo-v$(VERSION)"
	@echo ""
	@echo "Release ready: release/REAmo-v$(VERSION).zip"
	@echo "Contents:"
	@zipinfo -1 "release/REAmo-v$(VERSION).zip"

# Create release directory structure with installer + frontend + JSFX
release-dir:
	@rm -rf "$(RELEASE_DIR)"
	@mkdir -p "$(RELEASE_DIR)/web" "$(RELEASE_DIR)/effects/REAmo"
	@# Installer scripts and README
	cp installer/Install_REAmo.lua "$(RELEASE_DIR)/"
	cp installer/Uninstall_REAmo.lua "$(RELEASE_DIR)/"
	cp installer/README.txt "$(RELEASE_DIR)/"
	@# Frontend (built by 'frontend' target)
	cp -r web/* "$(RELEASE_DIR)/web/"
	@# JSFX tuner plugin
	cp extension/effects/REAmo/PitchDetect.jsfx "$(RELEASE_DIR)/effects/REAmo/"
