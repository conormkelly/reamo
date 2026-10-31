"""Hosts tests/ws-integration for scripts/harness/ws-integration.sh.

Opens test-fixtures/test-project-1.RPP, the project the specs assert
against, says so, then keeps REAPER up while the suite runs from a container
sharing this one's network. The runner ends the wait by writing the suite's
exit status to STATUS, which becomes this script's, so boot.sh's verdict
covers both the suite and whether REAPER survived it.
"""
import os
import sys
import time

from reamo_client import open_project

STATUS = "/tmp/ws-integration-status"
TIMEOUT = float(os.environ.get("WS_INTEGRATION_TIMEOUT", "900"))

print("dialogs:", open_project("/tmp/fixtures/test-project-1.RPP"), flush=True)
print("WS-INTEGRATION READY", flush=True)

deadline = time.monotonic() + TIMEOUT
while not os.path.exists(STATUS):
    if time.monotonic() > deadline:
        print(f"no result from the suite within {TIMEOUT:.0f} s", flush=True)
        sys.exit(1)
    time.sleep(0.2)
with open(STATUS) as f:
    status = int(f.read().strip() or "1")
print(f"ws-integration suite exited {status}", flush=True)
sys.exit(status)
