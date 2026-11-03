"""Compare the waveform tiles REAmo sends with REAPER's own peaks for a take.

REAPER's arrange view draws a take's waveform from the same peaks that
GetMediaItemTake_Peaks returns: the take's source as the take plays it
(section, reverse, start offset, playrate, loop, stretch markers, channel
mode) with fades, item and take volume, take pan and take envelopes applied.
So `reaper_profile` is the oracle, and `reamo_profile` reads the same span
out of REAmo's tiles.

Both are summarised per bin (half a second by default): the highest maximum
and lowest minimum of the first channel, or of each channel. Comparing bins
rather than single peaks keeps the check off REAmo's tile edges and the
int8 quantisation (1/127).

The fixtures use `harness.staircase_wav`: a 200 Hz square wave whose level
steps up by 0.1 each second (0.1 in the first second, 0.8 in the eighth), so
the order and spacing of the steps shows which part of the file an item
plays, and when.
"""
import json
import os
import struct
import time

from reamo_client import reaper, screenshot, WINDOWS

# Seconds per tile at each LOD (peaks_tile.zig TILE_CONFIGS).
TILE_SECONDS = [4096, 1024, 256, 64, 16, 4, 1]


def decode(frame):
    """Tiles of one binary peaks frame (type 2), as dicts."""
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
        out.append({"guid": guid, "lod": lod, "idx": idx, "npk": npk, "ch": ch, "epoch": epoch,
                    "item": itempos, "data": data})
    assert off == len(frame), f"frame has {len(frame) - off} trailing bytes"
    return out


def tiles_since(client, n=0):
    """Every tile in the client's binary frames from the n-th on."""
    out = []
    for fr in client.binary[n:]:
        out += decode(fr)
    return out


def wait_tiles(client, n=0, timeout=3.0, settle=0.5):
    """Wait for a peaks frame after the n-th, let any follow-up arrive, and
    return every tile since the n-th."""
    deadline = time.time() + timeout
    while len(client.binary) <= n and time.time() < deadline:
        client.drain(0.1)
    assert len(client.binary) > n, "no peaks frame arrived"
    client.drain(settle)
    return tiles_since(client, n)


def take_tiles(tiles, guid):
    """The take's tiles, the latest copy of each (lod, index)."""
    latest = {}
    for t in tiles:
        if t["guid"] == guid:
            latest[(t["lod"], t["idx"])] = t
    return list(latest.values())


def reamo_profile(tiles, length, bin_s=0.5):
    """{"channels", "epochs", "max": [[per bin] per channel], "min": ...} of a
    take's tiles over the item's first `length` seconds."""
    nb = int(length / bin_s + 0.5)
    chans = max((t["ch"] for t in tiles), default=0)
    mx = [[0.0] * nb for _ in range(chans)]
    mn = [[0.0] * nb for _ in range(chans)]
    for t in tiles:
        dur = TILE_SECONDS[t["lod"]]
        for p in range(t["npk"]):
            b = int((t["idx"] * dur + (p + 0.5) * dur / t["npk"]) / bin_s)
            if b >= nb:
                continue
            for c in range(t["ch"]):
                lo, hi = t["data"][(p * t["ch"] + c) * 2] / 127, t["data"][(p * t["ch"] + c) * 2 + 1] / 127
                mx[c][b] = max(mx[c][b], hi)
                mn[c][b] = min(mn[c][b], lo)
    return {"channels": sorted({t["ch"] for t in tiles}), "epochs": sorted({t["epoch"] for t in tiles}),
            "max": mx, "min": mn}


# GetMediaItemTake_Peaks for the first item on track `ti` (0-based), over the
# item, two channels. Returns the take's GUID, the item's length, the count
# of peaks REAPER returned and asked for, and per-bin max/min per channel.
# The minimum block starts after `n` (the count asked for) maximum peaks, not
# after the count returned: see peaks-item-past-its-source-end-known-gap.
_REAPER_PROFILE = """
local ti, rate, bin = %d, %f, %f
local it = reaper.GetTrackMediaItem(reaper.GetTrack(0, ti), 0)
local tk = reaper.GetActiveTake(it)
local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
local _, guid = reaper.GetSetMediaItemTakeInfo_String(tk, "GUID", "", false)
local n = math.floor(len * rate + 0.5)
local buf = reaper.new_array(n * 4)
buf.clear()
local got = reaper.GetMediaItemTake_Peaks(tk, rate, pos, 2, n, 0, buf) & 0xfffff
local nb = math.floor(len / bin + 0.5)
local mx, mn = {{}, {}}, {{}, {}}
for c = 1, 2 do for b = 1, nb do mx[c][b] = 0; mn[c][b] = 0 end end
for i = 0, got - 1 do
  local b = math.floor((i + 0.5) / rate / bin) + 1
  if b <= nb then
    for c = 1, 2 do
      mx[c][b] = math.max(mx[c][b], buf[i * 2 + c])
      mn[c][b] = math.min(mn[c][b], buf[n * 2 + i * 2 + c])
    end
  end
end
return {guid, len, got, n, mx, mn}
"""


