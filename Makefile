.PHONY: all frontend extension clean test test-frontend test-extension test-e2e

# Default target: run tests first, then build
all: test frontend extension

# Build frontend and copy to www root
frontend:
	@echo "Building frontend..."
	cd frontend && npm run build
	@echo "Copying to reamo.html..."
	cp frontend/dist/index.html reamo.html
	@echo "Frontend build complete: reamo.html"

# Build and install Zig extension
extension:
	@echo "Building extension..."
	cd extension && zig build
	@echo "Installing to REAPER UserPlugins..."
	cp extension/zig-out/lib/libreaper_reamo.dylib \
		"$(HOME)/Library/Application Support/REAPER/UserPlugins/reaper_reamo.dylib"
	@echo "Extension installed. Restart REAPER to load."

# Clean build artifacts
clean:
	@echo "Cleaning frontend..."
	rm -rf frontend/dist frontend/node_modules
	rm -f reamo.html
	@echo "Cleaning extension..."
	rm -rf extension/.zig-cache extension/zig-out
	@echo "Clean complete."

# Install frontend dependencies
install:
	cd frontend && npm install

# Run frontend dev server
dev:
	cd frontend && npm run dev

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
