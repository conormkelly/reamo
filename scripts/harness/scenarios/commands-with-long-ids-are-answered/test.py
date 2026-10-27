"""Every command that carries an id is answered, however long the id.

A client awaiting a reply matches it by id. Replies were formatted into
fixed 512-byte buffers, so an id near that size produced no reply at all:
success without a payload, errors and warnings alike, and the client waited
until its own timeout.
"""
import time
from reamo_client import Client

LONG = "x" * 1500

with Client(timeout=10) as c:
    c.wait_event("trackSkeleton")

    def ask(command, **params):
        c.send({"type": "command", "command": command, "id": LONG, **params})
        deadline = time.time() + 5
        while True:
            msg = c._next_message(deadline)
            if msg.get("type") == "response":
                return msg

    r = ask("transport/stop")  # handler sends no reply of its own
    assert r["id"] == LONG and r["success"], r
    r = ask("track/setMute", trackIdx=99, mute=1)  # error reply
    assert r["id"] == LONG and not r["success"], r
    r = ask("no/such/command")
    assert r["id"] == LONG and r["error"]["code"] == "UNKNOWN_COMMAND", r
    r = ask("undo/add", description="phone edit")  # reply naming the undo step
    assert r["id"] == LONG, r
