"""The control for long-session-stays-healthy: the same session on repeat
for SOAK_MINUTES, sampled the same way, on a REAPER without REAmo (this
folder's `no-extension` file) and with no phones. What REAPER does alone,
for the soak to compare with: make soak runs both side by side, and the
soak's summary reports both and the difference.

It is there for its numbers, so it fails only when its setup is wrong
(REAmo loaded, REAPER's mappings unreadable, a bad setting, the script
stopping) or REAPER exits, which boot.sh fails any scenario on. What the
soak's checks would fail on (a ReaScript call unanswered for HANG_SECS, a
stopped transport, a moved undo history, a broken limit) it reports in
its summary. It has no WebSocket probe, so a stall shows only through the
ReaScript call (within RPC_SECS + SOAK_SAMPLE_SECS + HANG_SECS), and no
REAmo memory stats.
"""
import os
import runpy

runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "long-session-stays-healthy",
                            "test.py"), run_name="__main__")
