# Live-REAPER harness

Runs the extension inside a **real, headless REAPER** (Linux, in Docker) and
drives it over WebSocket the way the web UI does. Use it to reproduce bugs
that unit tests and the mock backend can't reach: anything that depends on
what REAPER actually returns, how it copies strings, or whether REAPER
survives.

```sh
make harness                                  # every scenario
make harness SCENARIOS="smoke item-notes-poll"  # a subset
HARNESS_GDB=1 make harness SCENARIOS=item-notes-poll   # backtrace on a crash
```

A scenario passes only if its assertions hold **and REAPER is still running
afterwards**: a segfault is a failure even if the client saw no error.

## Requirements

- Docker (Apple Silicon runs REAPER for aarch64 natively; x86_64 hosts use x86_64)
- Zig 0.15.x, on `PATH` or via `ZIG=/path/to/zig`
- A built frontend in `web/` (`make frontend`): `index.html` carries the
  hello token the client reads, as the browser does
- A REAPER licence file, see below

The first run builds the `reamo-v1-harness` image (~30 s: Debian, pinned
REAPER 7.30, xvfb/GTK/ALSA, python3, gdb).

## REAPER licence (local only, never committed)

Unlicensed REAPER shows an evaluation dialog at startup. Under the harness it
is invisible but still modal, so it blocks REAPER's main thread and the
extension never starts. Copy your own licence file to:

```
scripts/harness/reaper-license.rk
```

It is gitignored (as is any `*.rk`), copied into the throwaway container
read-only, and never leaves your machine. On a desktop install it is
`reaper-license.rk` in REAPER's resource folder (Options → Show REAPER
resource path). `REAPER_LICENSE=/other/path.rk` overrides the location.

## How it works

`run.sh` cross-builds the extension for the container's architecture
(ReleaseSafe, as shipped), then runs each scenario in its own `--rm`
container. `boot.sh` (inside the container):

1. copies REAPER into a writable dir and writes a `reaper.ini` beside the
   binary, making it **portable**: that dir is REAPER's resource folder.
   - `linux_audio_mode=2`: REAPER's Linux dummy audio device, so the audio
     path (meters, audio hook) still runs with no sound hardware
   - `verchk=0` and `--network none`: no update check, whose dialog would
     also block the main thread
   - blank VST paths: no plugin scan
2. installs the extension into `UserPlugins/`, the web UI into
   `reaper_www_root/web/`, and the scenario's `startup.lua` as
   `Scripts/__startup.lua`, which REAPER runs at launch to build the fixture
3. starts REAPER under `xvfb-run` (REAPER always opens a window), waits for
   the fixture to report ready and port 9224 to accept connections
4. runs the scenario's `test.py`, then checks REAPER is alive and prints
   `reamo.log` errors

Containers have no network and publish no ports, so runs don't interfere
with a desktop REAPER or anything else on the machine.

## Writing a scenario

```
scenarios/<name>/
  startup.lua   optional fixture, built through the ReaScript API
  test.py       drives the extension and asserts; non-zero exit = fail
```

```lua
-- startup.lua
dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")
local t = harness.track("Vocals")
harness.item(t, 0, 4)
harness.ready()   -- always last
```

```python
# test.py
from reamo_client import Client

with Client() as c:                         # token from GET /, upgrade, hello
    c.wait_event("trackSkeleton")           # sent to every new client
    r = c.command("item/getNotes", trackIdx=1, itemIdx=0)
    assert r["success"], r
```

On connect a client receives `transport`, `project`, `markers`, `regions`,
`items`, `tempoMap`, `trackSkeleton` and `playlist`. Track detail and meters
need `track/subscribe`. `reamo_client.py` documents the rest; it uses only
the Python standard library.

Name scenarios after the behaviour they pin (`item-notes-poll`), and keep
each to one concern so a failure points somewhere.
