#!/usr/bin/env bash
# Container entry: run one scenario against a fresh headless REAPER.
#
# Mounts (set up by run.sh):
#   /harness   this directory (client library, lua helper, scenarios)
#   /ext       reaper_reamo.so built for the container's architecture
#   /reamo     the built frontend (index.html carries the hello token)
#   /effects   REAmo's own JSFX (extension/effects), installed as the release zip does
#   /fixtures  the repo's test-fixtures (projects a startup.lua can open)
#   /lic       optional reaper-license.rk (suppresses the evaluation nag)
#
# A scenario's folder can hold `capabilities` (run.sh), `no-extension`
# (REAPER starts without REAmo) and `jack-inputs` (REAPER runs on JACK with
# that many fed audio inputs; README, "Audio inputs through JACK").
#
# HARNESS_AUDIO=jack runs every scenario on JACK (2 inputs unless the
# scenario's `jack-inputs` says otherwise): for exploring what changes under
# JACK, not for a release check, since scenarios are written against
# REAPER's dummy device.
#
# Exit status: 0 only if the scenario's test.py passed AND REAPER is still
# alive afterwards. A crash is a failure even when the test script "passed".
# 77: the scenario skipped itself (this REAPER lacks what it checks).
set -uo pipefail

SCENARIO="${1:?usage: boot.sh <scenario>}"
# HARNESS_SCENARIO_DIR runs a scenario kept outside scenarios/, which a full
# run doesn't pick up (ws-integration.sh's host for tests/ws-integration).
SDIR="${HARNESS_SCENARIO_DIR:-/harness/scenarios/$SCENARIO}"
HOME_DIR=/tmp/reaper
READY=/tmp/harness_fixture_ready

cp -a "$REAPER_DIR" "$HOME_DIR"

# Audio device. linux_audio_mode=2 is REAPER's Linux dummy device, which runs
# the full audio path but has no inputs. linux_audio_mode=0 is JACK, here on
# jackd's dummy backend, whose capture ports a scenario feeds through
# jack_feeder.py. REAPER registers linux_audio_nch_in input ports (2 if
# unset, whatever the server has) and connects REAPER:inN to system:capture_N.
JACK_INPUTS=0
case "${HARNESS_AUDIO:-dummy}" in
    dummy) ;;
    jack) JACK_INPUTS=2 ;;
    *) echo "RESULT: FAIL ($SCENARIO: HARNESS_AUDIO is '$HARNESS_AUDIO', not dummy or jack)"; exit 2 ;;
esac
if [ -f "$SDIR/jack-inputs" ]; then
    JACK_INPUTS="$(tr -d '[:space:]' <"$SDIR/jack-inputs")"
    # 3 ports per input (system:capture_N, REAPER:inN, the feeder's out_N)
    # plus 4 for the stereo outputs must fit in --port-max 64.
    case "$JACK_INPUTS" in
        [1-9] | 1[0-6]) ;;
        *) echo "RESULT: FAIL ($SCENARIO: jack-inputs holds '$JACK_INPUTS', not an input count from 1 to 16)"; exit 2 ;;
    esac
fi
export HARNESS_JACK_INPUTS="$JACK_INPUTS"
AUDIO_INI='linux_audio_mode=2'
if [ "$JACK_INPUTS" -gt 0 ]; then
    # No JACK client (jack_lsp, REAPER, the feeder) may start a server of its
    # own: one started with the defaults wouldn't fit in /dev/shm, below.
    export JACK_NO_START_SERVER=1
    # --port-max 64: the default 2048 ports takes ~107 MB of shared memory,
    # more than the container's 64 MB /dev/shm, and jackd dies of SIGBUS.
    # --no-realtime: the container may not use realtime scheduling.
    jackd --no-realtime --port-max 64 -d dummy -C "$JACK_INPUTS" -P 2 -r 48000 -p 256 \
        >/tmp/jackd.out 2>&1 &
    JACKD_PID=$!
    jack_ok=0
    for _ in $(seq 1 100); do
        kill -0 "$JACKD_PID" 2>/dev/null || break
        if [ "$(jack_lsp 2>/dev/null | grep -c '^system:capture_')" = "$JACK_INPUTS" ]; then jack_ok=1; break; fi
        sleep 0.1
    done
    if [ "$jack_ok" != 1 ]; then
        echo "--- jackd output"
        cat /tmp/jackd.out
        echo "RESULT: FAIL ($SCENARIO: jackd did not offer $JACK_INPUTS capture ports within 10 s)"
        exit 2
    fi
    AUDIO_INI="linux_audio_mode=0
linux_audio_nch_in=$JACK_INPUTS
linux_audio_nch_out=2"
fi