def reaper_profile(track_idx, rate=200.0, bin_s=0.5):
    guid, length, got, n, mx, mn = reaper(_REAPER_PROFILE % (track_idx, rate, bin_s), timeout=20)
    return {"guid": guid, "length": length, "got": got, "asked": n, "max": mx, "min": mn}


def track_index(name):
    return reaper(f"""
for ti = 0, reaper.CountTracks(0) - 1 do
  local _, n = reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(0, ti), "P_NAME", "", false)
  if n == {json.dumps(name)} then return ti end
end
return -1
""")


def subscribe_all(client, start=0, end=14, width_px=1400):
    """Subscribe to every track's peaks over start..end seconds (the finest
    LOD for a 14 s view) and return the tiles of the first frame."""
    n = len(client.binary)
    count = reaper("return reaper.CountTracks(0)")
    r = client.command("peaks/subscribe", range={"start": 1, "end": count},
                       viewport={"start": start, "end": end, "widthPx": width_px})
    assert r["success"], r
    return wait_tiles(client, n)


def compare(tiles, names, channels=1):
    """REAmo's tiles against REAPER's peaks for each named track's item.
    Returns ({name: (reamo profile or None, REAPER profile)}, [mismatch lines])."""
    profiles, bad = {}, []
    for name in names:
        want = reaper_profile(track_index(name))
        mine = take_tiles(tiles, want["guid"])
        if not mine:
            profiles[name] = (None, want)
            bad.append(f"{name}: REAmo sent no tiles for its take")
            continue
        got = reamo_profile(mine, want["length"])
        profiles[name] = (got, want)
        bad += mismatches(name, got, want, channels)
    return profiles, bad


def steps(*levels, per=2):
    """Expected per-bin levels: each level held for `per` half-second bins."""
    return [lv for lv in levels for _ in range(per)]


def near(row, want, tol=0.03):
    return len(row) == len(want) and all(abs(a - b) <= tol for a, b in zip(row, want))


def fmt(row):
    return " ".join(f"{v:+.2f}" for v in row)


def mismatches(label, got, want, channels=1, tol=0.03):
    """Lines describing the bins where REAmo's profile is off REAPER's."""
    bad = []
    for c in range(channels):
        for kind in ("max", "min"):
            g, w = got[kind][c], want[kind][c]
            if len(g) != len(w) or any(abs(a - b) > tol for a, b in zip(g, w)):
                bad.append(f"{label} ch{c} {kind}:\n  REAmo  {fmt(g)}\n  REAPER {fmt(w)}")
    return bad


def save(name, obj):
    """Write evidence (tiles, profiles) to out/<scenario>/<name>.json."""
    path = os.path.join(os.environ.get("HARNESS_OUT", "/tmp"), f"{name}.json")
    with open(path, "w") as f:
        json.dump(obj, f)
    return path


def screenshot_arrange(name, start=0.0, end=14.0):
    """Screenshot REAPER's arrange view showing start..end seconds, the
    tracks as tall as fit (110 px at most) and the mixer hidden: REAPER's own
    drawing of the waveforms, kept in out/<scenario>/ next to REAmo's tiles."""
    reaper(f"""
if reaper.GetToggleCommandState(40078) == 1 then reaper.Main_OnCommand(40078, 0) end
local count = reaper.CountTracks(0)
for ti = 0, count - 1 do
  reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, ti), "I_HEIGHTOVERRIDE", math.min(110, 830 // count))
end
reaper.TrackList_AdjustWindows(false)
reaper.GetSet_ArrangeView2(0, true, 0, 0, {start}, {end})
reaper.UpdateArrange()
""")
    if not WINDOWS:
        import subprocess
        # The main window's title is "<project> - REAPER v<version>..."
        r = subprocess.run(["xdotool", "search", "--onlyvisible", "--name", "REAPER v[0-9]"],
                           capture_output=True, text=True, timeout=10)
        if not r.stdout.split():
            print(f"screenshot_arrange: REAPER's main window not found ({r.returncode}: {r.stderr.strip()})")
        for wid in r.stdout.split():
            subprocess.run(["xdotool", "windowmove", wid, "0", "0", "windowsize", wid, "1600", "1000"], timeout=10)
        reaper(f"reaper.GetSet_ArrangeView2(0, true, 0, 0, {start}, {end}); reaper.UpdateArrange()")
    time.sleep(1.0)
    return screenshot(name)
