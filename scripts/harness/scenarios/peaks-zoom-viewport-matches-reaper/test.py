"""Zooming the timeline re-sends peaks at the finer level, matching REAPER's peaks.

The timeline subscribes with its whole-song viewport, then the user pinches
in on 10-12 s (peaks/updateViewport). The finer tiles must show the loud
accent exactly where REAPER's GetMediaItemTake_Peaks puts it. MIDI and empty
items on subscribed tracks get no tiles and break nothing. After
peaks/unsubscribe, edits in REAPER send no more peaks frames.
"""
import struct
import time
from reamo_client import Client, reaper

REAPER_TILE_PEAK = """
local tk = reaper.GetActiveTake(reaper.GetTrackMediaItem(reaper.GetTrack(0, 0), 0))
local rate, start, len = %f, %f, %f
local n = math.floor(rate * len + 0.5)
local buf = reaper.new_array(n * 2)
reaper.GetMediaItemTake_Peaks(tk, rate, start, 1, n, 0, buf)
local m, loud = 0, 0
for i = 1, n do
  m = math.max(m, math.abs(buf[i]))
  if math.abs(buf[i]) > 0.5 then loud = loud + 1 end
end
return {m, loud}
"""
DURATION = [4096, 1024, 256, 64, 16, 4, 1]


def tiles(frame):
    assert frame[0] == 2, frame[0]
    count = struct.unpack_from("<H", frame, 2)[0]
    off, out = 4, []
    for _ in range(count):
        lod, ch, idx, npk, _r, epoch, start, itempos = struct.unpack_from("<BBHHHIff", frame, off)
        off += 20
        guid = frame[off:off + 40].rstrip(b"\0").decode()
        off += 40
        data = struct.unpack_from(f"<{npk * ch * 2}b", frame, off)
        off += npk * ch * 2
        loud = [p for p in range(npk) if max(abs(v) for v in data[p * ch * 2:(p + 1) * ch * 2]) > 64]
        out.append({"guid": guid, "lod": lod, "idx": idx, "npk": npk, "item": itempos, "ch": ch,
                    "loud": (loud[0], loud[-1], len(loud)) if loud else None,
                    "peak": max(abs(v) for v in data) / 127})
    assert off == len(frame), f"frame has {len(frame) - off} trailing bytes"
    return out


def next_frame(c, after, timeout=3):
    deadline = time.time() + timeout
    while len(c.binary) <= after and time.time() < deadline:
        c.drain(0.1)
    assert len(c.binary) > after, "no peaks frame arrived"
    return tiles(c.binary[after])


def check_against_reaper(ts, label):
    bad = []
    for t in ts:
        dur = DURATION[t["lod"]]
        start = t["item"] + t["idx"] * dur
        want_peak, want_loud = reaper(REAPER_TILE_PEAK % (t["npk"] / dur, start, dur))
        got_loud = t["loud"][2] if t["loud"] else 0
        # Peak windows may straddle a tile edge by one peak; allow that much.
        if abs(got_loud - want_loud) > 1 or (want_loud > 1 and abs(t["peak"] - want_peak) > 0.03):
            bad.append(f"tile {t['idx']} ({start:g}-{start + dur:g} s): phone {got_loud} loud peaks (max {t['peak']:.2f}), "
                       f"REAPER {want_loud} (max {want_peak:.2f})")
    print(f"  {label}: lod {sorted({t['lod'] for t in ts})}, tiles "
          + ", ".join(f"{t['idx']}:{t['peak']:.2f}" for t in ts))
    return bad


with Client() as c:
    items = c.wait_event("items")["payload"]["items"]
    audio = next(i["activeTakeGuid"] for i in items if i["trackIdx"] == 1)
    r = c.command("peaks/subscribe", range={"start": 1, "end": 3},
                  viewport={"start": 0, "end": 30, "widthPx": 400})
    assert r["success"], r
    ts = next_frame(c, 0)
    assert {t["guid"] for t in ts} == {audio}, f"tiles for takes other than the audio one: {ts}"
    bad = check_against_reaper(ts, "whole song")
    c.drain(0.6)  # the first poll after subscribing may re-send the whole-song tiles
    print(f"  whole-song frames before zooming: {len(c.binary)}")

    n = len(c.binary)
    r = c.command("peaks/updateViewport", viewport={"start": 10, "end": 12, "widthPx": 400})
    assert r["success"], r
    ts = next_frame(c, n)
    zoom_lods = {t["lod"] for t in ts}
    bad += check_against_reaper(ts, "zoomed 10-12 s")
    assert zoom_lods == {6}, f"zoomed to 2 s but got LOD {zoom_lods}"
    covered = sorted(t["idx"] for t in ts)
    assert 10 in covered and 11 in covered, f"zoomed tiles {covered} miss 10-12 s"
    assert not bad, "\n".join(bad)

    r = c.command("peaks/unsubscribe")
    assert r["success"], r
    n = len(c.binary)
    reaper('reaper.SetMediaItemInfo_Value(reaper.GetTrackMediaItem(reaper.GetTrack(0, 0), 0), "D_LENGTH", 20); reaper.UpdateArrange()')
    c.drain(1.0)
    assert len(c.binary) == n, f"{len(c.binary) - n} peaks frames after unsubscribe"
    r = c.command("peaks/updateViewport", viewport={"start": 0, "end": 5, "widthPx": 400})
    assert not r["success"] and r["error"]["code"] == "NOT_SUBSCRIBED", r
