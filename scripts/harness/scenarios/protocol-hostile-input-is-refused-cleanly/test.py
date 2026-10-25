"""Garbage on the socket never crashes REAPER, never wedges the connection,
and never does something other than what was asked.

Malformed JSON, missing/duplicate ids, unknown commands, and wrong
parameter types (strings for numbers, arrays, objects, floats, huge numbers,
"NaN") for the session commands. After each one the same connection must
still answer a normal command, and REAPER's state must be unchanged where
the input was invalid.
"""
import json
import struct
import os
import time

from reamo_client import Client, Closed, reaper

seq = [0]


def alive(c, what):
    seq[0] += 1
    rid = f"probe{seq[0]}"
    c.send({"type": "command", "command": "debug/memoryStats", "id": rid})
    deadline = time.time() + 3
    while True:
        m = c._next_message(deadline)  # raises TimeoutError -> test fails
        if m.get("type") == "response" and m.get("id") == rid:
            return


def send_raw_text(c, data: bytes):
    hdr = bytearray([0x81])
    n = len(data)
    if n < 126:
        hdr.append(0x80 | n)
    elif n < 65536:
        hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
    mask = os.urandom(4)
    c.sock.sendall(bytes(hdr) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def reply(c, rid, timeout=2):
    deadline = time.time() + timeout
    try:
        while True:
            m = c._next_message(deadline)
            if m.get("id") == rid:
                return m
    except TimeoutError:
        return None


PLAYLISTS = "local _, n = reaper.GetProjExtState(0, 'Reamo', 'PlaylistCount'); return n"
problems = []
with Client() as c:
    c.wait_event("playlist")
    # 1. Not JSON / broken JSON / no command / unknown command.
    for raw in [b"hello world", b'{"type":"command","command":"debug/memoryStats","id":"t1"',
                b'{"type":"command","id":"t2"}', b"\xff\xfe\x00garbage", b"[]", b"null", b'{"type":5}']:
        send_raw_text(c, raw)
        alive(c, raw)
    c.send({"type": "command", "command": "no/such", "id": "u1"})
    r = reply(c, "u1")
    if not r or r.get("error", {}).get("code") != "UNKNOWN_COMMAND":
        problems.append(f"unknown command: {r}")
    c.send({"type": "command", "command": "no/such"})  # no id: silent, connection fine
    alive(c, "unknown without id")

    # 2. Duplicate ids: each command gets its own response.
    for _ in range(2):
        c.send({"type": "command", "command": "debug/memoryStats", "id": "dup"})
    got = 0
    deadline = time.time() + 2
    try:
        while got < 2:
            m = c._next_message(deadline)
            got += m.get("id") == "dup"
    except TimeoutError:
        problems.append(f"duplicate id: got {got} of 2 responses")

    # 3. Wrong types for playlist/notes/midi params: refused, nothing created.
    bad = [
        ("playlist/create", {"name": 123}), ("playlist/create", {"name": None}),
        ("playlist/create", {"name": ["a"]}), ("playlist/create", {"name": {"x": "y"}}),
        ("playlist/addEntry", {"playlistIdx": "0", "regionId": 1}),
        ("playlist/addEntry", {"playlistIdx": 0, "regionId": "1"}),
        ("playlist/addEntry", {"playlistIdx": 99999999999999, "regionId": 1}),
        ("playlist/setLoopCount", {"playlistIdx": 0, "entryIdx": 0, "loopCount": "NaN"}),
        ("midi/cc", {"cc": "64", "value": 1}), ("midi/cc", {"cc": 64, "value": 128}),
        ("midi/cc", {"cc": 1.5, "value": 2}), ("midi/pitchBend", {"value": 16384}),
        ("midi/noteOn", {"note": -1, "velocity": 100}), ("midi/pc", {"program": [1]}),
        ("projectNotes/set", {"notes": 5}), ("projectNotes/set", {"notes": None}),
        ("action/execute", {"commandId": "40044"}), ("action/execute", {"commandId": 1e30}),
    ]
    notes_before = reaper("return select(1, reaper.GetSetProjectNotes(0, false, ''))")
    for i, (cmd, params) in enumerate(bad):
        rid = f"bad{i}"
        c.send({"type": "command", "command": cmd, "id": rid, **params})
        r = reply(c, rid)
        verdict = "no response" if r is None else ("ok" if r["success"] else r["error"]["code"])
        print(f"  {cmd:24s} {json.dumps(params):55.55s} -> {verdict}")
        if r is None:
            problems.append(f"{cmd} {params}: no response (the UI would wait out its timeout)")
        elif r["success"]:
            problems.append(f"{cmd} {params}: accepted")
        alive(c, cmd)
    c.drain(0.5)
    ev = c.latest_event("playlist")  # none since connect: nothing was created
    pl = ev["payload"]["playlists"] if ev else []
    if pl:
        problems.append(f"invalid playlist/create calls created playlists: {pl}")
    if reaper("return select(1, reaper.GetSetProjectNotes(0, false, ''))") != notes_before:
        problems.append("invalid projectNotes/set changed the notes")
    if reaper("return reaper.GetPlayState()") != 0:
        problems.append("a malformed action/execute started the transport")

# 4. An oversize frame (1 MB) closes only that connection.
with Client() as big, Client() as other:
    other.wait_event("transport")
    try:
        send_raw_text(big, json.dumps({"type": "command", "command": "projectNotes/set", "id": "huge",
                                       "notes": "x" * (1 << 20)}).encode())
        r = reply(big, "huge", timeout=3)
        print("oversize frame ->", None if r is None else r.get("error") or "ok")
    except (Closed, OSError) as e:
        print("oversize frame -> connection closed:", e)
    alive(other, "other client after oversize frame")
assert not problems, "\n".join(problems)
