#!/usr/bin/env bash
# Container entry: run one scenario against a fresh headless REAPER.
#
# Mounts (set up by run.sh):
#   /harness   this directory (client library, lua helper, scenarios)
#   /ext       reaper_reamo.so built for the container's architecture
#   /web       the built frontend (index.html carries the hello token)
#   /effects   REAmo's own JSFX (extension/effects), installed as the release zip does
#   /fixtures  the repo's test-fixtures (projects a startup.lua can open)
#   /lic       optional reaper-license.rk (suppresses the evaluation nag)
#
# Exit status: 0 only if the scenario's test.py passed AND REAPER is still
# alive afterwards. A crash is a failure even when the test script "passed".
set -uo pipefail

SCENARIO="${1:?usage: boot.sh <scenario>}"
SDIR="/harness/scenarios/$SCENARIO"
HOME_DIR=/tmp/reaper
READY=/tmp/harness_fixture_ready

cp -a "$REAPER_DIR" "$HOME_DIR"
# Portable mode (reaper.ini beside the binary). linux_audio_mode=2 is REAPER's
# Linux dummy audio device, which still runs the full audio path; blank VST
# paths skip the plugin scan; verchk=0 stops the update check, whose modal
# would block the main thread (as would the unlicensed evaluation nag).
cat > "$HOME_DIR/reaper.ini" <<'EOF'
[audioconfig]
mode=4
[REAPER]
vstpath=
vstpath_arm64=
linux_audio_mode=2
verchk=0
EOF
[ -f /lic/reaper-license.rk ] && cp /lic/reaper-license.rk "$HOME_DIR/"
mkdir -p "$HOME_DIR/UserPlugins" "$HOME_DIR/Scripts" "$HOME_DIR/reaper_www_root"
# The installer copies stock JSFX into the resource folder; portable mode doesn't.
cp -a "$HOME_DIR/InstallData/Effects" "$HOME_DIR/Effects"
cp -a /effects/. "$HOME_DIR/Effects/"
cp /ext/reaper_reamo.so "$HOME_DIR/UserPlugins/reaper_reamo.so"
cp -a /web "$HOME_DIR/reaper_www_root/web"
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

if [ "${HARNESS_GDB:-0}" = 1 ]; then
    xvfb-run -a gdb -q -batch -ex run -ex "thread apply all bt 25" \
        --args "$HOME_DIR/reaper" -nosplash >/tmp/reaper.out 2>&1 &
else
    xvfb-run -a "$HOME_DIR/reaper" -nosplash >/tmp/reaper.out 2>&1 &
fi

# Ready = the fixture has run and the extension's server accepts connections.
ok=0
for _ in $(seq 1 120); do
    if [ -f "$READY" ] && (exec 3<>/dev/tcp/127.0.0.1/9224) 2>/dev/null; then ok=1; break; fi
    sleep 0.25
done
[ -f /tmp/harness_lua.log ] && sed 's/^/[lua] /' /tmp/harness_lua.log
if [ "$ok" != 1 ]; then
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
if [ "$test_status" != 0 ]; then
    echo "RESULT: FAIL ($SCENARIO: assertions failed)"
    exit 1
fi
echo "RESULT: PASS ($SCENARIO)"
