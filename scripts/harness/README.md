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

The first run builds the `reamo-v1-harness:reaper-7.83` image (~30 s:
Debian, REAPER 7.83, xvfb/GTK/ALSA, python3, gdb).

## Running against another REAPER release

`--reaper` (or `REAPER_VERSION`, for `make`) picks the release: a number
as reaper.fm numbers it, or `pinned` (the default: the newest release we
have checked, 7.83), `oldest` (the oldest we support, 6.0) or `latest`
(reaper.fm's current release, looked up when the run starts, so it needs
the network). Each version gets its own image, built on first use from
that release's portable Linux tarball, and the run says which REAPER it
tested:

```sh
scripts/harness/run.sh --reaper 6.0 smoke
REAPER_VERSION=latest make harness
make release-check          # every scenario on oldest, then on pinned
```

`make release-check` is the release gate: both runs must pass. When a new
REAPER comes out, run on `latest`, then move `PINNED_REAPER` in `run.sh`.

Screenshots in `out/` are per scenario, not per version: a later run of the
same scenario on another version replaces them.

## Running on Windows

`run.sh --os windows` runs scenarios on a real Windows PC, driven over SSH:

```sh
scripts/harness/run.sh --os windows smoke
scripts/harness/run.sh --os windows                  # every scenario
```

It finds bugs the Linux container can't: http.zig's Windows-only blocking
mode, MSVC's C++ ABI, Win32 modal loops, Winsock. There is no Windows image:
Windows containers have no desktop, so REAPER's windows, dialogs and
screenshots wouldn't exist (Microsoft: containers "were designed to not have
RDP or GUI support"), and a Windows VM needs its own licence.

**How it runs.** `windows/run.sh` (on the controller) builds
`reaper_reamo.dll`, copies a snapshot of this directory, `web/`, the effects,
the fixtures and the licence to the PC, and runs each scenario there in turn.
A process started over SSH has no desktop, so `windows/run-scenario.ps1`
hands the scenario to `windows/boot.ps1` through a scheduled task in the
logged-in session, which:

- copies a fresh portable REAPER per scenario and starts it with
  `-cfgfile reaper.ini` (a `reaper.ini` beside `reaper.exe` alone doesn't
  make it portable on Windows: REAPER sets up `%APPDATA%\REAPER`);
- sets plugin paths to an empty folder and Dummy Audio (`[audioconfig]
  mode=4`, as on Linux); REAPER still scans the standard VST3 folder, which
  the setup keeps the test user from listing;
- runs `test.py`, then copies its log and screenshots back to `out/`.

The PC runs one scenario at a time (one desktop, one port), and a new run
ends any in progress, so don't start two Windows runs at once.
`reamo_client` drives windows with Win32 there (`win_desktop.py`): window
lists, key presses, button clicks, screenshots.

**Paths.** Windows reads a path starting with `/` as on the current drive,
so `/tmp` is `C:\tmp` (emptied per scenario) and `/harness` is `C:\harness`
(a junction to the staged copy). Any other `/`-rooted path lands among the
PC's own folders on `C:`: a scenario writes only under `/tmp`, makes
directories with `harness.mkdir` (no shell commands; Windows has no
`mkdir -p`), and one built on Linux itself calls
`reamo_client.skip_unless_linux(reason)` first.

### Setting up the PC

On the controller (the Mac or Linux machine that runs `run.sh`):

