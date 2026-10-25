"""A long non-ASCII playlist name is stored and sent as valid UTF-8.

Names are capped at 128 bytes. A user typing a long German/Japanese/emoji
name past the cap must not get a name cut through the middle of a
character: browsers drop the whole WebSocket on a text frame with invalid
UTF-8, and the playlist event goes to every client on every connect.
"""
import json
import types

import reamo_client
from reamo_client import Client

reamo_client.json = types.SimpleNamespace(
    dumps=lambda o: json.dumps(o, separators=(",", ":"), ensure_ascii=False), loads=json.loads, load=json.load)

NAME = "Größte Hits! " + "ü" * 70  # 15 + 140 bytes: byte 128 falls inside a 2-byte char
assert len(NAME.encode()) > 128

with Client() as c:
    c.wait_event("playlist")
    c.send({"type": "command", "command": "playlist/create", "id": "p1", "name": NAME})
    # Read raw frames so an invalid-UTF-8 payload is reported, not a client crash.
    bad = None
    got = None
    for _ in range(200):
        try:
            opcode, payload = c._recv_frame()
        except Exception as e:
            break
        if opcode != 1:
            continue
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError as e:
            bad = (payload[max(0, e.start - 20):e.end + 5], str(e))
            break
        msg = json.loads(text)
        if msg.get("event") == "playlist" and msg["payload"]["playlists"]:
            got = msg["payload"]["playlists"][0]["name"]
            break
    assert bad is None, f"server sent a text frame that is not UTF-8: {bad}"
    assert got is not None, "no playlist event after create"
    print(f"stored name: {len(got.encode())} bytes: {got!r}")
    assert NAME.startswith(got), got

# A fresh client (a phone connecting later) gets the same, valid, snapshot.
with Client() as d:
    ev = d.wait_event("playlist")
    assert ev["payload"]["playlists"][0]["name"] == got
