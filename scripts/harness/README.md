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
- Zig 0.15.x, on `PATH` or via `ZIG=/path/to/zig` (`make harness ZIG=...`
  works too)
- A built frontend in `reamo/` (`make frontend-build`): `index.html` carries
  the hello token the client reads, as the browser does
- Python 3, for the tour coverage check a full run starts with
- A REAPER licence file, see below

The first run builds the `reamo-v1-harness:reaper-7.83` image (~30 s:
Debian, REAPER 7.83, xvfb/GTK/ALSA, python3, gdb). The Debian base is pinned
by digest in the `Dockerfile`.

## The WebSocket integration suite

`tests/ws-integration` asserts against `test-fixtures/test-project-1.RPP`.
`make test-ws-harness` (`ws-integration.sh`) runs it against a headless
REAPER with that project open, so it needs no desktop REAPER:

```sh
make test-ws-harness
scripts/harness/ws-integration.sh --reaper oldest
```

REAPER runs as a harness scenario kept outside `scenarios/`
(`ws-integration/test.py`, which opens the project and waits); the suite
runs in the check image (`scripts/container/Dockerfile`) inside that
container's network namespace, so it reaches `localhost:9224` as on a
desktop. It passes only if every spec passes and REAPER is still running.

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

### What a run keeps

