"""Renames sent the way a browser sends them (raw UTF-8, JSON.stringify escapes)
reach REAPER as valid UTF-8, and every event carrying the name stays valid UTF-8.

A WebSocket text frame that is not valid UTF-8 makes the browser fail the
connection, so a name cut in the middle of a character would disconnect every
client on every skeleton broadcast.
"""
import json
import os
import struct
import time

from reamo_client import Client, reaper


class BrowserClient(Client):
    """Sends JSON like JSON.stringify (non-ASCII as raw UTF-8) and records any
    text frame that is not valid UTF-8 instead of crashing on it."""

    bad_frames = []

    def send(self, obj):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        n = len(data)
        hdr = bytearray([0x81])
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        self.sock.sendall(bytes(hdr) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _recv_frame(self):
        opcode, payload = super()._recv_frame()
        if opcode == 1:
            try:
                payload.decode("utf-8")
            except UnicodeDecodeError as e:
                self.bad_frames.append((e, payload[:120]))
                payload = payload.decode("utf-8", "replace").encode("utf-8")
        return opcode, payload


def reaper_name_bytes(idx):
    hexname = reaper(f"""
local _, n = reaper.GetTrackName(reaper.GetTrack(0, {idx - 1}))
return (n:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
""")
    return bytes.fromhex(hexname or "")


NAMES = [
    ("CJK, 300 bytes", "ギ" * 100),
    ("accents, 400 bytes", "é" * 200),
    ("emoji at the cut", "x" * 253 + "🎤🎤"),
    ("emoji", "🎤 Lead Vox"),
    ("quotes and backslash", 'Vox "lead" \\ dbl'),
    ("tab", "Vox\tL"),
    ("backspace/formfeed", "A\bB\fC"),
]

with BrowserClient() as c:
    c.wait_event("trackSkeleton")
    assert c.command("track/subscribe", range={"start": 0, "end": 1})["success"]
    problems = []
    for label, name in NAMES:
        r = c.command("track/rename", trackIdx=1, name=name)
        stored = reaper_name_bytes(1)
        try:
            stored_text = stored.decode("utf-8")
        except UnicodeDecodeError:
            problems.append(f"{label}: REAPER stored invalid UTF-8 {stored[-8:]!r} ({len(stored)} bytes)")
            stored_text = None
        want = name.encode("utf-8")
        if stored_text is not None:
            if len(want) <= 255 and stored_text != name:
                problems.append(f"{label}: REAPER stored {stored_text!r}, sent {name!r}")
            elif len(want) > 255 and not name.startswith(stored_text):
                problems.append(f"{label}: REAPER stored {stored_text[:20]!r}..., not a prefix of what was sent")
        # Let skeleton (1 Hz) and tracks (30 Hz) carry the new name to the client.
        deadline = time.time() + 2.5
        while time.time() < deadline:
            c.drain(0.2)
            ev = c.latest_event("trackSkeleton")
            skel = ev["payload"]["tracks"][1]["n"] if ev else None
            # The skeleton may shorten long names (128-byte buffer) but must show a prefix.
            if stored_text is None or (skel and stored_text.startswith(skel) and len(skel) >= min(len(stored_text), 40)):
                break
        if stored_text is not None and not (skel and stored_text.startswith(skel)):
            problems.append(f"{label}: skeleton shows {str(skel)[:30]!r}, REAPER has {stored_text[:30]!r}")
        c.events.clear()
        print(f"{label:>22}: success={r['success']} sent {len(want)} B, REAPER {len(stored)} B, "
              f"valid={stored_text is not None}")
    for e, head in BrowserClient.bad_frames[:3]:
        problems.append(f"server sent a text frame that is not UTF-8 ({e.reason} at {e.start}): {head!r}")
    if BrowserClient.bad_frames:
        problems.append(f"{len(BrowserClient.bad_frames)} invalid-UTF-8 text frames in total")
    assert not problems, "\n".join(problems)
