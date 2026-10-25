"""A phone that reconnects many times can still subscribe to action toggle states.

Phones drop and reopen the WebSocket constantly (screen lock, Wi-Fi roaming,
app switch). Every reconnect is a new client id. The toggle-button view
subscribes on each connect, so the 17th, 30th, 100th reconnect must work as
well as the first.
"""
import time

from reamo_client import Client, reaper

# Send compact JSON, as the browser's JSON.stringify does (see report: the
REPEAT = 1068  # Transport: Toggle repeat
CONNECTS = 20  # well past the 16 subscription slots

for n in range(1, CONNECTS + 1):
    with Client() as c:
        c.wait_event("transport")
        r = c.command("actionToggleState/subscribe", actions=[{"c": REPEAT, "s": 0}])
        assert r["success"], f"connect #{n}: subscribe failed after {n - 1} earlier sessions: {r}"
    time.sleep(0.15)  # let the main thread see the disconnect and clean up

# The subscription a reconnected phone holds must still deliver changes.
with Client() as c:
    r = c.command("actionToggleState/subscribe", actions=[{"c": REPEAT, "s": 0}])
    assert r["success"], r
    before = reaper(f"return reaper.GetToggleCommandState({REPEAT})")
    reaper(f"reaper.Main_OnCommand({REPEAT}, 0)")
    deadline = time.time() + 3
    got = None
    while time.time() < deadline and got is None:
        c.drain(0.2)
        for name, msg in c.events:
            if name == "actionToggleState":
                for ch in msg["payload"]["changes"]:
                    if ch["c"] == REPEAT:
                        got = ch["v"]
    assert got == 1 - before, f"toggle change not delivered: REAPER went {before}->{1 - before}, client saw {got}"
print(f"{CONNECTS} reconnects, every subscribe succeeded")