`out/<scenario>/` holds the scenario's latest run, on any OS or version:
`output.log` (everything the scenario printed, including a failed
assertion), `reamo.log`, its screenshots and, on Linux, `reaper.out`
(REAPER's own console output, where a crash says why). A later run
replaces it.

A failed run is also copied to `out/failures/<when>-<os>-reaper<version>-<scenario>/`,
which later runs leave alone, so a failure that doesn't come back can still
be read. Its `replay.txt` has the command that runs it again and the code it
ran: the commit, any uncommitted changes (in `worktree.diff`) and untracked
files. The command sets the `TOUR_ONLY` and `SOAK_*` settings the run had,
and any a scenario chose itself and wrote to `$HARNESS_OUT/replay.env` as
`NAME=value` lines (a soak's random seed). The run ends by listing where
each failure was kept. Delete `out/failures/` when you're done with them.

Ctrl-C (or a TERM to `run.sh`) removes the run's containers, and leaves
another run's alone.

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
`reaper_reamo.dll`, copies a snapshot of this directory, `reamo/`, the effects,
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
- runs `test.py`, then copies its log and screenshots back to `out/` (see
  "What a run keeps").

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
2. Make an SSH key used only for the PC (`ssh-keygen -t ed25519 -f
   <key file>`).
3. Add the PC to `~/.ssh/config` under the alias `reamo-win` (`run.sh`'s
   default; `HARNESS_WINDOWS_HOST` overrides it):

   ```
   Host reamo-win
    HostName <the PC's address>
    User <the test user>
    IdentityFile <key file>
    IdentitiesOnly yes
   ```

On the PC, in an elevated PowerShell while it still has internet access,
run `windows/setup-test-pc.ps1 -ControllerIp <controller address>
-PublicKey "<the .pub file's line>"` (`-User` names the test user). It:

- creates the test user, a standard (non-admin) account, and logs it in at boot
  (Sysinternals Autologon), since tests need its desktop;
- installs OpenSSH Server: only that user, only by key, the key only from
  the controller's address (`from=`, in an admin-owned key file the test
  user can't add to), the firewall rule likewise, on every network type;
- installs Python;
- hides the standard VST3 and CLAP folders from the test user, so no
  plugin's activation window blocks REAPER's startup (undo:
  `icacls "<folder>" /remove:d <the test user>`);
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

`restart_reaper()` quits REAPER (File: Quit REAPER) and starts it again as
`boot.sh` did; it returns once the fixture has run again and the server
accepts connections, with `reaper()` working. The new run has a new session
token. Linux only.

- It needs a clean project: a dirty one raises the save prompt, and the quit times out.
- The restarted REAPER isn't under gdb, even with `HARNESS_GDB=1`.
- The scenario's `startup.lua` runs again in the new REAPER.

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

## Soak tests

`soak/` holds scenarios that run for minutes to hours. A full run takes only
`scenarios/`, so they run only when named. Linux only for now.

```sh
make soak                          # 3 minutes: crashes, hangs, refusals, undo points, gross growth
SOAK_MINUTES=60 make soak          # an hour: also the RSS slope and CPU drift
SOAK_MINUTES=480 make soak         # a working day
SOAK_MINUTES=60 SOAK_SEED=7 scripts/harness/run.sh long-session-stays-healthy   # without the control
```

`make soak` runs the soak and its control at the same time, each in its
own container (with at least two jobs, whatever `HARNESS_JOBS` says).

`long-session-stays-healthy` opens the band session (`corpus/band-session.lua`)
and plays it on repeat:

- one phone stays connected throughout: mixer, peaks, notes and toggle
  states subscribed, and a main-thread command every 2 s;
- `SOAK_PHONES` (5) more connect, churn subscriptions (tracks, peaks
  viewports, FX chains and params, routing, audio stream, notes, toggle
  states), send read-only commands, pings and clock syncs, then drop the
  socket, close it, or go quiet first, and connect again;
- page loads (`GET /` and an asset) come in alongside.

**The control**, `long-session-baseline`: the same session on repeat for
the same time, sampled the same way, on a REAPER without REAmo (its
`no-extension` file) and with no phones.

- Report-only: it fails only if its setup is wrong (REAmo loaded,
  REAPER's mappings unreadable, a bad setting) or REAPER exits. A stalled
  ReaScript call, a stopped transport, a moved undo history or a broken
  limit go in its summary, not its result.
- No WebSocket probe, REAmo memory stats or refusals: those need REAmo.
- It doesn't read or record the phones' settings (`SOAK_PHONES`,
  `SOAK_SEED`, `SOAK_OPS`, `SOAK_REFUSAL_PCT`).
- They pair up by run id. When the soak ends (passed, failed or crashed)
  it writes `soak-done.json`; the control stops at its next sample and
  writes its summary. The soak waits up to 120 s for it, then reports
  both runs and the difference, against the first control if named
  twice. A failed soak isn't compared.
- No comparison, and the summary says why, if the soak runs alone, or
  the control didn't run alongside it (`run.sh` with the control named
  second and `HARNESS_JOBS=1`, or the control finished first).
- A failed soak's replay line runs both, and its kept copy holds the
  control's out dir too.
- The difference is REAmo plus what REAmo has REAPER do (API calls, peak
  reads, the audio hook), not REAmo's code alone.
- The limits judge the soak's own numbers, not the difference.

**The tuner is left out by default.** Opening and closing it leaves undo
points in REAPER (RV1-165), so a run with it fails. `SOAK_OPS=+tuner` puts
it in, to check a fix for RV1-165; until then that run fails on the undo
check, naming RV1-165.

It fails if:

- REAPER exits;
- a command goes unanswered for 10 s: the steady phone's probe runs every
  2 s, so a stall shows within about 12 s;
- a ReaScript call goes unanswered for 10 s: one runs at the first sample
  10 s after the last, so a stall seen only there shows within 25 s
  (10 + `SOAK_SAMPLE_SECS` + 10);
- the transport stops;
- the server closes or refuses a phone's connection, or a phone can't send
  its close frame;
- a command is refused, except `audio/startStream` with `STREAM_FAILED`
  while the listener slots are full by the phones' own count (four on the
  server; the phones keep to three, and count a slot given back in the last
  5 s as still held);
- REAPER's undo history or its project state change count moved: the
  phones make no edits;
- a phone's thread is still running 15 s after the run ends;
- after warm-up (`SOAK_WARMUP_MINUTES`: a third of the run, 1 to 20
  minutes), a limit below is broken.

A setting that doesn't parse, and a run under 2 minutes, fail with a
message. Every run writes its summary, failed or not.

| Limit (`SOAK_<NAME>` overrides) | Default | Checked |
|---|---|---|
| `RSS_GROWTH_MB`: RSS at the end of the post-warm-up span minus at its start (medians of a tenth of the samples) | 24 | always |
| `THREAD_GROWTH`, `FD_GROWTH`: threads, open files, the same way | 3, 4 | always |
| `REFUSAL_PCT`: allowed refusals, percent of commands | 0.5 | always |
| `RSS_SLOPE_MB_PER_HOUR`: least-squares slope of RSS | 6 | when warm-up is at least `SLOPE_MIN_WARMUP_MINUTES` (20) and at least `SLOPE_MIN_MINUTES` (30) follow it: runs of 60 minutes or more by default |
| `CPU_DRIFT_POINTS`: mean CPU of the last third of that span minus the first, in points of one core | 3 | likewise |

`SOAK_OPS` picks the phones' ops, in space-separated words matched against
op names:

- none: every op but the opt-in ones (the tuner);
- `+word`: the opt-in ops matching it as well (`+tuner`: every op and the tuner);
- `word`: only the ops matching a plain word, plus any `+word` ones
  (`peaks +tuner`: the peaks ops and the tuner);
- `-word`: never the ops matching it, whatever else matched (`-audio`).

`SOAK_SEED` seeds the phones' choices; timing still makes two runs differ.
An unset seed is random, and a failure's replay line carries the one used
(the scenario writes it to `replay.env`). For a crash, `HARNESS_GDB=1` puts
backtraces in `reaper.out`.

`out/long-session-stays-healthy/` keeps:

- `soak-series.csv`: one row per `SOAK_SAMPLE_SECS` (5): RSS, CPU of the
  process and its main thread, threads, open files, the probe's and the
  ReaScript call's latency, the slowest command, what the phones did.
  Written as it goes, so a crash leaves it.
- `soak-threads.csv`: per sample, each thread that used CPU: tid, name,
  group, CPU %. REAPER names its threads (`reaper/audio_dm`,
  `reaper/mediaafx`, ...); the main thread is `main`; REAmo's threads
  (HTTP/WebSocket server, audio stream) have no name and show as
  `unnamed`. The control runs none.
- `soak-summary.json`: settings, seed, metrics, limits, refusals,
  problems, RSS growth by mapping (`[heap]`, anonymous, libraries), CPU by
  thread group and the busiest threads, and `baseline`: the control's
  numbers beside the soak's.

`out/long-session-baseline/` keeps the control's, without `baseline`.

### When a number is high

Narrow it in this order:

1. **The baseline** (`baseline` in the summary). What the control shows
   too is REAPER's own; only the difference points at REAmo.
2. **Where it is.** `rss_growth_mb_by_mapping` says which memory grew: a
   library's mapping, `[heap]` (the main malloc arena) or anonymous
   (other malloc arenas, mmaps, thread stacks). `extension_memory`
   (`debug/memoryStats`) covers only REAmo's polling-state arenas (the
   30, 5 and 1 Hz tiers); growth outside them shows in the mappings only. `cpu_pct_by_thread_group`
   and `soak-threads.csv` say which thread: `unnamed` is REAmo's server
   or audio stream threads; `main` runs REAmo's timer and command
   handlers as well as REAPER's UI; `reaper/audio_dm` runs REAmo's audio
   hook as well as REAPER's audio; other `reaper/*` threads are REAPER's.
