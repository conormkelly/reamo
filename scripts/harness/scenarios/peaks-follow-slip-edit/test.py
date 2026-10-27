"""The waveform a phone shows follows a slip edit made in REAPER.

The item shows the silent first half of its file. The user slip-edits it in
REAPER (take start offset 2 s) so it now shows the loud half. A new peaks
frame arrives (the track's items changed); its tiles must show the loud
audio, as REAPER's own peaks for the item do.
"""
import struct
import time
from reamo_client import Client, reaper

REAPER_PEAK = """
local it = reaper.GetTrackMediaItem(reaper.GetTrack(0, 0), 0)
local tk = reaper.GetActiveTake(it)
local n = 200
local buf = reaper.new_array(n * 2)
local rv = reaper.GetMediaItemTake_Peaks(tk, 100, 0, 1, n, 0, buf)
local m = 0
for i = 1, n do m = math.max(m, math.abs(buf[i])) end
return m
"""


def tiles(frame):
    assert frame[0] == 2, f"not a peaks frame: type {frame[0]}"
    count = struct.unpack_from("<H", frame, 2)[0]
    off, out = 4, []
    for _ in range(count):
        lod, ch, idx, npk, _r, epoch, start, itempos = struct.unpack_from("<BBHHHIff", frame, off)
        off += 20
        guid = frame[off:off + 40].rstrip(b"\0").decode()
        off += 40
        data = struct.unpack_from(f"<{npk * ch * 2}b", frame, off)
        off += npk * ch * 2
        out.append({"guid": guid, "lod": lod, "idx": idx, "start": start, "peak": max(abs(v) for v in data) if data else 0})
    return out


def wait_frame(c, after, timeout=3):
    deadline = time.time() + timeout
    while len(c.binary) <= after and time.time() < deadline:
        c.drain(0.1)
    assert len(c.binary) > after, "no peaks frame arrived"
    c.drain(0.3)
    return tiles(c.binary[-1])


def peak_of(ts, guid):
    mine = [t["peak"] for t in ts if t["guid"] == guid]
    assert mine, f"no tiles for take {guid}"
    return max(mine) / 127


with Client() as c:
    items = c.wait_event("items")["payload"]["items"]
    take = {i["trackIdx"]: i["activeTakeGuid"] for i in items}
    r = c.command("peaks/subscribe", range={"start": 1, "end": 2},
                  viewport={"start": 0, "end": 4, "widthPx": 400})
    assert r["success"], r
    ts = wait_frame(c, 0)
    want = reaper(REAPER_PEAK)
    print(f"before slip: {len(ts)} tiles, item {peak_of(ts, take[1]):.2f}, control {peak_of(ts, take[2]):.2f}; REAPER item {want:.2f}")
    assert want < 0.01 and peak_of(ts, take[1]) < 0.01, ts
    assert abs(peak_of(ts, take[2]) - 0.8) < 0.05, f"control item (loud half) shows {peak_of(ts, take[2]):.2f}"

    n = len(c.binary)
    reaper('local tk = reaper.GetActiveTake(reaper.GetTrackMediaItem(reaper.GetTrack(0, 0), 0)); '
           'reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", 2); reaper.UpdateArrange()')
    ts = wait_frame(c, n)
    want = reaper(REAPER_PEAK)
    got = peak_of(ts, take[1])
    print(f"after slip:  {len(ts)} tiles, max peak {got:.2f}; REAPER max {want:.2f}")
    assert want > 0.7, want
    assert abs(got - want) < 0.05, \
        f"phone waveform shows {got:.2f} peak after the slip edit, REAPER's peaks for the item are {want:.2f}"