# Portable mode (reaper.ini beside the binary). Blank VST paths skip the
# plugin scan; verchk=0 stops the update check, whose modal would block the
# main thread (as would the unlicensed evaluation nag); diskcheck=0 and
# promptendrec=0 skip the low-disk-space warning and the "keep recorded
# files?" prompt, both modal, when a scenario records.
cat > "$HOME_DIR/reaper.ini" <<EOF
[audioconfig]
mode=4
[REAPER]
vstpath=
vstpath_arm64=
$AUDIO_INI
verchk=0
diskcheck=0
promptendrec=0
EOF
[ -f /lic/reaper-license.rk ] && cp /lic/reaper-license.rk "$HOME_DIR/"
mkdir -p "$HOME_DIR/UserPlugins" "$HOME_DIR/Scripts" "$HOME_DIR/reaper_www_root"
# The installer copies stock JSFX into the resource folder; portable mode doesn't.
cp -a "$HOME_DIR/InstallData/Effects" "$HOME_DIR/Effects"
cp -a /effects/. "$HOME_DIR/Effects/"
# A scenario with a `no-extension` file runs REAPER without REAmo: a
# control to measure REAmo against.
NO_EXT=0
[ -f "$SDIR/no-extension" ] && NO_EXT=1
[ "$NO_EXT" = 1 ] || cp /ext/reaper_reamo.so "$HOME_DIR/UserPlugins/reaper_reamo.so"
cp -a /reamo "$HOME_DIR/reaper_www_root/reamo"
# Writable copy: REAPER writes peak files beside media, as in a real project dir.
cp -a /fixtures /tmp/fixtures
cp /harness/harness.lua "$HOME_DIR/Scripts/harness.lua"
# The fixture runs under pcall: an uncaught Lua error would otherwise open
# REAPER's (invisible, modal) error dialog and hang the run until the timeout.
if [ -f "$SDIR/startup.lua" ]; then
    cp "$SDIR/startup.lua" "$HOME_DIR/Scripts/fixture.lua"
else
    printf 'dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")\nharness.ready()\n' \
        > "$HOME_DIR/Scripts/fixture.lua"
fi
cat > "$HOME_DIR/Scripts/__startup.lua" <<'EOF'
local ok, err = pcall(dofile, reaper.GetResourcePath() .. "/Scripts/fixture.lua")
if not ok then
  local f = io.open("/tmp/harness_lua.log", "a")
  f:write("FIXTURE ERROR: " .. tostring(err) .. "\n")
  f:close()
end
EOF

# One X display shared by REAPER and the test, so test.py can screenshot it
# and look for (or dismiss) dialogs; see reamo_client.screenshot()/windows().
export DISPLAY=:99 HARNESS_SCENARIO="$SCENARIO" HARNESS_OUT="/out/${HARNESS_OUT_DIR:-$SCENARIO}"
rm -rf "$HARNESS_OUT" && mkdir -p "$HARNESS_OUT"
Xvfb :99 -screen 0 1600x1000x24 -nolisten tcp >/tmp/xvfb.out 2>&1 &
for _ in $(seq 1 40); do xdotool getmouselocation >/dev/null 2>&1 && break; sleep 0.05; done
shot() { import -window root "$HARNESS_OUT/$1.png" 2>/dev/null && echo "screenshot: out/${HARNESS_OUT_DIR:-$SCENARIO}/$1.png"; }

if [ "${HARNESS_GDB:-0}" = 1 ]; then
    gdb -q -batch -ex run -ex "thread apply all bt 25" \
        --args "$HOME_DIR/reaper" -nosplash >/tmp/reaper.out 2>&1 &
else
    "$HOME_DIR/reaper" -nosplash >/tmp/reaper.out 2>&1 &
fi

# Ready = the fixture has run and the extension's server accepts connections
# (without REAmo, the fixture alone).
ok=0
for _ in $(seq 1 120); do
    if [ -f "$READY" ] && { [ "$NO_EXT" = 1 ] || (exec 3<>/dev/tcp/127.0.0.1/9224) 2>/dev/null; }; then ok=1; break; fi
    sleep 0.25
done
[ -f /tmp/harness_lua.log ] && sed 's/^/[lua] /' /tmp/harness_lua.log
if [ "$ok" != 1 ]; then
    shot not-ready
    echo "--- windows: $(xdotool search --onlyvisible --name . getwindowname %@ 2>/dev/null | tr '\n' '|')"
    echo "RESULT: FAIL ($SCENARIO: REAPER/extension not ready within 30 s)"
    tail -20 /tmp/reaper.out
    exit 2
fi

PYTHONPATH=/harness python3 "$SDIR/test.py"
test_status=$?
sleep "${HARNESS_SETTLE_SECS:-1}"  # let a deferred crash surface

alive=0
pgrep -x reaper >/dev/null && alive=1

LOG="$HOME_DIR/Logs/reamo.log"
# Kept with the screenshots: REAmo's own account of the run, and REAPER's.
[ ! -f "$LOG" ] || cp "$LOG" "$HARNESS_OUT/reamo.log"
cp /tmp/reaper.out "$HARNESS_OUT/reaper.out" 2>/dev/null || true
[ "$JACK_INPUTS" = 0 ] || cp /tmp/jackd.out "$HARNESS_OUT/jackd.out" 2>/dev/null || true
if [ -f "$LOG" ] && grep -qE "ERROR|PANIC" "$LOG"; then
    echo "--- reamo.log errors"
    grep -E "ERROR|PANIC" "$LOG" | grep -v "FastTimer" | head -20
fi
if [ "$alive" != 1 ]; then
    echo "--- REAPER exited; tail of its output"
    tail -40 /tmp/reaper.out
    echo "RESULT: FAIL ($SCENARIO: REAPER crashed)"
    exit 3
fi
if [ "$JACK_INPUTS" -gt 0 ] && ! kill -0 "$JACKD_PID" 2>/dev/null; then
    echo "--- jackd exited; tail of its output"
    tail -20 /tmp/jackd.out
    echo "RESULT: FAIL ($SCENARIO: jackd exited, taking REAPER's audio device with it)"
    exit 3
fi
if [ "$test_status" = 77 ]; then
    echo "RESULT: SKIP ($SCENARIO)"
    exit 77
fi
if [ "$test_status" != 0 ]; then
    shot failed
    echo "RESULT: FAIL ($SCENARIO: assertions failed)"
    exit 1
fi
echo "RESULT: PASS ($SCENARIO)"
