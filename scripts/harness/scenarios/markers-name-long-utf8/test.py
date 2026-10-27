"""Names typed on the phone reach REAPER whole, and never as broken UTF-8.

A marker renamed and a marker and region added from the phone, with a name
longer than 64 bytes whose 64th byte falls inside a multi-byte character.
The browser's JSON.stringify sends non-ASCII as raw UTF-8, so this test does
too (json.dumps(ensure_ascii=False)).
"""
import json
import os
import struct
import time
from reamo_client import Client, reaper

NAME = "Estribillo — versión acústica, guitarra y voz principal, ¡última!"  # 71 bytes


def cut_mid_char(b, n):
    try:
        b[:n].decode("utf-8")
        return False
    except UnicodeDecodeError:
        return True


assert len(NAME.encode()) > 64 and cut_mid_char(NAME.encode(), 64)


def send_like_browser(c, obj):
    data = json.dumps(obj, ensure_ascii=False).encode()
    n = len(data)
    hdr = bytearray([0x81])
    if n < 126:
        hdr.append(0x80 | n)
    else:
        hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
    mask = os.urandom(4)
    c.sock.sendall(bytes(hdr) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


# Names as hex so invalid UTF-8 survives the RPC.
NAMES = """
local out = {}
local i = 0
while true do
  local ok, isrgn, pos, rend, name, id = reaper.EnumProjectMarkers(i)
  if ok == 0 then break end
  out[#out + 1] = {isrgn and "region" or "marker", pos, (name:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))}
  i = i + 1
end
return out
"""

with Client() as c:
    c.wait_event("markers")
    send_like_browser(c, {"type": "command", "command": "marker/update", "id": 1, "name": NAME})
    send_like_browser(c, {"type": "command", "command": "marker/add", "position": 20.0, "name": NAME})
    send_like_browser(c, {"type": "command", "command": "region/add", "start": 24.0, "end": 28.0, "name": NAME})
    deadline = time.time() + 2
    while True:
        got = reaper(NAMES)
        if len(got) == 4 or time.time() > deadline:
            break
        time.sleep(0.1)
    problems = []
    for kind, pos, hexname in got:
        raw = bytes.fromhex(hexname)
        if raw == b"Verse":
            continue
        try:
            text = raw.decode("utf-8")
            note = ""
        except UnicodeDecodeError as e:
            text = raw.decode("utf-8", "replace")
            note = f" INVALID UTF-8 ({e.reason} at byte {e.start})"
        print(f"  {kind} @{pos}: {len(raw)} bytes {text!r}{note}")
        if raw != NAME.encode():
            problems.append(f"{kind} @{pos}: REAPER holds {len(raw)} bytes{note}, phone sent {len(NAME.encode())}")
    assert not problems, "\n".join(problems)