1. Give the controller a fixed address (reserve it in the router; on macOS
   set the Wi-Fi's Private Wi-Fi address to Fixed), and the PC one too.
2. Make a key just for the PC: `ssh-keygen -t ed25519 -f
   ~/.ssh/id_ed25519_reamo_win -C reamo-harness`.
3. Add it to `~/.ssh/config` as `reamo-win` (`run.sh` uses that name;
   `HARNESS_WINDOWS_HOST` overrides it):

   ```
   Host reamo-win
    HostName <the PC's address>
    User reamotest
    IdentityFile ~/.ssh/id_ed25519_reamo_win
    IdentitiesOnly yes
   ```

On the PC, in an elevated PowerShell while it still has internet access,
run `windows/setup-test-pc.ps1 -ControllerIp <controller address>
-PublicKey "<the .pub file's line>"`. It:

- creates `reamotest`, a standard (non-admin) user, and logs it in at boot
  (Sysinternals Autologon), since tests need its desktop;
- installs OpenSSH Server: only that user, only by key, the key only from
  the controller's address (`from=`, in an admin-owned key file the test
  user can't add to), the firewall rule likewise, on every network type;
- installs Python;
- hides the standard VST3 and CLAP folders from the test user, so no
  plugin's activation window blocks REAPER's startup (undo:
  `icacls "<folder>" /remove:d reamotest`);
- refuses network connections to the test REAPER and Python, so Windows
  never asks to let them through the firewall (tests connect from the PC
  itself, which the firewall doesn't filter).

The controller downloads REAPER for Windows (`7zz` unpacks its installer;
`brew install sevenzip`) and copies it across, so the PC can then go
offline: a fixed address with no gateway or DNS, IPv6 off on its adapter
(a router may give it an IPv6 route out), and Windows Firewall blocking
outbound traffic except to the local subnet. With no gateway Windows calls
the network "Unidentified" and applies the Public profile, which the SSH
rule covers.

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
   `reaper_www_root/reamo/`, and the scenario's `startup.lua` as
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
  capabilities  optional Linux capabilities for the container, one per line
                (NET_ADMIN lets test.py add network adapters with `ip`)
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

### REAPER as the oracle

When the right answer is "whatever REAPER says" (bar labels, tempo maths),
have the fixture ask REAPER and record it, then compare in the test:

```lua
harness.oracle("label@0", reaper.format_timestr_pos(0, "", 2))
```

```python
from reamo_client import oracle
assert got == oracle()["label@0"]
```

### Acting in REAPER mid-test

`reaper(lua)` runs a Lua chunk on REAPER's main thread while the test is
connected, the way a user's edit in REAPER would land, and returns what the
chunk returns (numbers, strings, booleans, tables as lists/dicts):

```python
from reamo_client import reaper
reaper("reaper.SetTempoTimeSigMarker(0, -1, 2, -1, -1, 60, 3, 4, false); reaper.UpdateTimeline()")
want = reaper('return reaper.format_timestr_pos(4, "", 2)')
```

A command sent with `fire()` is applied on a later extension tick, so when
the oracle depends on it, re-read it inside your wait loop rather than once.
A Lua error raises `ReaperError`. `harness.ready()` starts the RPC loop, so
every fixture has it.

### Every supported REAPER

Scenarios run on the oldest REAPER we support (6.0) as well as the newest,
so fixture and test Lua sticks to what 6.0's ReaScript has, or goes through
a harness helper that covers the difference:

- `harness.save_as(path)` saves the project as `path` and carries on in it.
  A fixture that saves starts with `harness.begin_project(path)` (6.0 can
  save only to the file a project was opened from).
- `harness.config(name)` reads a preference or project setting, or `nil`
  where REAPER can't tell a script (6.0 can't read project settings).
- `harness.build_peaks(src)` builds a source's peaks now.
- Pass the buffer argument to calls that return text (`TrackFX_GetFXName(tr,
  i, "")`, `GetMediaSourceFileName(src, "")`): 6.0 requires it.

A scenario that checks something a REAPER release doesn't have ends with
`reamo_client.skip(reason)` (exit 77), after checking the extension's answer
there when it has one: `skip_before_lanes()` requires lane commands to be
refused before REAPER 7. A tour op raises `Skip`, and `t.need(key)` skips
when the digest has no such fact on this REAPER. Skips are listed apart from
passes and failures, so a run shows what it didn't check.

### Real projects

`harness.open_fixture("test-project-1.RPP")` opens a project from the repo's
`test-fixtures/` (a writable copy, so REAPER can write peak files). Fixture
errors are caught and logged as `FIXTURE ERROR` rather than opening REAPER's
invisible error dialog.

Name scenarios after the behaviour they pin (`item-notes-poll`), and keep
each to one concern so a failure points somewhere.

## The operation tour

The `tour-*` scenarios run every protocol command against a realistic
project (`corpus/*.lua` builds it), with REAPER as the oracle. Each op in
`tour_ops/` performs one user action with the parameters the frontend
sends, then the tour (`tour.py`) checks four things:

- REAPER shows exactly the change the op declares and nothing else. Every
  user-visible fact is in `digest.lua`, so an edit that reaches the wrong
  track, item or setting fails.
- Undo and redo from the client return the project to its state before
  and after the op, where the op is undoable.
- Every event stream a client mirrors (`tour_mirror.py`) converges to
  REAPER's state.
- REAPER is still alive.

```sh
scripts/harness/check_tour_coverage.py    # every registry command toured or exempt?
TOUR_ONLY="marker region" make harness SCENARIOS=tour-band-session   # ops whose name contains either word
```

A new command needs an op (or an `EXEMPT` entry with the reason) or the
coverage check fails, and a full `make harness` runs that check first. Ops
choose their targets by role (a track with items, one with FX, a folder),
preferring the band session's track for each flow, and raise `Skip` when a
project has none. They leave the project as they found it, so a later op
sees the same session whatever runs before it.

The tour runs over five corpus projects, each its own `tour-*` scenario:
`band-session` (a full band arrangement), `demo-sketch` (an evening's
untidy idea), `tempo-map` (ramps and meter changes, time-locked),
`legacy-v6` (a hand-written REAPER 6 project with a missing plugin and
missing media, so REAPER's load dialogs come up) and `empty-unsaved`
(REAPER's startup project).