3. **Which ops.** Rerun with `SOAK_OPS` cut down (`peaks`, `-audio`,
   `trackFx`, ...): the op family the growth follows points at its
   command handlers.
4. **Profile the narrowed case.** Profiling is being evaluated separately.

### Where the limits come from

Measured on REAPER 7.83, aarch64 Docker, up to seven runs at once:

- No churn (the steady phone only): RSS flat at 200 MB, CPU 11.9 % (main
  thread 2.6 %).
- Full load without the tuner, 60 minutes: RSS climbs from 204 to 237 MB
  over about 20 minutes, flattening, then holds: 0.04 MB growth and a
  0.06 MB/h slope over the 40 minutes after a 20-minute warm-up. CPU
  17.5 % mean (sd 1.2), main thread 5.4 %, drift -0.8 points. Threads (40 to
  41) and open files (26 to 30): median growth 1 at most. Allowed refusals: 1 in 31,787 commands.
- 30 minutes is still inside that climb (14 MB/h after a 10-minute
  warm-up), hence slope and drift only from 60.
- 15-minute runs of one op family each: growth up to 12 MB, in steps, then
  flat; CPU drift within 1.1 points.
- Soak beside the control, 60 minutes, 20-minute warm-up: the control
  (REAPER alone) held at 180 MB with no growth (slope 0.00 MB/h), CPU
  15.4 % (main thread 3.2 %), 30 threads, none unnamed, 18 open files. The
  soak held at 237 MB, 1.2 MB growth, 1.3 MB/h, CPU 18.3 % (main 5.6 %,
  REAmo's unnamed threads 0.3 %), drift -0.5 points in both. The
  difference is REAmo under the phones' load: 57 MB, 2.9 points of CPU
  (2.4 on the main thread), 10 to 11 threads.

The growth limit sits at twice the largest warm-up step, the slope limit
far above the measured noise and well below a leak that matters over a
working day (RV1-165 grows about 40 MB/h in the full mix), the drift limit
at about three times the largest measured.
