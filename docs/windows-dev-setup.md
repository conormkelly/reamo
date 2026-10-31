# Windows Dev Setup for REAmo

## Prerequisites

Install these via PowerShell or CMD:

```
winget install zig.zig --version 0.15.2
winget install OpenJS.NodeJS.LTS
winget install Git.Git
winget install ezwinports.make
```

**Close and reopen your terminal after each install** so PATH updates take effect.

REAmo builds with Zig **0.15.x** only: a plain `winget install zig.zig` takes
the newest Zig, which can't build it. If winget has no 0.15.2, download
`zig-x86_64-windows-0.15.2.zip` from [ziglang.org](https://ziglang.org/download/)
and either put it on `PATH` or pass `ZIG=C:/path/to/zig.exe` to `make`.

Run `make` from **Git Bash**: the Makefile's recipes use POSIX commands
(`mkdir -p`, `cp`, `rm -rf`). Git for Windows doesn't include `make` itself,
hence the `ezwinports.make` install above. npm runs package scripts with
`cmd.exe` whichever shell calls it, and the frontend's build script uses `rm`
and `cp` too, so point npm at Git Bash once:

```bash
npm config set script-shell "C:\Program Files\Git\bin\bash.exe"
```

The frontend refuses npm older than 11.16; Node's bundled npm may be older:

```bash
npm --version            # if older than 11.16:
npm install -g npm@11
```

## Required Versions

| Tool  | Version                  | Check with        |
| ----- | ------------------------ | ----------------- |
| Zig   | 0.15.x (releases: 0.15.2) | `zig version`     |
| Node  | 22.22.2+ or 24.15+       | `node --version`  |
| npm   | 11.16+                   | `npm --version`   |
| Git   | any                      | `git --version`   |
| Make  | any GNU Make             | `make --version`  |

## REAPER

Install [REAPER](https://www.reaper.fm/download.php) (x64) to the default location (`C:\Program Files\REAPER (x64)`).

## Clone & Build

```bash
git clone https://github.com/conormkelly/reamo.git
cd reamo
make install        # npm dependencies, git hooks, Playwright's Chromium
make frontend       # the web UI, into REAPER's reaper_www_root\reamo
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
make extension      # or: make dev-extension (the HTML is re-read on every request)
make start-reaper
```

## Running Tests

```bash
make check             # lint, typecheck, and every test below
make test-extension    # Zig unit tests
make test-frontend     # Vitest
make test-e2e          # Playwright
```

`make help` lists every target.

## Known Quirks

- Zig extraction takes a while on NTFS (lots of small files in the 88MB zip)
- The Windows build uses `ReleaseSafe` by default — Debug builds can stack overflow due to Zig's large debug stack frames combined with Windows' 1MB default thread stack (vs 8MB on macOS)
- DLL output goes to `zig-out/bin/` on Windows (not `zig-out/lib/` like macOS/Linux) — the Makefile handles this automatically
