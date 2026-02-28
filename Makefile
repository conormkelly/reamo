.PHONY: all frontend extension clean test test-frontend test-extension test-e2e \
        dev dev-notests dev-cycle stop-reaper start-reaper frontend-dev install typecheck tracy

# Platform detection: library name and REAPER plugin directory
ifeq ($(shell uname),Darwin)
    EXT_LIB = libreaper_reamo.dylib
    EXT_DEST = reaper_reamo.dylib
    REAPER_PLUGINS = $(HOME)/Library/Application Support/REAPER/UserPlugins
else
    EXT_LIB = libreaper_reamo.so
    EXT_DEST = reaper_reamo.so
    REAPER_PLUGINS = $(HOME)/.config/REAPER/UserPlugins
endif

# Default target: run tests first, then build
all: test frontend extension

# Build frontend and copy to www root
frontend:
	@echo "Building frontend..."
	cd frontend && npm run build
	@echo "Frontend build complete: index.html + icons + manifest.json"

# Build and install Zig extension
# Linux uses ReleaseSafe to work around Zig 0.15 Debug codegen bug (MIR InvalidInstruction)
extension:
	@echo "Building extension..."
ifeq ($(shell uname),Darwin)
	cd extension && zig build
else
	cd extension && zig build -Doptimize=ReleaseSafe
endif
	@echo "Installing to REAPER UserPlugins..."
	@mkdir -p "$(REAPER_PLUGINS)"
	cp "extension/zig-out/lib/$(EXT_LIB)" "$(REAPER_PLUGINS)/$(EXT_DEST)"
	@echo "Extension installed. Restart REAPER to load."

# Build extension with Tracy profiler enabled (ReleaseFast required for Zig 0.15)
tracy:
	@echo "Building extension with Tracy profiler..."
	cd extension && zig build -Dtracy=true -Doptimize=ReleaseFast
	@echo "Installing Tracy-enabled build to REAPER UserPlugins..."
	@mkdir -p "$(REAPER_PLUGINS)"
	cp "extension/zig-out/lib/$(EXT_LIB)" "$(REAPER_PLUGINS)/$(EXT_DEST)"
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
	cp "extension/zig-out/lib/$(EXT_LIB)" "$(REAPER_PLUGINS)/$(EXT_DEST)"
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
dev-cycle: stop-reaper extension start-reaper

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
