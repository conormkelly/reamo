"""Nothing about the session reaches a socket that has not passed the hello
handshake: no commands run, and no state events (track names, markers,
notes, playlists) are pushed to it. Wrong tokens and protocol versions are
refused with their close codes, and the server keeps serving real clients.
"""
import time

from reamo_client import Client, Closed, fetch_token, reaper


def close_code(c, seconds=2):
    deadline = time.time() + seconds
    try:
        while time.time() < deadline:
            c._next_message(deadline)
    except Closed as e:
        return str(e)
    except TimeoutError:
        return None


problems = []
token = fetch_token()

# 1. A socket that never says hello, while REAPER's state changes.
with Client(hello=False) as lurker, Client() as phone:
    phone.wait_event("markers")
    for i in range(3):
        reaper(f'reaper.AddProjectMarker2(0, false, {i + 1}, 0, "Secret marker {i}", -1, 0); reaper.UpdateTimeline()')
    reaper('reaper.GetSetProjectNotes(0, true, "private notes")')
    lurker.drain(2.0)
    phone.drain(0.1)
    leaked = sorted({name for name, _ in lurker.events})
    if leaked:
        problems.append(f"unauthenticated socket received events: {leaked}")
    print("phone got:", sorted({n for n, _ in phone.events}), "| lurker got:", leaked)

    # Commands before hello are refused (and must not run).
    before = reaper("return ({reaper.CountProjectMarkers(0)})[2]")
    lurker.send({"type": "command", "command": "marker/add", "id": "x1", "position": 9, "name": "injected"})
    lurker.drain(0.5)
    after = reaper("return ({reaper.CountProjectMarkers(0)})[2]")
    if after != before:
        problems.append("a command sent before hello ran")

# 2. Wrong token, and a token-less hello: refused with 4001.
for label, hello in [("wrong token", {"type": "hello", "token": "0" * 32, "protocolVersion": 1}),
                     ("no token", {"type": "hello", "protocolVersion": 1})]:
    with Client(hello=False) as c:
        c.send(hello)
        code = close_code(c)
        if not code or "0fa1" not in code:  # 4001 = 0x0fa1
            problems.append(f"{label}: expected close 4001, got {code}")

# 3. A newer client protocol: refused with 4002.
with Client(hello=False) as c:
    c.send({"type": "hello", "token": token, "protocolVersion": 2, "clientVersion": "future"})
    code = close_code(c)
    if not code or "0fa2" not in code:  # 4002
        problems.append(f"protocolVersion 2: expected close 4002, got {code}")

# The server still serves a real client.
with Client() as c:
    assert c.command("debug/memoryStats")["success"]
assert not problems, "\n".join(problems)
