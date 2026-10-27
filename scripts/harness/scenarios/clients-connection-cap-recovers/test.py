"""Past the 64-connection cap, extra sockets are refused, the clients already
connected keep working, and once sockets close the slots come back: a
reconnect storm (phones flapping on Wi-Fi) must not leak connection slots.
"""
import gc
import subprocess
import time

from reamo_client import Client, Closed

problems = []


def try_connect():
    try:
        c = Client(timeout=3)
        c.wait_event("transport", timeout=3)
        return c
    except (RuntimeError, Closed, OSError, TimeoutError) as e:
        return f"{type(e).__name__}: {str(e)[:40]}"  # not e: its traceback keeps the socket open


with Client() as first:
    first.wait_event("transport")
    held, refused = [], []
    for i in range(72):
        r = try_connect()
        (held if isinstance(r, Client) else refused).append(r)
    gc.collect()  # close the refused sockets now, as a browser giving up would
    print(f"connected {len(held)} more, refused {len(refused)}: {sorted(set(refused))}")
    if len(held) + 1 < 60:
        problems.append(f"only {len(held) + 1} clients fit, expected about 64")
    if not refused:
        problems.append("no connection was refused past the cap")
    try:
        r = first.command("debug/memoryStats", timeout=3)
        assert r["success"]
    except Exception as e:
        problems.append(f"an existing client stopped working at the cap: {e!r}")
    for c in held:
        c.close()

    # Storm: 150 quick connect/close cycles, some without even a hello.
    time.sleep(1.0)
    for i in range(150):
        try:
            c = Client(hello=(i % 3 != 0), timeout=3)
            if i % 2:
                c.drain(0.02)
            c.close()
        except Exception as e:
            problems.append(f"storm connect {i} failed: {e!r}")
            break
    time.sleep(2.0)

    # All slots must be free again: 60 concurrent clients connect.
    again = []
    for i in range(60):
        r = try_connect()
        if not isinstance(r, Client):
            problems.append(f"after the storm only {i} clients could connect ({r!r})")
            break
        again.append(r)
    for c in again:
        c.close()
    r = first.command("debug/memoryStats", timeout=3)
    assert r["success"], r
log = subprocess.run("grep -c 'CLIENT ADD' /tmp/reaper/Logs/reamo.log; grep 'CLIENT REMOVE' /tmp/reaper/Logs/reamo.log | tail -1",
                     shell=True, capture_output=True, text=True).stdout
print(log.strip())
assert not problems, "\n".join(problems)
