# Windows Dev Setup for REAmo

## Prerequisites

Install these via PowerShell or CMD:

```
winget install zig.zig
winget install OpenJS.NodeJS.LTS
winget install Git.Git
```

**Close and reopen your terminal after each install** so PATH updates take effect.

You also need **GNU Make** — it comes with Git for Windows if you use Git Bash, or you can install it via:

```
winget install GnuWin32.Make
```

## Required Versions

| Tool  | Minimum | Check with        |
| ----- | ------- | ----------------- |
| Zig   | 0.15.0  | `zig version`     |
| Node  | 22+     | `node --version`  |
| Git   | any     | `git --version`   |
| Make  | any     | `make --version`  |

## REAPER

Install [REAPER](https://www.reaper.fm/download.php) (x64) to the default location (`C:\Program Files\REAPER (x64)`).

## Clone & Build

```bash
git clone https://github.com/conormkelly/reamo.git
cd reamo
cd frontend && npm install && cd ..
make extension
```

Zig fetches its own dependencies on first build (httpz, ztracy) — no extra setup needed. The `make extension` target builds with `ReleaseSafe` on Windows and copies the DLL to `%APPDATA%\REAPER\UserPlugins\`.

## Dev Cycle

```bash
make dev-notests    # kills REAPER, builds, copies DLL, relaunches
```

Or manually:

```bash
make stop-reaper
make extension      # or: make dev-extension (for hot-reload HTML)
make start-reaper
```

## Running Tests

```bash
make test-extension    # Zig unit tests
make test-frontend     # Vitest
make test-e2e          # Playwright (needs: npx playwright install chromium)
```

## Known Quirks

- Zig extraction takes a while on NTFS (lots of small files in the 88MB zip)
- The Windows build uses `ReleaseSafe` by default — Debug builds can stack overflow due to Zig's large debug stack frames combined with Windows' 1MB default thread stack (vs 8MB on macOS)
- DLL output goes to `zig-out/bin/` on Windows (not `zig-out/lib/` like macOS/Linux) — the Makefile handles this automatically
