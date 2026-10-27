"""Markers and regions events are valid UTF-8 even when a REAPER name is cut.

A text WebSocket frame that is not valid UTF-8 makes browsers fail the
connection (close 1007), and the snapshot on reconnect carries the same
bytes, so one long accented marker name would keep every phone offline.
"""
import json
from reamo_client import Client, oracle

assert int(oracle()["name_len"]) > 128


def raw_text_frames(c, seconds):
    """Read raw frames without json-decoding them; returns text payloads."""
    import time
    out = []
    deadline = time.time() + seconds
    while time.time() < deadline:
        c.sock.settimeout(max(0.01, deadline - time.time()))
        try:
            opcode, payload = c._recv_frame()
        except Exception:
            break
        if opcode == 1:
            out.append(payload)
    return out


c = Client()
frames = raw_text_frames(c, 2.0)
c.close()
problems = []
seen = set()
for p in frames:
    try:
        text = p.decode("utf-8")
    except UnicodeDecodeError as e:
        head = p[:60].decode("utf-8", "replace")
        problems.append(f"invalid UTF-8 at byte {e.start}: {head}...")
        continue
    msg = json.loads(text)
    if msg.get("type") == "event" and msg["event"] in ("markers", "regions"):
        seen.add(msg["event"])
        items = msg["payload"].get("markers") or msg["payload"].get("regions")
        print(f"  {msg['event']}: name {len(items[0]['name'].encode())} bytes")
print(f"  {len(frames)} text frames, invalid: {len(problems)}")
assert not problems, "\n".join(problems)
assert seen == {"markers", "regions"}, seen
