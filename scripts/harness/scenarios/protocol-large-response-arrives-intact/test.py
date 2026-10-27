"""A large response (the action list, ~700 KB) reaches a client that reads at
network speed, whole, and the connection keeps working afterwards.

The action picker awaits action/getActions with the UI's 5 s timeout. A phone
on Wi-Fi drains 700 KB over a few hundred milliseconds, so the server must
cope with the socket filling up mid-frame. The client here pauses 1 s before
reading, which is what a slow link looks like from the server's side.
"""
import subprocess
import time

from reamo_client import Client

with Client(timeout=10) as c:
    c.wait_event("transport")
    c.drain(0.5)
    c.send({"type": "command", "command": "action/getActions", "id": "big"})
    time.sleep(1.0)  # a slow link: the server's writes outpace the reader
    r = None
    deadline = time.time() + 5
    try:
        while r is None:
            msg = c._next_message(deadline)
            if msg.get("type") == "response" and msg.get("id") == "big":
                r = msg
    except TimeoutError:
        pass
    except Exception as e:  # a torn frame shows up as garbage JSON
        print("stream corrupt:", type(e).__name__, str(e)[:200])
    log = subprocess.run(
        "grep -E 'getActions|WebSocket write error' /tmp/reaper/Logs/reamo.log | tail -5",
        shell=True, capture_output=True, text=True).stdout
    print(log.strip())
    assert r is not None, "no getActions response within the UI's 5 s"
    assert r["success"] and len(r["payload"]) > 1000, r.get("error")
    print(f"getActions: {len(r['payload'])} actions")

    # The socket must still carry ordinary traffic afterwards.
    r2 = c.command("debug/memoryStats", timeout=3)
    assert r2["success"], r2
